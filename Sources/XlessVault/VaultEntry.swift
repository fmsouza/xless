import Foundation

/// One secret in the store: its name, kind and non-secret metadata in clear (so `list` and `status` work while the store
/// is locked), the secret itself sealed with the data key. The metadata is authenticated with the secret (it is the
/// seal's associated data): an altered, added or removed name, kind or metadata field makes the entry fail to open.
///
/// Entry formats: 1 (stores of `version` 1) authenticated `role`, `certificateType` and `services` only when set;
/// 2 (`"version": 2` on the entry) authenticates every field, set or not. Fields a newer xless added are kept as they
/// were read and written back unchanged.
public struct VaultEntry: Codable, Sendable, Equatable {
    /// The entry format this xless seals.
    public static let currentFormat = 2

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
        /// with commas): App Store Connect never tells a key its own role.
        public var role: String?
        /// The App Store Connect `certificateType` of the certificate a signing key belongs to (`DISTRIBUTION`).
        public var certificateType: String?
        /// The services an auth key signs for (`apns`, `apns,siwa`), as `xless keys create` takes them.
        public var services: String?
        /// Fields this xless does not know, as read (a newer xless's). A format-2 entry with any fails to open.
        var unknown: [String: VaultJSON] = [:]

        public init(teamID: String? = nil, keyID: String? = nil, issuerID: String? = nil, certificateID: String? = nil,
                    created: Date? = nil, expires: Date? = nil, role: String? = nil, certificateType: String? = nil,
                    services: String? = nil) {
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
            self.certificateType = clean(certificateType)
            self.services = clean(services)
        }

        static func wholeSeconds(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case teamID, keyID, issuerID, certificateID, created, expires, role, certificateType, services
        }

        static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
            keyID = try c.decodeIfPresent(String.self, forKey: .keyID)
            issuerID = try c.decodeIfPresent(String.self, forKey: .issuerID)
            certificateID = try c.decodeIfPresent(String.self, forKey: .certificateID)
            created = try c.decodeIfPresent(Date.self, forKey: .created)
            expires = try c.decodeIfPresent(Date.self, forKey: .expires)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            certificateType = try c.decodeIfPresent(String.self, forKey: .certificateType)
            services = try c.decodeIfPresent(String.self, forKey: .services)
            unknown = try VaultJSON.unknownMembers(of: decoder, known: Self.knownKeys)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(teamID, forKey: .teamID)
            try c.encodeIfPresent(keyID, forKey: .keyID)
            try c.encodeIfPresent(issuerID, forKey: .issuerID)
            try c.encodeIfPresent(certificateID, forKey: .certificateID)
            try c.encodeIfPresent(created, forKey: .created)
            try c.encodeIfPresent(expires, forKey: .expires)
            try c.encodeIfPresent(role, forKey: .role)
            try c.encodeIfPresent(certificateType, forKey: .certificateType)
            try c.encodeIfPresent(services, forKey: .services)
            try VaultJSON.encode(unknown, to: encoder, known: Self.knownKeys)
        }
    }

    public let name: String
    public let kind: Kind
    public let metadata: Metadata
    /// AES-256-GCM, combined form (nonce, ciphertext, tag).
    let sealed: Data
    /// The entry format its seal was made with (see the type's comment); 0 when the file says nothing valid (a format-1
    /// entry in a store of version 2 or later), which never opens.
    var format: Int
    /// Entry fields this xless does not know, as read.
    var unknown: [String: VaultJSON] = [:]

    init(name: String, kind: Kind, metadata: Metadata, sealed: Data, format: Int = VaultEntry.currentFormat) {
        self.name = name
        self.kind = kind
        self.metadata = metadata
        self.sealed = sealed
        self.format = format
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case name, kind, metadata, sealed, version }
    static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// Format 1 when the entry carries no `version` (the store's version decides what it really is: `VaultFile`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        metadata = try c.decode(Metadata.self, forKey: .metadata)
        sealed = try c.decode(Data.self, forKey: .sealed)
        format = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        unknown = try VaultJSON.unknownMembers(of: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(sealed, forKey: .sealed)
        if format >= 2 { try c.encode(format, forKey: .version) }
        try VaultJSON.encode(unknown, to: encoder, known: Self.knownKeys)
    }

    /// Letters, digits and `. _ @ -`, starting with a letter or digit, at most 128 characters (`ASC_KEY_P8`,
    /// `XLESS_DIST_KEY@ABCDE12345`).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= 128 else { return false }
        func plain(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c)) }
        return plain(first) && name.unicodeScalars.allSatisfy { plain($0) || "._@-".unicodeScalars.contains($0) }
    }

    /// What the seal authenticates besides the secret, length-prefixed so no two entries share it. Format 1: the eight
    /// first fields, then `role`, `certificateType` and `services` only when set (labelled). Format 2: every field, each
    /// marked set or not. Nil for a format this xless cannot check.
    var associatedData: Data? {
        guard format == 1 || format == 2 else { return nil }
        var out = Data("xless-vault-entry/\(format)".utf8)
        func field(_ s: String?) {
            guard let s else { out.append(0); return }
            out.append(1)
            let bytes = Data(s.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        let m = metadata
        let dates = [m.created, m.expires].map { $0.map { String(Int64($0.timeIntervalSince1970)) } }
        for f in [name, kind.rawValue, m.teamID, m.keyID, m.issuerID, m.certificateID, dates[0], dates[1]] { field(f) }
        if format == 2 {
            for f in [m.role, m.certificateType, m.services] { field(f) }
            return out
        }
        for (label, value) in [("role", m.role), ("certificateType", m.certificateType), ("services", m.services)] {
            if let value {
                field(label)
                field(value)
            }
        }
        return out
    }
}
