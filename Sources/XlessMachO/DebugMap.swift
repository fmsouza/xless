import Foundation

/// What dsymutil and the dSYMs of Rust executables need from an image: its debug map (the N_OSO stabs the linker writes
/// for each object file with debug info), whether two links of the same objects hold the same code, and its UUID.
extension MachO {
    static let nOSO: UInt8 = 0x66

    /// The object files the debug map of every slice names (N_OSO stabs, in symbol table order): `path/to/x.o`, or
    /// `path/to/lib.a(member.o)` for an archive member. Empty when the image has no symbol table or no debug map.
    public static func debugMapObjects(in data: Data) throws -> [String] {
        var out: [String] = []
        for r in try slices(data) {
            var symtab: (off: Int, n: Int, str: Int, strsize: Int)?
            try forEachLoadCommand(data, slice: r) { off, cmd, size in
                guard cmd == lcSymtab else { return }
                guard size >= 24 else { throw MachOError.truncated }
                symtab = (Int(try data.u32(off + 8)), Int(try data.u32(off + 12)), Int(try data.u32(off + 16)), Int(try data.u32(off + 20)))
            }
            guard let st = symtab else { continue }
            let base = r.lowerBound
            guard base + st.off + st.n * 16 <= r.upperBound, base + st.str + st.strsize <= r.upperBound else { throw MachOError.truncated }
            let strings = (base + st.str)..<(base + st.str + st.strsize)
            for i in 0..<st.n {
                let e = base + st.off + i * 16
                guard data[e + 4] == nOSO else { continue }
                let start = strings.lowerBound + Int(try data.u32(e))
                guard start < strings.upperBound else { throw MachOError.truncated }
                let stop = data[start..<strings.upperBound].firstIndex(of: 0) ?? strings.upperBound
                out.append(String(decoding: data[start..<stop], as: UTF8.self))
            }
        }
        return out
    }

    /// Whether two thin 64-bit images hold the same code and data: the same segments (name, addresses, file range)
    /// but `__LINKEDIT`, and the same sections (addresses, sizes, flags and bytes). The symbol table, the UUID and the
    /// rest of the load commands may differ: they do between an executable linked with `-x` and the same link without.
    public static func sameCode(_ a: Data, _ b: Data) throws -> Bool {
        guard !isFat(a), !isFat(b) else { return false }
        return try codeLayout(a) == codeLayout(b)
    }

    private struct Section: Equatable {
        var segment: String, name: String, addr: UInt64, size: UInt64, flags: UInt32, bytes: Data?
    }

    private struct Segment: Equatable {
        var name: String, vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64, sections: [Section]
    }

    private static func codeLayout(_ d: Data) throws -> [Segment] {
        func name(_ off: Int) -> String {
            let raw = d[off..<(off + 16)]
            return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var segments: [Segment] = []
        try forEachLoadCommand(d, slice: 0..<d.count) { off, cmd, size in
            guard cmd == lcSegment64 else { return }
            guard size >= 72 else { throw MachOError.truncated }
            let segname = name(off + 8)
            guard segname != "__LINKEDIT" else { return }
            let nsects = Int(try d.u32(off + 64))
            guard 72 + nsects * 80 <= size else { throw MachOError.truncated }
            var sections: [Section] = []
            for i in 0..<nsects {
                let s = off + 72 + i * 80
                let addr = try d.u64(s + 32), sz = try d.u64(s + 40), fileoff = Int(try d.u32(s + 48)), flags = try d.u32(s + 64)
                // Zero-fill sections (S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL) have no bytes in the file.
                let zerofill = [0x1, 0xc, 0x12].contains(flags & 0xff)
                var bytes: Data?
                if !zerofill && fileoff != 0 {
                    guard fileoff <= d.count, sz <= UInt64(d.count - fileoff) else { throw MachOError.truncated }
                    bytes = d.subdata(in: fileoff..<(fileoff + Int(sz)))
                }
                sections.append(Section(segment: name(s + 16), name: name(s), addr: addr, size: sz, flags: flags, bytes: bytes))
            }
            segments.append(Segment(name: segname, vmaddr: try d.u64(off + 24), vmsize: try d.u64(off + 32), fileoff: try d.u64(off + 40),
                                    filesize: try d.u64(off + 48), sections: sections))
        }
        return segments
    }

    /// Sets the LC_UUID of a thin 64-bit image to `uuid` (`dwarfdump --uuid` form, `8-4-4-4-12` hex digits). Throws for
    /// a fat file, an image without LC_UUID and a malformed UUID.
    public static func setUUID(in data: inout Data, to uuid: String) throws {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, uuid.count == 36 else { throw MachOError.unsupported("malformed UUID '\(uuid)'") }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { throw MachOError.unsupported("malformed UUID '\(uuid)'") }
            bytes.append(b)
            i = j
        }
        guard !isFat(data) else { throw MachOError.unsupported("setting the UUID of a fat file") }
        var at: Int?
        try forEachLoadCommand(data, slice: 0..<data.count) { off, cmd, size in
            guard cmd == lcUUID else { return }
            guard size >= 24 else { throw MachOError.truncated }
            at = off + 8
        }
        guard let at else { throw MachOError.unsupported("no LC_UUID") }
        data.replaceSubrange(at..<(at + 16), with: bytes)
    }
}
