import Foundation

/// What went wrong talking to an authenticator, at the protocol level. `SecurityKeys` turns these into a
/// `SecurityKeyError` a person can act on.
public enum FIDOError: Error, Equatable, CustomStringConvertible {
    /// A CTAP2 status byte other than CTAP2_OK.
    case ctap(UInt8)
    /// A CTAPHID_ERROR frame.
    case hid(UInt8)
    /// A U2F (CTAP1) status word other than 0x9000.
    case u2f(UInt16)
    /// No answer before the deadline.
    case timeout
    /// An answer that does not follow the protocol.
    case malformed(String)
    /// The device could not be read or written (errno).
    case io(String)

    public var description: String {
        switch self {
        case .ctap(let s): return String(format: "CTAP2 error 0x%02X", s) + (CTAP2Status.name(s).map { " (\($0))" } ?? "")
        case .hid(let c): return String(format: "CTAPHID error 0x%02X", c)
        case .u2f(let sw): return String(format: "U2F status 0x%04X", sw)
        case .timeout: return "no answer in time"
        case .malformed(let why): return "an answer that does not follow the protocol (\(why))"
        case .io(let why): return why
        }
    }
}

/// CTAP2 status codes xless reacts to (CTAP 2.1, section 8.2).
public enum CTAP2Status {
    public static let ok: UInt8 = 0x00
    public static let invalidCommand: UInt8 = 0x01
    public static let invalidParameter: UInt8 = 0x02
    public static let channelBusy: UInt8 = 0x06
    public static let operationDenied: UInt8 = 0x27
    public static let unsupportedOption: UInt8 = 0x2B
    public static let invalidOption: UInt8 = 0x2C
    public static let keepaliveCancel: UInt8 = 0x2D
    public static let noCredentials: UInt8 = 0x2E
    public static let userActionTimeout: UInt8 = 0x2F
    public static let pinInvalid: UInt8 = 0x31
    public static let pinBlocked: UInt8 = 0x32
    public static let pinAuthInvalid: UInt8 = 0x33
    public static let pinAuthBlocked: UInt8 = 0x34
    public static let pinNotSet: UInt8 = 0x35
    /// CTAP2_ERR_PUAT_REQUIRED (CTAP 2.0: PIN_REQUIRED): the operation needs user verification.
    public static let pinRequired: UInt8 = 0x36
    public static let pinPolicyViolation: UInt8 = 0x37
    public static let actionTimeout: UInt8 = 0x3A
    public static let upRequired: UInt8 = 0x3B
    public static let uvBlocked: UInt8 = 0x3C
    public static let uvInvalid: UInt8 = 0x3F

    static func name(_ status: UInt8) -> String? {
        switch status {
        case invalidCommand: return "invalid command"
        case invalidParameter: return "invalid parameter"
        case channelBusy: return "channel busy"
        case operationDenied: return "operation denied"
        case unsupportedOption: return "unsupported option"
        case invalidOption: return "invalid option"
        case keepaliveCancel: return "cancelled"
        case noCredentials: return "no credentials"
        case userActionTimeout, actionTimeout: return "user action timeout"
        case pinInvalid: return "PIN invalid"
        case pinBlocked: return "PIN blocked"
        case pinAuthInvalid: return "PIN auth invalid"
        case pinAuthBlocked: return "PIN auth blocked"
        case pinNotSet: return "PIN not set"
        case pinRequired: return "user verification required"
        case pinPolicyViolation: return "PIN policy violation"
        case uvBlocked: return "user verification blocked"
        case uvInvalid: return "user verification invalid"
        default: return nil
        }
    }
}

/// A failure of the security-key sign-in, worded for the person at the terminal: what happened and what to do. Never
/// carries a PIN, a challenge or key material.
public struct SecurityKeyError: Error, Equatable, CustomStringConvertible {
    public let cause: String
    public let fix: String
    public init(_ cause: String, fix: String) { self.cause = cause; self.fix = fix }
    public var description: String { "\(cause) — \(fix)" }

    static let replug = "unplug the security key, plug it in again, then re-run"

    static let noKey = SecurityKeyError(
        "no security key is connected",
        fix: "plug in a USB security key registered with this Apple ID, then re-run (NFC and Bluetooth keys are not supported)")

    /// `devices`: their paths (Linux), or their names.
    static func permission(_ devices: [String]) -> SecurityKeyError {
        #if os(macOS)
        SecurityKeyError(
            "macOS does not let xless open the security key (\(devices.joined(separator: ", ")))",
            fix: "allow your terminal under System Settings > Privacy & Security > Input Monitoring, open it again and re-run; or sign in with an Apple ID that uses two-factor codes (docs/apple-account.md#signing-in-with-a-security-key)")
        #else
        SecurityKeyError(
            "xless may not open the security key (\(devices.joined(separator: ", ")): permission denied)",
            fix: "give your user access to security keys with a udev rule (docs/apple-account.md#signing-in-with-a-security-key), unplug and plug the key in again, then re-run")
        #endif
    }

    static let notRegistered = SecurityKeyError(
        "none of the connected security keys is registered with this Apple ID",
        fix: "plug in a key you added to this Apple ID (Settings > Apple Account > Sign-In & Security on an Apple device), then re-run")

    static let notTouched = SecurityKeyError("the security key was not touched in time", fix: "re-run and touch the key when xless asks")
    static let denied = SecurityKeyError("the security key refused the sign-in", fix: "re-run and approve the sign-in on the key")
    static let pinNotSet = SecurityKeyError(
        "the security key wants its PIN to be checked, but it has no PIN",
        fix: "set a PIN on the key with its maker's tool (for example ykman fido access change-pin), then re-run")
    static let pinBlocked = SecurityKeyError(
        "the security key's PIN is blocked after too many wrong tries",
        fix: "the key must be reset with its maker's tool (this removes it from every account), then added to the Apple ID again")
    static let pinAuthBlocked = SecurityKeyError(
        "the security key stopped accepting PINs after three wrong ones in a row", fix: replug)
    static let uvBlocked = SecurityKeyError(
        "the security key's built-in verification (fingerprint) is blocked after too many failures",
        fix: "unlock it as its maker documents (often by entering the PIN), then re-run")
    static func wrongPIN(retries: Int?) -> SecurityKeyError {
        SecurityKeyError(
            "the security key did not accept the PIN" + (retries.map { " (\($0) tries left before the key locks)" } ?? ""),
            fix: "re-run and type the key's PIN (not the Apple ID's password)")
    }
    static let unsupported = SecurityKeyError(
        "the connected security key speaks neither FIDO2 (CTAP2) nor U2F", fix: "use a FIDO2 or U2F security key registered with this Apple ID")
    static func protocolError(_ error: Error) -> SecurityKeyError {
        SecurityKeyError("the security key answered something xless cannot use (\(error))", fix: replug)
    }
    static let badAnswer = SecurityKeyError("the security key's answer does not match what was asked", fix: replug)
    static let unsupportedSystem = SecurityKeyError(
        "xless does not talk to security keys on this system",
        fix: "sign in on Linux or macOS, or with an Apple ID that uses two-factor codes")
}
