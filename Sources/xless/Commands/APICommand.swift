import ArgumentParser
import Foundation
import XlessASC
import XlessCore

struct APICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Call any documented App Store Connect API endpoint with your API key and print the JSON it returns.",
        discussion: """
        Like `gh api`, for api.appstoreconnect.apple.com only (no other host is ever sent the key). The key is ASC_KEY_ID, \
        ASC_ISSUER_ID and ASC_KEY_P8 (or *_FILE), else the secret store's ASC_KEY_P8 entry.

          xless api GET /v1/apps --paginate
          xless api GET /v1/apps -f 'filter[bundleId]=com.example.app' --include appInfos
          xless api PATCH /v1/apps/123 --input body.json

        -f adds query parameters, for every method; a body comes only from --input. A method other than GET asks first \
        (or needs --yes); a POST is sent once and never retried. Failures print `[account] cause — fix` and exit 20.
        """)

    @Argument(help: "GET, POST, PATCH or DELETE.")
    var method: String

    @Argument(help: "A path such as /v1/apps (a ?query may follow), or a full https://api.appstoreconnect.apple.com/... URL such as a links.next.")
    var path: String

    @Option(name: [.customShort("f"), .customLong("field")],
            help: ArgumentHelp("A query parameter (repeatable), e.g. filter[bundleId]=com.example.app, fields[apps]=name, limit=10.", valueName: "name=value"))
    var fields: [String] = []

    @Option(help: ArgumentHelp("A JSON request body from this file, or - for standard input (POST, PATCH, DELETE).", valueName: "file"))
    var input: String?

    @Flag(help: "GET only: follow links.next and print every page's data (and included) as one document.")
    var paginate = false

    @Option(help: ArgumentHelp("Related resources to include (comma-separated or repeated): adds include=....", valueName: "relationship"))
    var include: [String] = []

    @OptionGroup var team: TeamOption
    @OptionGroup var confirmation: YesOption
    @OptionGroup var trace: VerboseOption

    func validate() throws {
        _ = try APIRequest(method: method, path: path, fields: fields, include: include, body: input == nil ? nil : Data("{}".utf8), paginate: paginate)
    }

    func run() async throws {
        let body = try input.map(Self.readBody)
        let request = try APIRequest(method: method, path: path, fields: fields, include: include, body: body, paginate: paginate)
        try await AccountSession.run {
            let session = try AccountSession.open(team: team.team, verbose: trace.verbose)
            let out = try await APICall(resources: session.resources).run(request, yes: confirmation.yes)
            FileHandle.standardOutput.write(Data(out.utf8))
        }
    }

    /// The body: a file, or standard input for `-`; it must be JSON.
    static func readBody(_ input: String) throws -> Data {
        let data: Data
        if input == "-" { data = FileHandle.standardInput.readDataToEndOfFile() } else {
            guard let d = FileManager.default.contents(atPath: input) else {
                throw XlessError(.account, "cannot read \(input)", fix: "check the path given to --input")
            }
            data = d
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw XlessError(.account, "the body given to --input is not JSON", fix: "pass a JSON:API document such as {\"data\": {\"type\": …, \"attributes\": {…}}}")
        }
        return data
    }
}

/// A validated `xless api` request: the method, a documented path on api.appstoreconnect.apple.com, its query and body.
struct APIRequest {
    static let host = "api.appstoreconnect.apple.com"
    static let methods = ["GET", "POST", "PATCH", "DELETE"]

    let method: String
    let path: String
    let query: [(String, String)]
    let body: Data?
    let paginate: Bool

    init(method: String, path: String, fields: [String] = [], include: [String] = [], body: Data? = nil, paginate: Bool = false) throws {
        let method = method.uppercased()
        guard Self.methods.contains(method) else { throw ValidationError("\(method): use GET, POST, PATCH or DELETE") }
        let (p, q) = try Self.split(path)
        var query = q
        for field in fields {
            guard let eq = field.firstIndex(of: "="), eq != field.startIndex else {
                throw ValidationError("-f \(field): use name=value, e.g. filter[bundleId]=com.example.app")
            }
            query.append((String(field[..<eq]), String(field[field.index(after: eq)...])))
        }
        let included = include.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !included.isEmpty { query.append(("include", included.joined(separator: ","))) }
        if body != nil, method == "GET" { throw ValidationError("--input: a GET has no body") }
        if paginate, method != "GET" { throw ValidationError("--paginate follows the pages of a GET listing") }
        self.method = method; self.path = p; self.query = query; self.body = body; self.paginate = paginate
    }

    /// The path and query of `/v1/…[?…]` or `https://api.appstoreconnect.apple.com/v1/…[?…]`. Anything that could reach
    /// another host, or climb out of the versioned API (`..`), is refused.
    static func split(_ text: String) throws -> (String, [(String, String)]) {
        let refused = ValidationError("\(text): give a path such as /v1/apps, or a URL on https://\(host)/")
        var full: String
        if text.hasPrefix("/") {
            guard !text.hasPrefix("//") else { throw refused }
            full = "https://\(host)\(text)"
        } else if text.lowercased().hasPrefix("https://") {
            let rest = text.dropFirst("https://".count)
            let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard authority.lowercased() == host else { throw refused }
            full = "https://\(host)" + rest.dropFirst(authority.count)
        } else if text.first == "v", text.dropFirst().first?.isNumber == true {
            full = "https://\(host)/\(text)"
        } else {
            throw refused
        }
        if let hash = full.firstIndex(of: "#") { full = String(full[..<hash]) }
        guard let (path, query) = ASCPaging.parseLink(full) else { throw refused }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        guard let version = segments.first, version.count > 1, version.first == "v", version.dropFirst().allSatisfy { $0.isNumber }, segments.count > 1,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { throw refused }
        return (path, query)
    }
}

/// Sends an `APIRequest` and renders what came back.
struct APICall {
    let resources: ASCResources

    /// The text to print: the response's JSON (keys sorted), the merged pages with `--paginate`, nothing for an empty
    /// body or a declined confirmation (which says so on standard error).
    func run(_ request: APIRequest, yes: Bool, terminal: () -> (any Confirming)? = { try? TerminalPrompter.forAccount() },
             say: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) async throws -> String {
        if request.method != "GET" {
            let what = "\(request.method) \(request.path)"
            guard try AccountConfirm.confirm("Send \(what) to App Store Connect?", action: "sending \(what)", yes: yes, terminal: terminal) else {
                say("cancelled; nothing was sent")
                return ""
            }
        }
        if request.paginate {
            let listing = try await resources.list(request.path, query: ASCQuery(extra: request.query), as: JSONValue.self)
            var document: [String: JSONValue] = ["data": .array(listing.items)]
            if !listing.included.isEmpty { document["included"] = try JSONValue.array(listing.included.map { try $0.jsonValue() }) }
            return try ASCOutput.json(JSONValue.object(document))
        }
        let response = try await ASCDirectRequests(resources: resources).request(request.method, request.path, query: request.query, body: request.body,
                                                                                 maxAttempts: request.method == "POST" ? 1 : ASCClient.maxAttempts)
        guard !response.data.isEmpty else { return "" }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: response.data) else {
            return String(decoding: response.data, as: UTF8.self) + "\n"
        }
        return try ASCOutput.json(json)
    }
}

extension ASCAnyResource {
    func jsonValue() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self)) }
}
