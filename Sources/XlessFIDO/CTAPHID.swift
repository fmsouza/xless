import Foundation

/// One HID device, as reports of a fixed size (64 bytes for every FIDO key). `write` takes one output report without
/// a report ID; `read` returns one input report, or nil when none came within `timeout` milliseconds.
public protocol HIDConnection: AnyObject {
    var reportSize: Int { get }
    func write(_ report: [UInt8]) throws
    func read(timeout milliseconds: Int) throws -> [UInt8]?
}

/// CTAPHID (CTAP 2.1, section 11.2): messages split into an initialization packet and continuation packets on a
/// channel the authenticator allocates in answer to INIT.
public final class CTAPHIDChannel {
    public enum Command {
        public static let ping: UInt8 = 0x81
        public static let msg: UInt8 = 0x83
        public static let initialize: UInt8 = 0x86
        public static let wink: UInt8 = 0x88
        public static let cbor: UInt8 = 0x90
        public static let cancel: UInt8 = 0x91
        public static let keepalive: UInt8 = 0xBB
        public static let error: UInt8 = 0xBF
    }
    public enum Capability {
        public static let wink: UInt8 = 0x01
        public static let cbor: UInt8 = 0x04
        /// The authenticator does NOT implement CTAPHID_MSG (U2F).
        public static let nmsg: UInt8 = 0x08
    }
    /// KEEPALIVE status: still processing, or waiting for the user's touch.
    public enum KeepaliveStatus {
        public static let processing: UInt8 = 1
        public static let userPresenceNeeded: UInt8 = 2
    }
    static let broadcast: UInt32 = 0xFFFF_FFFF
    static let maxPayload = 7609

    public let connection: HIDConnection
    public let channel: UInt32
    public let capabilities: UInt8
    public var supportsCBOR: Bool { capabilities & Capability.cbor != 0 }
    public var supportsMSG: Bool { capabilities & Capability.nmsg == 0 }

    /// Allocates a channel (CTAPHID_INIT with an 8-byte `nonce`).
    public init(_ connection: HIDConnection, nonce: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) },
                timeout: Double = 3) throws {
        precondition(nonce.count == 8)
        self.connection = connection
        try Self.send(connection, channel: Self.broadcast, command: Command.initialize, payload: nonce)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (command, payload) = try Self.receive(connection, channel: Self.broadcast, deadline: deadline)
            // Another program's INIT answer on the broadcast channel carries its own nonce: skip it.
            guard command == Command.initialize, payload.count >= 17, Array(payload[0..<8]) == nonce else {
                if command == Command.error, let code = payload.first { throw FIDOError.hid(code) }
                continue
            }
            channel = UInt32(payload[8]) << 24 | UInt32(payload[9]) << 16 | UInt32(payload[10]) << 8 | UInt32(payload[11])
            capabilities = payload[16]
            guard channel != 0, channel != Self.broadcast else { throw FIDOError.malformed("INIT gave channel \(channel)") }
            return
        }
    }

    /// Sends `payload` as `command` and returns the answer's payload. KEEPALIVE frames are passed to `onKeepalive` and do
    /// not end the wait; an ERROR frame throws `FIDOError.hid`.
    public func transact(_ command: UInt8, _ payload: [UInt8], timeout: Double,
                         onKeepalive: (UInt8) -> Void = { _ in }) throws -> [UInt8] {
        try Self.send(connection, channel: channel, command: command, payload: payload)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (answer, data) = try Self.receive(connection, channel: channel, deadline: deadline)
            switch answer {
            case Command.keepalive: onKeepalive(data.first ?? 0)
            case Command.error: throw FIDOError.hid(data.first ?? 0)
            case command: return data
            default: throw FIDOError.malformed(String(format: "answer 0x%02X to command 0x%02X", answer, command))
            }
        }
    }

    /// Asks the authenticator to stop waiting for a touch (best effort, no answer expected).
    public func cancel() { try? Self.send(connection, channel: channel, command: Command.cancel, payload: []) }

    static func send(_ connection: HIDConnection, channel: UInt32, command: UInt8, payload: [UInt8]) throws {
        guard payload.count <= maxPayload else { throw FIDOError.malformed("a request of \(payload.count) bytes") }
        let size = connection.reportSize
        let cid: [UInt8] = [UInt8(channel >> 24), UInt8(channel >> 16 & 0xFF), UInt8(channel >> 8 & 0xFF), UInt8(channel & 0xFF)]
        var packet = cid + [command, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        var offset = min(payload.count, size - 7)
        packet += payload[0..<offset]
        try connection.write(packet + [UInt8](repeating: 0, count: size - packet.count))
        var sequence: UInt8 = 0
        while offset < payload.count {
            let end = min(payload.count, offset + size - 5)
            packet = cid + [sequence] + payload[offset..<end]
            try connection.write(packet + [UInt8](repeating: 0, count: size - packet.count))
            offset = end
            sequence += 1
        }
    }

    /// The next whole message on `channel`; packets of other channels are skipped.
    static func receive(_ connection: HIDConnection, channel: UInt32, deadline: Date) throws -> (UInt8, [UInt8]) {
        func next() throws -> [UInt8] {
            while true {
                let left = Int(deadline.timeIntervalSinceNow * 1000)
                guard left > 0, let packet = try connection.read(timeout: left) else { throw FIDOError.timeout }
                guard packet.count >= 7 else { throw FIDOError.malformed("a \(packet.count)-byte report") }
                let cid = UInt32(packet[0]) << 24 | UInt32(packet[1]) << 16 | UInt32(packet[2]) << 8 | UInt32(packet[3])
                if cid == channel { return packet }
            }
        }
        var first = try next()
        while first[4] & 0x80 == 0 { first = try next() } // a stray continuation packet: not the start of a message
        let command = first[4]
        let length = Int(first[5]) << 8 | Int(first[6])
        guard length <= maxPayload else { throw FIDOError.malformed("an answer of \(length) bytes") }
        var data = Array(first[7..<min(first.count, 7 + length)])
        var sequence: UInt8 = 0
        while data.count < length {
            let packet = try next()
            guard packet[4] & 0x80 == 0 else { throw FIDOError.malformed("a new message before the last one ended") }
            guard packet[4] == sequence else { throw FIDOError.malformed("packet \(packet[4]) where \(sequence) was due") }
            data += packet[5..<min(packet.count, 5 + length - data.count)]
            sequence += 1
        }
        return (command, data)
    }
}
