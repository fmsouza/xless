import BigInt
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// Signs an Apple ID in to Apple's web services, the way fastlane and xcodes do it: SRP-6a (the password itself is never
/// sent), then the two-factor code from a trusted device or a text message. The session's cookies stay in `client`'s
/// in-memory jar. Nothing is stored, logged or printed beyond the prompts.
public struct AppleSignIn {
    static let maxCodeAttempts = 3
    let client: AppleWebClient
    let prompter: SignInPrompter
    let now: @Sendable () -> Date
    let srpPrivateKey: BigUInt?

    public init(client: AppleWebClient, prompter: SignInPrompter) {
        self.init(client: client, prompter: prompter, now: { Date() }, srpPrivateKey: nil)
    }

    init(client: AppleWebClient, prompter: SignInPrompter, now: @escaping @Sendable () -> Date, srpPrivateKey: BigUInt?) {
        self.client = client; self.prompter = prompter; self.now = now; self.srpPrivateKey = srpPrivateKey
    }

    public func run() async throws {
        let account = try await prompter.ask("Apple ID (email): ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { throw fail("no Apple ID given", fix: "type the email address of your Apple ID") }
        var password = try await prompter.askSecret("Password: ")
        guard !password.isEmpty else { throw fail("no password given", fix: "type the Apple ID's password") }
        var passwordSHA256 = Array(SHA256.hash(data: password))
        password.resetBytes()
        defer { passwordSHA256.resetBytes() }

        let widgetKey = try await serviceKey()
        let hashcash = try await hashcash(widgetKey: widgetKey)
        let srp = AppleSRP(privateKey: srpPrivateKey)
        let initResponse = try await srpInit(account: account, publicKey: srp.publicKey, widgetKey: widgetKey)
        guard let salt = Data(base64Encoded: initResponse.salt), let b = Data(base64Encoded: initResponse.b) else {
            throw fail("Apple's sign-in answered with a malformed SRP challenge", fix: Self.changedFix)
        }
        var key = ApplePasswordKey.derive(passwordSHA256: passwordSHA256, salt: Array(salt), iterations: initResponse.iteration,
                                          protocol: initResponse.protocol)
        defer { key.resetBytes() }
        let proofs = try srp.proofs(accountName: account, passwordKey: key, salt: Array(salt), serverPublicKey: Array(b))
        let (data, response) = try await client.send(json(AppleEndpoints.signInComplete, method: "POST", widgetKey: widgetKey, body: [
            "accountName": account, "c": initResponse.c,
            "m1": Data(proofs.m1).base64EncodedString(), "m2": Data(proofs.m2).base64EncodedString(), "rememberMe": false,
        ], extra: ["X-Apple-HC": hashcash]))
        switch response.statusCode {
        case 200:
            break
        case 409:
            guard let session = response.value(forHTTPHeaderField: "X-Apple-ID-Session-Id"),
                  let scnt = response.value(forHTTPHeaderField: "scnt") else {
                throw fail("Apple asked for a second factor without a session to verify it in", fix: Self.changedFix)
            }
            var twoFactor = TwoFactor(client: client, prompter: prompter, widgetKey: widgetKey, sessionID: session, scnt: scnt)
            try await twoFactor.run()
        case 401:
            throw fail("Apple refused the Apple ID or password", fix: "check them and re-run (a few failed attempts can lock the Apple ID)")
        case 403:
            throw fail("Apple says the Apple ID is locked\(serviceMessage(data))", fix: "unlock it at https://iforgot.apple.com, then re-run")
        case 412:
            throw fail("Apple wants this Apple ID to accept new terms or privacy notices",
                       fix: "sign in once at https://developer.apple.com/account in a browser and accept what it asks, then re-run")
        default:
            throw fail("Apple's sign-in answered HTTP \(response.statusCode)\(serviceMessage(data))", fix: Self.changedFix)
        }
        // Best effort, as xcodes does: lets App Store Connect set its cookies; a free Apple ID may be refused here.
        _ = try? await client.send(URLRequest(url: AppleEndpoints.olympusSession))
    }

    static let changedFix = "re-run; if it keeps failing, Apple's sign-in may have changed (report it)"

    /// The sign-in widget key, from where App Store Connect's sign-out redirects to, else from Olympus' app config.
    private func serviceKey() async throws -> String {
        var head = URLRequest(url: AppleEndpoints.logout)
        head.httpMethod = "HEAD"
        if let (_, r) = try? await client.send(head, followRedirects: false), (300..<400).contains(r.statusCode),
           let location = r.value(forHTTPHeaderField: "Location"),
           let key = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "widgetKey" })?.value, !key.isEmpty {
            return key
        }
        struct Config: Decodable { let authServiceKey: String }
        if let (data, r) = try? await client.send(URLRequest(url: AppleEndpoints.olympusConfig)), r.statusCode == 200,
           let key = try? JSONDecoder().decode(Config.self, from: data).authServiceKey, !key.isEmpty {
            return key
        }
        throw fail("could not get the sign-in key from Apple", fix: "check network access to appstoreconnect.apple.com, then re-run")
    }

    private func hashcash(widgetKey: String) async throws -> String {
        var r = URLRequest(url: AppleEndpoints.signIn(widgetKey: widgetKey))
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await client.send(r)
        guard (200..<300).contains(response.statusCode),
              let bits = response.value(forHTTPHeaderField: "X-Apple-HC-Bits").flatMap({ Int($0) }), (0...32).contains(bits),
              let challenge = response.value(forHTTPHeaderField: "X-Apple-HC-Challenge"), !challenge.isEmpty else {
            throw fail("Apple's sign-in did not send its proof-of-work challenge (HTTP \(response.statusCode))", fix: Self.changedFix)
        }
        return Hashcash.mint(challenge: challenge, bits: bits, date: Hashcash.timestamp(now()))
    }

    private func srpInit(account: String, publicKey: [UInt8], widgetKey: String) async throws -> SRPInitResponse {
        let (data, response) = try await client.send(json(AppleEndpoints.signInInit, method: "POST", widgetKey: widgetKey, body: [
            "a": Data(publicKey).base64EncodedString(), "accountName": account, "protocols": ["s2k", "s2k_fo"],
        ]))
        guard response.statusCode == 200, let decoded = try? JSONDecoder().decode(SRPInitResponse.self, from: data) else {
            if response.statusCode == 401 || response.statusCode == 400 {
                throw fail("Apple refused the Apple ID\(serviceMessage(data))", fix: "check the email address and re-run")
            }
            throw fail("Apple's sign-in answered HTTP \(response.statusCode) to the SRP start\(serviceMessage(data))", fix: Self.changedFix)
        }
        return decoded
    }

    private func json(_ url: URL, method: String, widgetKey: String, body: [String: Any], extra: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        for (k, v) in ["Accept": "application/json", "Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest",
                       "X-Apple-Widget-Key": widgetKey].merging(extra, uniquingKeysWith: { $1 }) {
            r.setValue(v, forHTTPHeaderField: k)
        }
        return r
    }
}

/// The second factor: a code pushed to the account's trusted devices, or sent by text message to a trusted number.
struct TwoFactor {
    let client: AppleWebClient
    let prompter: SignInPrompter
    let widgetKey: String
    let sessionID: String
    var scnt: String

    init(client: AppleWebClient, prompter: SignInPrompter, widgetKey: String, sessionID: String, scnt: String) {
        self.client = client; self.prompter = prompter; self.widgetKey = widgetKey; self.sessionID = sessionID; self.scnt = scnt
    }

    mutating func run() async throws {
        let (data, response) = try await send(URLRequest(url: AppleEndpoints.auth))
        guard response.statusCode == 200, let options = try? JSONDecoder().decode(AuthOptions.self, from: data) else {
            throw fail("Apple did not say how to verify this sign-in (HTTP \(response.statusCode))", fix: AppleSignIn.changedFix)
        }
        if options.trustedDevices != nil {
            throw fail("this Apple ID uses Apple's old two-step verification, which xless does not support",
                       fix: "turn on two-factor authentication for the Apple ID (https://support.apple.com/HT204915), then re-run")
        }
        guard let phones = options.trustedPhoneNumbers else {
            if options.fsaChallenge != nil { throw securityKey() }
            throw fail("Apple asked for a second factor xless does not know", fix: AppleSignIn.changedFix)
        }
        let length = options.securityCode?.length ?? 6
        prompter.say("Two-factor authentication is on for this Apple ID.")
        if options.noTrustedDevices == true {
            let phone = phones.count == 1 ? phones[0] : try await choosePhone(phones)
            if phones.count != 1 { try await requestSMS(phone) }
            try await enterCodes(length: length, phone: phone)
        } else if options.fsaChallenge != nil {
            throw securityKey()
        } else {
            try await enterCodes(length: length, phone: nil, phones: phones)
        }
        let (_, trust) = try await send(URLRequest(url: AppleEndpoints.trust))
        guard (200..<300).contains(trust.statusCode) else {
            throw fail("Apple did not finish the sign-in after the code (HTTP \(trust.statusCode))", fix: AppleSignIn.changedFix)
        }
    }

    /// Prompts for the code (a trusted-device code until the user types `sms`), up to `maxCodeAttempts` wrong codes.
    private mutating func enterCodes(length: Int, phone initial: AuthOptions.Phone?, phones: [AuthOptions.Phone] = []) async throws {
        var phone = initial
        var wrong = 0
        while true {
            let prompt = phone.map { "Enter the \(length)-digit code sent to \($0.numberWithDialCode): " }
                ?? "Enter the \(length)-digit code shown on your trusted Apple device (or type sms to get it by text message): "
            let code = String(try await prompter.ask(prompt).filter { !$0.isWhitespace })
            if code.isEmpty { continue }
            if phone == nil && code.lowercased() == "sms" {
                guard !phones.isEmpty else {
                    throw fail("this Apple ID has no trusted phone number to send a code to", fix: "use the code shown on a trusted device")
                }
                let chosen = phones.count == 1 ? phones[0] : try await choosePhone(phones)
                try await requestSMS(chosen)
                phone = chosen
                continue
            }
            var r = URLRequest(url: phone == nil ? AppleEndpoints.verifyDeviceCode : AppleEndpoints.verifyPhoneCode)
            r.httpMethod = "POST"
            var body: [String: Any] = ["securityCode": ["code": code]]
            if let phone { body["phoneNumber"] = ["id": phone.id]; body["mode"] = "sms" }
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await send(r)
            switch response.statusCode {
            case 200..<300:
                return
            case 400, 401:
                wrong += 1
                guard wrong < AppleSignIn.maxCodeAttempts else {
                    throw fail("Apple did not accept the verification code \(wrong) times", fix: "re-run and sign in again")
                }
                prompter.say("That code was not accepted\(serviceMessage(data)). Try again.")
            case 412:
                throw fail("Apple wants this Apple ID to accept new terms or privacy notices",
                           fix: "sign in once at https://developer.apple.com/account in a browser and accept what it asks, then re-run")
            default:
                throw fail("Apple answered HTTP \(response.statusCode) to the verification code\(serviceMessage(data))", fix: AppleSignIn.changedFix)
            }
        }
    }

    private func choosePhone(_ phones: [AuthOptions.Phone]) async throws -> AuthOptions.Phone {
        prompter.say("Trusted phone numbers:")
        for (i, p) in phones.enumerated() { prompter.say("  \(i + 1): \(p.numberWithDialCode)") }
        for _ in 0..<5 {
            let answer = try await prompter.ask("Send the code by text message to which number? [1-\(phones.count)]: ")
            if let n = Int(answer.trimmingCharacters(in: .whitespaces)), phones.indices.contains(n - 1) { return phones[n - 1] }
            prompter.say("Type a number from 1 to \(phones.count).")
        }
        throw fail("no trusted phone number chosen", fix: "re-run and type the number of a trusted phone")
    }

    private mutating func requestSMS(_ phone: AuthOptions.Phone) async throws {
        var r = URLRequest(url: AppleEndpoints.verifyPhone)
        r.httpMethod = "PUT"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["phoneNumber": ["id": phone.id], "mode": "sms"], options: [.sortedKeys])
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(r)
        guard (200..<300).contains(response.statusCode) else {
            throw fail("Apple did not send the text message (HTTP \(response.statusCode))\(serviceMessage(data))",
                       fix: "wait a few minutes (Apple limits how many codes it sends), then re-run")
        }
    }

    /// Sends with the two-factor headers, and keeps the newest `scnt` Apple returns.
    private mutating func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = request
        r.setValue(sessionID, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        r.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        r.setValue(scnt, forHTTPHeaderField: "scnt")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.send(r)
        if let next = response.value(forHTTPHeaderField: "scnt"), !next.isEmpty { scnt = next }
        return (data, response)
    }

    private func securityKey() -> XlessError {
        fail("this Apple ID signs in with a hardware security key, which xless does not support",
             fix: "use an Apple ID without security keys to download Xcode")
    }
}

func fail(_ cause: String, fix: String) -> XlessError { XlessError(.sdk, cause, fix: fix) }

/// ": <Apple's message>" from a `serviceErrors` body, or "".
func serviceMessage(_ data: Data) -> String {
    (try? JSONDecoder().decode(ServiceErrors.self, from: data))?.message.map { ": \($0)" } ?? ""
}
