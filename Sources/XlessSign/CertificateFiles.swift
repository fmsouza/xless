import Foundation
import X509
import XlessCore

/// A certificate signing request someone else made (`xless certs create --csr`): its key lives elsewhere (an HSM, another
/// machine), so nothing secret touches xless.
public enum CSRFile {
    /// The CSR in `data` (PEM, or DER as some tools write it) as PEM, the form App Store Connect's `csrContent` takes.
    /// Anything that is not a well-formed, self-signed CSR is refused before it is sent.
    public static func pem(from data: Data, path: String) throws -> String {
        let csr: CertificateSigningRequest
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            guard let parsed = try? CertificateSigningRequest(pemEncoded: PEM.normalize(text)) else { throw refused(path) }
            csr = parsed
        } else {
            guard let parsed = try? CertificateSigningRequest(derEncoded: Array(data)) else { throw refused(path) }
            csr = parsed
        }
        guard csr.publicKey.isValidSignature(csr.signature, for: csr) else { throw refused(path) }
        do { return try csr.serializeAsPEM().pemString + "\n" } catch { throw refused(path) }
    }

    static func refused(_ path: String) -> XlessError {
        XlessError(.account, "\(path) is not a certificate signing request (PEM \"CERTIFICATE REQUEST\" or DER)",
                   fix: "pass the .certSigningRequest/.csr file made with the key (Keychain Access, openssl req -new, your HSM)")
    }
}

/// What xless reads from a certificate Apple issued: when it expires and the team it is for (Apple puts the team ID in
/// the subject's organizational unit).
public struct CertificateFacts: Sendable, Equatable {
    public var expires: Date?
    public var teamID: String?

    public init(expires: Date?, teamID: String?) { self.expires = expires; self.teamID = teamID }

    /// nil when `der` is not a certificate.
    public init?(der: Data) {
        guard let cert = try? Certificate(derEncoded: Array(der)) else { return nil }
        expires = cert.notValidAfter
        teamID = cert.subject.flatMap { $0 }.first { $0.type == .RDNAttributeType.organizationalUnitName }.flatMap { String($0.value) }
    }
}
