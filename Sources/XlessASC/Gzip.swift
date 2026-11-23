import Foundation

// A streaming gzip (RFC 1952) / deflate (RFC 1951) decoder in Swift, with no zlib: App Store Connect hands sales and
// finance reports out gzipped, and xless writes them to disk decompressed as they arrive, never holding a whole report
// in memory. No C library keeps the static Linux build free of one more dependency (the Xar writer avoids zlib too).

/// Data that is not a gzip stream, or one that is corrupt or cut short.
public struct GzipError: Error, CustomStringConvertible, Sendable, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// CRC-32 (IEEE 802.3, reflected), gzip's checksum.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// `crc` (0 to start) carried over `bytes`.
    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    public static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { update(0, $0) } }
}

/// Decompresses gzip data fed in pieces of any size (`write`), handing the output to `output` in pieces as it goes; holds
/// at most deflate's 32 KiB window plus a bounded amount of pending output. Several gzip members one after another
/// (what `cat a.gz b.gz` makes) decode as one stream. Every member's CRC-32 and length are checked; `finish` fails when
/// the data stopped in the middle of a member.
public struct GzipDecoder {
    /// The first two bytes of every gzip member.
    public static func isGzip(_ prefix: Data) -> Bool {
        prefix.count >= 2 && prefix[prefix.startIndex] == 0x1F && prefix[prefix.startIndex + 1] == 0x8B
    }

    private enum Phase { case header, block, stored(Int), codes, trailer }
    private struct NeedMore: Error {}

    private let output: (Data) throws -> Void
    private var input: [UInt8] = []
    private var pos = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0
    private var phase = Phase.header
    private var lastBlock = false
    private var literals = Huffman.fixedLiterals
    private var distances = Huffman.fixedDistances
    /// The last 32 KiB of output (back-references reach into it) followed by what has not been handed out yet.
    private var window: [UInt8] = []
    private var pending = 0
    private var crc: UInt32 = 0
    private var size: UInt32 = 0
    private var members = 0
    /// Decompressed bytes handed to `output` so far.
    public private(set) var bytesOut = 0

    static let windowSize = 32768
    /// Output is handed out once this much is pending, even in the middle of one `write`.
    static let flushThreshold = 256 * 1024

    public init(output: @escaping (Data) throws -> Void) { self.output = output }

    /// Decodes `data`, the next piece of the stream.
    public mutating func write(_ data: Data) throws {
        if pos > 0 { input.removeFirst(pos); pos = 0 }
        input.append(contentsOf: data)
        try run()
        try flush()
    }

    /// The stream is over: fails when it stopped inside a member (or held no member at all).
    public mutating func finish() throws {
        try run()
        try flush()
        guard case .header = phase, pos == input.count, bitCount == 0 else { throw GzipError("the gzip data ends before its end (truncated)") }
        guard members > 0 else { throw GzipError("the gzip data is empty") }
    }

    // MARK: Driving

    private mutating func run() throws {
        while true {
            let saved = (pos, bitBuffer, bitCount)
            do {
                guard try step() else { return }
            } catch is NeedMore {
                (pos, bitBuffer, bitCount) = saved
                return
            }
            if window.count - pending >= Self.flushThreshold { try flush() }
        }
    }

    /// One indivisible piece: a header, a block header, a symbol, some stored bytes or a trailer. Returns false when
    /// there is nothing to do until more input comes; throws `NeedMore` to be rolled back to where it started.
    private mutating func step() throws -> Bool {
        switch phase {
        case .header:
            guard pos < input.count || bitCount > 0 else { return false }
            try readHeader()
            phase = .block
        case .block:
            try readBlockHeader()
        case .stored(var left):
            if left == 0 { phase = lastBlock ? .trailer : .block; return true }
            let before = left
            while left > 0, bitCount >= 8 {
                window.append(UInt8(truncatingIfNeeded: bitBuffer))
                bitBuffer >>= 8; bitCount -= 8; left -= 1
            }
            let take = min(left, input.count - pos)
            window.append(contentsOf: input[pos..<pos + take])
            pos += take; left -= take
            if left == before { throw NeedMore() }
            phase = .stored(left)
        case .codes:
            try readSymbol()
        case .trailer:
            dropToByte()
            let expectedCRC = UInt32(try bits(32))
            let expectedSize = UInt32(try bits(32))
            try flush()
            guard expectedCRC == crc else { throw GzipError("the gzip data is corrupt (CRC-32 mismatch)") }
            guard expectedSize == size else { throw GzipError("the gzip data is corrupt (length mismatch)") }
            crc = 0; size = 0; members += 1
            window.removeAll(keepingCapacity: true); pending = 0
            phase = .header
        }
        return true
    }

    /// Hands out the pending output and keeps the last 32 KiB as the window.
    private mutating func flush() throws {
        guard window.count > pending else { return }
        let chunk = window[pending...]
        chunk.withUnsafeBytes { crc = CRC32.update(crc, $0) }
        size &+= UInt32(truncatingIfNeeded: chunk.count)
        bytesOut += chunk.count
        try output(Data(chunk))
        if window.count > 2 * Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        pending = window.count
    }

    // MARK: Bits

    /// Loads whole bytes until `n` bits are held or the input runs out.
    private mutating func fill(_ n: Int) {
        while bitCount < n, pos < input.count {
            bitBuffer |= UInt64(input[pos]) << UInt64(bitCount)
            pos += 1; bitCount += 8
        }
    }

    private mutating func bits(_ n: Int) throws -> UInt64 {
        if n == 0 { return 0 }
        fill(n)
        guard bitCount >= n else { throw NeedMore() }
        let value = bitBuffer & ((1 << UInt64(n)) - 1)
        bitBuffer >>= UInt64(n); bitCount -= n
        return value
    }

    private mutating func dropToByte() {
        let extra = bitCount & 7
        bitBuffer >>= UInt64(extra); bitCount -= extra
    }

    // MARK: gzip

    private mutating func readHeader() throws {
        let id1 = try bits(8), id2 = try bits(8)
        guard id1 == 0x1F, id2 == 0x8B else {
            throw GzipError(members == 0 ? "the data is not gzip" : "the gzip data has something that is not gzip after its end")
        }
        guard try bits(8) == 8 else { throw GzipError("the gzip data uses a compression method other than deflate") }
        let flags = try bits(8)
        guard flags & 0xE0 == 0 else { throw GzipError("the gzip header has reserved flags set") }
        _ = try bits(32); _ = try bits(16) // MTIME, XFL, OS
        if flags & 0x04 != 0 { for _ in 0..<(try bits(16)) { _ = try bits(8) } } // FEXTRA
        if flags & 0x08 != 0 { while try bits(8) != 0 {} } // FNAME
        if flags & 0x10 != 0 { while try bits(8) != 0 {} } // FCOMMENT
        if flags & 0x02 != 0 { _ = try bits(16) } // FHCRC
        lastBlock = false
    }

    // MARK: deflate

    private mutating func readBlockHeader() throws {
        let final = try bits(1) == 1
        switch try bits(2) {
        case 0:
            dropToByte()
            let length = try bits(16), check = try bits(16)
            guard length == ~check & 0xFFFF else { throw GzipError("the gzip data is corrupt (stored block length)") }
            phase = .stored(Int(length))
        case 1:
            literals = Huffman.fixedLiterals; distances = Huffman.fixedDistances
            phase = .codes
        case 2:
            try readDynamicTables()
            phase = .codes
        default:
            throw GzipError("the gzip data is corrupt (block type 3)")
        }
        lastBlock = final
    }

    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private mutating func readDynamicTables() throws {
        let literalCount = Int(try bits(5)) + 257, distanceCount = Int(try bits(5)) + 1, codeCount = Int(try bits(4)) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw GzipError("the gzip data is corrupt (too many codes)") }
        var codeLengths = [UInt8](repeating: 0, count: 19)
        for i in 0..<codeCount { codeLengths[Self.codeLengthOrder[i]] = UInt8(try bits(3)) }
        let lengthCode = try Huffman(codeLengths[...])
        var lengths: [UInt8] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try decode(lengthCode)
            switch symbol {
            case 0...15: lengths.append(UInt8(symbol))
            case 16:
                guard let previous = lengths.last else { throw GzipError("the gzip data is corrupt (repeat with no length)") }
                lengths += repeatElement(previous, count: 3 + Int(try bits(2)))
            case 17: lengths += repeatElement(0, count: 3 + Int(try bits(3)))
            default: lengths += repeatElement(0, count: 11 + Int(try bits(7)))
            }
        }
        guard lengths.count == literalCount + distanceCount else { throw GzipError("the gzip data is corrupt (code lengths overrun)") }
        guard lengths[256] != 0 else { throw GzipError("the gzip data is corrupt (no end-of-block code)") }
        literals = try Huffman(lengths[0..<literalCount])
        distances = try Huffman(lengths[literalCount...])
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                      4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private mutating func readSymbol() throws {
        let symbol = try decode(literals)
        if symbol < 256 { window.append(UInt8(symbol)); return }
        if symbol == 256 { phase = lastBlock ? .trailer : .block; return }
        let index = symbol - 257
        guard index < Self.lengthBase.count else { throw GzipError("the gzip data is corrupt (length code)") }
        let length = Self.lengthBase[index] + Int(try bits(Self.lengthExtra[index]))
        let code = try decode(distances)
        guard code < Self.distanceBase.count else { throw GzipError("the gzip data is corrupt (distance code)") }
        let distance = Self.distanceBase[code] + Int(try bits(Self.distanceExtra[code]))
        guard distance <= window.count else { throw GzipError("the gzip data is corrupt (distance too far back)") }
        let start = window.count - distance
        for i in 0..<length { window.append(window[start + i]) }
    }

    private mutating func decode(_ code: Huffman) throws -> Int {
        fill(code.bits)
        let entry = code.table[Int(bitBuffer & ((1 << UInt64(code.bits)) - 1))]
        let length = Int(entry & 0xFF)
        guard length > 0 else {
            if bitCount < code.bits { throw NeedMore() }
            throw GzipError("the gzip data is corrupt (invalid code)")
        }
        guard length <= bitCount else { throw NeedMore() }
        bitBuffer >>= UInt64(length); bitCount -= length
        return Int(entry >> 8)
    }
}

/// A canonical Huffman code as a lookup table indexed by the next `bits` bits of the stream (codes are stored
/// bit-reversed, as deflate packs them): each entry is `symbol << 8 | code length`, 0 for no code.
struct Huffman {
    var table: [UInt32]
    var bits: Int

    init(_ lengths: ArraySlice<UInt8>) throws {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths { counts[Int(length)] += 1 }
        counts[0] = 0
        var left = 1
        for length in 1...15 {
            left = left << 1 - counts[length]
            guard left >= 0 else { throw GzipError("the gzip data is corrupt (over-subscribed code)") }
        }
        let maxLength = lengths.max().map(Int.init) ?? 0
        bits = max(maxLength, 1)
        table = [UInt32](repeating: 0, count: 1 << bits)
        var next = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + counts[length - 1]) << 1
            next[length] = code
        }
        for (symbol, l) in lengths.enumerated() where l > 0 {
            let length = Int(l)
            let value = next[length]
            next[length] += 1
            var reversed = 0
            for i in 0..<length where value & (1 << i) != 0 { reversed |= 1 << (length - 1 - i) }
            let entry = UInt32(symbol) << 8 | UInt32(length)
            var index = reversed
            while index < table.count { table[index] = entry; index += 1 << length }
        }
    }

    static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return try! Huffman(lengths[...])
    }()

    static let fixedDistances: Huffman = try! Huffman([UInt8](repeating: 5, count: 30)[...])
}
