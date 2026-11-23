import Foundation
import XlessCore

// The team's sandbox testers (GET /v2/sandboxTesters): the Apple Accounts that buy in-app purchases in development
// and TestFlight builds without being charged; clearing one's purchase history (POST
// /v2/sandboxTestersClearPurchaseHistoryRequest) lets it buy non-consumables and start introductory offers again.

public struct ASCSandboxTesterAttributes: ASCAttributes, Equatable {
    public var firstName: String?
    public var lastName: String?
    /// The tester's Apple Account (an email address).
    public var acAccountName: String?
    public var territory: String?
    public var applePayCompatible: Bool?
    public var interruptPurchases: Bool?
    public var subscriptionRenewalRate: String?
    public init() {}
}

public typealias ASCSandboxTester = ASCKeptResource<ASCSandboxTesterAttributes>

public struct ASCSandboxTesters: Sendable {
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    /// Every sandbox tester of the team, by account.
    public func list() async throws -> [ASCSandboxTester] {
        try await resources.list("/v2/sandboxTesters", as: ASCSandboxTester.self).items
            .sorted { ($0.attributes.acAccountName ?? "").lowercased() < ($1.attributes.acAccountName ?? "").lowercased() }
    }

    /// The testers named by account (email, any case) or ID; an unknown name is an error naming it, before anything is sent.
    public static func pick(_ names: [String], from all: [ASCSandboxTester]) throws -> [ASCSandboxTester] {
        var out: [ASCSandboxTester] = []
        var unknown: [String] = []
        for name in names {
            let found = all.first { $0.attributes.acAccountName?.lowercased() == name.lowercased() } ?? all.first { $0.id == name }
            if let found { if !out.contains(where: { $0.id == found.id }) { out.append(found) } } else { unknown.append(name) }
        }
        guard unknown.isEmpty else {
            throw XlessError(.account, "no sandbox tester \(unknown.joined(separator: ", ")) in this team",
                             fix: "`xless sandbox-testers list` lists them (account or ID); App Store Connect creates them (Users and Access, Sandbox)")
        }
        return out
    }

    /// Clears the purchase history of `ids`, in one request (POST once).
    public func clearHistory(_ ids: [String]) async throws {
        let body: JSONValue = .object(["data": .object([
            "type": .string("sandboxTestersClearPurchaseHistoryRequest"),
            "relationships": .object(["sandboxTesters": .object(["data": .array(ids.map { .object(["type": .string("sandboxTesters"), "id": .string($0)]) })])]),
        ])])
        _ = try await resources.client.request("POST", "/v2/sandboxTestersClearPurchaseHistoryRequest", body: try JSONEncoder().encode(body), maxAttempts: 1)
    }
}
