import Foundation
import XlessCore

// Customer reviews of an app on the App Store and the developer's responses (`/v1/apps/{id}/customerReviews`,
// `/v1/customerReviews`, `/v1/customerReviewResponses`). Needs an API key with the Customer Support role (or Admin,
// App Manager): docs/apple-account.md#xless-reviews.

public struct ASCCustomerReviewAttributes: ASCAttributes, Equatable {
    public var rating: Int?
    public var title: String?
    public var body: String?
    public var reviewerNickname: String?
    public var createdDate: String?
    public var territory: String?
    public init() {}
}

public typealias ASCCustomerReview = ASCKeptResource<ASCCustomerReviewAttributes>

extension ASCKeptResource where A == ASCCustomerReviewAttributes {
    public var rating: Int { attributes.rating ?? 0 }
    public var title: String { attributes.title ?? "" }
    public var body: String { attributes.body ?? "" }
    /// The ID of the review's response, when it has one (and the read asked for the relationship).
    public var responseID: String? { resource.relatedID("response") }
    /// The rating as `4/5`.
    public var stars: String { "\(rating)/5" }
}

public struct ASCReviewResponseAttributes: ASCAttributes, Equatable {
    public var responseBody: String?
    public var lastModifiedDate: String?
    /// `PUBLISHED` or `PENDING_PUBLISH`.
    public var state: String?
    public init() {}
}

public typealias ASCReviewResponse = ASCKeptResource<ASCReviewResponseAttributes>

extension ASCKeptResource where A == ASCReviewResponseAttributes {
    public var text: String { attributes.responseBody ?? "" }
    public var state: String { attributes.state ?? "" }
}

/// The order of a review listing, as `--sort` names it.
public enum ReviewSort: String, CaseIterable, Sendable {
    case newest, oldest, highest, lowest

    public var parameter: String {
        switch self {
        case .newest: "-createdDate"
        case .oldest: "createdDate"
        case .highest: "-rating"
        case .lowest: "rating"
        }
    }
}

/// Which reviews a listing asks for.
public struct ReviewFilter: Sendable, Equatable {
    /// Star ratings (1–5); empty = every rating.
    public var ratings: [Int]
    /// App Store territories (`USA`, `FRA`); empty = every territory.
    public var territories: [String]
    /// true: only reviews with a published response; false: only those without; nil: both.
    public var answered: Bool?
    public var sort: ReviewSort

    public init(ratings: [Int] = [], territories: [String] = [], answered: Bool? = nil, sort: ReviewSort = .newest) {
        self.ratings = ratings; self.territories = territories; self.answered = answered; self.sort = sort
    }

    var query: ASCQuery {
        var filters: [(String, String)] = []
        if !ratings.isEmpty { filters.append(("rating", ratings.map(String.init).joined(separator: ","))) }
        if !territories.isEmpty { filters.append(("territory", territories.joined(separator: ","))) }
        let extra = answered.map { [("exists[publishedResponse]", String($0))] } ?? []
        return ASCQuery(filters: filters, include: ["response"], sort: [sort.parameter], extra: extra)
    }
}

public enum ReviewInput {
    /// The most characters App Store Connect takes in a response.
    public static let maxResponseLength = 5970

    /// `--rating 1,2` (repeatable or comma-separated): each 1 to 5, each once, in order.
    public static func ratings(_ arguments: [String]) throws -> [Int] {
        var out: [Int] = []
        for word in arguments.flatMap({ $0.split(separator: ",") }) {
            let text = word.trimmingCharacters(in: .whitespaces)
            guard let rating = Int(text), (1...5).contains(rating) else { throw IdentifierInputError("\(text) is not a rating: 1 to 5 stars") }
            if !out.contains(rating) { out.append(rating) }
        }
        return out.sorted()
    }

    /// `--territory USA,FRA`: three-letter App Store territory codes, upper-cased.
    public static func territories(_ arguments: [String]) throws -> [String] {
        var out: [String] = []
        for word in arguments.flatMap({ $0.split(separator: ",") }) {
            let code = word.trimmingCharacters(in: .whitespaces).uppercased()
            guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw IdentifierInputError("\(word) is not a territory: three letters, e.g. USA or FRA")
            }
            if !out.contains(code) { out.append(code) }
        }
        return out
    }

    /// A response's text: trimmed, not empty, at most `maxResponseLength` characters.
    public static func response(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IdentifierInputError("the response is empty") }
        guard trimmed.count <= maxResponseLength else {
            throw IdentifierInputError("the response has \(trimmed.count) characters; App Store Connect takes at most \(maxResponseLength)")
        }
        return trimmed
    }

    /// A review's ID (from `xless reviews list`): letters, digits and dashes.
    public static func isReviewID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 128 && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }
}

/// The customer review operations, on the App Store Connect API key.
public struct ASCCustomerReviews: Sendable {
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    /// The app's reviews (at most `maxItems`; nil = every one), each with its response in `included`.
    public func list(app appID: String, filter: ReviewFilter = ReviewFilter(), maxItems: Int? = nil) async throws -> ASCListing<ASCCustomerReview> {
        try await resources.list("/v1/apps/\(appID)/customerReviews", query: filter.query, as: ASCCustomerReview.self, maxItems: maxItems)
    }

    /// One review and its response, when it has one.
    public func get(id: String) async throws -> (review: ASCCustomerReview, response: ASCReviewResponse?) {
        let single = try await resources.get("/v1/customerReviews/\(id)", query: ASCQuery(include: ["response"]), as: ASCCustomerReview.self)
        return (single.data, Self.response(of: single.data, in: single.included))
    }

    /// The response of `review` among a read's `included` resources.
    public static func response(of review: ASCCustomerReview, in included: [ASCAnyResource]) -> ASCReviewResponse? {
        guard let id = review.responseID,
              let resource = included.first(where: { $0.type == "customerReviewResponses" && $0.id == id }) else { return nil }
        return ASCReviewResponse(resource: resource)
    }

    /// Creates the review's response, or replaces the one it has (App Store Connect keeps one per review). Sent once,
    /// never retried.
    public func respond(to reviewID: String, text: String) async throws -> ASCReviewResponse {
        let created: ASCSingle<ASCReviewResponse> = try await resources.create(
            "/v1/customerReviewResponses", type: "customerReviewResponses", attributes: ["responseBody": text],
            relationships: ["review": ASCToOne(ASCRef(type: "customerReviews", id: reviewID))])
        return created.data
    }

    /// Deletes a response: the review shows none on the App Store any more.
    public func deleteResponse(id: String) async throws {
        try await resources.delete("/v1/customerReviewResponses/\(id)")
    }
}
