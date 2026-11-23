import Crypto
import _CryptoExtras
import Foundation
import XlessCore
@testable import XlessFIDO

/// A security key in memory, speaking CTAPHID with CTAP2 (getInfo, getAssertion, clientPIN with PIN protocols one and
/// two) and U2F authenticate, and signing with real P-256 credentials. The framing and the PIN protocol's key
/// derivation are written here again, from the specification, rather than borrowed from XlessFIDO.
final class SimulatedKey: HIDConnection, @unchecked Sendable {
    struct Credential {
        let id: [UInt8]
        let key = P256.Signing.PrivateKey()
        var userID: [UInt8]? = nil
    }
    enum Touch { case yes, never, deny }

    var credentials: [Credential]
    var rpID = "apple.com"
    var ctap2 = true
    var u2f = true
    var pin: String?
    var pinRetries = 8
    var consecutiveWrongPINs = 0
    var alwaysUV = false
    var builtInUV: Bool?
    var pinProtocols = [2, 1]
    var tokenPermissions = true
    var maxCredentialCountInList: Int?
    var omitCredentialForOneItemList = false
    var keepalives = 2
    var touch = Touch.yes
    /// U2F: how many "not touched yet" answers before the signature.
    var u2fWaits = 2
    var counter: UInt32 = 7
    var reportSize = 64
    var channelID: UInt32 = 0x0102_0304
    /// Packets of another channel put before each answer.
    var noise = false
    /// Sign over this relying party instead of the one asked for (a misbehaving key).
    var signRPOverride: String?

    private(set) var log: [String] = []
    private var outbox: [[UInt8]] = []
    private var inbound: (cid: UInt32, cmd: UInt8, length: Int, data: [UInt8], seq: UInt8)?
    private let agreementKey = P256.KeyAgreement.PrivateKey()
    private var token: (bytes: [UInt8], version: Int, rp: String?)?

    init(credentials: [Credential]) { self.credentials = credentials }

    var touchesAsked: Int { log.filter { $0 == "getAssertion up" || $0 == "u2f sign" }.count }

    // MARK: HIDConnection

    func write(_ report: [UInt8]) throws {
        precondition(report.count == reportSize)
        let cid = UInt32(report[0]) << 24 | UInt32(report[1]) << 16 | UInt32(report[2]) << 8 | UInt32(report[3])
        if report[4] & 0x80 != 0 {
            let length = Int(report[5]) << 8 | Int(report[6])
            inbound = (cid, report[4], length, Array(report[7..<min(reportSize, 7 + length)]), 0)
        } else if var message = inbound, message.cid == cid {
            precondition(report[4] == message.seq, "continuation out of order")
            message.data += report[5..<min(reportSize, 5 + message.length - message.data.count)]
            message.seq += 1
            inbound = message
        }
        guard let message = inbound, message.data.count == message.length else { return }
        inbound = nil
        handle(cid: message.cid, cmd: message.cmd, data: message.data)
    }

    func read(timeout milliseconds: Int) throws -> [UInt8]? { outbox.isEmpty ? nil : outbox.removeFirst() }

    // MARK: Framing

    private func reply(_ cid: UInt32, _ cmd: UInt8, _ payload: [UInt8]) {
        if noise { frames(0x0BAD_0BAD, cmd, [0x99, 0x99]) }
        frames(cid, cmd, payload)
    }

    private func frames(_ cid: UInt32, _ cmd: UInt8, _ payload: [UInt8]) {
        let c = [UInt8(cid >> 24), UInt8(cid >> 16 & 0xFF), UInt8(cid >> 8 & 0xFF), UInt8(cid & 0xFF)]
        var packet = c + [cmd, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        var used = min(payload.count, reportSize - 7)
        packet += payload[0..<used]
        outbox.append(packet + [UInt8](repeating: 0, count: reportSize - packet.count))
        var seq: UInt8 = 0
        while used < payload.count {
            let end = min(payload.count, used + reportSize - 5)
            packet = c + [seq] + payload[used..<end]
            outbox.append(packet + [UInt8](repeating: 0, count: reportSize - packet.count))
            used = end; seq += 1
        }
    }

    private func handle(cid: UInt32, cmd: UInt8, data: [UInt8]) {
        switch cmd {
        case 0x86:
            log.append("init")
            let caps: UInt8 = 0x01 | (ctap2 ? 0x04 : 0) | (u2f ? 0 : 0x08)
            let ch = channelID
            reply(cid, 0x86, data + [UInt8(ch >> 24), UInt8(ch >> 16 & 0xFF), UInt8(ch >> 8 & 0xFF), UInt8(ch & 0xFF), 2, 5, 4, 3, caps])
        case 0x90 where ctap2:
            let status: UInt8, body: CBOR?
            (status, body) = ctap(data)
            reply(cid, 0x90, [status] + (body?.encoded() ?? []))
        case 0x83 where u2f:
            reply(cid, 0x83, u2fMessage(data))
        case 0x91:
            log.append("cancel")
        default:
            reply(cid, 0xBF, [0x01])
        }
    }

    // MARK: CTAP2

    private func ctap(_ data: [UInt8]) -> (UInt8, CBOR?) {
        let parameters = data.count > 1 ? (try? CBOR.decode(Array(data[1...]))) : nil
        switch data.first {
        case 0x04:
            log.append("getInfo")
            var options: [(CBOR, CBOR)] = [(.text("rk"), .bool(true)), (.text("up"), .bool(true))]
            options.append((.text("clientPin"), .bool(pin != nil)))
            if let builtInUV { options.append((.text("uv"), .bool(builtInUV))) }
            if tokenPermissions { options.append((.text("pinUvAuthToken"), .bool(true))) }
            if alwaysUV { options.append((.text("alwaysUv"), .bool(true))) }
            var info: [(CBOR, CBOR)] = [
                (.int(1), .array([.text("U2F_V2"), .text("FIDO_2_0"), .text("FIDO_2_1")])),
                (.int(3), .bytes([UInt8](repeating: 0xAA, count: 16))),
                (.int(4), .map(options)),
                (.int(6), .array(pinProtocols.map { .int($0) })),
            ]
            if let maxCredentialCountInList { info.append((.int(7), .int(maxCredentialCountInList))) }
            return (0, .map(info))
        case 0x02:
            return getAssertion(parameters ?? .null)
        case 0x06:
            return clientPIN(parameters ?? .null)
        default:
            return (0x01, nil)
        }
    }

    private func getAssertion(_ p: CBOR) -> (UInt8, CBOR?) {
        guard let rp = p[1]?.textValue, let cdh = p[2]?.bytesValue, let allow = p[3]?.arrayValue else { return (0x14, nil) }
        let ids = allow.compactMap { $0["id"]?.bytesValue }
        let up = p[5]?["up"]?.boolValue ?? true
        let uv = p[5]?["uv"]?.boolValue ?? false
        log.append(up ? "getAssertion up" : "getAssertion probe")
        if let max = maxCredentialCountInList, ids.count > max { return (0x15, nil) }
        var verified = false
        if let param = p[6]?.bytesValue {
            guard let token, let version = p[7]?.intValue, version == token.version, token.rp == nil || token.rp == rp else { return (0x33, nil) }
            let mac = Array(HMAC<SHA256>.authenticationCode(for: cdh, using: SymmetricKey(data: token.bytes)))
            guard param == (version == 1 ? Array(mac[0..<16]) : mac) else { return (0x33, nil) }
            verified = true
        } else if uv {
            guard builtInUV == true else { return (0x2C, nil) }
            verified = true
        } else if alwaysUV {
            return (0x36, nil)
        }
        guard rp == rpID, let credential = credentials.first(where: { ids.contains($0.id) }) else { return (0x2E, nil) }
        if up {
            for _ in 0..<keepalives { frames(channelID, 0xBB, [0x02]) }
            switch touch {
            case .never: return (0x2F, nil)
            case .deny: return (0x27, nil)
            case .yes: break
            }
        }
        counter += 1
        let rpHash = Array(SHA256.hash(data: Array((signRPOverride ?? rp).utf8)))
        let flags: UInt8 = (up ? 0x01 : 0) | (verified ? 0x04 : 0)
        let authData = rpHash + [flags] + bigEndian(counter)
        let signature = Array(try! credential.key.signature(for: authData + cdh).derRepresentation)
        var answer: [(CBOR, CBOR)] = [(.int(2), .bytes(authData)), (.int(3), .bytes(signature))]
        if !(omitCredentialForOneItemList && ids.count == 1) {
            answer.append((.int(1), .map([(.text("id"), .bytes(credential.id)), (.text("type"), .text("public-key"))])))
        }
        if let userID = credential.userID { answer.append((.int(4), .map([(.text("id"), .bytes(userID))]))) }
        return (0, .map(answer))
    }

    private func clientPIN(_ p: CBOR) -> (UInt8, CBOR?) {
        guard let version = p[1]?.intValue, pinProtocols.contains(version), let sub = p[2]?.intValue else { return (0x02, nil) }
        log.append("clientPIN \(sub)")
        switch sub {
        case 0x01:
            return (0, .map([(.int(3), .int(pinRetries))]))
        case 0x02:
            let point = Array(agreementKey.publicKey.x963Representation)
            return (0, .map([(.int(1), .map([(.int(1), .int(2)), (.int(3), .int(-25)), (.int(-1), .int(1)),
                                             (.int(-2), .bytes(Array(point[1..<33]))), (.int(-3), .bytes(Array(point[33..<65])))]))]))
        case 0x05, 0x09:
            guard let pin else { return (0x35, nil) }
            if sub == 0x09 { guard p[9]?.intValue == 0x02, p[10]?.textValue == rpID else { return (0x02, nil) } }
            guard pinRetries > 0 else { return (0x32, nil) }
            guard consecutiveWrongPINs < 3 else { return (0x34, nil) }
            guard let x = p[3]?[-2]?.bytesValue, let y = p[3]?[-3]?.bytesValue, let enc = p[6]?.bytesValue,
                  let peer = try? P256.KeyAgreement.PublicKey(x963Representation: [0x04] + x + y),
                  let z = try? agreementKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes({ Array($0) }) else { return (0x02, nil) }
            let (hmacKey, aesKey) = derive(z, version)
            _ = hmacKey
            guard let hash = decrypt(enc, aesKey, version) else { return (0x02, nil) }
            guard hash == Array(Array(SHA256.hash(data: Array(pin.utf8)))[0..<16]) else {
                pinRetries -= 1
                consecutiveWrongPINs += 1
                if pinRetries == 0 { return (0x32, nil) }
                return (consecutiveWrongPINs >= 3 ? 0x34 : 0x31, nil)
            }
            consecutiveWrongPINs = 0
            pinRetries = 8
            let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
            token = (bytes, version, sub == 0x09 ? rpID : nil)
            return (0, .map([(.int(2), .bytes(encrypt(bytes, aesKey, version)))]))
        default:
            return (0x01, nil)
        }
    }

    private func derive(_ z: [UInt8], _ version: Int) -> ([UInt8], [UInt8]) {
        if version == 1 { let k = Array(SHA256.hash(data: z)); return (k, k) }
        let salt = [UInt8](repeating: 0, count: 32)
        func hkdf(_ info: String) -> [UInt8] {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: z), salt: salt, info: Array(info.utf8), outputByteCount: 32)
                .withUnsafeBytes { Array($0) }
        }
        return (hkdf("CTAP2 HMAC key"), hkdf("CTAP2 AES key"))
    }

    private func encrypt(_ data: [UInt8], _ key: [UInt8], _ version: Int) -> [UInt8] {
        let iv = version == 1 ? [UInt8](repeating: 0, count: 16) : (0..<16).map { _ in UInt8.random(in: 0...255) }
        let body = Array(try! AES._CBC.encrypt(data, using: SymmetricKey(data: key), iv: try! AES._CBC.IV(ivBytes: iv), noPadding: true))
        return version == 1 ? body : iv + body
    }

    private func decrypt(_ data: [UInt8], _ key: [UInt8], _ version: Int) -> [UInt8]? {
        let iv = version == 1 ? [UInt8](repeating: 0, count: 16) : Array(data.prefix(16))
        let body = version == 1 ? data : Array(data.dropFirst(16))
        return (try? AES._CBC.decrypt(body, using: SymmetricKey(data: key), iv: try AES._CBC.IV(ivBytes: iv), noPadding: true)).map(Array.init)
    }

    // MARK: U2F

    private func u2fMessage(_ apdu: [UInt8]) -> [UInt8] {
        guard apdu.count >= 7, apdu[1] == 0x02 else { return [0x6D, 0x00] }
        let length = Int(apdu[5]) << 8 | Int(apdu[6])
        guard apdu.count >= 7 + length, length >= 65 else { return [0x67, 0x00] }
        let data = Array(apdu[7..<7 + length])
        let challenge = Array(data[0..<32]), app = Array(data[32..<64])
        let handle = Array(data[65..<65 + Int(data[64])])
        guard app == Array(SHA256.hash(data: Array(rpID.utf8))), let credential = credentials.first(where: { $0.id == handle }) else {
            log.append("u2f wrong")
            return [0x6A, 0x80]
        }
        if apdu[2] == 0x07 { log.append("u2f check"); return [0x69, 0x85] }
        log.append("u2f sign")
        if u2fWaits > 0 { u2fWaits -= 1; return [0x69, 0x85] }
        counter += 1
        let signed = app + [0x01] + bigEndian(counter) + challenge
        let signature = Array(try! credential.key.signature(for: signed).derRepresentation)
        return [0x01] + bigEndian(counter) + signature + [0x90, 0x00]
    }

    private func bigEndian(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] }
}

struct SimulatedDevice: SecurityKeyDevice {
    let name: String
    let path: String
    let key: SimulatedKey
    var openError: HIDOpenError?
    func open() throws -> HIDConnection {
        if let openError { throw openError }
        return key
    }
}

/// The terminal, scripted: PINs from a queue, Enter presses counted.
final class ScriptedUI: SecurityKeyUI, @unchecked Sendable {
    private let lock = NSLock()
    private var pins: [String]
    private(set) var said: [String] = []
    private(set) var prompts: [String] = []
    private(set) var keyWaits = 0
    var onWaitForKey: () -> Void = {}

    init(pins: [String] = []) { self.pins = pins }

    func say(_ line: String) { lock.withLock { said.append(line) } }
    func askPIN(_ prompt: String) async throws -> SecretBytes {
        try lock.withLock {
            prompts.append(prompt)
            guard !pins.isEmpty else { throw SecurityKeyError("no scripted PIN", fix: "") }
            return SecretBytes(utf8: pins.removeFirst())
        }
    }
    func waitForKey(_ prompt: String) async throws {
        lock.withLock { prompts.append(prompt); keyWaits += 1 }
        onWaitForKey()
    }
}
