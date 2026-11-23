import Foundation
import XlessCore

// App Store Connect webhooks of an app (`/v1/apps/{id}/webhooks`, `/v1/webhooks`): App Store Connect POSTs events
// (a build's upload state, a version's state…) to a URL, signed with a secret the owner chose. xless makes that secret
// itself and keeps it in the secret store; it is never printed (docs/apple-account.md#xless-webhooks).

public struct ASCWebhookAttributes: ASCAttributes, Equatable {
    public var enabled: Bool?
    public var eventTypes: [String]?
    public var name: String?
    public var url: String?
    public init() {}
}

public typealias ASCWebhook = ASCKeptResource<ASCWebhookAttributes>

extension ASCKeptResource where A == ASCWebhookAttributes {
    public var name: String { attributes.name ?? "" }
    public var url: String { attributes.url ?? "" }
    public var events: [String] { attributes.eventTypes ?? [] }
    public var enabled: Bool { attributes.enabled ?? false }
}

/// The events a webhook can be sent (`WebhookEventType`, App Store Connect API 4.6.1).
public enum WebhookEvents {
    public static let known = [
        "ALTERNATIVE_DISTRIBUTION_PACKAGE_AVAILABLE_UPDATED", "ALTERNATIVE_DISTRIBUTION_PACKAGE_VERSION_CREATED",
        "ALTERNATIVE_DISTRIBUTION_TERRITORY_AVAILABILITY_UPDATED", "APP_STORE_VERSION_APP_VERSION_STATE_UPDATED",
        "BACKGROUND_ASSET_VERSION_APP_STORE_RELEASE_STATE_UPDATED", "BACKGROUND_ASSET_VERSION_EXTERNAL_BETA_RELEASE_STATE_UPDATED",
        "BACKGROUND_ASSET_VERSION_INTERNAL_BETA_RELEASE_CREATED", "BACKGROUND_ASSET_VERSION_STATE_UPDATED",
        "BETA_FEEDBACK_CRASH_SUBMISSION_CREATED", "BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED",
        "BUILD_BETA_DETAIL_EXTERNAL_BUILD_STATE_UPDATED", "BUILD_UPLOAD_STATE_UPDATED",
    ]

    /// `--events a,b` (repeatable): any case, `-` or `_`, each once. A well-formed name xless does not know (one Apple
    /// added since) is kept and reported in `unknown`, so it can be sent anyway.
    public static func parse(_ arguments: [String]) throws -> (events: [String], unknown: [String]) {
        var events: [String] = [], unknown: [String] = []
        for word in arguments.flatMap({ $0.split(separator: ",") }) {
            let name = word.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "_")
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw IdentifierInputError("\(word) is not an event: one of \(known.joined(separator: ", "))")
            }
            if events.contains(name) { continue }
            events.append(name)
            if !known.contains(name) { unknown.append(name) }
        }
        guard !events.isEmpty else { throw IdentifierInputError("give at least one event: \(known.joined(separator: ", "))") }
        return (events, unknown)
    }
}

public enum WebhookInput {
    /// The address App Store Connect sends to: an absolute `https` URL with a host, no user or password in it.
    public static func url(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URLComponents(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            throw IdentifierInputError("\(text) is not an https URL")
        }
        guard url.user == nil, url.password == nil else {
            throw IdentifierInputError("the URL must not carry a user name or password; App Store Connect signs each request with the webhook's secret instead")
        }
        return trimmed
    }

    /// A webhook's name: not empty, at most 255 characters.
    public static func name(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { throw IdentifierInputError("a webhook's name is 1 to 255 characters") }
        return trimmed
    }

    /// The default name: the URL's host.
    public static func defaultName(for url: String) -> String { URLComponents(string: url)?.host ?? "xless webhook" }

    /// A webhook's ID: letters, digits and dashes.
    public static func isWebhookID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// A new signing secret: 32 random bytes as 64 hexadecimal characters.
    public static func newSecret() -> SecretBytes {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        text.reserveCapacity(64)
        for _ in 0..<32 {
            let byte = UInt8.random(in: 0...255, using: &generator)
            text.append(digits[Int(byte >> 4)]); text.append(digits[Int(byte & 0x0F)])
        }
        return SecretBytes(wiping: &text)
    }
}

/// What a webhook is created with, besides its secret.
public struct WebhookRequest: Sendable, Equatable {
    public var appID: String
    public var name: String
    public var url: String
    public var events: [String]
    public var enabled: Bool

    public init(appID: String, name: String, url: String, events: [String], enabled: Bool = true) {
        self.appID = appID; self.name = name; self.url = url; self.events = events; self.enabled = enabled
    }
}

/// The webhook operations, on the App Store Connect API key.
public struct ASCWebhooks: Sendable {
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    public func list(app appID: String) async throws -> [ASCWebhook] {
        try await resources.list("/v1/apps/\(appID)/webhooks", as: ASCWebhook.self).items.sorted { $0.name < $1.name }
    }

    public func get(id: String) async throws -> ASCWebhook {
        try await resources.get("/v1/webhooks/\(id)", as: ASCWebhook.self).data
    }

    /// Creates the webhook, signed with `secret`. Sent once, never retried; the secret is hidden from `--verbose` traces
    /// and from App Store Connect's error text.
    public func create(_ request: WebhookRequest, secret: SecretBytes) async throws -> ASCWebhook {
        let value = secret.utf8String()
        HTTPTrace.hide(value)
        let attributes: [String: JSONValue] = [
            "name": .string(request.name), "url": .string(request.url), "enabled": .bool(request.enabled),
            "eventTypes": .array(request.events.map { .string($0) }), "secret": .string(value),
        ]
        do {
            let created: ASCSingle<ASCWebhook> = try await resources.create(
                "/v1/webhooks", type: "webhooks", attributes: attributes,
                relationships: ["app": ASCToOne(ASCRef(type: "apps", id: request.appID))])
            return created.data
        } catch let e as ASCError {
            throw e.scrubbing(value)
        } catch {
            if "\(error)".contains(value) { throw XlessError(.account, "creating the webhook failed", fix: "re-run the command") }
            throw error
        }
    }

    public func delete(id: String) async throws {
        try await resources.delete("/v1/webhooks/\(id)")
    }
}
