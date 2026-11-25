import Foundation
import Testing

// One App Store Connect path, one place that calls it (fmsouza/xless#184). The test reads Sources/: every string literal
// (comments left out) that is a path of Apple's, with the path constants of its file put in and what is interpolated
// written `{}`. A path belongs to one file, the service of its resource; the services' path constants and `ASCClient`
// itself are not used around them. What differs on purpose is listed below, each with its reason; an entry nothing needs
// any more fails the test too.

/// A second file that has a path on purpose: `file path` → why.
private let exceptions: [String: String] = [
    "XlessStore/StorePlan.swift /v1/{}": "store push's plan holds the create it will send, of any resource type (the owner is AssetUploader, which reserves a file of any type)",
    "XlessStore/StorePlan.swift /v1/{}/{}": "store push's plan holds the updates and deletes it will send, of any resource type",
    "XlessStore/StoreSender.swift /v1/{}/{}": "deletes the items of a screenshot or preview set, whose type the plan has",
    "XlessStore/StoreSender.swift /v1/{}": "compares a planned request's path, to adopt a version text App Store Connect made itself",
    "XlessStore/StorePushProducts.swift /v2/inAppPurchases/{}": "store push's plan holds the update it will send (InAppPurchases reads the product)",
    "xless/LiveCheck.swift /olympus/v1/session": "the live check lets this one sign-in POST through its read-only transport; it sends nothing itself",
    "XlessAppleID/SignInModels.swift /olympus/v1/session": "the sign-in asks for it once before it has a session, and so before there is an ASCWebClient",
    "xless/LiveCheck.swift v1/bundleIds": "the label of a check; the portal's service sends the request",
]

/// Called from several files today, to be made one: the list only gets shorter.
private let pending: Set<String> = [
    "/v1/betaBuildLocalizations", "/v1/betaBuildLocalizations/{}",
    "/v1/betaGroups", "/v1/betaGroups/{}", "/v1/builds/{}/betaBuildLocalizations",
]
private let pendingCallers: Set<String> = []

/// Files outside XlessASC that send through `ASCClient` themselves: file → why.
private let clientCallers: [String: String] = [
    "XlessStore/StoreSender.swift": "sends the requests of store push's plan as the plan showed them, whatever their resource type",
    "xless/Commands/APICommand.swift": "xless api sends the path the person typed",
    "xless/Commands/StoreCommands.swift": "downloads a media file from Apple's delivery network: no App Store Connect path",
]

struct SourcePaths {
    struct Use: Hashable {
        var file: String
        var line: Int
        /// The call the path is the first argument of (`list`, `create`, `request GET`); "" when it is not one.
        var call: String
        var path: String
    }

    var uses: [Use] = []
    /// `Type.constant` of every path constant → its file.
    var constants: [String: String] = [:]

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func files() throws -> [(name: String, text: String)] {
        let base = root.resolvingSymlinksInPath().path + "/"
        let found = try #require(FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: nil))
        return try found.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
            .map { (String($0.path.dropFirst(base.count)), try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// The text with comments blanked (newlines kept) and the string literals found, in order.
    struct Scan {
        struct Literal { var start: Int; var end: Int; var text: String; var interpolations: [String] }
        var code: [Character]
        var literals: [Literal] = []

        init(_ source: String) {
            code = Array(source)
            var i = 0
            scan(&i, until: nil)
        }

        /// Scans code from `i`; `until` is the closing parenthesis of an interpolation.
        private mutating func scan(_ i: inout Int, until close: Character?) {
            var depth = 0
            while i < code.count {
                let c = code[i]
                if c == "/", i + 1 < code.count, code[i + 1] == "/" {
                    while i < code.count, code[i] != "\n" { code[i] = " "; i += 1 }
                } else if c == "/", i + 1 < code.count, code[i + 1] == "*" {
                    while i < code.count, !(code[i] == "*" && i + 1 < code.count && code[i + 1] == "/") { if code[i] != "\n" { code[i] = " " }; i += 1 }
                    for _ in 0..<2 where i < code.count { code[i] = " "; i += 1 }
                } else if c == "\"" || (c == "#" && isRawString(at: i)) {
                    literal(&i)
                } else if c == "(", close != nil {
                    depth += 1; i += 1
                } else if let close, c == close {
                    if depth == 0 { return }
                    depth -= 1; i += 1
                } else {
                    i += 1
                }
            }
        }

        private func isRawString(at i: Int) -> Bool {
            var j = i
            while j < code.count, code[j] == "#" { j += 1 }
            return j < code.count && code[j] == "\""
        }

        private mutating func literal(_ i: inout Int) {
            let start = i
            var hashes = 0
            while code[i] == "#" { hashes += 1; i += 1 }
            let multi = i + 2 < code.count && code[i + 1] == "\"" && code[i + 2] == "\""
            i += multi ? 3 : 1
            var text = "", interpolations: [String] = []
            while i < code.count {
                let closing = Array(repeating: Character("\""), count: multi ? 3 : 1) + Array(repeating: Character("#"), count: hashes)
                if i + closing.count <= code.count, Array(code[i..<(i + closing.count)]) == closing { i += closing.count; break }
                if !multi, code[i] == "\n" { break }
                if code[i] == "\\", i + hashes < code.count, code[(i + 1)..<(i + 1 + hashes)].allSatisfy({ $0 == "#" }) {
                    i += 1 + hashes
                    guard i < code.count else { break }
                    if code[i] == "(" {
                        i += 1
                        let from = i
                        scan(&i, until: ")")
                        interpolations.append(String(code[from..<min(i, code.count)]))
                        text += "\u{1}"
                        i += 1
                    } else {
                        text.append(code[i]); i += 1
                    }
                } else {
                    text.append(code[i]); i += 1
                }
            }
            literals.append(Literal(start: start, end: i, text: text, interpolations: interpolations))
        }
    }

    /// Whether `text` is a path of App Store Connect's API, its web session or the developer portal.
    static func isPath(_ text: String) -> Bool {
        text.wholeMatch(of: /(\/v[0-9]+\/|\/iris\/v1\/|\/olympus\/v1\/|QH65B2\/|v1\/(bundleIds|cloudContainers)).+|v1\/(bundleIds|cloudContainers)/) != nil
            && !text.contains(" ")
    }

    static func read(_ files: [(name: String, text: String)]) -> SourcePaths {
        var out = SourcePaths()
        for (name, text) in files {
            let scan = Scan(text)
            let code = String(scan.code)
            // The path constants of the file: name → value.
            var constants: [String: String] = [:]
            let types = code.matches(of: /(?:struct|enum|class|actor|extension) +(\w+)/).map { (at: $0.range.lowerBound, name: String($0.1)) }
            for m in code.matches(of: /let +(\w+) *= *"([^"\\\n]+)"/) where isPath(String(m.2)) {
                constants[String(m.1)] = String(m.2)
                if let type = types.last(where: { $0.at < m.range.lowerBound }) { out.constants["\(type.name).\(m.1)"] = name }
            }
            /// Apple's hosts left out, so that a whole URL is the same path.
            func local(_ path: String) -> String {
                for host in ["https://api.appstoreconnect.apple.com", "https://appstoreconnect.apple.com", "https://developer.apple.com/services-account/"]
                where path.hasPrefix(host) { return String(path.dropFirst(host.count)) }
                return path
            }
            func resolved(_ l: Scan.Literal) -> String {
                var parts = l.text.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
                var path = parts.removeFirst()
                for (expression, rest) in zip(l.interpolations, parts) {
                    let constant = constants[expression.trimmingCharacters(in: .whitespaces).split(separator: ".").last.map(String.init) ?? ""]
                    path += (path.isEmpty ? constant : nil) ?? "{}"
                    path += rest
                }
                return String(local(path).split(separator: "?", maxSplits: 1)[safe: 0] ?? "")
            }
            func line(_ offset: Int) -> Int { scan.code[..<offset].count { $0 == "\n" } + 1 }
            /// The call the text at `offset` is the (first, or after a method) argument of.
            func call(before offset: Int) -> String {
                let before = String(scan.code[max(0, offset - 60)..<offset])
                if let m = before.firstMatch(of: /\.(\w+)\(\s*"([A-Z]+)",\s*$/) { return "\(m.1) \(m.2)" }
                if let m = before.firstMatch(of: /\.(\w+)\(\s*$/) { return String(m.1) }
                return ""
            }
            /// `, "name"` after the first argument of a relationship call.
            func relationship(_ call: String, after offset: Int) -> String {
                guard call.lowercased().hasSuffix("relationship") else { return "" }
                let after = String(scan.code[offset..<min(scan.code.count, offset + 60)])
                return after.firstMatch(of: /^,\s*"(\w+)"/).map { "/relationships/\($0.1)" } ?? ""
            }
            for l in scan.literals {
                let path = resolved(l)
                guard isPath(path) else { continue }
                let call = call(before: l.start)
                out.uses.append(Use(file: name, line: line(l.start), call: call, path: path + relationship(call, after: l.end)))
            }
            // A constant passed as it is: `resources.list(Self.path, …)`.
            for (constant, path) in constants {
                for m in code.matches(of: try! Regex("(?:Self|[A-Z]\\w*)\\.\(constant)(?!\\w)")) {
                    let offset = code.distance(from: code.startIndex, to: m.range.lowerBound)
                    let end = code.distance(from: code.startIndex, to: m.range.upperBound)
                    if scan.literals.contains(where: { $0.start < offset && offset < $0.end }) { continue }
                    let call = call(before: offset)
                    guard !call.isEmpty else { continue }
                    out.uses.append(Use(file: name, line: line(offset), call: call, path: path + relationship(call, after: end)))
                }
            }
        }
        return out
    }
}

extension Collection {
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}

@Test func eachAppStoreConnectPathIsCalledFromOnePlace() throws {
    let files = try SourcePaths.files()
    #expect(files.count > 200)
    let paths = SourcePaths.read(files)
    #expect(Set(paths.uses.map(\.path)).count > 100, "the paths were not found")

    var needed = Set<String>()
    for (path, uses) in Dictionary(grouping: paths.uses, by: \.path).sorted(by: { $0.key < $1.key }) where Set(uses.map(\.file)).count > 1 {
        needed.formUnion(uses.map { "\($0.file) \(path)" }.filter { exceptions[$0] != nil })
        let left = uses.filter { exceptions["\($0.file) \(path)"] == nil }
        if Set(left.map(\.file)).count > 1, !pending.contains(path) {
            Issue.record("\(path) is called from several files: \(Set(left.map { "\($0.file):\($0.line)" }).sorted().joined(separator: ", "))")
        }
    }
    for unused in Set(exceptions.keys).subtracting(needed).sorted() { Issue.record("nothing needs the exception \(unused) any more; remove it") }
}

/// A service's path constant is the service's own: another file that uses it calls the path too.
@Test func noFileUsesThePathConstantOfAnother() throws {
    let files = try SourcePaths.files()
    let paths = SourcePaths.read(files)
    #expect(paths.constants.count > 5)
    for (name, text) in files {
        let code = String(SourcePaths.Scan(text).code)
        for (constant, owner) in paths.constants.sorted(by: { $0.key < $1.key }) where owner != name && code.contains(constant) {
            Issue.record("\(name) uses \(constant), which \(owner) owns")
        }
    }
}

/// Outside XlessASC a path reaches Apple through a service: nothing calls `ASCClient` itself.
@Test func onlyTheServicesCallTheClient() throws {
    var needed = Set<String>()
    for (name, text) in try SourcePaths.files() where !name.hasPrefix("XlessASC/") && !name.hasPrefix("XlessAppleID/") {
        let code = String(SourcePaths.Scan(text).code)
        guard code.contains(/[cC]lient\.(get|post|postOnce|patch|delete|request|download)\(/) else { continue }
        if pendingCallers.contains(name) { continue }
        if clientCallers[name] != nil { needed.insert(name) } else { Issue.record("\(name) calls ASCClient itself") }
    }
    #expect(needed == Set(clientCallers.keys), "an exception nothing needs any more")
}

/// The scan finds what it is meant to find.
@Test func theScanFindsPathsConstantsAndRelationships() {
    let source = ##"""
    /// GET "/v1/commented"
    public struct Things {
        static let path = "/v1/things"
        let help = "see /v1/things"
        func a() { try await resources.list(Self.path, as: X.self) }   // "/v1/alsoCommented"
        func b() { try await resources.get("\(Self.path)/\(try f("x"))?a=b", as: X.self) }
        func c() { try await resources.addRelationship("\(Things.path)/\(id)", "others", []) }
        func d() { try await client.request("POST", "/v1/others/\(id)", body: nil) }
        /* "/v1/blocked" */
        let url = URL(string: "https://appstoreconnect.apple.com/olympus/v1/whole?a=b")!
        let raw = #"/v2/raw/\#(id)"#
    }
    """##
    let found = SourcePaths.read([("A.swift", source)])
    #expect(found.constants == ["Things.path": "A.swift"])
    #expect(Set(found.uses.map { "\($0.call) \($0.path)" }) == [
        " /v1/things", "list /v1/things", "get /v1/things/{}", "addRelationship /v1/things/{}/relationships/others", "request POST /v1/others/{}", " /v2/raw/{}",
        " /olympus/v1/whole",
    ])
}
