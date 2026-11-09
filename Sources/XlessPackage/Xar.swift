import Foundation
import Crypto
import XlessCore

/// Writes the XAR container a macOS flat package is made of, so the pkg stage needs no `xar` tool (no Ubuntu release
/// packages one). The layout is the format's own: a 28-byte big-endian header, the zlib-compressed XML table of
/// contents, then the heap (the TOC's SHA-1 first, then every file's bytes, at the offsets the TOC names).
///
/// Everything is stored: the TOC in a zlib stream of uncompressed blocks, the files with the
/// `application/octet-stream` encoding. A package's members are already compressed (`Payload` is gzip) or tiny
/// (`Bom`, `PackageInfo`, `Distribution`), and a stored archive needs no zlib binding on either platform.
/// libxar lists the top level of the TOC in the reverse of its XML order (and a directory's children in it), so the top
/// level is written reversed here; ids and heap offsets keep the document order (checked against Apple's `xar -tf`).
/// Output is a function of the inputs and `modified` alone, so a package is reproducible.
public enum Xar {
    public indirect enum Node {
        case file(name: String, source: URL)
        case directory(name: String, children: [Node])
    }

    /// One file as the TOC records it.
    private struct Member { var source: URL; var size: Int; var sha1: String; var offset: Int }

    /// Writes `nodes` (document order is the TOC and heap order) to `out`. `modified` dates the archive and every entry.
    public static func write(_ nodes: [Node], to out: URL, modified: Date) throws {
        let stamp = ISO8601DateFormatter().string(from: modified)   // UTC, `2023-11-14T22:13:20Z`
        var nextID = 1
        var heapSize = checksumSize
        var members: [Member] = []
        let entries = try nodes.map { try entry($0, stamp: stamp, nextID: &nextID, heapSize: &heapSize, members: &members) }

        let toc = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xar><toc><creation-time>\(stamp)</creation-time>"
            + "<checksum style=\"sha1\"><offset>0</offset><size>\(checksumSize)</size></checksum>"
            + entries.reversed().joined() + "</toc></xar>").utf8)
        let compressed = stored(toc)
        var header = Data()
        header.append(be: 0x7861_7221 as UInt32)            // "xar!"
        header.append(be: 28 as UInt16)                     // header size
        header.append(be: 1 as UInt16)                      // format version
        header.append(be: UInt64(compressed.count))
        header.append(be: UInt64(toc.count))
        header.append(be: 1 as UInt32)                      // checksum algorithm: SHA-1

        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else {
            throw XlessError(.package, "cannot write \(out.lastPathComponent)", fix: "check free space and permissions of \(out.deletingLastPathComponent().path)")
        }
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: compressed)
            try handle.write(contentsOf: Data(Insecure.SHA1.hash(data: compressed)))
            for member in members { try copy(member, to: handle) }
        } catch let error as XlessError { throw error } catch {
            throw XlessError(.package, "cannot write \(out.lastPathComponent): \(error.localizedDescription)", fix: "check free space and permissions of \(out.deletingLastPathComponent().path)")
        }
    }

    private static let checksumSize = 20   // SHA-1

    /// The TOC entry of `node` (and, for a directory, of everything under it); records each file's heap slot.
    private static func entry(_ node: Node, stamp: String, nextID: inout Int, heapSize: inout Int, members: inout [Member]) throws -> String {
        let id = nextID
        nextID += 1
        func common(_ name: String, _ type: String, _ mode: String) -> String {
            "<file id=\"\(id)\"><name>\(escape(name))</name><type>\(type)</type><mode>\(mode)</mode><uid>0</uid><gid>0</gid>"
                + "<user>root</user><group>wheel</group><mtime>\(stamp)</mtime><atime>\(stamp)</atime><ctime>\(stamp)</ctime>"
        }
        switch node {
        case .directory(let name, let children):
            let inner = try children.map { try entry($0, stamp: stamp, nextID: &nextID, heapSize: &heapSize, members: &members) }
            return common(name, "directory", "0755") + inner.joined() + "</file>"
        case .file(let name, let source):
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? nil
            guard let size else { throw XlessError(.package, "cannot read \(source.lastPathComponent)", fix: "re-run the package stage") }
            let head = common(name, "file", "0644")
            if size == 0 { return head + "</file>" }
            let sha1 = try digest(source)
            members.append(Member(source: source, size: size, sha1: sha1, offset: heapSize))
            defer { heapSize += size }
            return head + "<data><archived-checksum style=\"sha1\">\(sha1)</archived-checksum>"
                + "<extracted-checksum style=\"sha1\">\(sha1)</extracted-checksum><encoding style=\"application/octet-stream\"/>"
                + "<size>\(size)</size><offset>\(heapSize)</offset><length>\(size)</length></data></file>"
        }
    }

    private static let chunk = 1 << 20

    private static func digest(_ url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw XlessError(.package, "cannot read \(url.lastPathComponent)", fix: "re-run the package stage") }
        defer { try? handle.close() }
        var sha = Insecure.SHA1()
        while let bytes = try handle.read(upToCount: chunk), !bytes.isEmpty { sha.update(data: bytes) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(_ member: Member, to out: FileHandle) throws {
        let handle = try FileHandle(forReadingFrom: member.source)
        defer { try? handle.close() }
        var copied = 0
        while let bytes = try handle.read(upToCount: chunk), !bytes.isEmpty {
            try out.write(contentsOf: bytes)
            copied += bytes.count
        }
        guard copied == member.size else {
            throw XlessError(.package, "\(member.source.lastPathComponent) changed while it was archived", fix: "re-run the package stage")
        }
    }

    /// A zlib stream of stored blocks: header, the data in blocks of at most 65535 bytes, the Adler-32.
    static func stored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        var offset = data.startIndex
        repeat {
            let end = min(offset + 65535, data.endIndex)
            let length = UInt16(end - offset)
            out.append(end == data.endIndex ? 1 : 0)
            out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)])
            out.append(data[offset..<end])
            offset = end
        } while offset < data.endIndex
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        out.append(be: b << 16 | a)
        return out
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
