import Foundation
import XlessASC
import XlessCore

/// What the review commands do once their arguments are valid; returns what goes to standard output and says the rest
/// (cancellations) on standard error.
struct ReviewCLI {
    let reviews: ASCCustomerReviews
    let apps: ASCApps
    var json = false
    var terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() }
    var say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    init(resources: ASCResources, json: Bool = false, terminal: @escaping () -> (any Confirming)? = { try? TerminalPrompter.forAccount() },
         say: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) {
        reviews = ASCCustomerReviews(resources: resources); apps = ASCApps(resources: resources)
        self.json = json; self.terminal = terminal; self.say = say
    }

    struct Listing: Encodable { var data: [ASCCustomerReview]; var included: [ASCAnyResource] }

    func list(app argument: String, filter: ReviewFilter, limit: Int?) async throws -> String {
        let app = try await apps.resolve(argument)
        let listing = try await reviews.list(app: app.id, filter: filter, maxItems: limit)
        if json { return try ASCOutput.json(Listing(data: listing.items, included: listing.included)) }
        guard !listing.items.isEmpty else { return "No review of \(app.bundleID) matches.\n" }
        var text = listing.items.map { review in
            Self.block(review, response: ASCCustomerReviews.response(of: review, in: listing.included))
        }.joined(separator: "\n")
        if let limit, listing.items.count == limit { text += "\n(the first \(limit); --limit or --all for more)\n" }
        return text
    }

    /// One review as text: a header line, the title and body indented, then the response.
    static func block(_ review: ASCCustomerReview, response: ASCReviewResponse?) -> String {
        let date = String((review.attributes.createdDate ?? "").prefix(10))
        var lines = ["\(review.id)  \(review.stars)  \(review.attributes.territory ?? "-")  \(date)  by \(review.attributes.reviewerNickname ?? "-")"]
        if !review.title.isEmpty { lines.append("  \(review.title)") }
        lines += review.body.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }
        if let response {
            let when = String((response.attributes.lastModifiedDate ?? "").prefix(10))
            lines.append("  ↳ response \(response.id) (\(response.state)\(when.isEmpty ? "" : ", \(when)")):")
            lines += response.text.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct ResponseReport: Encodable {
        /// `created`, `replaced` or `unchanged`.
        var result: String
        var data: ASCReviewResponse
    }

    func respond(_ reviewID: String, text: String, yes: Bool) async throws -> String {
        let (review, existing) = try await reviews.get(id: reviewID)
        if let existing {
            if existing.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                if json { return try ASCOutput.json(ResponseReport(result: "unchanged", data: existing)) }
                return "review \(review.id) already has this response (\(existing.state)); nothing was sent\n"
            }
            let question = "Replace the response to review \(review.id) (\(review.stars), \"\(review.title)\")? It says now: \"\(Self.excerpt(existing.text))\""
            guard try AccountConfirm.confirm(question, action: "replacing the response to review \(review.id)", yes: yes, terminal: terminal) else {
                say("cancelled; nothing was sent")
                return ""
            }
        }
        let response = try await reviews.respond(to: review.id, text: text)
        if json { return try ASCOutput.json(ResponseReport(result: existing == nil ? "created" : "replaced", data: response)) }
        let verb = existing == nil ? "responded to" : "replaced the response to"
        return "\(verb) review \(review.id) (\(review.stars)): response \(response.id), \(response.state.isEmpty ? "sent" : response.state); Apple shows it on the App Store once published\n"
    }

    func deleteResponse(_ reviewID: String, yes: Bool) async throws -> String {
        let (review, existing) = try await reviews.get(id: reviewID)
        guard let existing else {
            if json { return try ASCOutput.json(["deleted": ASCReviewResponse?.none]) }
            return "review \(review.id) has no response; nothing was sent\n"
        }
        let question = "Delete the response to review \(review.id) (\(review.stars), \"\(review.title)\")? It says: \"\(Self.excerpt(existing.text))\""
        guard try AccountConfirm.confirm(question, action: "deleting the response to review \(review.id)", yes: yes, terminal: terminal) else {
            say("cancelled; nothing was sent")
            return ""
        }
        try await reviews.deleteResponse(id: existing.id)
        if json { return try ASCOutput.json(["deleted": existing]) }
        return "deleted response \(existing.id) to review \(review.id)\n"
    }

    /// The first 80 characters of a text, on one line.
    static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= 80 ? line : String(line.prefix(79)) + "…"
    }
}
