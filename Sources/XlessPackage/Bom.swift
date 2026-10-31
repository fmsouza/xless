import Foundation
import XlessCore

/// The bill-of-materials (`Bom`) file of a macOS flat package: the byte format `/usr/bin/mkbom`
/// writes, decoded against that tool's output (see `Tests/XlessPackageTests/Fixtures`) plus the
/// open-source bomutils project's struct definitions.
///
/// A store is a 512-byte header pointing at a *vars* table and a *pointer table* (which closes
/// the file, ahead of a free list), plus the blocks the table addresses. Named vars hold
/// `BomInfo` (the path count and the byte total of all files), `Paths` (the file tree) and the
/// `HLIndex`, `VIndex` and `Size64` lookup trees — empty in today's mkbom output, except that
/// `Size64` indexes files over 4 GiB. `Paths` is a "tree" header whose child is a chain of
/// 4096-byte BOMPaths leaves, chained through forward/back links and sorted by (parent id, name);
/// once paths no longer fit one leaf, a branch node sits above the chain with one entry per
/// non-final leaf (the shape today's mkbom emits). Every path owns three blocks: path info (type,
/// mode, uid/gid, mtime, size and the `cksum(1)` CRC-32 of the contents — of the target string
/// for symlinks), a file record (parent id + name) and an id/index pair. Today's mkbom stores mod
/// times as Unix-epoch seconds and sizes in 32 bits; `mkbom -s` writes path-only Boms whose
/// infos are just 4 bytes of type.
public struct Bom: Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Hashable {
        case file = 1, directory = 2, symlink = 3
    }

    /// One parsed path: what `lsbom` prints, plus the ids that build the tree.
    public struct Record: Sendable, Equatable, Hashable {
        public var path: String
        public var kind: Kind
        public var mode: UInt16
        public var userID: UInt32
        public var groupID: UInt32
        public var modificationDate: Date?
        public var size: UInt64?
        public var checksum: UInt32?
        public var linkTarget: String?
        /// Path ids are 1-based preorder; the root is 1 and its `parentID` is 0.
        public var id: UInt32
        public var parentID: UInt32
    }

    /// One path to write, preorder with each parent listed before its children and paths shaped
    /// like mkbom's (`.` then `./Contents/MacOS`). Symlinks carry `linkTarget`; their stored size
    /// and digest follow from it. The format's size and time fields are 32-bit, so anything
    /// beyond that range is refused rather than truncated.
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var kind: Kind
        public var mode: UInt16
        public var userID: UInt32
        public var groupID: UInt32
        public var modificationDate: Date
        public var size: UInt64
        public var checksum: UInt32
        public var linkTarget: String?

        public init(path: String, kind: Kind, mode: UInt16, userID: UInt32, groupID: UInt32,
                    modificationDate: Date, size: UInt64, checksum: UInt32, linkTarget: String?) {
            self.path = path
            self.kind = kind
            self.mode = mode
            self.userID = userID
            self.groupID = groupID
            self.modificationDate = modificationDate
            self.size = size
            self.checksum = checksum
            self.linkTarget = linkTarget
        }

        /// Permission bits with the file-type bits mkbom records for this kind.
        var fullMode: UInt16 {
            let typeBits: UInt16 = switch kind {
            case .file: 0o100000
            case .directory: 0o040000
            case .symlink: 0o120000
            }
            return (mode & 0o7777) | typeBits
        }

        /// The stored size: symlinks size from their target, like mkbom does.
        var storedSize: UInt64 { kind == .symlink ? UInt64(linkTarget?.utf8.count ?? 0) : size }
    }

    public private(set) var records: [Record]

    /// Parses a Bom. Truncated stores, dangling references or unsupported entry types throw
    /// `[package]` errors — every offset and length comes from the file, so nothing is trusted.
    public init(_ data: Data) throws {
        var parser = Parser(store: Blob(bytes: [UInt8](data)))
        records = try parser.run()
    }

    /// The mkbom-format bytes for `entries`. A byte-for-byte match with mkbom would mean
    /// emulating the scratch junk its allocator leaves in free gaps (Task 2 report); this emits
    /// the same blocks in the same structures, cleanly laid out, which Apple's tools parse as is.
    public static func data(for entries: [Entry]) throws -> Data {
        try Writer(entries).bytes()
    }

    /// The POSIX `cksum` CRC-32 mkbom stores as the content digest of files and symlinks (the
    /// 4.4BSD algorithm: MSB-first poly 0x04c11db7, init 0, file length folded in LSB-first,
    /// complemented) — the format has no sha256 slot.
    public static func cksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        let poly: UInt32 = 0x04c11db7
        func mix() {
            crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ poly : crc << 1
        }
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { mix() }
        }
        // The length rides after the bytes, least-significant byte first (none for empty input).
        var length = UInt64(data.count)
        while length != 0 {
            crc ^= UInt32(length & 0xff) << 24
            for _ in 0..<8 { mix() }
            length >>= 8
        }
        return ~crc
    }

    /// Paths a single 4096-byte `BOMPaths` leaf can hold: 12 bytes of header + 8-byte entries.
    static let leafCapacity = 510
    /// A single-level root branch holds one entry per non-final leaf, so it covers at most
    /// `leafCapacity + 1` leaves; deeper trees would need nested branch nodes.
    static let maxPaths = leafCapacity * (leafCapacity + 1)

    static func malformed(_ what: String) -> XlessError {
        XlessError(.package, "malformed Bom: \(what)",
                   fix: "rebuild the payload — this Bom came from a corrupted or hostile source")
    }

    static func unsupported(_ what: String) -> XlessError {
        XlessError(.package, "unsupported Bom: \(what)",
                   fix: "rebuild the payload with supported entries (files, directories, symlinks)")
    }

    // MARK: - Bounds-checked big-endian reading

    /// A byte array with checked reads. Offsets and lengths all come from the file.
    struct Blob {
        let bytes: [UInt8]

        func u8(_ offset: Int) throws -> UInt8 {
            guard offset >= 0 && offset + 1 <= bytes.count else { throw Bom.malformed("byte at \(offset) is out of \(bytes.count)") }
            return bytes[offset]
        }
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0 && offset + 2 <= bytes.count else { throw Bom.malformed("u16 at \(offset) is out of \(bytes.count)") }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0 && offset + 4 <= bytes.count else { throw Bom.malformed("u32 at \(offset) is out of \(bytes.count)") }
            return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
                UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            guard offset >= 0 && count >= 0 && offset + count <= bytes.count else {
                throw Bom.malformed("\(count) bytes at \(offset) are out of \(bytes.count)")
            }
            return Array(bytes[offset ..< offset + count])
        }
        /// A NUL-terminated (mkbom always terminates one) byte string starting at `offset`.
        func zeroTerminated(_ offset: Int) throws -> [UInt8] {
            guard offset >= 0 && offset < bytes.count else { throw Bom.malformed("string at \(offset) is out of \(bytes.count)") }
            guard let nul = bytes[offset...].firstIndex(of: 0) else { throw Bom.malformed("unterminated string at \(offset)") }
            return Array(bytes[offset ..< nul])
        }
        func startsWith(_ offset: Int, _ reference: [UInt8]) -> Bool {
            guard offset >= 0 && offset + reference.count <= bytes.count else { return false }
            return Array(bytes[offset ..< offset + reference.count]) == reference
        }
    }

    /// A BOMPaths node: a leaf's entries pair an id block with a file record; a branch's entries
    /// pair child leaves with their separator records. Both are chained through `forward`.
    struct PathNode {
        var isLeaf: Bool
        var entries: [(idSlot: UInt32, recordSlot: UInt32)]
        var forward: UInt32

        init(_ blob: Blob, slot: UInt32) throws {
            guard blob.bytes.count >= 12 else { throw Bom.malformed("path node \(slot) is too small") }
            let shape = try blob.u16(0)
            guard shape == 0 || shape == 1 else { throw Bom.malformed("path node \(slot) has an unknown shape \(shape)") }
            let count = Int(try blob.u16(2))
            guard 12 + 8 * count <= blob.bytes.count else { throw Bom.malformed("path node \(slot) overruns its block") }
            isLeaf = shape == 1
            var list: [(idSlot: UInt32, recordSlot: UInt32)] = []
            for i in 0..<count {
                list.append((try blob.u32(12 + i * 8), try blob.u32(16 + i * 8)))
            }
            entries = list
            forward = try blob.u32(4)
        }
    }

    private struct Parser {
        let store: Blob
        var slots: [Blob] = []                // slot i -> slots[i]; slot 0 is the null entry
        var names: [UInt32: String] = [:]     // id -> last path component
        var parents: [UInt32: UInt32] = [:]   // id -> parent id
        var seenIds: Set<UInt32> = []
        var records: [Record] = []
        var order: [UInt32] = []

        init(store: Blob) { self.store = store }

        /// The Paths tree, walked exactly the way lsbom walks it: descend branch nodes to the
        /// first leaf, then read every leaf along the forward chain.
        mutating func run() throws -> [Record] {
            guard store.bytes.count >= 32 else { throw Bom.malformed("store is only \(store.bytes.count) bytes") }
            guard store.startsWith(0, Array("BOMStore".utf8)) else { throw Bom.malformed("missing BOMStore magic") }
            guard try store.u32(8) == 1 else { throw Bom.unsupported("store version \(try store.u32(8))") }
            let indexOffset = Int(try store.u32(16))
            let varsOffset = Int(try store.u32(24))
            guard indexOffset >= 5 && indexOffset < store.bytes.count else { throw Bom.malformed("indexOffset is out of bounds") }
            guard varsOffset >= 0 && varsOffset < store.bytes.count else { throw Bom.malformed("varsOffset is out of bounds") }

            // Pointer table: an entry count plus (address, length) pairs for slot 0 (null) upward.
            let tableCount = Int(try store.u32(indexOffset))
            guard tableCount >= 1 && 4 + 8 * tableCount <= store.bytes.count - indexOffset else {
                throw Bom.malformed("pointer table of \(tableCount) entries overruns the file")
            }
            for i in 0..<tableCount {
                let address = Int(try store.u32(indexOffset + 4 + 8 * i))
                let length = Int(try store.u32(indexOffset + 4 + 8 * i + 4))
                guard address >= 0 && address + length <= store.bytes.count else {
                    throw Bom.malformed("block at \(address)+\(length) is out of bounds")
                }
                slots.append(Blob(bytes: Array(store.bytes[address ..< address + length])))
            }

            var cursor = varsOffset
            let varCount = Int(try store.u32(cursor))
            cursor += 4
            guard varCount <= 0x4000_00 else { throw Bom.malformed("var table of \(varCount) entries") }
            var varNames: [String: UInt32] = [:]
            for _ in 0..<varCount {
                let slot = try store.u32(cursor)
                let length = Int(try store.u8(cursor + 4))
                let name = String(decoding: try store.bytes(cursor + 5, length), as: UTF8.self)
                cursor += 5 + length
                if slot != 0 { varNames[name] = slot }   // null slots (BomInfo may be one) stay null
            }
            guard let pathsSlot = varNames["Paths"] else { throw Bom.malformed("store has no Paths var") }

            // The var is a "tree" header (magic, version, child slot, block size); its child is
            // the BOMPaths node chain.
            let tree = try blob(pathsSlot)
            guard tree.startsWith(0, Array("tree".utf8)) else { throw Bom.malformed("Paths var lacks its tree header") }
            let rootSlot = try tree.u32(8)
            var slot = rootSlot
            var node = try PathNode(try blob(slot), slot: slot)
            var visited: Set<UInt32> = []
            var depth = 0
            while !node.isLeaf {
                guard visited.insert(rootSlot).inserted && depth <= 0x1000 else {
                    throw Bom.malformed("branch chain in Paths cycles or never ends")
                }
                depth += 1
                guard let child = node.entries.first?.idSlot else { throw Bom.malformed("branch node without a child") }
                slot = child
                node = try PathNode(try blob(slot), slot: slot)
            }

            var leaves = 0
            var leafSlot = slot
            while true {
                guard visited.insert(leafSlot).inserted && leaves <= 0x2_0000 else {
                    throw Bom.malformed("leaf chain in Paths cycles or never ends")
                }
                leaves += 1
                try collect(leafSlot)
                guard node.forward != 0 else { break }
                leafSlot = node.forward
                node = try PathNode(try blob(leafSlot), slot: leafSlot)
            }

            // Rebuild full paths from the parent links. Each hop moves one level up, so the
            // chain is bounded by the number of paths.
            for (index, id) in order.enumerated() {
                var components: [String] = []
                var current = id
                while current != 0 {
                    guard components.count <= order.count else { throw Bom.malformed("parent chain at path id \(id) cycles") }
                    guard let component = names[current] else { throw Bom.malformed("path id \(current) is missing") }
                    components.append(component)
                    guard let parent = parents[current] else { throw Bom.malformed("path id \(current) has no parent link") }
                    current = parent
                }
                records[index].path = components.reversed().joined(separator: "/")
            }
            return records
        }

        private func blob(_ slot: UInt32) throws -> Blob {
            guard slot > 0 && Int(slot) < slots.count else { throw Bom.malformed("block slot \(slot) does not exist") }
            return slots[Int(slot)]
        }

        /// One leaf: its entries are (path-id block, file record) pairs.
        private mutating func collect(_ leafSlot: UInt32) throws {
            let node = try PathNode(try blob(leafSlot), slot: leafSlot)
            guard node.isLeaf else { throw Bom.malformed("expected a leaf at slot \(leafSlot)") }
            for (pairSlot, fileSlot) in node.entries {
                let pair = try blob(pairSlot)
                guard pair.bytes.count >= 8 else { throw Bom.malformed("path-id block \(pairSlot) is too small") }
                let id = try pair.u32(0)
                guard id != 0, seenIds.insert(id).inserted else { throw Bom.malformed("path id \(id) appears twice or is invalid") }
                let infoSlot = try pair.u32(4)
                let info = try blob(infoSlot)
                guard info.bytes.count >= 4 else { throw Bom.malformed("path info \(infoSlot) is too small") }
                let rawKind = try info.u8(0)
                guard let kind = Kind(rawValue: rawKind) else {
                    throw Bom.unsupported("path type \(rawKind) (files, directories and symlinks only)")
                }
                var record = Record(path: "", kind: kind, mode: 0, userID: 0, groupID: 0,
                                    modificationDate: nil, size: nil, checksum: nil, linkTarget: nil,
                                    id: id, parentID: 0)
                if info.bytes.count >= 31 {
                    record.mode = try info.u16(4)
                    record.userID = try info.u32(6)
                    record.groupID = try info.u32(10)
                    let seconds = try info.u32(14)
                    // Boms recorded before 2026 shift mtime into seconds since 1904; today's
                    // mkbom stores Unix seconds. The two ranges split at the 2038 line.
                    record.modificationDate = Date(timeIntervalSince1970: seconds > 0x7fff_ffff
                        ? TimeInterval(Int64(seconds) - 2082844800)
                        : TimeInterval(seconds))
                    record.size = UInt64(try info.u32(18))
                    if info.bytes.count >= 27 { record.checksum = try info.u32(23) }
                    if kind == .symlink {
                        let targetLength = Int(try info.u32(27))
                        guard targetLength > 0 else { throw Bom.malformed("symlink \(infoSlot) declares an empty target") }
                        let stored = try info.bytes(31, targetLength)
                        guard stored.last == 0 else { throw Bom.malformed("symlink \(infoSlot) target is not NUL-terminated") }
                        record.linkTarget = String(decoding: stored.dropLast(), as: UTF8.self)
                    }
                }
                let file = try blob(fileSlot)
                guard file.bytes.count >= 5 else { throw Bom.malformed("file record \(fileSlot) is too small") }
                record.parentID = try file.u32(0)
                names[id] = String(decoding: try file.zeroTerminated(4), as: UTF8.self)
                parents[id] = record.parentID
                order.append(id)
                records.append(record)
            }
        }
    }
}

// MARK: - Writing

/// Emits the mkbom store layout: header (patched last), blocks in slot order, vars, pointer
/// table, and an empty free list with mkbom's two reserved zero pointers.
private struct Writer {
    let entries: [Bom.Entry]
    var nameOf: [UInt32: [UInt8]] = [:]   // id -> last path component bytes
    var parentOf: [UInt32: UInt32] = [:]  // id -> parent id

    init(_ entries: [Bom.Entry]) throws {
        guard !entries.isEmpty else { throw Bom.malformed("the tree is empty") }
        guard entries.count <= Bom.maxPaths else {
            throw Bom.unsupported("\(entries.count) paths (the tree structure covers \(Bom.maxPaths))")
        }
        guard entries[0].path == "." && entries[0].kind == .directory else {
            throw Bom.malformed("the tree must start with the root directory \".\"")
        }
        self.entries = entries
        nameOf[1] = Array(".".utf8)
        parentOf[1] = 0
        var seen: Set<String> = ["."]
        var listed: [String: UInt32] = [".": 1]
        for (index, entry) in entries.enumerated() {
            let id = UInt32(index + 1)
            guard !entry.path.contains("\0") else { throw Bom.malformed("path \(entry.path) may not contain NUL") }
            guard entry.path.hasPrefix("./") || entry.path == "." else {
                throw Bom.malformed("path \(entry.path) must be \".\" or start with \"./\"")
            }
            guard entry.linkTarget != nil || entry.kind != .symlink else {
                throw Bom.malformed("symlink \(entry.path) has no link target")
            }
            guard entry.linkTarget == nil || entry.kind == .symlink else {
                throw Bom.malformed("path \(entry.path) is not a symlink but carries a link target")
            }
            if let target = entry.linkTarget {
                guard !target.isEmpty && !target.contains("\0") else {
                    throw Bom.malformed("symlink \(entry.path) has an unusable target string")
                }
                guard target.utf8.count + 1 <= UInt32.max else {
                    throw Bom.unsupported("symlink \(entry.path) target exceeds the format's 32-bit lengths")
                }
            }
            guard entry.size <= UInt64(UInt32.max) else {
                throw Bom.unsupported("\(entry.path) is \(entry.size) bytes (the format stores 32-bit sizes)")
            }
            let seconds = entry.modificationDate.timeIntervalSince1970
            guard seconds >= 0 && seconds <= Double(UInt32.max) else {
                throw Bom.unsupported("\(entry.path) has a modification time the format cannot store")
            }
            guard entry.path != "." || index == 0 else { throw Bom.malformed("the root directory \".\" is listed twice") }
            if entry.path == "." { continue }
            // Split "./a/b" into parent "./a" and name "b"; reject empty and dot components.
            let body = entry.path.dropFirst(2)
            let components = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let name = components.last, !name.isEmpty, !components.contains(""),
                  !components.contains("."), !components.contains("..") else {
                throw Bom.malformed("path \(entry.path) is not mkbom-shaped")
            }
            let parentPath = components.count == 1 ? "." : "./" + components.dropLast().joined(separator: "/")
            guard let parentID = listed[parentPath], entries[Int(parentID - 1)].kind == .directory else {
                throw Bom.malformed("path \(entry.path) comes before its parent \(parentPath)")
            }
            guard seen.insert(entry.path).inserted else { throw Bom.malformed("path \(entry.path) is listed twice") }
            nameOf[id] = Array(name.utf8)
            parentOf[id] = parentID
            listed[entry.path] = id
        }
    }

    func bytes() throws -> Data {
        // Leaf and record order: by (parent id, name) bytes — the shape mkbom's leaves have.
        let order = entries.indices.sorted { a, b in
            let aID = UInt32(a + 1), bID = UInt32(b + 1)
            let aParent = parentOf[aID] ?? 0, bParent = parentOf[bID] ?? 0
            if aParent != bParent { return aParent < bParent }
            return lexLess(nameOf[aID] ?? [], nameOf[bID] ?? [])
        }
        var leaves: [[Int]] = []
        var cursor = 0
        while cursor < order.count {
            leaves.append(Array(order[cursor ..< min(cursor + Bom.leafCapacity, order.count)]))
            cursor += Bom.leafCapacity
        }
        let singleLeaf = leaves.count == 1

        // Slot layout (stream order = slot order): 1 BomInfo, 2 the Paths tree header, 3 the
        // root node (leaf or branch), 4.. the leaves when branched, then the three lookup trees,
        // then three blocks per path (info, file record, id pair).
        let treeBase: UInt32 = singleLeaf ? 4 : UInt32(4 + leaves.count)
        let hlTreeSlot = treeBase
        let hlLeafSlot = hlTreeSlot + 1
        let vIndexSlot = hlLeafSlot + 1
        let vTreeSlot = vIndexSlot + 1
        let vLeafSlot = vTreeSlot + 1
        let sizeTreeSlot = vLeafSlot + 1
        let sizeLeafSlot = sizeTreeSlot + 1
        let entryBase = sizeLeafSlot + 1
        func infoSlot(_ index: Int) -> UInt32 { entryBase + UInt32(index * 3) }
        func recordSlot(_ index: Int) -> UInt32 { entryBase + UInt32(index * 3 + 1) }
        let maxSlot = entryBase + UInt32(entries.count * 3) - 1

        var out: [UInt8] = Array(repeating: 0, count: 512)
        var addresses: [UInt32: (address: Int, length: Int)] = [:]
        func emit(_ slot: UInt32, _ payload: [UInt8], paddedTo: Int? = nil) {
            var bytes = payload
            if let paddedTo { bytes += Array(repeating: 0, count: max(0, paddedTo - bytes.count)) }
            addresses[slot] = (out.count, bytes.count)
            out += bytes
        }

        // BomInfo: version 1, path count + 1, one info entry, entry {0, 0, file byte total, 0}.
        var b = Bytes()
        b.u32(1)
        b.u32(UInt32(entries.count) + 1)
        b.u32(1)
        b.u32(0)
        b.u32(0)
        let contentBytes = entries.reduce(0) { $0 + ($1.kind == .directory ? 0 : $1.storedSize) }
        b.u32(UInt32(truncatingIfNeeded: contentBytes))
        b.u32(0)
        emit(1, b.take())

        // Paths tree: "tree", version 1, child, 4096-byte blocks, and the path count — a plain
        // u32 with a zero trailing byte (checked against mkbom's 255-path and full fixtures).
        b = Bytes()
        b.raw("tree")
        b.u32(1)
        b.u32(3)
        b.u32(0x1000)
        b.u32(UInt32(entries.count))
        b.u8(0)
        emit(2, b.take())

        if singleLeaf {
            emit(3, leafPayload(leaves[0], forward: 0, backward: 0, entryBase: entryBase), paddedTo: 4096)
        } else {
            // Branch node: one entry per non-final leaf, pointing at the leaf and at the file
            // record of its last entry.
            b = Bytes()
            b.u16(0)
            b.u16(UInt16(leaves.count - 1))
            b.u32(0)
            b.u32(0)
            for (i, leaf) in leaves.enumerated() where i < leaves.count - 1 {
                b.u32(UInt32(4 + i))
                b.u32(recordSlot(leaf[leaf.count - 1]))
            }
            emit(3, b.take())
            for (i, leaf) in leaves.enumerated() {
                let forward: UInt32 = i + 1 < leaves.count ? UInt32(4 + i + 1) : 0
                let backward: UInt32 = i > 0 ? UInt32(4 + i - 1) : 0
                emit(UInt32(4 + i), leafPayload(leaf, forward: forward, backward: backward, entryBase: entryBase), paddedTo: 4096)
            }
        }

        // The three lookup trees, exactly as today's mkbom writes them: HLIndex and Size64 as
        // 4096-byte empty leaves; VIndex as an index header pointing through a "tree" header
        // (block size 128) at a 128-byte empty leaf.
        _ = vTreeSlot
        b = Bytes()
        b.raw("tree")
        b.u32(1)
        b.u32(hlLeafSlot)
        b.u32(0x1000)
        b.u32(0)
        b.u8(0)
        emit(hlTreeSlot, b.take())
        b = Bytes()
        b.u16(1)
        b.u16(0)
        b.u32(0)
        b.u32(0)
        emit(hlLeafSlot, b.take(), paddedTo: 4096)
        b = Bytes()
        b.u32(1)
        b.u32(vTreeSlot)
        b.u32(0)
        b.u8(0)
        emit(vIndexSlot, b.take())
        b = Bytes()
        b.raw("tree")
        b.u32(1)
        b.u32(vLeafSlot)
        b.u32(0x80)
        b.u32(0)
        b.u8(0)
        emit(vTreeSlot, b.take())
        b = Bytes()
        b.u16(1)
        b.u16(0)
        b.u32(0)
        b.u32(0)
        emit(vLeafSlot, b.take(), paddedTo: 128)
        b = Bytes()
        b.raw("tree")
        b.u32(1)
        b.u32(sizeLeafSlot)
        b.u32(0x1000)
        b.u32(0)
        b.u8(0)
        emit(sizeTreeSlot, b.take())
        b = Bytes()
        b.u16(1)
        b.u16(0)
        b.u32(0)
        b.u32(0)
        emit(sizeLeafSlot, b.take(), paddedTo: 4096)

        // Per path: info block (mkbom's PathInfo2 with today's field values), file record, id pair.
        for (index, entry) in entries.enumerated() {
            b = Bytes()
            b.u8(entry.kind.rawValue)
            b.u8(1)
            b.u16(0x000f)
            b.u16(entry.fullMode)
            b.u32(entry.userID)
            b.u32(entry.groupID)
            b.u32(UInt32(entry.modificationDate.timeIntervalSince1970))
            b.u32(UInt32(entry.storedSize))
            b.u8(1)
            switch entry.kind {
            case .directory:
                b.u32(0)
                b.u32(0)
            case .file:
                b.u32(entry.checksum)
                b.u32(0)
                b.u32(0)
            case .symlink:
                let target = entry.linkTarget ?? ""
                let targetBytes = Array(target.utf8)
                b.u32(Bom.cksum(Data(targetBytes)))
                b.u32(UInt32(targetBytes.count + 1))
                b.raw(target)
                b.u8(0)
                b.u32(0)
                b.u32(0)
            }
            emit(infoSlot(index), b.take())

            b = Bytes()
            b.u32(parentOf[UInt32(index + 1)] ?? 0)
            b.bytes.append(contentsOf: nameOf[UInt32(index + 1)] ?? [])
            b.u8(0)
            emit(recordSlot(index), b.take())

            b = Bytes()
            b.u32(UInt32(index + 1))
            b.u32(infoSlot(index))
            emit(entryBase + UInt32(index * 3 + 2), b.take())
        }

        // Vars, in mkbom's order (BomInfo, Paths, HLIndex, VIndex, Size64).
        let varsOffset = out.count
        b = Bytes()
        b.u32(5)
        b.u32(1); b.u8(7); b.raw("BomInfo")
        b.u32(2); b.u8(5); b.raw("Paths")
        b.u32(hlTreeSlot); b.u8(7); b.raw("HLIndex")
        b.u32(vIndexSlot); b.u8(6); b.raw("VIndex")
        b.u32(sizeTreeSlot); b.u8(6); b.raw("Size64")
        out += b.take()

        // Pointer table: slot 0 null, then every block's file offset and length; the free list
        // closes the file: count 0 plus mkbom's two reserved zero pointers (16 bytes).
        let indexOffset = out.count
        let varsLength = indexOffset - varsOffset
        b = Bytes()
        b.u32(maxSlot + 1)
        for slot in 0...maxSlot {
            if slot == 0 {
                b.u32(0)
                b.u32(0)
            } else if let placed = addresses[slot] {
                b.u32(UInt32(placed.address))
                b.u32(UInt32(placed.length))
            } else {
                throw Bom.malformed("block slot \(slot) was never emitted")
            }
        }
        out += b.take()
        out += Array(repeating: 0, count: 20)

        // Header: magic, version, non-null block count, then the section offsets and lengths.
        b = Bytes()
        b.raw("BOMStore")
        b.u32(1)
        b.u32(maxSlot)
        b.u32(UInt32(indexOffset))
        b.u32(UInt32(out.count - indexOffset))
        b.u32(UInt32(varsOffset))
        b.u32(UInt32(varsLength))
        out.replaceSubrange(0..<b.bytes.count, with: b.bytes)
        return Data(out)
    }

    /// A 4096-byte leaf: header (isLeaf, count, forward, backward) and 8-byte entries, each
    /// pairing the path's id block with its file record.
    private func leafPayload(_ indices: [Int], forward: UInt32, backward: UInt32, entryBase: UInt32) -> [UInt8] {
        var b = Bytes()
        b.u16(1)
        b.u16(UInt16(indices.count))
        b.u32(forward)
        b.u32(backward)
        for index in indices {
            b.u32(entryBase + UInt32(index * 3 + 2))
            b.u32(entryBase + UInt32(index * 3 + 1))
        }
        return b.bytes
    }

    /// Whether `a` sorts before `b` byte-wise, the way mkbom compares names.
    private func lexLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for pair in zip(a, b) where pair.0 != pair.1 { return pair.0 < pair.1 }
        return a.count < b.count
    }
}

/// Small big-endian byte assembler used for building blocks.
struct Bytes {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xff)] }
    mutating func u32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
    mutating func raw(_ text: String) { bytes.append(contentsOf: Array(text.utf8)) }

    /// Returns the bytes accumulated so far and empties the buffer (`size` zero-pads to it).
    mutating func take(paddedTo size: Int? = nil) -> [UInt8] {
        var result = bytes
        if let size, result.count < size {
            result += Array(repeating: 0, count: size - result.count)
        }
        bytes.removeAll()
        return result
    }
}