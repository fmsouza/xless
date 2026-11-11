import Foundation

/// The terminal the sign-in talks to. `askSecret` returns the typed bytes (never echoed); the caller zeroes them.
public protocol SignInPrompter: Sendable {
    func ask(_ prompt: String) async throws -> String
    func askSecret(_ prompt: String) async throws -> [UInt8]
    func say(_ line: String)
}

/// Apple's endpoints for the sign-in and the developer downloads (as fastlane and xcodes use them).
enum AppleEndpoints {
    static let logout = URL(string: "https://appstoreconnect.apple.com/logout")!
    static let olympusConfig = URL(string: "https://appstoreconnect.apple.com/olympus/v1/app/config?hostname=itunesconnect.apple.com")!
    static let olympusSession = URL(string: "https://appstoreconnect.apple.com/olympus/v1/session")!
    static let auth = URL(string: "https://idmsa.apple.com/appleauth/auth")!
    static func signIn(widgetKey: String) -> URL {
        var c = URLComponents(string: "https://idmsa.apple.com/appleauth/auth/signin")!
        c.queryItems = [URLQueryItem(name: "widgetKey", value: widgetKey)]
        return c.url!
    }
    static let signInInit = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/init")!
    static let signInComplete = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/complete?isRememberMeEnabled=false")!
    static let verifyPhone = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone")!
    static let verifyPhoneCode = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/phone/securitycode")!
    static let verifyDeviceCode = URL(string: "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")!
    static let trust = URL(string: "https://idmsa.apple.com/appleauth/auth/2sv/trust")!
    static let listDownloads = URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!
    static func downloadAuth(path: String) -> URL {
        var c = URLComponents(string: "https://developerservices2.apple.com/services/download")!
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return c.url!
    }
    static func download(path: String) -> URL? {
        URL(string: "https://download.developer.apple.com" + (path.hasPrefix("/") ? path : "/" + path))
    }
}

struct SRPInitResponse: Decodable {
    let iteration: Int
    let salt: String
    let `protocol`: SRPPasswordProtocol
    let b: String
    let c: String
}

struct ServiceErrors: Decodable {
    struct Entry: Decodable { let code: String?; let message: String? }
    let serviceErrors: [Entry]?
    var message: String? {
        let m = (serviceErrors ?? []).compactMap(\.message).joined(separator: " ")
        return m.isEmpty ? nil : m
    }
}

/// `GET /appleauth/auth`: how the account's second factor works.
struct AuthOptions: Decodable {
    struct Phone: Decodable { let id: Int; let numberWithDialCode: String }
    struct CodeInfo: Decodable { let length: Int? }
    struct Present: Decodable { init(from decoder: Decoder) throws {} }
    let trustedPhoneNumbers: [Phone]?
    let trustedDevices: [Present]?
    let securityCode: CodeInfo?
    let noTrustedDevices: Bool?
    let fsaChallenge: Present?
}
