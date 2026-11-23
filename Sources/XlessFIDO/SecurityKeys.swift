import Crypto
import Foundation
import XlessCore

/// What a WebAuthn assertion is asked for: the relying party, the hash of the client data, and the credentials the
/// relying party accepts (Apple's allow list).
public struct AssertionRequest: Sendable, Equatable {
    public let rpID: String
    public let clientDataHash: [UInt8]
    public let credentials: [[UInt8]]

    public init(rpID: String, clientDataHash: [UInt8], credentials: [[UInt8]]) {
        self.rpID = rpID; self.clientDataHash = clientDataHash; self.credentials = credentials
    }
}

/// The terminal the security-key steps talk to.
public protocol SecurityKeyUI: Sendable {
    func say(_ line: String)
    /// The key's PIN, read with echo off; zeroed when released.
    func askPIN(_ prompt: String) async throws -> SecretBytes
    /// Waits until the person says the key is plugged in (Enter).
    func waitForKey(_ prompt: String) async throws
}

/// Something that produces assertions: the USB keys (`USBSecurityKeys`), or a fake in tests.
public protocol SecurityKeySource: Sendable {
    /// An assertion over `request` from a key holding one of its credentials. The result's `credentialID` is always set
    /// and is one of `request.credentials`. Throws `SecurityKeyError`.
    func assertion(for request: AssertionRequest, ui: any SecurityKeyUI) async throws -> Assertion
}

/// A FIDO HID device found on the system.
public protocol SecurityKeyDevice {
    /// For display, e.g. "Yubico YubiKey OTP+FIDO+CCID".
    var name: String { get }
    var path: String { get }
    func open() throws -> HIDConnection
}

/// Opening a device failed.
public enum HIDOpenError: Error, Equatable, Sendable {
    case permissionDenied(String)
    case failed(String, String)
}

/// The USB security keys plugged into this machine, spoken to directly (CTAP2, or U2F for keys without it).
public struct USBSecurityKeys: SecurityKeySource {
    let devices: @Sendable () throws -> [any SecurityKeyDevice]
    let touchTimeout: Double
    let sleep: @Sendable (Double) async throws -> Void

    public init(devices: @escaping @Sendable () throws -> [any SecurityKeyDevice] = { try HIDRawDevices.list() },
                touchTimeout: Double = 60,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.devices = devices; self.touchTimeout = touchTimeout; self.sleep = sleep
    }

    static let maxKeyPrompts = 3
    static let maxPINAttempts = 3

    public func assertion(for request: AssertionRequest, ui: any SecurityKeyUI) async throws -> Assertion {
        guard !request.credentials.isEmpty else { throw SecurityKeyError.notRegistered }
        do {
            return try await run(request, ui: ui)
        } catch {
            throw Self.describe(error)
        }
    }

    private func run(_ request: AssertionRequest, ui: any SecurityKeyUI) async throws -> Assertion {
        var found = try devices()
        var prompts = 0
        while found.isEmpty {
            guard prompts < Self.maxKeyPrompts else { throw SecurityKeyError.noKey }
            try await ui.waitForKey("Plug in your security key, then press Enter: ")
            prompts += 1
            found = try devices()
        }

        var opened: [OpenedKey] = []
        var denied: [String] = []
        var failure: Error?
        for device in found {
            do {
                opened.append(try OpenedKey(device: device))
            } catch HIDOpenError.permissionDenied(let path) {
                denied.append(path)
            } catch {
                failure = error
            }
        }
        if opened.isEmpty {
            if !denied.isEmpty { throw SecurityKeyError.permission(denied) }
            throw failure ?? SecurityKeyError.noKey
        }

        // Ask each key, without a touch, whether it holds one of the credentials; use the first that does.
        var chosen: (OpenedKey, Match)?
        for key in opened {
            switch key.probe(request) {
            case .some(.holds(let list)): chosen = (key, .holds(list))
            case .some(.unknown): if chosen == nil { chosen = (key, .unknown) }
            case nil: continue
            }
            if case .holds = chosen?.1 { break }
        }
        guard let (key, match) = chosen else { throw SecurityKeyError.notRegistered }

        ui.say("Touch your security key (\(key.device.name)) to sign in.")
        if key.info == nil { return try await u2fSign(key, request, match: match) }
        return try await ctap2Sign(key, request, match: match, ui: ui)
    }

    // MARK: CTAP2

    private enum Verification { case none, builtIn, pin([UInt8], Int) }

    private func ctap2Sign(_ key: OpenedKey, _ request: AssertionRequest, match: Match, ui: any SecurityKeyUI) async throws -> Assertion {
        let info = key.info!
        let lists: [[[UInt8]]]
        if case .holds(let list) = match { lists = [list] } else { lists = key.chunks(request.credentials) }
        var verification = Verification.none
        for list in lists {
            while true {
                var pinAuth: ([UInt8], Int)?
                if case .pin(let param, let version) = verification { pinAuth = (param, version) }
                var builtIn = false
                if case .builtIn = verification { builtIn = true }
                do {
                    let assertion = try key.authenticator.getAssertion(
                        rpID: request.rpID, clientDataHash: request.clientDataHash, allowList: list, userPresence: true,
                        userVerification: builtIn, pinAuth: pinAuth, timeout: touchTimeout)
                    return try Self.checked(assertion, request, list: list)
                } catch FIDOError.ctap(CTAP2Status.noCredentials) where lists.count > 1 {
                    break
                } catch FIDOError.ctap(CTAP2Status.pinRequired) where !builtIn && pinAuth == nil {
                    // The key wants the person verified: by its own fingerprint reader when it has one, else by its PIN.
                    if info.options["uv"] == true { verification = .builtIn; continue }
                    guard info.options["clientPin"] == true else { throw SecurityKeyError.pinNotSet }
                    let (param, version) = try await pinAuthParameter(key, request, ui: ui)
                    verification = .pin(param, version)
                } catch let FIDOError.ctap(status) where builtIn && info.options["clientPin"] == true
                            && [CTAP2Status.uvInvalid, CTAP2Status.uvBlocked, CTAP2Status.invalidOption,
                                CTAP2Status.unsupportedOption, CTAP2Status.pinRequired].contains(status) {
                    let (param, version) = try await pinAuthParameter(key, request, ui: ui)
                    verification = .pin(param, version)
                } catch FIDOError.timeout {
                    key.authenticator.channel.cancel()
                    throw SecurityKeyError.notTouched
                }
            }
        }
        throw SecurityKeyError.notRegistered
    }

    /// Asks for the key's PIN (up to three times) and turns it into the request's pinUvAuthParam.
    private func pinAuthParameter(_ key: OpenedKey, _ request: AssertionRequest, ui: any SecurityKeyUI) async throws -> ([UInt8], Int) {
        let info = key.info!
        var left = key.authenticator.pinRetries(info.pinProtocol)
        if left == 0 { throw SecurityKeyError.pinBlocked }
        ui.say("The security key asks for its PIN.")
        for attempt in 1...Self.maxPINAttempts {
            let prompt = attempt == 1 ? "Security key PIN: " : "Security key PIN\(left.map { " (\($0) tries left)" } ?? ""): "
            let pin = try await ui.askPIN(prompt)
            defer { pin.wipe() }
            let characters = pin.withUnsafeBytes { $0.filter { $0 & 0xC0 != 0x80 }.count }
            guard characters >= 4, pin.count <= 63 else {
                ui.say("A security key PIN has 4 to 63 characters.")
                continue
            }
            do {
                let (proto, token) = try key.authenticator.pinToken(pin: pin, rpID: request.rpID, info: info)
                return (proto.authenticate(key: token, request.clientDataHash), proto.version)
            } catch FIDOError.ctap(CTAP2Status.pinInvalid) {
                left = key.authenticator.pinRetries(info.pinProtocol)
                if left == 0 { throw SecurityKeyError.pinBlocked }
                if attempt < Self.maxPINAttempts { ui.say("The security key did not accept that PIN.") }
            }
        }
        throw SecurityKeyError.wrongPIN(retries: left)
    }

    // MARK: U2F

    private func u2fSign(_ key: OpenedKey, _ request: AssertionRequest, match: Match) async throws -> Assertion {
        let app = Array(SHA256.hash(data: Array(request.rpID.utf8)))
        let candidates: [[UInt8]]
        if case .holds(let list) = match { candidates = list } else { candidates = request.credentials.filter { $0.count <= 255 } }
        let deadline = Date().addingTimeInterval(touchTimeout)
        for credential in candidates {
            while true {
                do {
                    let answer = try key.authenticator.u2fAuthenticate(appParameter: app, challenge: request.clientDataHash,
                                                                       keyHandle: credential, checkOnly: false)
                    guard answer.count > 5 else { throw FIDOError.malformed("a U2F signature answer of \(answer.count) bytes") }
                    let assertion = Assertion(credentialID: credential, authenticatorData: app + Array(answer[0..<5]),
                                              signature: Array(answer[5...]), userHandle: nil)
                    return try Self.checked(assertion, request, list: [credential])
                } catch FIDOError.u2f(Authenticator.U2FStatus.conditionsNotSatisfied) {
                    // Not touched yet: U2F keys answer at once and are asked again.
                    guard Date() < deadline else { throw SecurityKeyError.notTouched }
                    try await sleep(0.25)
                } catch FIDOError.u2f(Authenticator.U2FStatus.wrongData) {
                    break
                }
            }
        }
        throw SecurityKeyError.notRegistered
    }

    // MARK: Checks and errors

    /// The assertion, with its credential ID filled in, when it answers `request`: a credential that was asked for,
    /// authenticator data for this relying party with the user-present flag, and a signature.
    static func checked(_ assertion: Assertion, _ request: AssertionRequest, list: [[UInt8]]) throws -> Assertion {
        var result = assertion
        guard let id = assertion.credentialID ?? (list.count == 1 ? list[0] : nil), request.credentials.contains(id) else {
            throw SecurityKeyError.badAnswer
        }
        result.credentialID = id
        let data = assertion.authenticatorData
        guard data.count >= 37, Array(data[0..<32]) == Array(SHA256.hash(data: Array(request.rpID.utf8))), data[32] & 0x01 != 0,
              !assertion.signature.isEmpty else {
            throw SecurityKeyError.badAnswer
        }
        return result
    }

    static func describe(_ error: Error) -> SecurityKeyError {
        switch error {
        case let e as SecurityKeyError: return e
        case FIDOError.timeout: return .notTouched
        case FIDOError.ctap(let status):
            switch status {
            case CTAP2Status.userActionTimeout, CTAP2Status.actionTimeout: return .notTouched
            case CTAP2Status.operationDenied, CTAP2Status.keepaliveCancel: return .denied
            case CTAP2Status.noCredentials: return .notRegistered
            case CTAP2Status.pinBlocked: return .pinBlocked
            case CTAP2Status.pinAuthBlocked: return .pinAuthBlocked
            case CTAP2Status.pinNotSet: return .pinNotSet
            case CTAP2Status.uvBlocked: return .uvBlocked
            case CTAP2Status.channelBusy: return busy
            default: return .protocolError(error)
            }
        case FIDOError.hid(0x06): return busy
        case FIDOError.u2f(Authenticator.U2FStatus.wrongData): return .notRegistered
        case HIDOpenError.permissionDenied(let path): return .permission([path])
        default: return .protocolError(error)
        }
    }

    static let busy = SecurityKeyError("the security key is busy with another program (a browser asking for a touch?)",
                                       fix: "finish or cancel what the other program asked, then re-run")
}

/// Whether a key holds one of the credentials asked for: yes (the allow list to send it), or it could not say.
enum Match: Equatable {
    case holds([[UInt8]])
    case unknown
}

/// One opened key: its channel, and its getInfo (nil for a U2F-only key).
final class OpenedKey {
    let device: any SecurityKeyDevice
    let connection: HIDConnection
    let authenticator: Authenticator
    let info: AuthenticatorInfo?

    init(device: any SecurityKeyDevice) throws {
        self.device = device
        connection = try device.open()
        let channel = try CTAPHIDChannel(connection)
        authenticator = Authenticator(channel: channel)
        if channel.supportsCBOR, let info = try? authenticator.info() {
            self.info = info
        } else if channel.supportsMSG {
            info = nil
        } else {
            throw SecurityKeyError.unsupported
        }
    }

    /// The allow list in pieces the key accepts (its maxCredentialCountInList), without IDs longer than it takes.
    func chunks(_ credentials: [[UInt8]]) -> [[[UInt8]]] {
        let usable = credentials.filter { id in info?.maxCredentialIDLength.map { id.count <= $0 } ?? true }
        let size = max(1, info?.maxCredentialCountInList ?? usable.count)
        return stride(from: 0, to: usable.count, by: size).map { Array(usable[$0..<min(usable.count, $0 + size)]) }
    }

    /// Asks, without a touch, whether this key holds one of `request`'s credentials; nil when it holds none.
    func probe(_ request: AssertionRequest) -> Match? {
        if info != nil {
            for list in chunks(request.credentials) {
                do {
                    let found = try authenticator.getAssertion(rpID: request.rpID, clientDataHash: request.clientDataHash,
                                                               allowList: list, userPresence: false, timeout: 5)
                    if let id = found.credentialID, list.contains(id) { return .holds([id]) }
                    return .holds(list)
                } catch FIDOError.ctap(CTAP2Status.noCredentials) {
                    continue
                } catch {
                    return .unknown
                }
            }
            return nil
        }
        let app = Array(SHA256.hash(data: Array(request.rpID.utf8)))
        for id in request.credentials where id.count <= 255 {
            do {
                _ = try authenticator.u2fAuthenticate(appParameter: app, challenge: request.clientDataHash, keyHandle: id, checkOnly: true)
                return .holds([id])
            } catch FIDOError.u2f(Authenticator.U2FStatus.conditionsNotSatisfied) {
                return .holds([id])
            } catch FIDOError.u2f {
                continue
            } catch {
                return .unknown
            }
        }
        return nil
    }
}
