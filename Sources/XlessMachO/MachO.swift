import Foundation

public struct BuildVersion: Equatable, Sendable {
    public var cpuType: Int32
    public var platform: UInt32
    public var minos: UInt32
    public var sdk: UInt32
}

public enum MachOError: Error, Equatable, Sendable {
    case notMachO, truncated, badVersion(String), unsupported(String)
}

extension Data {
    func u32(_ off: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard off >= 0, off + 4 <= count else { throw MachOError.truncated }
        let raw = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: raw) : UInt32(littleEndian: raw)
    }

    mutating func setU32LE(_ off: Int, _ value: UInt32) throws {
        guard off >= 0, off + 4 <= count else { throw MachOError.truncated }
        withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self) }
    }
}

public enum MachO {
    static let mhMagic64: UInt32 = 0xfeedfacf
    static let mhMagic32: UInt32 = 0xfeedface
    static let fatMagic: UInt32 = 0xcafebabe
    static let lcBuildVersion: UInt32 = 0x32

    /// "27.0" → 0x001b0000 (xxxx.yy.zz nibble encoding).
    public static func encodeVersion(_ s: String) throws -> UInt32 {
        let raw = s.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) }
        guard (1...3).contains(raw.count), raw.allSatisfy({ $0 != nil }) else { throw MachOError.badVersion(s) }
        let p = raw.map { $0! } + Array(repeating: 0, count: 3 - raw.count)
        guard p[0] <= 0xffff, p[1] <= 0xff, p[2] <= 0xff else { throw MachOError.badVersion(s) }
        return (p[0] << 16) | (p[1] << 8) | p[2]
    }

    public static func decodeVersion(_ v: UInt32) -> String {
        let base = "\(v >> 16).\((v >> 8) & 0xff)"
        return (v & 0xff) == 0 ? base : "\(base).\(v & 0xff)"
    }

    public static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4, let le = try? data.u32(0), let be = try? data.u32(0, bigEndian: true) else { return false }
        return le == mhMagic64 || be == fatMagic
    }

    /// True when `data` is a thin 64-bit Mach-O image, or a fat file whose slices are all 64-bit images.
    /// A thin `ar` archive, or a fat wrapper whose slices are `ar` archives (CocoaPods xcframework statics
    /// such as onnxruntime), is a static library: it has no load commands to stamp, so this is false.
    /// A fat file mixing images and non-images is unexpected and throws. Files that are not Mach-O at all are false.
    public static func containsLoadableImage(_ data: Data) throws -> Bool {
        guard data.count >= 4, let le = try? data.u32(0), let be = try? data.u32(0, bigEndian: true) else { return false }
        if le == mhMagic64 { return true }
        guard be == fatMagic, data.count >= 8, let n = try? data.u32(4, bigEndian: true), (1...32).contains(n) else { return false }
        let flags = try slices(data).map { r in r.count >= 4 && (try? data.u32(r.lowerBound)) == mhMagic64 }
        if flags.allSatisfy({ $0 }) { return true }
        if flags.contains(true) {
            throw MachOError.unsupported("fat binary mixes Mach-O images and non-image slices")
        }
        return false
    }

    static func slices(_ data: Data) throws -> [Range<Int>] {
        let le = try data.u32(0)
        if le == mhMagic64 { return [0..<data.count] }
        if le == mhMagic32 { throw MachOError.unsupported("32-bit Mach-O") }
        guard try data.u32(0, bigEndian: true) == fatMagic else { throw MachOError.notMachO }
        let n = Int(try data.u32(4, bigEndian: true))
        return try (0..<n).map { i in
            let base = 8 + i * 20
            let off = Int(try data.u32(base + 8, bigEndian: true))
            let size = Int(try data.u32(base + 12, bigEndian: true))
            guard off + size <= data.count else { throw MachOError.truncated }
            return off..<(off + size)
        }
    }

    /// Calls `body(offset, cmd, size)` for each load command of a 64-bit slice, bounds-checked.
    static func forEachLoadCommand(_ data: Data, slice r: Range<Int>, _ body: (Int, UInt32, Int) throws -> Void) throws {
        let b = r.lowerBound
        guard r.count >= 32 else { throw MachOError.truncated }
        guard try data.u32(b) == mhMagic64 else { throw MachOError.unsupported("non-64-bit slice") }
        var off = b + 32
        for _ in 0..<Int(try data.u32(b + 16)) {
            guard off + 8 <= r.upperBound else { throw MachOError.truncated }
            let size = Int(try data.u32(off + 4))
            guard size >= 8, off + size <= r.upperBound else { throw MachOError.truncated }
            try body(off, try data.u32(off), size)
            off += size
        }
    }

    static func forEachBuildVersion(_ data: Data, _ body: (Int, Int32) throws -> Void) throws {
        for r in try slices(data) {
            guard r.count >= 32 else { throw MachOError.truncated }
            let cpu = Int32(bitPattern: try data.u32(r.lowerBound + 4))
            try forEachLoadCommand(data, slice: r) { off, cmd, size in
                if cmd == lcBuildVersion {
                    guard size >= 24 else { throw MachOError.truncated }
                    try body(off, cpu)
                }
            }
        }
    }

    public static func buildVersions(in data: Data) throws -> [BuildVersion] {
        var out: [BuildVersion] = []
        try forEachBuildVersion(data) { off, cpu in
            out.append(BuildVersion(cpuType: cpu, platform: try data.u32(off + 8),
                                    minos: try data.u32(off + 12), sdk: try data.u32(off + 16)))
        }
        return out
    }

    static let lcLoadDylib: UInt32 = 0xc
    static let lcLoadWeakDylib: UInt32 = 0x80000018
    static let lcReexportDylib: UInt32 = 0x8000001f
    static let lcRpath: UInt32 = 0x8000001c

    /// Names of the load commands whose type is in `kinds`, in load-command order. Thin 64-bit only; a fat binary uses its first slice.
    static func pathCommands(_ data: Data, _ kinds: Set<UInt32>, slice: Range<Int>? = nil) throws -> [String] {
        guard let r = try slice ?? slices(data).first else { return [] }
        let b = r.lowerBound
        guard r.count >= 32 else { throw MachOError.truncated }
        guard try data.u32(b) == mhMagic64 else { throw MachOError.unsupported("non-64-bit slice") }
        let ncmds = Int(try data.u32(b + 16))
        var off = b + 32
        var out: [String] = []
        for _ in 0..<ncmds {
            guard off + 8 <= r.upperBound else { throw MachOError.truncated }
            let cmd = try data.u32(off)
            let size = Int(try data.u32(off + 4))
            guard size >= 8, off + size <= r.upperBound else { throw MachOError.truncated }
            if kinds.contains(cmd) {
                guard size >= 12 else { throw MachOError.truncated }
                let nameOff = Int(try data.u32(off + 8))
                guard nameOff >= 12, nameOff <= size else { throw MachOError.truncated }
                let bytes = data[(off + nameOff)..<(off + size)].prefix { $0 != 0 }
                out.append(String(decoding: bytes, as: UTF8.self))
            }
            off += size
        }
        return out
    }

    /// LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB and LC_REEXPORT_DYLIB names, in load-command order.
    /// `slice` selects one slice range (from `sliceArchitectures`); nil keeps the first-slice behaviour.
    public static func linkedLibraries(in data: Data, slice: Range<Int>? = nil) throws -> [String] {
        try pathCommands(data, [lcLoadDylib, lcLoadWeakDylib, lcReexportDylib], slice: slice)
    }

    public static func rpaths(in data: Data, slice: Range<Int>? = nil) throws -> [String] {
        try pathCommands(data, [lcRpath], slice: slice)
    }

    /// LC_BUILD_VERSION of one slice (nil when the slice has none).
    public static func buildVersion(in data: Data, slice: Range<Int>) throws -> BuildVersion? {
        let b = slice.lowerBound
        guard slice.count >= 32 else { throw MachOError.truncated }
        guard try data.u32(b) == mhMagic64 else { throw MachOError.unsupported("non-64-bit slice") }
        let cpu = Int32(bitPattern: try data.u32(b + 4))
        let ncmds = Int(try data.u32(b + 16))
        var off = b + 32
        for _ in 0..<ncmds {
            guard off + 8 <= slice.upperBound else { throw MachOError.truncated }
            let cmd = try data.u32(off)
            let size = Int(try data.u32(off + 4))
            guard size >= 8, off + size <= slice.upperBound else { throw MachOError.truncated }
            if cmd == lcBuildVersion {
                guard size >= 24 else { throw MachOError.truncated }
                return BuildVersion(cpuType: cpu, platform: try data.u32(off + 8),
                                    minos: try data.u32(off + 12), sdk: try data.u32(off + 16))
            }
            off += size
        }
        return nil
    }

    /// The load command types of every slice, in file order (thin and fat 64-bit images).
    public static func loadCommandTypes(in data: Data) throws -> [UInt32] {
        var out: [UInt32] = []
        for r in try slices(data) { try forEachLoadCommand(data, slice: r) { _, cmd, _ in out.append(cmd) } }
        return out
    }

    /// True when `data` is a fat (universal) wrapper rather than a thin image.
    public static func isFat(_ data: Data) -> Bool {
        (try? data.u32(0, bigEndian: true)) == fatMagic
    }

    /// Architecture of each slice, in file order. A thin image yields one entry.
    /// `arm64` = 0x0100000c, `x86_64` = 0x01000007; any other cpu type is named `cpu<hex>`.
    public static func sliceArchitectures(in data: Data) throws -> [(cpuType: Int32, name: String, range: Range<Int>)] {
        try slices(data).map { r in
            guard r.count >= 8 else { throw MachOError.truncated }
            let raw = try data.u32(r.lowerBound + 4)
            let name: String
            switch raw {
            case 0x0100000c: name = "arm64"
            case 0x01000007: name = "x86_64"
            default: name = "cpu" + String(raw, radix: 16)
            }
            return (Int32(bitPattern: raw), name, r)
        }
    }

    /// Rewrites LC_BUILD_VERSION.sdk in every slice. Returns the number of commands patched.
    @discardableResult
    public static func patchSDK(in data: inout Data, to sdk: UInt32) throws -> Int {
        var offsets: [Int] = []
        try forEachBuildVersion(data) { off, _ in offsets.append(off) }
        for off in offsets { try data.setU32LE(off + 16, sdk) }
        return offsets.count
    }

    static let lcUUID: UInt32 = 0x1b

    /// LC_UUID of every slice that has one, in file order, as `dwarfdump --uuid` prints it (upper-case 8-4-4-4-12).
    /// A dSYM's DWARF file carries its binary's UUID: that is how crash reporters match the two.
    public static func uuids(in data: Data) throws -> [String] {
        var out: [String] = []
        for r in try slices(data) {
            try forEachLoadCommand(data, slice: r) { off, cmd, size in
                guard cmd == lcUUID else { return }
                guard size >= 24 else { throw MachOError.truncated }
                let hex = data[(off + 8)..<(off + 24)].map { String(format: "%02X", $0) }.joined()
                var parts: [Substring] = [], rest = Substring(hex)
                for n in [8, 4, 4, 4, 12] { parts.append(rest.prefix(n)); rest = rest.dropFirst(n) }
                out.append(parts.joined(separator: "-"))
            }
        }
        return out
    }

    /// Combines thin 64-bit slices into a universal binary (2^14 alignment).
    public static func makeFat(_ thins: [Data]) throws -> Data {
        let align: UInt32 = 14
        let alignBytes = 1 << Int(align)
        var out = Data()
        func be(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        be(fatMagic); be(UInt32(thins.count))
        var offset = 8 + 20 * thins.count
        var placements: [(Int, Data)] = []
        for t in thins {
            guard try t.u32(0) == mhMagic64 else { throw MachOError.notMachO }
            offset = (offset + alignBytes - 1) & ~(alignBytes - 1)
            be(try t.u32(4)); be(try t.u32(8)); be(UInt32(offset)); be(UInt32(t.count)); be(align)
            placements.append((offset, t))
            offset += t.count
        }
        for (off, t) in placements {
            out.append(Data(count: off - out.count))
            out.append(t)
        }
        return out
    }
}
