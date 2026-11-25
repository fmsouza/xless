import Foundation
import XlessASC
import XlessCore

/// The three certificates the pipeline signs with.
public enum CertificateKind: String, Sendable, CaseIterable {
    case distribution, developerID = "developer-id", installer

    /// The certificate types that count as this kind; the first is the one xless creates.
    public var types: [CertificateType] {
        switch self {
        case .distribution: [.distribution]
        case .developerID: [.developerIDApplicationG2, .developerIDApplication]
        // "3rd Party Mac Developer Installer": the only certificate App Store Connect accepts on a Mac App Store .pkg.
        case .installer: [.macInstallerDistribution]
        }
    }
    /// The type `sign bootstrap` and `provision apply` create.
    public var certificateType: CertificateType { types[0] }
    public var secretName: String {
        switch self {
        case .distribution: "XLESS_DIST_KEY"
        case .developerID: "XLESS_DEVID_KEY"
        case .installer: "XLESS_INSTALLER_KEY"
        }
    }
}

/// The certificate a signing key belongs to, and its content (DER).
public struct SigningCertificate: Sendable {
    public var certificate: ASCCertificate
    public var der: Data
    public var id: String { certificate.id }
}

extension SigningKey {
    /// The certificate of `list` for this key, the first one still valid at `now`; `expired` is one that no longer is.
    public func certificate(in list: [ASCCertificate], now: Date = Date()) -> (valid: SigningCertificate?, expired: ASCCertificate?) {
        var expired: ASCCertificate?
        for c in list {
            guard let der = c.der, (try? matches(certificateDER: Array(der))) == true else { continue }
            if (c.expires ?? .distantFuture) > now { return (SigningCertificate(certificate: c, der: der), expired) }
            expired = expired ?? c
        }
        return (nil, expired)
    }
}

extension ASCCertificates {
    /// The team's certificate of `kind` for `key`, as `sign` and `package` use it.
    public func find(for key: SigningKey, kind: CertificateKind, now: Date = Date()) async throws -> SigningCertificate {
        let found = key.certificate(in: try await list(types: kind.types, withContent: true), now: now)
        if let valid = found.valid { return valid }
        if let expired = found.expired {
            throw XlessError(.sign, "the \(kind.rawValue) certificate \(expired.id) of \(kind.secretName) expired on \(expired.expires.map(ASCDate.day) ?? "")",
                             fix: "create the next one (`xless sign bootstrap --type \(kind.rawValue)`, docs/account.md#rotate-a-certificate)")
        }
        throw XlessError(.sign, "no \(kind.rawValue) certificate in App Store Connect matches \(kind.secretName)",
                         fix: "run `xless sign bootstrap --type \(kind.rawValue)` (or check you set the right key)")
    }
}
