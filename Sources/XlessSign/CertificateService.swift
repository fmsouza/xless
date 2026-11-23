import Foundation
import XlessASC
import XlessCore

public enum CertificateKind: String, Sendable, CaseIterable {
    case distribution, developerID = "developer-id", installer

    /// certificateType values that count as this kind when listing.
    public var ascTypes: [String] {
        switch self {
        case .distribution: ["DISTRIBUTION"]
        case .developerID: ["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"]
        // "3rd Party Mac Developer Installer": the only certificate App Store Connect accepts on a Mac App Store .pkg.
        case .installer: ["MAC_INSTALLER_DISTRIBUTION"]
        }
    }
    public var createType: String { ascTypes[0] }
    /// Apple's documented per-team limit (`CertificateType.cap`: five Developer ID Application certificates); nil where
    /// Apple documents none, and App Store Connect refuses a certificate too many itself.
    public var cap: Int? { certificateType.cap }
    /// The API type `bootstrap` creates.
    public var certificateType: CertificateType {
        switch self {
        case .distribution: .distribution
        case .developerID: .developerIDApplicationG2
        case .installer: .macInstallerDistribution
        }
    }
    public var secretName: String {
        switch self {
        case .distribution: "XLESS_DIST_KEY"
        case .developerID: "XLESS_DEVID_KEY"
        case .installer: "XLESS_INSTALLER_KEY"
        }
    }
}

public struct CertificateAttributes: Codable, Sendable {
    public var certificateType: String?
    public var certificateContent: String?
    public var name: String?
    public var expirationDate: String?
    public var csrContent: String?
}

public struct CertificateService: Sendable {
    let client: ASCClient
    public init(client: ASCClient) { self.client = client }

    /// Every certificate of `kind` (all pages).
    public func list(_ kind: CertificateKind) async throws -> [ASCResource<CertificateAttributes>] {
        try await ASCResources(client: client).list("/v1/certificates", query: ASCQuery(filters: [("certificateType", kind.ascTypes.joined(separator: ","))]),
                                                    as: ASCResource<CertificateAttributes>.self).items
    }

    public func find(matching key: SigningKey, kind: CertificateKind) async throws -> ASCResource<CertificateAttributes> {
        for cert in try await list(kind) {
            guard let b64 = cert.attributes.certificateContent, let der = Data(base64Encoded: b64) else { continue }
            if (try? key.matches(certificateDER: Array(der))) == true { return cert }
        }
        throw XlessError(.sign, "no \(kind.rawValue) certificate in App Store Connect matches \(kind.secretName)",
                         fix: "run `xless sign bootstrap --type \(kind.rawValue)` (or check you set the right key)")
    }

    /// Generates a key and creates a certificate. Prefer `bootstrap(kind:allowNew:key:)` with a key already persisted to disk.
    public func bootstrap(kind: CertificateKind, allowNew: Bool) async throws -> (SigningKey, ASCResource<CertificateAttributes>) {
        let key = try SigningKey.generate()
        return (key, try await bootstrap(kind: kind, allowNew: allowNew, key: key))
    }

    /// Creates a certificate for `key`. The POST is attempted exactly once (a retry could burn a second slot).
    public func bootstrap(kind: CertificateKind, allowNew: Bool, key: SigningKey) async throws -> ASCResource<CertificateAttributes> {
        let existing = try await list(kind)
        if let cap = kind.cap, existing.count >= cap {
            throw XlessError(.sign, "team already has \(existing.count) \(kind.rawValue) certificates (Apple limit \(cap))",
                             fix: "revoke an unused one (`xless certs list --type \(kind.certificateType.argument)`, `xless certs revoke <id>`)")
        }
        if !existing.isEmpty, !allowNew {
            throw XlessError(.sign, "team already has \(existing.count) \(kind.rawValue) certificate(s); their private keys cannot be downloaded",
                             fix: "reuse the key you already stored, or pass --allow-new to create another\(kind.cap.map { " (uses one of \($0) slots)" } ?? "")")
        }
        struct Attrs: Codable, Sendable { var csrContent: String; var certificateType: String }
        let body = ASCCreate<Attrs, ASCNoRelationships>(type: "certificates",
                                                        attributes: .init(csrContent: try key.csrPEM(commonName: "xless"), certificateType: kind.createType))
        do {
            let doc: ASCDocument<ASCResource<CertificateAttributes>> = try await client.postOnce("/v1/certificates", body: body)
            return doc.data
        } catch let e as ASCError where e.status == 403 {
            throw XlessError(.sign, "App Store Connect refused to create a \(kind.rawValue) certificate (\(e))",
                             fix: "Developer ID certificates need the Account Holder: have them run `xless sign bootstrap --type \(kind.rawValue)`, or run `xless sign bootstrap --type \(kind.rawValue) --csr-only --out <key file>` and have them create it with `xless certs create --type \(kind.certificateType.argument) --csr <key file>.csr`")
        } catch where Self.isAmbiguous(error) {
            let now = (try? await list(kind).count).map(String.init) ?? "unknown"
            throw XlessError(.sign, "\(Self.ambiguousMarker): the create request failed (\(error)) and may or may not have succeeded; team now has \(now) \(kind.rawValue) certificate(s) (was \(existing.count))",
                             fix: "check `xless certs list --type \(kind.certificateType.argument)` before retrying with --allow-new; the key was kept in case the certificate exists")
        }
    }

    static let ambiguousMarker = "certificate creation is ambiguous"

    /// `ASCCertificates.isAmbiguous`: whether a failed create POST may have made the certificate.
    static func isAmbiguous(_ error: Error) -> Bool { ASCCertificates.isAmbiguous(error) }
}

extension XlessError {
    /// True when a certificate POST failed in a way that may have created the certificate.
    public var isAmbiguousCertificateCreation: Bool { cause.hasPrefix(CertificateService.ambiguousMarker) }
}
