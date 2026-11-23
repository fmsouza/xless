import Foundation
import XlessCore

// App records (`/v1/apps`) for `xless apps list | show | update` (docs/apple-account.md#xless-apps), and the input rules
// `xless apps create` checks before anything is sent. Creating an app has no documented API: XlessAppleID's
// `ASCWebApps` does it through the Apple ID web session.

public struct ASCAppAttributes: ASCAttributes, Equatable {
    public var name: String?
    public var bundleId: String?
    public var sku: String?
    public var primaryLocale: String?
    public var contentRightsDeclaration: String?
    public init() {}
}

public typealias ASCApp = ASCKeptResource<ASCAppAttributes>

extension ASCKeptResource where A == ASCAppAttributes {
    public var name: String { attributes.name ?? "" }
    public var bundleID: String { attributes.bundleId ?? "" }
}

/// An app info: the app's App Store details that change only with a new version (state, age rating).
public struct ASCAppInfoAttributes: ASCAttributes, Equatable {
    public var state: String?
    public var appStoreState: String?
    public var appStoreAgeRating: String?
    public init() {}
}

public typealias ASCAppInfo = ASCKeptResource<ASCAppInfoAttributes>

public struct ASCAppStoreVersionAttributes: ASCAttributes, Equatable {
    public var platform: String?
    public var versionString: String?
    public var appVersionState: String?
    public var appStoreState: String?
    public var releaseType: String?
    public var createdDate: String?
    public init() {}
}

public typealias ASCAppStoreVersion = ASCKeptResource<ASCAppStoreVersionAttributes>

/// How a command names an app: its App Store Connect app ID (digits, e.g. 1234567890) or its bundle identifier.
public enum AppArgument {
    public static func isAppID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 20 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    public static func validate(_ text: String) throws {
        if isAppID(text) { return }
        guard BundleIdentifier.isIdentifier(text), !text.contains("*") else {
            throw IdentifierInputError("\(text) is neither an app ID (digits, see `xless apps list`) nor a bundle identifier (com.example.app)")
        }
        _ = try BundleIdentifier.validate(text)
    }
}

/// An app's SKU: letters, digits, `-`, `.` and `_`, not starting with one of those three marks (App Store Connect's rule).
public enum AppSKU {
    public static func validate(_ raw: String) throws -> String {
        let sku = raw.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard !sku.isEmpty, sku.count <= 255, sku.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let first = sku.first, !"-._".contains(first) else {
            throw IdentifierInputError("\(sku.isEmpty ? "an empty SKU" : "SKU \(sku)") is not one App Store Connect accepts: use letters, digits, -, . and _, not starting with -, . or _")
        }
        return sku
    }
}

/// An app's name on the App Store: 2 to 30 characters (App Store Connect's rule). Unique across the whole store, which
/// only Apple can check.
public enum AppName {
    public static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard (2...30).contains(name.count) else {
            throw IdentifierInputError("the app name \"\(name)\" has \(name.count) characters: App Store Connect takes 2 to 30")
        }
        return name
    }
}

/// App Store Connect's locales, as it spells them.
public enum AppLocale {
    public static let known = [
        "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR",
        "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sv",
        "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    /// A known locale in App Store Connect's spelling (`en-us` → `en-US`); a well-formed locale xless does not know is
    /// passed on as it is, for Apple to accept or refuse.
    public static func normalize(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let match = known.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return match }
        guard text.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw IdentifierInputError("\(text.isEmpty ? "an empty locale" : text) is not a locale: use App Store Connect's, e.g. en-US, de-DE, ja, zh-Hans")
        }
        return text
    }
}

/// Whether the app shows, contains or accesses third-party content (App Store Connect's content rights declaration).
public enum AppContentRights: String, Codable, Sendable, CaseIterable {
    case usesThirdPartyContent = "USES_THIRD_PARTY_CONTENT"
    case doesNotUseThirdPartyContent = "DOES_NOT_USE_THIRD_PARTY_CONTENT"

    /// `uses-third-party-content` / `does-not-use-third-party-content` (or the API value, any case), `uses` / `none`.
    public init?(argument: String) {
        let a = argument.lowercased().replacingOccurrences(of: "_", with: "-")
        switch a {
        case "uses-third-party-content", "uses": self = .usesThirdPartyContent
        case "does-not-use-third-party-content", "none": self = .doesNotUseThirdPartyContent
        default: return nil
        }
    }

    public var argument: String { rawValue.lowercased().replacingOccurrences(of: "_", with: "-") }
}

/// The platforms an app record is created for (App Store versions).
public enum AppPlatform: String, Codable, Sendable, CaseIterable {
    case ios = "IOS"
    case macOS = "MAC_OS"

    /// `ios`, `macos` or `mac`, any case.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "ios": self = .ios
        case "macos", "mac": self = .macOS
        default: return nil
        }
    }

    public var argument: String { self == .ios ? "ios" : "macos" }

    /// The command-line name of an API platform value; an unknown one as it is.
    public static func display(_ value: String?) -> String {
        guard let value else { return "" }
        return AppPlatform(rawValue: value)?.argument ?? value
    }
}

/// The app-record operations, on the App Store Connect API key.
public struct ASCApps: Sendable {
    public static let path = "/v1/apps"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    /// Every app the key sees (every page), by name.
    public func list() async throws -> [ASCApp] {
        let listing = try await resources.list(Self.path, as: ASCApp.self)
        return listing.items.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    public func get(id: String) async throws -> ASCApp {
        guard AppArgument.isAppID(id) else {
            throw XlessError(.account, "\(id) is not an app ID", fix: "use an app ID or a bundle identifier from `xless apps list`")
        }
        let single: ASCSingle<ASCApp> = try await resources.get("\(Self.path)/\(id)", as: ASCApp.self)
        return single.data
    }

    /// The app with exactly this bundle identifier.
    public func find(bundleID: String) async throws -> ASCApp? {
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: [("bundleId", bundleID)]), as: ASCApp.self)
        return listing.items.first { $0.bundleID == bundleID }
    }

    /// The app a command names: an app ID or a bundle identifier (looked up).
    public func resolve(_ text: String) async throws -> ASCApp {
        if AppArgument.isAppID(text) { return try await get(id: text) }
        do { try AppArgument.validate(text) } catch let e as IdentifierInputError {
            throw XlessError(.account, e.description, fix: "use an app ID or a bundle identifier from `xless apps list`")
        }
        guard let found = try await find(bundleID: text) else {
            throw XlessError(.account, "no app record for \(text) is visible to this API key",
                             fix: "check `xless apps list` (and --team), or create it with `xless apps create --bundle-id \(text) --name <name> --sku <sku> --locale <locale>`")
        }
        return found
    }

    public func infos(of appID: String) async throws -> [ASCAppInfo] {
        try await resources.list("\(Self.path)/\(appID)/appInfos", as: ASCAppInfo.self).items
    }

    public func versions(of appID: String) async throws -> [ASCAppStoreVersion] {
        try await resources.list("\(Self.path)/\(appID)/appStoreVersions", as: ASCAppStoreVersion.self).items
    }

    /// Changes the given attributes that differ from the app's (PATCH /v1/apps/{id}); nil when none differs and nothing
    /// was sent.
    public func update(_ app: ASCApp, primaryLocale: String?, contentRights: AppContentRights?, bundleID: String?) async throws -> ASCApp? {
        struct Attributes: Encodable, Sendable { var primaryLocale: String?; var contentRightsDeclaration: String?; var bundleId: String? }
        let a = app.attributes
        let changes = Attributes(primaryLocale: primaryLocale.flatMap { $0 == a.primaryLocale ? nil : $0 },
                                 contentRightsDeclaration: contentRights.flatMap { $0.rawValue == a.contentRightsDeclaration ? nil : $0.rawValue },
                                 bundleId: bundleID.flatMap { $0 == a.bundleId ? nil : $0 })
        guard changes.primaryLocale != nil || changes.contentRightsDeclaration != nil || changes.bundleId != nil else { return nil }
        let updated: ASCSingle<ASCApp> = try await resources.update("\(Self.path)/\(app.id)", type: "apps", id: app.id, attributes: changes)
        return updated.data
    }
}
