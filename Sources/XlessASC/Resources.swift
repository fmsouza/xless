import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The query of a listing or a read: `filter[…]`, sparse fieldsets (`fields[type]`), `include`, `sort`, `limit` and any
/// other parameter, rendered in that order (`limit` last).
public struct ASCQuery: Sendable {
    public var filters: [(String, String)]
    public var fields: [(String, [String])]
    public var include: [String]
    public var sort: [String]
    public var limit: Int?
    public var extra: [(String, String)]

    public init(filters: [(String, String)] = [], fields: [(String, [String])] = [], include: [String] = [], sort: [String] = [],
                limit: Int? = nil, extra: [(String, String)] = []) {
        self.filters = filters; self.fields = fields; self.include = include; self.sort = sort; self.limit = limit; self.extra = extra
    }

    /// The query parameters, as `ASCClient` sends them.
    public var items: [(String, String)] {
        var out = filters.map { ("filter[\($0.0)]", $0.1) }
        out += fields.map { ("fields[\($0.0)]", $0.1.joined(separator: ",")) }
        if !include.isEmpty { out.append(("include", include.joined(separator: ","))) }
        if !sort.isEmpty { out.append(("sort", sort.joined(separator: ","))) }
        out += extra
        if let limit { out.append(("limit", String(limit))) }
        return out
    }
}

/// A resource of any type, attributes as raw JSON: what `included` holds, and what commands without a model print.
public struct ASCAnyResource: Codable, Sendable, Equatable {
    public var type: String
    public var id: String
    public var attributes: [String: JSONValue]?
    public var relationships: [String: JSONValue]?
    public var links: [String: JSONValue]?

    public init(type: String, id: String, attributes: [String: JSONValue]? = nil, relationships: [String: JSONValue]? = nil) {
        self.type = type; self.id = id; self.attributes = attributes; self.relationships = relationships
    }

    public var ref: ASCRef { ASCRef(type: type, id: id) }

    static func find<A: Codable & Sendable>(_ ref: ASCRef, in included: [ASCAnyResource], as: A.Type) throws -> ASCResource<A>? {
        try included.first { $0.type == ref.type && $0.id == ref.id }?.decode(as: A.self)
    }

    /// This resource with typed attributes.
    public func decode<A: Codable & Sendable>(as: A.Type) throws -> ASCResource<A> {
        try JSONDecoder().decode(ASCResource<A>.self, from: JSONEncoder().encode(self))
    }
}

/// One page of a listing.
public struct ASCPage<D: Decodable & Sendable>: Decodable, Sendable {
    public struct Links: Decodable, Sendable { public var next: String? }
    public struct Meta: Decodable, Sendable {
        public struct Paging: Decodable, Sendable { public var total: Int? }
        public var paging: Paging?
    }
    public var data: [D]
    public var included: [ASCAnyResource]?
    public var links: Links?
    public var meta: Meta?
}

/// Every item of a listing, with the resources its pages `included` (each once, in the order first seen).
public struct ASCListing<D: Sendable>: Sendable {
    public var items: [D]
    public var included: [ASCAnyResource]

    public init(items: [D] = [], included: [ASCAnyResource] = []) { self.items = items; self.included = included }

    mutating func merge(included more: [ASCAnyResource]?) {
        for resource in more ?? [] where !included.contains(where: { $0.type == resource.type && $0.id == resource.id }) {
            included.append(resource)
        }
    }

    /// The included resource `ref` points at, typed; nil when the listing did not include it.
    public func included<A: Codable & Sendable>(_ ref: ASCRef, as: A.Type) throws -> ASCResource<A>? {
        try ASCAnyResource.find(ref, in: included, as: A.self)
    }
}

/// A single resource read, with what it `included`.
public struct ASCSingle<D: Decodable & Sendable>: Decodable, Sendable {
    public var data: D
    public var included: [ASCAnyResource]

    enum CodingKeys: String, CodingKey { case data, included }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(D.self, forKey: .data)
        included = try c.decodeIfPresent([ASCAnyResource].self, forKey: .included) ?? []
    }

    public func included<A: Codable & Sendable>(_ ref: ASCRef, as: A.Type) throws -> ASCResource<A>? {
        try ASCAnyResource.find(ref, in: included, as: A.self)
    }
}

/// The JSON:API operations every App Store Connect resource shares, on top of `ASCClient` (JWT, retries, rate limits):
/// listings that follow `links.next`, reads with `include`, creates, updates, deletes and relationship linkage. Untyped
/// resources decode as `ASCAnyResource` / `JSONValue`.
public struct ASCResources: Sendable {
    public let client: ASCClient
    /// The page size asked when the query sets none: App Store Connect's maximum for most listings.
    public static let defaultLimit = 200

    public init(client: ASCClient) { self.client = client }

    /// Every item of the listing at `path` (at most `maxItems`), following `links.next`. A listing that does not end
    /// within `ASCPaging.maxPages` pages throws `ASCPagingError.didNotTerminate`, never returns a truncated list.
    public func list<D: Decodable & Sendable>(_ path: String, query: ASCQuery = ASCQuery(), as: D.Type, maxItems: Int? = nil) async throws -> ASCListing<D> {
        var q = query
        if q.limit == nil, !q.extra.contains(where: { $0.0 == "limit" }) { q.limit = maxItems.map { min($0, Self.defaultLimit) } ?? Self.defaultLimit }
        var listing = ASCListing<D>()
        var next: (path: String, query: [(String, String)])? = (path, q.items)
        var pages = 0
        while let (p, items) = next {
            let page: ASCPage<D> = try await client.get(p, query: items)
            listing.items += page.data
            listing.merge(included: page.included)
            pages += 1
            next = nil
            if let maxItems, listing.items.count >= maxItems {
                listing.items = Array(listing.items.prefix(maxItems))
                break
            }
            if let link = page.links?.next, let target = ASCPaging.parseLink(link) {
                guard pages < ASCPaging.maxPages else { throw ASCPagingError.didNotTerminate(path: path) }
                next = target
            }
        }
        return listing
    }

    /// One resource (`/v1/apps/<id>`), with what `query.include` asked for.
    public func get<D: Decodable & Sendable>(_ path: String, query: ASCQuery = ASCQuery(), as: D.Type) async throws -> ASCSingle<D> {
        try await client.get(path, query: query.items)
    }

    /// POST `{ data: { type, attributes, relationships } }` to a collection. Sent once, never retried: a retry of a
    /// create whose first attempt went through could make a second resource, or burn a scarce one (a certificate slot).
    public func create<A: Encodable & Sendable, R: Encodable & Sendable, D: Decodable & Sendable>(
        _ path: String, type: String, attributes: A, relationships: R?) async throws -> ASCSingle<D> {
        try await client.postOnce(path, body: Body(data: .init(type: type, id: nil, attributes: attributes, relationships: relationships)))
    }

    public func create<A: Encodable & Sendable, D: Decodable & Sendable>(_ path: String, type: String, attributes: A) async throws -> ASCSingle<D> {
        try await create(path, type: type, attributes: attributes, relationships: ASCNoRelationships?.none)
    }

    /// PATCH `{ data: { type, id, attributes } }` to the resource at `path`.
    public func update<A: Encodable & Sendable, D: Decodable & Sendable>(_ path: String, type: String, id: String, attributes: A) async throws -> ASCSingle<D> {
        try await client.patch(path, body: Body(data: .init(type: type, id: id, attributes: attributes, relationships: ASCNoRelationships?.none)))
    }

    public func delete(_ path: String) async throws { try await client.delete(path) }

    /// The linkage of a to-many relationship (`<resource>/relationships/<name>`), every page.
    public func relationship(_ resource: String, _ name: String) async throws -> [ASCRef] {
        try await list("\(resource)/relationships/\(name)", as: ASCRef.self).items
    }

    /// The linkage of a to-one relationship; nil when it is empty.
    public func toOneRelationship(_ resource: String, _ name: String) async throws -> ASCRef? {
        let doc: ToOneDocument = try await client.get("\(resource)/relationships/\(name)")
        return doc.data
    }

    /// Adds `refs` to a to-many relationship (POST).
    public func addRelationship(_ resource: String, _ name: String, _ refs: [ASCRef]) async throws {
        let _: ASCEmpty = try await client.post("\(resource)/relationships/\(name)", body: ASCToMany(refs))
    }

    /// Removes `refs` from a to-many relationship (DELETE with a body).
    public func removeRelationship(_ resource: String, _ name: String, _ refs: [ASCRef]) async throws {
        try await client.delete("\(resource)/relationships/\(name)", body: ASCToMany(refs))
    }

    /// Replaces a to-many relationship's linkage with `refs` (PATCH).
    public func replaceRelationship(_ resource: String, _ name: String, _ refs: [ASCRef]) async throws {
        let _: ASCEmpty = try await client.patch("\(resource)/relationships/\(name)", body: ASCToMany(refs))
    }

    /// Points a to-one relationship at `ref` (PATCH).
    public func replaceToOneRelationship(_ resource: String, _ name: String, _ ref: ASCRef) async throws {
        let _: ASCEmpty = try await client.patch("\(resource)/relationships/\(name)", body: ASCToOne(ref))
    }

    struct ToOneDocument: Decodable { var data: ASCRef? }

    struct Body<A: Encodable & Sendable, R: Encodable & Sendable>: Encodable, Sendable {
        struct Inner: Encodable, Sendable {
            var type: String
            var id: String?
            var attributes: A
            var relationships: R?
        }
        var data: Inner
    }
}
