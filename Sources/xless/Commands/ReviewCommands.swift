import ArgumentParser
import Foundation
import XlessASC
import XlessCore

// `xless reviews`: customer reviews of an app and the responses to them (docs/apple-account.md#xless-reviews).

struct ReviewsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reviews",
        abstract: "List an app's customer reviews, and respond to them or delete a response.",
        discussion: """
        Uses the App Store Connect API key (/v1/apps/{id}/customerReviews, /v1/customerReviewResponses), which needs the \
        Customer Support role (or App Manager, Admin): `xless auth api-key create --role CUSTOMER_SUPPORT`. A review is \
        named by its ID, from `list`.

          xless reviews list --app com.example.app --rating 1,2 --unanswered
          xless reviews respond 00000057-9d5b-1a03-6a2f-c33b00000000 --text "Thanks! Fixed in 1.2."
          xless reviews delete-response 00000057-9d5b-1a03-6a2f-c33b00000000
        """,
        subcommands: [ReviewsListCommand.self, ReviewsRespondCommand.self, ReviewsDeleteResponseCommand.self])
}

/// The review argument: an ID from `xless reviews list`.
struct ReviewArgument: ParsableArguments {
    @Argument(help: ArgumentHelp("The review's ID (see `xless reviews list`).", valueName: "review-id")) var review: String

    func validate() throws {
        guard ReviewInput.isReviewID(review) else { throw ValidationError("\(review) is not a review ID (letters, digits and dashes)") }
    }
}

/// Opens the account session and runs `body` with the review operations; prints what it returns.
private func runReviews(_ account: AccountOptions, _ body: (ReviewCLI) async throws -> String) async throws {
    try await AccountSession.run {
        let session = try AccountSession.open(team: account.team.team, verbose: account.trace.verbose)
        let out = try await body(ReviewCLI(resources: session.resources, json: account.output.json))
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct ReviewsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List an app's customer reviews, newest first, each with its response.")

    @OptionGroup var app: ProductAppOption
    @Option(name: .customLong("rating"), help: ArgumentHelp("Only these star ratings (1 to 5); repeatable or comma-separated.", valueName: "stars"))
    var ratings: [String] = []
    @Option(name: .customLong("territory"), help: ArgumentHelp("Only reviews from this App Store territory (USA, FRA…); repeatable or comma-separated.", valueName: "code"))
    var territories: [String] = []
    @Flag(help: "Only reviews that have a published response.") var answered = false
    @Flag(help: "Only reviews that have no published response.") var unanswered = false
    @Option(help: ArgumentHelp("The order: \(ReviewSort.allCases.map(\.rawValue).joined(separator: ", ")).", valueName: "order"))
    var sort: String = ReviewSort.newest.rawValue
    @Option(help: ArgumentHelp("At most this many reviews.", valueName: "n")) var limit: Int = 100
    @Flag(help: "Every review (no --limit).") var all = false
    @OptionGroup var account: AccountOptions

    func validate() throws {
        do {
            _ = try ReviewInput.ratings(ratings)
            _ = try ReviewInput.territories(territories)
        } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        if answered, unanswered { throw ValidationError("--answered and --unanswered exclude each other") }
        if ReviewSort(rawValue: sort.lowercased()) == nil {
            throw ValidationError("--sort \(sort): one of \(ReviewSort.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if limit < 1 { throw ValidationError("--limit must be at least 1") }
    }

    func run() async throws {
        let filter = ReviewFilter(ratings: try ReviewInput.ratings(ratings), territories: try ReviewInput.territories(territories),
                                  answered: answered ? true : unanswered ? false : nil, sort: ReviewSort(rawValue: sort.lowercased()) ?? .newest)
        try await runReviews(account) { try await $0.list(app: app.app, filter: filter, limit: all ? nil : limit) }
    }
}

struct ReviewsRespondCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respond",
        abstract: "Respond to a review, or replace its response (asks first); the same text again sends nothing.",
        discussion: "The response is public once Apple publishes it (state PENDING_PUBLISH, then PUBLISHED); at most \(ReviewInput.maxResponseLength) characters.")

    @OptionGroup var review: ReviewArgument
    @Option(help: ArgumentHelp("The response.", valueName: "text")) var text: String?
    @Option(help: ArgumentHelp("A UTF-8 text file holding the response.", valueName: "path")) var file: String?
    @OptionGroup var account: AccountOptions

    func validate() throws {
        if (text == nil) == (file == nil) { throw ValidationError("give the response with --text or --file (one of them)") }
        if let text {
            do { _ = try ReviewInput.response(text) } catch let e as IdentifierInputError { throw ValidationError(e.description) }
        }
    }

    func run() async throws {
        try await runReviews(account) { cli in
            let raw = try text ?? TextFile.read(file ?? "", option: "--file")
            let response: String
            do { response = try ReviewInput.response(raw) } catch let e as IdentifierInputError {
                throw XlessError(.account, "--file \(file ?? ""): \(e.description)", fix: "edit the file")
            }
            return try await cli.respond(review.review, text: response, yes: account.confirmation.yes)
        }
    }
}

struct ReviewsDeleteResponseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-response",
        abstract: "Delete the response to a review (asks first).")

    @OptionGroup var review: ReviewArgument
    @OptionGroup var account: AccountOptions

    func run() async throws {
        try await runReviews(account) { try await $0.deleteResponse(review.review, yes: account.confirmation.yes) }
    }
}
