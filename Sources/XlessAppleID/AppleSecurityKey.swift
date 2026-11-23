import Crypto
import Foundation
import XlessCore
import XlessFIDO

/// Apple's security-key second factor, as XcodesLoginKit (`Client+SecurityKey.swift`) and the asc CLI
/// (`internal/web/auth_security_key.go`) answer it: a WebAuthn assertion for the relying party `apple.com`, over client
/// data that names idmsa.apple.com as its origin, posted flat (standard base64 fields) to `verify/security/key`.
enum AppleSecurityKey {
    static let rpID = "apple.com"
    static let origin = "https://idmsa.apple.com"

    /// What is signed and sent for one `fsaChallenge`.
    struct Prepared: Equatable {
        let challenge: [UInt8]
        let clientData: [UInt8]
        let request: AssertionRequest
    }

    enum Problem: Error, Equatable {
        /// No challenge, or one that is not base64.
        case unreadable
        /// No registered key to sign with.
        case noCredentials
    }

    static func prepare(_ fsa: FSAChallenge) throws(Problem) -> Prepared {
        guard let text = fsa.challenge, let challenge = base64(text), !challenge.isEmpty else { throw .unreadable }
        var encoded = (fsa.allowedCredentials ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if encoded.isEmpty { encoded = (fsa.keyHandles ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        guard !encoded.isEmpty else { throw .noCredentials }
        var credentials: [[UInt8]] = []
        for item in encoded {
            guard let id = base64(item), !id.isEmpty else { throw .unreadable }
            if !credentials.contains(id) { credentials.append(id) }
        }
        let data = clientData(challenge: challenge)
        return Prepared(challenge: challenge, clientData: data,
                        request: AssertionRequest(rpID: rpID, clientDataHash: Array(SHA256.hash(data: data)), credentials: credentials))
    }

    /// The client data, byte for byte as the two implementations Apple accepts write it (crossOrigin true, as they
    /// both send; the key signs its hash and Apple reads it back from the body).
    static func clientData(challenge: [UInt8]) -> [UInt8] {
        Array(#"{"type":"webauthn.get","challenge":"\#(base64URL(challenge))","origin":"\#(origin)","crossOrigin":true}"#.utf8)
    }

    /// The body of `POST /appleauth/auth/verify/security/key`.
    static func body(_ prepared: Prepared, _ assertion: Assertion) -> Data {
        let userHandle = assertion.userHandle.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        let fields: [String: String] = [
            "challenge": Data(prepared.challenge).base64EncodedString(),
            "clientData": Data(prepared.clientData).base64EncodedString(),
            "signatureData": Data(assertion.signature).base64EncodedString(),
            "authenticatorData": Data(assertion.authenticatorData).base64EncodedString(),
            "userHandle": userHandle,
            "credentialID": Data(assertion.credentialID ?? []).base64EncodedString(),
            "rpId": rpID,
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    /// Standard or URL-safe base64, padded or not.
    static func base64(_ text: String) -> [UInt8]? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.contains("=") || s.hasSuffix("=") else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        if s.count % 4 == 1 { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).map(Array.init)
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The sign-in's terminal, for the security-key steps: the PIN is read like the password (echo off).
struct PrompterKeyUI: SecurityKeyUI {
    let prompter: any SignInPrompter
    func say(_ line: String) { prompter.say(line) }
    func askPIN(_ prompt: String) async throws -> SecretBytes { try await prompter.askSecret(prompt) }
    func waitForKey(_ prompt: String) async throws { _ = try await prompter.ask(prompt) }
}
