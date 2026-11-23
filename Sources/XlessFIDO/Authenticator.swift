import Crypto
import Foundation
import XlessCore

/// What authenticatorGetInfo says about a CTAP2 authenticator (the parts xless uses).
public struct AuthenticatorInfo: Equatable, Sendable {
    public var versions: [String] = []
    public var options: [String: Bool] = [:]
    public var pinProtocols: [Int] = []
    public var maxCredentialCountInList: Int?
    public var maxCredentialIDLength: Int?

    public init(versions: [String] = [], options: [String: Bool] = [:], pinProtocols: [Int] = [],
                maxCredentialCountInList: Int? = nil, maxCredentialIDLength: Int? = nil) {
        self.versions = versions; self.options = options; self.pinProtocols = pinProtocols
        self.maxCredentialCountInList = maxCredentialCountInList; self.maxCredentialIDLength = maxCredentialIDLength
    }

    init(_ map: CBOR) throws {
        guard map.mapValue != nil else { throw FIDOError.malformed("getInfo is not a map") }
        versions = map[1]?.arrayValue?.compactMap(\.textValue) ?? []
        for (k, v) in map[4]?.mapValue ?? [] { if let k = k.textValue, let v = v.boolValue { options[k] = v } }
        pinProtocols = map[6]?.arrayValue?.compactMap(\.intValue) ?? []
        maxCredentialCountInList = map[7]?.intValue
        maxCredentialIDLength = map[8]?.intValue
    }

    /// The PIN protocol to use: two when offered, else one (CTAP 2.0 keys list none and speak one).
    public var pinProtocol: PINProtocol { PINProtocol(version: pinProtocols.contains(2) ? 2 : 1)! }
}

/// A WebAuthn assertion as the authenticator gave it.
public struct Assertion: Equatable, Sendable {
    /// The credential used; nil when the authenticator left it out (allowed for a one-credential allow list).
    public var credentialID: [UInt8]?
    public var authenticatorData: [UInt8]
    public var signature: [UInt8]
    public var userHandle: [UInt8]?

    public init(credentialID: [UInt8]?, authenticatorData: [UInt8], signature: [UInt8], userHandle: [UInt8]?) {
        self.credentialID = credentialID; self.authenticatorData = authenticatorData
        self.signature = signature; self.userHandle = userHandle
    }
}

/// One opened authenticator, spoken to over a CTAPHID channel: CTAP2 commands, and U2F (CTAP1) for keys without CTAP2.
public final class Authenticator {
    enum CTAP2Command {
        static let getAssertion: UInt8 = 0x02
        static let getInfo: UInt8 = 0x04
        static let clientPIN: UInt8 = 0x06
    }
    public let channel: CTAPHIDChannel
    /// Called with each KEEPALIVE status while a command waits (for example, for a touch).
    public var onKeepalive: (UInt8) -> Void = { _ in }

    public init(channel: CTAPHIDChannel) { self.channel = channel }

    /// One CTAP2 command: the command byte and its CBOR parameters; the CBOR answer (`.null` when it has none).
    public func ctap2(_ command: UInt8, _ parameters: CBOR?, timeout: Double) throws -> CBOR {
        let answer = try channel.transact(CTAPHIDChannel.Command.cbor, [command] + (parameters?.encoded() ?? []), timeout: timeout,
                                          onKeepalive: onKeepalive)
        guard let status = answer.first else { throw FIDOError.malformed("an empty CTAP2 answer") }
        guard status == CTAP2Status.ok else { throw FIDOError.ctap(status) }
        guard answer.count > 1 else { return .null }
        do { return try CBOR.decode(Array(answer[1...])) } catch { throw FIDOError.malformed("\(error)") }
    }

    public func info(timeout: Double = 5) throws -> AuthenticatorInfo {
        try AuthenticatorInfo(try ctap2(CTAP2Command.getInfo, nil, timeout: timeout))
    }

    /// authenticatorGetAssertion. `userPresence: false` asks silently whether one of `allowList` is on this key (no
    /// touch, no usable signature); `pinAuth` is (pinUvAuthParam, protocol version).
    public func getAssertion(rpID: String, clientDataHash: [UInt8], allowList: [[UInt8]], userPresence: Bool,
                             userVerification: Bool = false, pinAuth: ([UInt8], Int)? = nil, timeout: Double) throws -> Assertion {
        // "up" is sent only to turn it off (its default is on: some CTAP 2.0 keys refuse it spelled out), as libfido2 does.
        var options: [(CBOR, CBOR)] = userPresence ? [] : [(.text("up"), .bool(false))]
        if userVerification { options.append((.text("uv"), .bool(true))) }
        var parameters: [(CBOR, CBOR)] = [
            (.int(1), .text(rpID)),
            (.int(2), .bytes(clientDataHash)),
            (.int(3), .array(allowList.map { .map([(.text("id"), .bytes($0)), (.text("type"), .text("public-key"))]) })),
        ]
        if !options.isEmpty { parameters.append((.int(5), .map(options))) }
        if let (param, version) = pinAuth { parameters += [(.int(6), .bytes(param)), (.int(7), .int(version))] }
        let answer = try ctap2(CTAP2Command.getAssertion, .map(parameters), timeout: timeout)
        guard let authData = answer[2]?.bytesValue, let signature = answer[3]?.bytesValue else {
            throw FIDOError.malformed("an assertion without authenticator data or signature")
        }
        return Assertion(credentialID: answer[1]?["id"]?.bytesValue, authenticatorData: authData, signature: signature,
                         userHandle: answer[4]?["id"]?.bytesValue)
    }

    // MARK: PIN

    private func clientPIN(_ version: Int, _ sub: Int, _ extra: [(CBOR, CBOR)] = [], timeout: Double = 10) throws -> CBOR {
        try ctap2(CTAP2Command.clientPIN, .map([(.int(1), .int(version)), (.int(2), .int(sub))] + extra), timeout: timeout)
    }

    /// How many PIN tries are left before the key locks; nil when it does not say.
    public func pinRetries(_ proto: PINProtocol) -> Int? {
        (try? clientPIN(proto.version, 0x01))?[3]?.intValue
    }

    /// A pinUvAuthToken for `pin`, limited to getAssertion on `rpID` when the key supports permissions.
    public func pinToken(pin: SecretBytes, rpID: String, info: AuthenticatorInfo) throws -> (PINProtocol, SymmetricKey) {
        let proto = info.pinProtocol
        guard let keyAgreement = try clientPIN(proto.version, 0x02)[1] else {
            throw FIDOError.malformed("no key-agreement key")
        }
        let agreement = try proto.agree(with: keyAgreement)
        let hash = try proto.pinHashEnc(agreement, pin: pin)
        let answer: CBOR
        if info.options["pinUvAuthToken"] == true {
            answer = try clientPIN(proto.version, 0x09, [(.int(3), agreement.platformKey), (.int(6), .bytes(hash)),
                                                         (.int(9), .int(0x02)), (.int(10), .text(rpID))])
        } else {
            answer = try clientPIN(proto.version, 0x05, [(.int(3), agreement.platformKey), (.int(6), .bytes(hash))])
        }
        guard let encrypted = answer[2]?.bytesValue else { throw FIDOError.malformed("no PIN token") }
        var token = try proto.decrypt(agreement, encrypted)
        defer { for i in token.indices { token[i] = 0 } }
        guard token.count == 16 || token.count == 32 else { throw FIDOError.malformed("a PIN token of \(token.count) bytes") }
        return (proto, SymmetricKey(data: token))
    }

    // MARK: U2F (CTAP1)

    public enum U2FStatus {
        public static let ok: UInt16 = 0x9000
        /// Sign: no touch yet. Check-only: the key handle IS this key's.
        public static let conditionsNotSatisfied: UInt16 = 0x6985
        /// The key handle is not this key's.
        public static let wrongData: UInt16 = 0x6A80
    }

    /// U2F_AUTHENTICATE (FIDO U2F raw messages, section 5): check-only (P1 0x07) or enforce-user-presence-and-sign
    /// (P1 0x03). Returns the response data; throws `FIDOError.u2f(status)` for any status but 0x9000.
    public func u2fAuthenticate(appParameter: [UInt8], challenge: [UInt8], keyHandle: [UInt8], checkOnly: Bool,
                                timeout: Double = 5) throws -> [UInt8] {
        guard keyHandle.count <= 255 else { throw FIDOError.u2f(U2FStatus.wrongData) }
        let data = challenge + appParameter + [UInt8(keyHandle.count)] + keyHandle
        let apdu: [UInt8] = [0x00, 0x02, checkOnly ? 0x07 : 0x03, 0x00, 0x00, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
            + data + [0x00, 0x00]
        let answer = try channel.transact(CTAPHIDChannel.Command.msg, apdu, timeout: timeout, onKeepalive: onKeepalive)
        guard answer.count >= 2 else { throw FIDOError.malformed("a U2F answer of \(answer.count) bytes") }
        let status = UInt16(answer[answer.count - 2]) << 8 | UInt16(answer[answer.count - 1])
        guard status == U2FStatus.ok else { throw FIDOError.u2f(status) }
        return Array(answer[0..<answer.count - 2])
    }
}
