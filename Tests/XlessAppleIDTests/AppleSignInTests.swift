import XCTest
import BigInt
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore
import XlessFIDO
@testable import XlessAppleID

/// Scripted terminal: answers `ask` from a queue, `askSecret` with the password; records everything said.
final class ScriptedPrompter: SignInPrompter, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private let secret: String
    private(set) var prompts: [String] = []
    private(set) var said: [String] = []

    init(answers: [String], secret: String) { self.answers = answers; self.secret = secret }

    func ask(_ prompt: String) async throws -> String {
        try lock.withLock {
            prompts.append(prompt)
            guard !answers.isEmpty else { throw XlessError(.sdk, "no scripted answer for \(prompt)", fix: "") }
            return answers.removeFirst()
        }
    }
    func askSecret(_ prompt: String) async throws -> SecretBytes {
        lock.withLock { prompts.append(prompt) }
        return SecretBytes(utf8: secret)
    }
    func say(_ line: String) { lock.withLock { said.append(line) } }
}

/// Apple's sign-in, played by a real SRP server that knows the password's verifier.
final class FakeApple: @unchecked Sendable {
    static let password = "correct horse battery"
    static let salt: [UInt8] = Array(0..<16)
    static let iterations = 1000
    static let group = SRPGroup.rfc5054_2048
    static let b = BigUInt("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20", radix: 16)!
    static let v: BigUInt = {
        let key = ApplePasswordKey.derive(passwordSHA256: Array(SHA256.hash(data: Array(password.utf8))), salt: salt,
                                          iterations: iterations, protocol: .s2k)
        return group.g.power(AppleSRP.x(salt: salt, message: [0x3a] + key), modulus: group.N)
    }()
    static let B: BigUInt = { (AppleSRP(privateKey: 1).k * v + group.g.power(b, modulus: group.N)) % group.N }()

    var completeStatus = 409
    var completeBody: [String: Any] = ["authType": "hsa2"]
    var authOptions: [String: Any] = ["trustedPhoneNumbers": [["id": 1, "numberWithDialCode": "+1 (•••) •••-••12"]],
                                      "securityCode": ["length": 6]]
    var codeStatuses: [Int] = [204]
    var securityKeyStatus = 200
    /// The security key's public key: the posted assertion is checked against it, as Apple would.
    var securityKeyPublicKey: P256.Signing.PublicKey?
    private(set) var securityKeyBodies: [[String: String]] = []
    private var A = BigUInt(0)
    private let lock = NSLock()

    func handle(_ r: URLRequest) throws -> MockTransport.Reply {
        try lock.withLock { try route(r) }
    }

    private func route(_ r: URLRequest) throws -> MockTransport.Reply {
        let url = r.url!, method = r.httpMethod ?? "GET"
        switch (method, url.host!, url.path) {
        case ("HEAD", "appstoreconnect.apple.com", "/logout"):
            return .init(status: 302, headers: ["Location": "https://idmsa.apple.com/appleauth/auth/signin?widgetKey=WK123&locale=en_US"])
        case ("GET", "idmsa.apple.com", "/appleauth/auth/signin"):
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "widgetKey" }?.value, "WK123")
            return .init(status: 200, headers: ["X-Apple-HC-Bits": "1", "X-Apple-HC-Challenge": "chal"])
        case ("POST", "idmsa.apple.com", "/appleauth/auth/signin/init"):
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
            A = BigUInt(Data(base64Encoded: body["a"] as! String)!)
            XCTAssertEqual(body["protocols"] as? [String], ["s2k", "s2k_fo"])
            XCTAssertEqual(r.header("X-Apple-Widget-Key"), "WK123")
            return .json(200, ["iteration": Self.iterations, "salt": Data(Self.salt).base64EncodedString(), "protocol": "s2k",
                               "b": Data(Self.B.serialize()).base64EncodedString(), "c": "ctoken"])
        case ("POST", "idmsa.apple.com", "/appleauth/auth/signin/complete"):
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
            XCTAssertEqual(body["c"] as? String, "ctoken")
            XCTAssertTrue(r.header("X-Apple-HC")?.hasPrefix("1:1:") ?? false)
            guard Data(base64Encoded: body["m1"] as! String) == Data(expectedM1(account: body["accountName"] as! String)) else {
                return .json(401, ["serviceErrors": [["code": "-20101", "message": "Your Apple ID or password was incorrect."]]])
            }
            return .json(completeStatus, completeBody, headers: ["X-Apple-ID-Session-Id": "sess", "scnt": "s1"])
        case ("GET", "idmsa.apple.com", "/appleauth/auth"):
            XCTAssertEqual(r.header("scnt"), "s1")
            XCTAssertEqual(r.header("X-Apple-ID-Session-Id"), "sess")
            return .json(200, authOptions, headers: ["scnt": "s2"])
        case ("PUT", "idmsa.apple.com", "/appleauth/auth/verify/phone"):
            return .json(200, ["trustedPhoneNumber": ["id": 1]])
        case ("POST", "idmsa.apple.com", "/appleauth/auth/verify/trusteddevice/securitycode"),
             ("POST", "idmsa.apple.com", "/appleauth/auth/verify/phone/securitycode"):
            XCTAssertEqual(r.header("scnt"), "s2")
            let status = codeStatuses.isEmpty ? 204 : codeStatuses.removeFirst()
            return .init(status: status)
        case ("POST", "idmsa.apple.com", "/appleauth/auth/verify/security/key"):
            XCTAssertEqual(r.header("scnt"), "s2")
            XCTAssertEqual(r.header("X-Apple-ID-Session-Id"), "sess")
            XCTAssertEqual(r.header("X-Apple-Widget-Key"), "WK123")
            XCTAssertEqual(r.header("Content-Type"), "application/json")
            let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: String]
            securityKeyBodies.append(body)
            if let key = securityKeyPublicKey {
                let clientData = Data(base64Encoded: body["clientData"]!)!
                let authData = Data(base64Encoded: body["authenticatorData"]!)!
                let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: body["signatureData"]!)!)
                XCTAssertTrue(key.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))), "signature")
            }
            return .json(securityKeyStatus, securityKeyStatus == 200 ? [:] : ["serviceErrors": [["code": "-21669", "message": "Verification failed."]]])
        case ("GET", "idmsa.apple.com", "/appleauth/auth/2sv/trust"):
            XCTAssertEqual(r.header("X-Apple-ID-Session-Id"), "sess")
            return .init(status: 204, headers: ["Set-Cookie": "myacinfo=trusted; Domain=.apple.com; Path=/; Secure"])
        case ("GET", "appstoreconnect.apple.com", "/olympus/v1/session"):
            return .init(status: 401)
        default:
            XCTFail("unexpected \(method) \(url)")
            return .init(status: 404)
        }
    }

    private func expectedM1(account: String) -> [UInt8] {
        let N = Self.group.N
        let H: ([UInt8]) -> [UInt8] = { Array(SHA256.hash(data: $0)) }
        let pad: (BigUInt) -> [UInt8] = { n in let r = Array(n.serialize()); return [UInt8](repeating: 0, count: 256 - r.count) + r }
        let u = BigUInt(Data(H(pad(A) + pad(Self.B))))
        let S = (A * Self.v.power(u, modulus: N)).power(Self.b, modulus: N)
        let K = H(Array(S.serialize()))
        let x = zip(H(Array(N.serialize())), H(pad(Self.group.g))).map { $0 ^ $1 }
        return H(x + H(Array(account.utf8)) + Self.salt + Array(A.serialize()) + Array(Self.B.serialize()) + K)
    }
}

final class AppleSignInTests: XCTestCase {
    func signIn(_ apple: FakeApple, answers: [String], password: String = FakeApple.password) async throws -> (MockTransport, ScriptedPrompter) {
        let mock = MockTransport { try apple.handle($0) }
        let prompter = ScriptedPrompter(answers: answers, secret: password)
        try await AppleSignIn(client: AppleWebClient(transport: mock), prompter: prompter).run()
        return (mock, prompter)
    }

    func paths(_ mock: MockTransport) -> [String] { mock.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

    func assertSDKError(_ op: () async throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await op()
            XCTFail("expected an error", file: file, line: line)
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .sdk, file: file, line: line)
            XCTAssertTrue(e.description.contains(text), "\(e.description)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testTrustedDeviceCodeSignIn() async throws {
        let apple = FakeApple()
        let (mock, prompter) = try await signIn(apple, answers: ["me@example.com", "123456"])
        XCTAssertEqual(paths(mock), [
            "HEAD /logout", "GET /appleauth/auth/signin", "POST /appleauth/auth/signin/init", "POST /appleauth/auth/signin/complete",
            "GET /appleauth/auth", "POST /appleauth/auth/verify/trusteddevice/securitycode", "GET /appleauth/auth/2sv/trust",
            "GET /olympus/v1/session",
        ])
        let submit = mock.requests[5]
        XCTAssertEqual(try JSONSerialization.jsonObject(with: submit.httpBody!) as? NSDictionary, ["securityCode": ["code": "123456"]])
        XCTAssertTrue(prompter.prompts.contains { $0.contains("6-digit code") && $0.contains("trusted") })
        XCTAssertEqual(mock.requests.last?.header("Cookie"), "myacinfo=trusted")
    }

    func testSingleNumberSMSAutoSent() async throws {
        let apple = FakeApple()
        apple.authOptions["noTrustedDevices"] = true
        let (mock, prompter) = try await signIn(apple, answers: ["me@example.com", "654321"])
        XCTAssertFalse(paths(mock).contains("PUT /appleauth/auth/verify/phone"))
        let submit = try XCTUnwrap(mock.requests.first { $0.url!.path == "/appleauth/auth/verify/phone/securitycode" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: submit.httpBody!) as? NSDictionary,
                       ["securityCode": ["code": "654321"], "phoneNumber": ["id": 1], "mode": "sms"])
        XCTAssertTrue(prompter.prompts.contains { $0.contains("••12") })
    }

    func testSMSChoiceSendsPUT() async throws {
        let apple = FakeApple()
        apple.authOptions["noTrustedDevices"] = true
        apple.authOptions["trustedPhoneNumbers"] = [["id": 1, "numberWithDialCode": "••11"], ["id": 7, "numberWithDialCode": "••77"]]
        let (mock, _) = try await signIn(apple, answers: ["me@example.com", "2", "111222"])
        let put = try XCTUnwrap(mock.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: put.httpBody!) as? NSDictionary, ["phoneNumber": ["id": 7], "mode": "sms"])
        let submit = try XCTUnwrap(mock.requests.first { $0.url!.path == "/appleauth/auth/verify/phone/securitycode" })
        XCTAssertEqual((try JSONSerialization.jsonObject(with: submit.httpBody!) as? NSDictionary)?["phoneNumber"] as? NSDictionary, ["id": 7])
    }

    func testSpacesInTheCodeAreDropped() async throws {
        let (mock, _) = try await signIn(FakeApple(), answers: ["me@example.com", " 123 456 "])
        let submit = try XCTUnwrap(mock.requests.first { $0.url?.path.hasSuffix("trusteddevice/securitycode") == true })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: submit.httpBody!) as? NSDictionary, ["securityCode": ["code": "123456"]])
    }

    func testTypingSMSSwitchesFromDeviceCode() async throws {
        let apple = FakeApple()
        let (mock, _) = try await signIn(apple, answers: ["me@example.com", "sms", "1", "333444"])
        XCTAssertTrue(paths(mock).contains("PUT /appleauth/auth/verify/phone"))
        XCTAssertTrue(paths(mock).contains("POST /appleauth/auth/verify/phone/securitycode"))
        XCTAssertFalse(paths(mock).contains("POST /appleauth/auth/verify/trusteddevice/securitycode"))
    }

    func testWrongCodeIsRetried() async throws {
        let apple = FakeApple()
        apple.codeStatuses = [400, 204]
        let (mock, prompter) = try await signIn(apple, answers: ["me@example.com", "000000", "123456"])
        XCTAssertEqual(paths(mock).filter { $0.hasSuffix("securitycode") }.count, 2)
        XCTAssertTrue(paths(mock).contains("GET /appleauth/auth/2sv/trust"))
        XCTAssertTrue(prompter.said.contains { $0.contains("not accepted") })
    }

    func testThreeWrongCodesFail() async {
        let apple = FakeApple()
        apple.codeStatuses = [400, 401, 400]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com", "1", "2", "3"]) }, contains: "code")
    }

    func test401WrongPassword() async {
        await assertSDKError({ _ = try await self.signIn(FakeApple(), answers: ["me@example.com"], password: "wrong") },
                             contains: "Apple ID or password")
    }

    func test403Locked() async {
        let apple = FakeApple()
        apple.completeStatus = 403
        apple.completeBody = ["serviceErrors": [["code": "-20209", "message": "This Apple ID has been locked for security reasons."]]]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "locked")
    }

    func test412Terms() async {
        let apple = FakeApple()
        apple.completeStatus = 412
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "developer.apple.com")
    }

    func testAnUnreadableSecurityKeyChallengeIsReported() async {
        let apple = FakeApple()
        apple.authOptions = ["fsaChallenge": ["challenge": "x", "keyHandles": [], "allowedCredentials": ""]]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "security key in a form xless cannot read")
        apple.authOptions = ["fsaChallenge": "not an object"]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "security key in a form xless cannot read")
        apple.authOptions = ["fsaChallenge": ["challenge": "AAAA", "keyHandles": [], "allowedCredentials": ""]]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "named none registered")
    }

    func testTwoStepRefused() async {
        let apple = FakeApple()
        apple.authOptions = ["trustedDevices": [["id": "d", "name": "iPhone", "modelName": "iPhone"]]]
        await assertSDKError({ _ = try await self.signIn(apple, answers: ["me@example.com"]) }, contains: "two-step")
    }

    func testNoTwoFactorSignIn() async throws {
        let apple = FakeApple()
        apple.completeStatus = 200
        let (mock, _) = try await signIn(apple, answers: ["me@example.com"])
        XCTAssertFalse(paths(mock).contains("GET /appleauth/auth"))
        XCTAssertEqual(paths(mock).last, "GET /olympus/v1/session")
    }

    func testFallsBackToOlympusForTheWidgetKey() async throws {
        let apple = FakeApple()
        let mock = MockTransport { r in
            if r.httpMethod == "HEAD" { return .init(status: 200) }
            if r.url!.path == "/olympus/v1/app/config" { return .json(200, ["authServiceKey": "WK123"]) }
            return try apple.handle(r)
        }
        try await AppleSignIn(client: AppleWebClient(transport: mock), prompter: ScriptedPrompter(answers: ["me@example.com", "1"], secret: FakeApple.password)).run()
        XCTAssertTrue(mock.requests.contains { $0.url!.path == "/olympus/v1/app/config" })
    }

    func testEmptyAppleIDIsRefusedBeforeAnyRequest() async {
        let mock = MockTransport { _ in .init(status: 500) }
        do {
            try await AppleSignIn(client: AppleWebClient(transport: mock), prompter: ScriptedPrompter(answers: ["  "], secret: "x")).run()
            XCTFail("expected an error")
        } catch {}
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testPasswordNeverSent() async throws {
        let (mock, _) = try await signIn(FakeApple(), answers: ["me@example.com", "123456"])
        let pw = FakeApple.password
        let digest = Array(SHA256.hash(data: Array(pw.utf8)))
        let needles = [pw, Data(pw.utf8).base64EncodedString(), hex(digest), Data(digest).base64EncodedString()]
        for r in mock.requests {
            let haystack = [r.url!.absoluteString, r.bodyString, (r.allHTTPHeaderFields ?? [:]).description].joined(separator: "\n")
            for n in needles { XCTAssertFalse(haystack.contains(n), "\(r.url!.path) carries password material") }
        }
    }

    func testAccountStageAndTheAppleIDReturned() async throws {
        let apple = FakeApple()
        apple.completeStatus = 200
        let ok = MockTransport { try apple.handle($0) }
        let id = try await AppleSignIn(client: AppleWebClient(transport: ok),
                                       prompter: ScriptedPrompter(answers: [" me@example.com "], secret: FakeApple.password), stage: .account).run()
        XCTAssertEqual(id, "me@example.com")

        let refusing = FakeApple()
        refusing.completeStatus = 412
        let mock = MockTransport { try refusing.handle($0) }
        do {
            try await AppleSignIn(client: AppleWebClient(transport: mock),
                                  prompter: ScriptedPrompter(answers: ["me@example.com"], secret: FakeApple.password), stage: .account).run()
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.fix.contains("appstoreconnect.apple.com/agreements"), e.fix)
            XCTAssertTrue(e.cause.contains("never accepts"), e.cause)
        }
    }
}

/// A security key in a test: signs with a real P-256 key, as a key would, and records what it was asked.
final class FakeSecurityKeys: SecurityKeySource, @unchecked Sendable {
    let credentialID: [UInt8] = Array(repeating: 0x42, count: 48)
    let key = P256.Signing.PrivateKey()
    var userHandle: [UInt8]? = Array("abc123".utf8)
    var failure: SecurityKeyError?
    var askPIN = false
    private(set) var requests: [AssertionRequest] = []
    private(set) var pins: [String] = []

    func assertion(for request: AssertionRequest, ui: any SecurityKeyUI) async throws -> Assertion {
        requests.append(request)
        if let failure { throw failure }
        ui.say("Touch your security key (Fake) to sign in.")
        if askPIN { let pin = try await ui.askPIN("Security key PIN: "); pins.append(pin.utf8String()) }
        let authData = Array(SHA256.hash(data: Array("apple.com".utf8))) + [0x01, 0, 0, 0, 9]
        let signature = try key.signature(for: authData + request.clientDataHash)
        return Assertion(credentialID: credentialID, authenticatorData: authData, signature: Array(signature.derRepresentation),
                         userHandle: userHandle)
    }
}

final class AppleSecurityKeySignInTests: XCTestCase {
    let challenge: [UInt8] = Array(0..<32).map { UInt8($0 * 7 % 256) }
    let other: [UInt8] = Array(repeating: 0x17, count: 48)

    func fsa(_ keys: FakeSecurityKeys, keyHandlesOnly: Bool = false) -> [String: Any] {
        var challenge: [String: Any] = ["challenge": AppleSecurityKey.base64URL(self.challenge),
                                        "keyHandles": [Data(keys.credentialID).base64EncodedString()]]
        challenge["allowedCredentials"] = keyHandlesOnly ? "" :
            [other, keys.credentialID].map { AppleSecurityKey.base64URL($0) }.joined(separator: ",")
        return ["fsaChallenge": challenge, "trustedPhoneNumbers": [["id": 1, "numberWithDialCode": "••12"]], "securityCode": ["length": 6]]
    }

    func signIn(_ apple: FakeApple, _ keys: FakeSecurityKeys, answers: [String] = ["me@example.com"],
                stage: Stage = .sdk) async throws -> (MockTransport, ScriptedPrompter) {
        let mock = MockTransport { try apple.handle($0) }
        let prompter = ScriptedPrompter(answers: answers, secret: FakeApple.password)
        try await AppleSignIn(client: AppleWebClient(transport: mock), prompter: prompter, stage: stage, securityKeys: keys).run()
        return (mock, prompter)
    }

    func testSignsInWithASecurityKey() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys)
        apple.securityKeyPublicKey = keys.key.publicKey
        let (mock, prompter) = try await signIn(apple, keys)
        XCTAssertEqual(mock.requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" }.suffix(4), [
            "GET /appleauth/auth", "POST /appleauth/auth/verify/security/key", "GET /appleauth/auth/2sv/trust", "GET /olympus/v1/session",
        ])
        XCTAssertTrue(prompter.said.contains("This Apple ID signs in with a security key."))
        XCTAssertTrue(prompter.said.contains("Touch your security key (Fake) to sign in."))
        XCTAssertFalse(prompter.prompts.contains { $0.contains("code") })

        let request = try XCTUnwrap(keys.requests.first)
        XCTAssertEqual(request.rpID, "apple.com")
        XCTAssertEqual(request.credentials, [other, keys.credentialID])
        let clientData = #"{"type":"webauthn.get","challenge":"\#(AppleSecurityKey.base64URL(challenge))","origin":"https://idmsa.apple.com","crossOrigin":true}"#
        XCTAssertEqual(request.clientDataHash, Array(SHA256.hash(data: Array(clientData.utf8))))

        let body = try XCTUnwrap(apple.securityKeyBodies.first)
        XCTAssertEqual(Set(body.keys), ["challenge", "clientData", "signatureData", "authenticatorData", "userHandle", "credentialID", "rpId"])
        XCTAssertEqual(body["challenge"], Data(challenge).base64EncodedString())
        XCTAssertEqual(body["clientData"], Data(clientData.utf8).base64EncodedString())
        XCTAssertEqual(body["credentialID"], Data(keys.credentialID).base64EncodedString())
        XCTAssertEqual(body["userHandle"], "abc123")
        XCTAssertEqual(body["rpId"], "apple.com")
        XCTAssertEqual(Data(base64Encoded: body["authenticatorData"]!)!.count, 37)
    }

    func testKeyHandlesAreUsedWhenAllowedCredentialsIsEmpty() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys, keyHandlesOnly: true)
        keys.userHandle = [0xFF, 0xFE]
        _ = try await signIn(apple, keys)
        XCTAssertEqual(keys.requests.first?.credentials, [keys.credentialID])
        XCTAssertEqual(apple.securityKeyBodies.first?["userHandle"], "", "a user handle that is not UTF-8 is sent empty")
    }

    func testTextMessagesWinWhenAppleOffersNothingElse() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys)
        apple.authOptions["noTrustedDevices"] = true
        let (mock, _) = try await signIn(apple, keys, answers: ["me@example.com", "123456"])
        XCTAssertTrue(keys.requests.isEmpty)
        XCTAssertTrue(mock.requests.contains { $0.url!.path == "/appleauth/auth/verify/phone/securitycode" })
    }

    func testAppleRefusingTheAssertionIsNotRetried() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys)
        apple.securityKeyStatus = 400
        do {
            _ = try await signIn(apple, keys, stage: .account)
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertTrue(e.cause.contains("Apple did not accept the security key's answer: Verification failed."), e.cause)
        }
        XCTAssertEqual(apple.securityKeyBodies.count, 1)
        XCTAssertEqual(keys.requests.count, 1)

        apple.securityKeyStatus = 412
        do { _ = try await signIn(apple, keys); XCTFail("expected an error") } catch let e as XlessError {
            XCTAssertTrue(e.cause.contains("never accepts"), e.cause)
        }
    }

    func testTheKeysOwnFailuresReachThePerson() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys)
        keys.failure = SecurityKeyError("no security key is connected", fix: "plug one in")
        do {
            _ = try await signIn(apple, keys, stage: .account)
            XCTFail("expected an error")
        } catch let e as XlessError {
            XCTAssertEqual(e.stage, .account)
            XCTAssertEqual(e.cause, "no security key is connected")
            XCTAssertEqual(e.fix, "plug one in")
        }
        XCTAssertTrue(apple.securityKeyBodies.isEmpty)
    }

    func testThePINIsReadLikeThePasswordAndNeverSent() async throws {
        let apple = FakeApple(), keys = FakeSecurityKeys()
        apple.authOptions = fsa(keys)
        keys.askPIN = true
        let (mock, prompter) = try await signIn(apple, keys)
        XCTAssertEqual(keys.pins, [FakeApple.password], "askSecret answers the PIN prompt")
        XCTAssertTrue(prompter.prompts.contains("Security key PIN: "))
        for r in mock.requests where r.url!.path.hasSuffix("security/key") {
            XCTAssertFalse(r.bodyString.contains(FakeApple.password))
        }
    }

    func testBase64InEveryFormAppleMightUse() {
        let bytes: [UInt8] = [0xFB, 0xFF, 0x01]
        XCTAssertEqual(AppleSecurityKey.base64("-_8B"), bytes)
        XCTAssertEqual(AppleSecurityKey.base64("+/8B"), bytes)
        XCTAssertEqual(AppleSecurityKey.base64("AQ"), [1])
        XCTAssertEqual(AppleSecurityKey.base64("AQ=="), [1])
        XCTAssertNil(AppleSecurityKey.base64("A"))
        XCTAssertNil(AppleSecurityKey.base64("A=Q"))
        XCTAssertNil(AppleSecurityKey.base64("!!!!"))
        XCTAssertEqual(AppleSecurityKey.base64URL(bytes), "-_8B")
        XCTAssertEqual(AppleSecurityKey.base64URL([1]), "AQ")
    }
}
