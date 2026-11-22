import Foundation

/// One secret in the store: its name, kind and non-secret metadata in clear (so `list` and `status` work while the store
/// is locked), the secret itself sealed with the data key. The metadata is authenticated with the secret (it is the
/// seal's associated data): an altered name, kind or ID makes the entry fail to open.
public struct VaultEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ascAPIKey = "asc-api-key"
        case signingKey = "signing-key"
        case authKey = "auth-key"
        case password
        case generic
    }

    public struct Metadata: Codable, Sendable, Equatable {
        public var teamID: String?
        public var keyID: String?
        public var issuerID: String?
        public var certificateID: String?
        /// Whole seconds (so the dates survive the file's ISO 8601 text unchanged).
        public var created: Date?
        public var expires: Date?
        /// The App Store Connect role of an API key xless created or was told (`ADMIN`, `APP_MANAGER`; several joined
        /// with commas): App Store Connect never tells a key its own role. Authenticated only when set, so entries
        /// written before it existed keep their associated data (an older xless reads an entry with a role as altered).
        public var role: String?

        public init(teamID: String? = nil, keyID: String? = nil, issuerID: String? = nil, certificateID: String? = nil,
                    created: Date? = nil, expires: Date? = nil, role: String? = nil) {
            func clean(_ s: String?) -> String? {
                guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                return t
            }
            self.teamID = clean(teamID)
            self.keyID = clean(keyID)
            self.issuerID = clean(issuerID)
            self.certificateID = clean(certificateID)
            self.created = created.map(Self.wholeSeconds)
            self.expires = expires.map(Self.wholeSeconds)
            self.role = clean(role)
        }

        static func wholeSeconds(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
    }

    public let name: String
    public let kind: Kind
    public let metadata: Metadata
    /// AES-256-GCM, combined form (nonce, ciphertext, tag).
    let sealed: Data

    init(name: String, kind: Kind, metadata: Metadata, sealed: Data) {
        self.name = name
        self.kind = kind
        self.metadata = metadata
        self.sealed = sealed
    }

    /// Letters, digits and `. _ @ -`, starting with a letter or digit, at most 128 characters (`ASC_KEY_P8`,
    /// `XLESS_DIST_KEY@ABCDE12345`).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 128 else { return false }
        func plain(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c)) }
        return plain(first) && name.unicodeScalars.allSatisfy { plain($0) || "._@-".unicodeScalars.contains($0) }
    }

    /// What the seal authenticates besides the secret: every clear field, length-prefixed so no two entries share it.
    var associatedData: Data {
        var out = Data("xless-vault-entry/1".utf8)
        func field(_ s: String?) {
            guard let s else { out.append(0); return }
            out.append(1)
            let bytes = Data(s.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        field(name)
        field(kind.rawValue)
        field(metadata.teamID)
        field(metadata.keyID)
        field(metadata.issuerID)
        field(metadata.certificateID)
        field(metadata.created.map { String(Int64($0.timeIntervalSince1970)) })
        field(metadata.expires.map { String(Int64($0.timeIntervalSince1970)) })
        if let role = metadata.role {
            field("role")
            field(role)
        }
        return out
    }
}
