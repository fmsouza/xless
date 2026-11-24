import Crypto
import Foundation
import XlessCore

/// Makes an HFS+ volume made by mkfs.hfsplus and libdmg-hfsplus independent of when it was made. Both tools stamp the
/// time of the run: mkfs on the volume header (create, modify, checked) and the root folder, `hfsplus` on every folder,
/// file and symlink it adds (libdmg never reads the source's mtimes), and mkfs draws a random volume UUID. `pin`
/// rewrites, in place:
/// - every non-zero date of a catalog folder or file record to the source's own date for that path (`date`), else
///   `fallback` (the volume root, the `/Applications` link, what mkfs made itself);
/// - every non-zero date of the volume header and its alternate copies to `fallback` (mkfs writes one 1024 bytes before
///   the end of the image, libdmg one 1024 bytes before the end of the last allocation block: two places when the
///   image is not a whole number of blocks);
/// - the volume UUID (Finder info words 6 and 7, when mkfs set one) to the first 8 bytes of the SHA-256 of the pinned
///   volume with those words zeroed: stable for the same content, different for other content.
/// Structures as in Apple's TN1150 (big-endian). Dates are seconds since 1904-01-01 UTC; the volume header's create
/// date is local time by the letter of TN1150, but pinned to the same UTC value so the time zone cannot change it.
enum HFSPlusDates {
    /// What `read` finds: the volume header's four dates (create, modify, backup, checked) and UUID, and those of each
    /// alternate copy (in file order),
    /// and the five dates (create, content modify, attribute modify, access, backup) of every catalog folder or file
    /// record, by path from the volume root ("" is the root; `#<id>` for a name that is not libdmg's encoding).
    struct Snapshot: Equatable {
        var volumeDates: [UInt32], alternateVolumeDates: [[UInt32]]
        var volumeID: [UInt8], alternateVolumeIDs: [[UInt8]]
        var entries: [String: [UInt32]]
    }

    static let secondsFrom1904To1970: Int64 = 2_082_844_800

    /// The HFS+ value of `date`: whole seconds since 1904, clamped to what 32 bits hold (1904 to 2040).
    static func hfsDate(_ date: Date) -> UInt32 {
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down)) + secondsFrom1904To1970
        return UInt32(clamping: seconds)
    }

    /// Rewrites the dates and the volume UUID of the volume in `image` (see the type's comment). `date` is asked for the
    /// path of every catalog entry relative to the volume root, as `/`-joined names (the root itself is never asked).
    static func pin(image: URL, fallback: Date, date: (String) -> Date?) throws {
        try reportingIOErrors(image) { try pinVolume(image: image, fallback: fallback, date: date) }
    }

    private static func pinVolume(image: URL, fallback: Date, date: (String) -> Date?) throws {
        var volume = try Volume(image)
        let fallbackValue = hfsDate(fallback)
        for record in try volume.records() where record.isEntry {
            let value = record.path.flatMap { $0.isEmpty ? nil : date($0) }.map(hfsDate) ?? fallbackValue
            for offset in Volume.entryDateOffsets where volume.catalog.u32(record.offset + offset) != 0 {
                volume.catalog.setU32(record.offset + offset, value)
            }
        }
        // The main header is index 0, then the alternates.
        var headers = [volume.header] + volume.alternates.map(\.bytes)
        var hadID: [Bool] = []
        for h in headers.indices {
            for offset in Volume.headerDateOffsets where headers[h].u32(offset) != 0 { headers[h].setU32(offset, fallbackValue) }
            hadID.append(headers[h][Volume.idOffset..<Volume.idOffset + 8].contains { $0 != 0 })
            headers[h].replaceSubrange(Volume.idOffset..<Volume.idOffset + 8, with: [UInt8](repeating: 0, count: 8))
        }
        volume.setHeaders(headers)
        try volume.write()
        guard hadID.contains(true) else { return }
        let id = try volume.digest()
        for h in headers.indices where hadID[h] { headers[h].replaceSubrange(Volume.idOffset..<Volume.idOffset + 8, with: id) }
        volume.setHeaders(headers)
        try volume.writeHeaders()
    }

    /// The volume's dates and UUID, read without changing anything.
    static func read(image: URL) throws -> Snapshot {
        try reportingIOErrors(image) { try snapshot(image) }
    }

    /// A Foundation error from opening, reading or writing the image, as an `XlessError` of the package stage.
    private static func reportingIOErrors<T>(_ image: URL, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as XlessError { throw e } catch { throw failure(image, "\(error)") }
    }

    private static func snapshot(_ image: URL) throws -> Snapshot {
        let volume = try Volume(image)
        var entries: [String: [UInt32]] = [:]
        for record in try volume.records() where record.isEntry {
            entries[record.path ?? "#\(record.id)"] = Volume.entryDateOffsets.map { volume.catalog.u32(record.offset + $0) }
        }
        return Snapshot(volumeDates: Volume.headerDateOffsets.map { volume.header.u32($0) },
                        alternateVolumeDates: volume.alternates.map { a in Volume.headerDateOffsets.map { a.bytes.u32($0) } },
                        volumeID: Array(volume.header[Volume.idOffset..<Volume.idOffset + 8]),
                        alternateVolumeIDs: volume.alternates.map { Array($0.bytes[Volume.idOffset..<Volume.idOffset + 8]) },
                        entries: entries)
    }
}

private func failure(_ image: URL, _ reason: String) -> XlessError {
    XlessError(.package, "cannot pin the dates of the DMG volume \(image.lastPathComponent): \(reason)",
               fix: "re-run from package; if it persists, report it with the app's file count")
}

/// One HFS+ volume image: its volume header, the alternate copies and its catalog file, read into memory and written
/// back in place.
private struct Volume {
    static let headerOffset: UInt64 = 1024, headerSize = 512
    static let headerDateOffsets = [16, 20, 24, 28]          // createDate, modifyDate, backupDate, checkedDate
    static let idOffset = 80 + 24                             // finderInfo[6] and [7]
    static let entryDateOffsets = [12, 16, 20, 24, 28]        // folder and file records alike
    static let catalogFork = 272

    let image: URL
    let size: UInt64
    let blockSize: UInt64
    let extents: [(start: UInt64, count: UInt64)]
    var header: [UInt8], alternates: [(offset: UInt64, bytes: [UInt8])], catalog: [UInt8]

    init(_ image: URL) throws {
        self.image = image
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        size = try handle.seekToEnd()
        let notHFS = failure(image, "not an HFS+ volume")
        guard size >= Volume.headerOffset * 2 + UInt64(Volume.headerSize) else { throw notHFS }
        header = try handle.bytes(at: Volume.headerOffset, count: Volume.headerSize)
        guard header.u16(0) == 0x482B, header.u16(2) == 4 else { throw notHFS }                        // "H+", version 4
        blockSize = UInt64(header.u32(40))
        guard blockSize >= 512, blockSize <= 1 << 20, blockSize & (blockSize - 1) == 0 else { throw notHFS }
        // The alternate at the end of the image must be there; the one at the end of the blocks is libdmg's, when apart.
        // A copy is the volume's own when it agrees on the signature, version, block size and block count.
        let main = header
        func isCopy(_ h: [UInt8]) -> Bool { h.prefix(4) == main.prefix(4) && h[40..<48] == main[40..<48] }
        let endOfBlocks = UInt64(header.u32(44)) * blockSize
        guard endOfBlocks >= Volume.headerOffset * 2 + UInt64(Volume.headerSize), endOfBlocks <= size else { throw notHFS }
        var alternates: [(offset: UInt64, bytes: [UInt8])] = []
        for offset in Set([endOfBlocks - 1024, size - 1024]).sorted() where offset >= Volume.headerOffset + 512 {
            let h = try handle.bytes(at: offset, count: Volume.headerSize)
            if isCopy(h) { alternates.append((offset, h)) } else if offset == size - 1024 { throw notHFS }
        }
        guard !alternates.isEmpty else { throw notHFS }
        self.alternates = alternates
        let logicalSize = header.u64(Volume.catalogFork), totalBlocks = UInt64(header.u32(Volume.catalogFork + 12))
        var extents: [(start: UInt64, count: UInt64)] = []
        for i in 0..<8 {
            let at = Volume.catalogFork + 16 + 8 * i
            let start = UInt64(header.u32(at)), count = UInt64(header.u32(at + 4))
            guard count > 0 else { continue }
            guard (start + count) * blockSize <= size else { throw failure(image, "the catalog file lies outside the volume") }
            extents.append((start, count))
        }
        guard extents.map(\.count).reduce(0, +) >= totalBlocks, totalBlocks * blockSize >= logicalSize, logicalSize > 0 else {
            throw failure(image, "the catalog file continues in the extents overflow file (too many files for libdmg-hfsplus)")
        }
        self.extents = extents
        var catalog: [UInt8] = []
        for e in extents { catalog += try handle.bytes(at: e.start * blockSize, count: Int(e.count * blockSize)) }
        self.catalog = Array(catalog.prefix(Int(logicalSize)))
    }

    /// One catalog leaf record: its offset in `catalog` (of the record's data, after the key), type and catalog node ID,
    /// and its path when it is a folder or file whose names all decode.
    struct Record { var offset: Int; var type: UInt16; var id: UInt32; var path: String?
        var isEntry: Bool { type == 1 || type == 2 } }

    /// Every leaf record of the catalog B-tree, in leaf-chain order, with paths resolved through the thread records.
    func records() throws -> [Record] {
        let bad = { (what: String) in failure(image, "the catalog B-tree is damaged (\(what))") }
        guard catalog.count >= 512, catalog[8] == 1 else { throw bad("no header node") }
        let nodeSize = Int(catalog.u16(32)), totalNodes = Int(catalog.u32(36))
        guard nodeSize >= 512, nodeSize & (nodeSize - 1) == 0, totalNodes > 0, nodeSize * totalNodes <= catalog.count else {
            throw bad("node size \(nodeSize), \(totalNodes) nodes")
        }
        var records: [Record] = [], threads: [UInt32: (parent: UInt32, name: String?)] = [:]
        var node = Int(catalog.u32(24)), visited = 0
        while node != 0 {
            visited += 1
            guard node < totalNodes, visited <= totalNodes else { throw bad("leaf chain") }
            let base = node * nodeSize, end = base + nodeSize
            guard catalog[base + 8] == 0xFF else { throw bad("node \(node) is not a leaf") }
            for i in 0..<Int(catalog.u16(base + 10)) {
                let slot = end - 2 * (i + 1)
                guard slot >= base + 14 else { throw bad("node \(node) record count") }
                let start = base + Int(catalog.u16(slot))
                guard start >= base + 14, start + 2 <= slot else { throw bad("node \(node) record \(i) offset") }
                let data = start + 2 + Int(catalog.u16(start))
                guard data + 10 <= slot else { throw bad("node \(node) record \(i) size") }
                let type = catalog.u16(data)
                switch type {
                case 1, 2:
                    guard data + 32 <= slot else { throw bad("node \(node) record \(i) size") }
                    records.append(Record(offset: data, type: type, id: catalog.u32(data + 8), path: nil))
                case 3, 4:
                    let length = Int(catalog.u16(data + 8))
                    guard data + 10 + 2 * length <= slot else { throw bad("node \(node) record \(i) name") }
                    let units = (0..<length).map { catalog.u16(data + 10 + 2 * $0) }
                    threads[catalog.u32(start + 2)] = (catalog.u32(data + 4), Volume.libdmgName(units))
                default: throw bad("node \(node) record \(i) type \(type)")
                }
            }
            node = Int(catalog.u32(base))
        }
        func path(_ id: UInt32, depth: Int) -> String? {
            if id == 2 { return "" }                                  // the root folder
            guard depth < 1024, let thread = threads[id], let name = thread.name,
                  let parent = path(thread.parent, depth: depth + 1) else { return nil }
            return parent.isEmpty ? name : "\(parent)/\(name)"
        }
        return records.map { var r = $0; r.path = path(r.id, depth: 0); return r }
    }

    /// libdmg-hfsplus stores a name's UTF-8 bytes one per UTF-16 unit, sign-extended where `char` is signed (x86_64):
    /// the low bytes give the UTF-8 back. A name in any other encoding (mkfs's own) has no source path: nil.
    static func libdmgName(_ units: [UInt16]) -> String? {
        guard units.allSatisfy({ $0 <= 0xFF || $0 >= 0xFF80 }) else { return nil }
        return String(bytes: units.map { UInt8(truncatingIfNeeded: $0) }, encoding: .utf8)
    }

    mutating func setHeaders(_ headers: [[UInt8]]) {
        header = headers[0]
        for i in alternates.indices { alternates[i].bytes = headers[i + 1] }
    }

    /// Writes the catalog and every header back where they were read from.
    func write() throws {
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        var at = 0
        for e in extents where at < catalog.count {
            let count = min(Int(e.count * blockSize), catalog.count - at)
            try handle.seek(toOffset: e.start * blockSize)
            try handle.write(contentsOf: catalog[at..<at + count])
            at += count
        }
        try writeHeaders(handle)
    }

    func writeHeaders(_ open: FileHandle? = nil) throws {
        let handle = try open ?? FileHandle(forUpdating: image)
        defer { if open == nil { try? handle.close() } }
        try handle.seek(toOffset: Volume.headerOffset)
        try handle.write(contentsOf: header)
        for a in alternates {
            try handle.seek(toOffset: a.offset)
            try handle.write(contentsOf: a.bytes)
        }
    }

    /// The first 8 bytes of the SHA-256 of the whole image as it is on disk; never all zero (zero means "no UUID").
    func digest() throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: image)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        var id = Array(hash.finalize().prefix(8))
        if id.allSatisfy({ $0 == 0 }) { id[7] = 1 }
        return id
    }
}

private extension FileHandle {
    func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        try seek(toOffset: offset)
        let data = try read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw XlessError(.package, "cannot read \(count) bytes at \(offset) of the DMG volume", fix: "re-run from package")
        }
        return [UInt8](data)
    }
}

private extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) << 8 | UInt16(self[at + 1]) }
    func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(self[at + $1]) } }
    func u64(_ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 << 8 | UInt64(self[at + $1]) } }
    mutating func setU32(_ at: Int, _ value: UInt32) {
        for i in 0..<4 { self[at + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
    }
}
