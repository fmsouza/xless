import Foundation
import Testing

// One App Store Connect path, one place that calls it (fmsouza/xless#184). The test reads Sources/: every string literal
// (comments left out) that is a path of Apple's, with the string constants of its type put in, what is added to it with `+`
// or joined with `[…].joined(separator: "/")` put together, and what else is in it written `{}`. A path belongs to one file,
// the service of its resource; the services' path constants and `ASCClient` itself are not used around them (the second is
// the compiler's to see to). What differs on purpose is listed below, each with its reason; an entry nothing needs any more
// fails the test too.
//
// It reads text, so it finds what is written by accident, not a path hidden on purpose: one put together over several
// statements (`path += …`), by a function or with another separator is not found.

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

/// Files outside XlessASC that send a request without a service (`ASCDirectRequests`): file → why.
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

    /// The Swift files under `root`, named by their path from there, whichever way `root` is written (a checkout below a
    /// symlink: /tmp, /var or /private/tmp on macOS).
    static func files(_ root: URL = root) throws -> [(name: String, text: String)] {
        let found = try #require(FileManager.default.enumerator(atPath: root.path))
        return try found.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted()
            .map { ($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
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

    /// Reads `code` around its literals: what is added to one, what a list joins.
    struct Parts {
        let code: [Character]
        let literals: [Scan.Literal]
        /// The value of a literal or a named string constant, and "{}" for any other expression.
        let value: (Scan.Literal) -> String
        let constant: (String) -> String?
        private let starts: [Int: Scan.Literal]

        init(_ scan: Scan, value: @escaping (Scan.Literal) -> String, constant: @escaping (String) -> String?) {
            code = scan.code; literals = scan.literals; self.value = value; self.constant = constant
            starts = Dictionary(scan.literals.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        }

        private func skipSpace(_ i: Int) -> Int {
            var i = i
            while i < code.count, code[i].isWhitespace { i += 1 }
            return i
        }

        /// The operand at `i` (a literal, or a name with its members, calls and subscripts): its value and where it ends.
        private func operand(_ start: Int) -> (text: String, end: Int)? {
            if let l = starts[start] { return (value(l), l.end) }
            var i = start, depth = 0
            while i < code.count {
                if let l = starts[i] { i = l.end; continue }
                let c = code[i]
                if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { if depth == 0 { break }; depth -= 1 }
                else if depth == 0, !(c.isLetter || c.isNumber || "_.?!".contains(c)) { break }
                i += 1
            }
            guard i > start else { return nil }
            return (constant(String(code[start..<i])) ?? "{}", i)
        }

        /// `a + b + …` from the operand at `start`: the text put together and where it ends.
        func sum(_ start: Int) -> (text: String, end: Int)? {
            guard var (text, end) = operand(start) else { return nil }
            while true {
                let plus = skipSpace(end)
                guard plus < code.count, code[plus] == "+", plus + 1 < code.count, code[plus + 1] != "=" , let next = operand(skipSpace(plus + 1)) else { return (text, end) }
                text += next.text; end = next.end
            }
        }

        /// Where the sum that the literal at `start` is part of begins.
        func sumStart(_ start: Int) -> Int {
            var start = start
            while true {
                var i = start - 1
                while i >= 0, code[i].isWhitespace { i -= 1 }
                guard i >= 0, code[i] == "+" else { return start }
                i -= 1
                while i >= 0, code[i].isWhitespace { i -= 1 }
                if let l = literals.first(where: { $0.end == i + 1 }) { start = l.start; continue }
                var j = i, depth = 0
                while j >= 0 {
                    let c = code[j]
                    if c == ")" || c == "]" { depth += 1 } else if c == "(" || c == "[" { if depth == 0 { break }; depth -= 1 }
                    else if depth == 0, !(c.isLetter || c.isNumber || "_.?!".contains(c)) { break }
                    j -= 1
                }
                guard j < i else { return start }
                start = j + 1
            }
        }

        /// `[a, b, …].joined(separator: "/")` with the literal at `start` as its first element: the text and the list's bounds.
        func joined(firstAt start: Int) -> (text: String, start: Int, end: Int)? {
            var i = start - 1
            while i >= 0, code[i].isWhitespace { i -= 1 }
            guard i >= 0, code[i] == "[" else { return nil }
            let open = i
            var parts: [String] = [], at = start
            while let part = sum(at) {
                parts.append(part.text)
                let next = skipSpace(part.end)
                guard next < code.count else { return nil }
                if code[next] == "," { at = skipSpace(next + 1); if at < code.count, code[at] == "]" { i = at; break }; continue }
                guard code[next] == "]" else { return nil }
                i = next
                break
            }
            guard i > open else { return nil }
            let rest = String(code[(i + 1)..<min(code.count, i + 41)])
            guard let m = rest.prefixMatch(of: /\s*\.joined\(\s*separator:\s*"\/"\s*\)/) else { return nil }
            return (parts.joined(separator: "/"), open, i + 1 + rest.distance(from: rest.startIndex, to: m.range.upperBound))
        }
    }

    static func read(_ files: [(name: String, text: String)]) -> SourcePaths {
        var out = SourcePaths()
        let scans = files.map { Scan($0.text) }, codes = scans.map { String($0.code) }
        // Every string constant, by its type, for the files that name another's: `Parts.base`.
        var all: [String: String] = [:]
        let types = codes.map { code in code.matches(of: /(?:struct|enum|class|actor|extension) +(\w+)/).map { (at: $0.range.lowerBound, name: String($0.1)) } }
        let strings = codes.map { code in code.matches(of: /let +(\w+)(?: *: *String)? *= *"([^"\\\n]+)" *(?=\n|;|\/)/).map { (at: $0.range.lowerBound, name: String($0.1), value: String($0.2)) } }
        for (file, found) in strings.enumerated() {
            for s in found { if let type = types[file].last(where: { $0.at < s.at }) { all["\(type.name).\(s.name)"] = s.value } }
        }
        for (file, name) in files.map(\.name).enumerated() {
            let scan = scans[file], code = codes[file]
            // The string constants of the file (name → value), and of those the ones that are paths.
            let named = Dictionary(strings[file].map { ($0.name, $0.value) }, uniquingKeysWith: { _, b in b })
            let constants = named.filter { isPath($0.value) }
            for s in strings[file] where isPath(s.value) {
                if let type = types[file].last(where: { $0.at < s.at }) { out.constants["\(type.name).\(s.name)"] = name }
            }
            func constant(_ expression: String) -> String? {
                let expression = expression.trimmingCharacters(in: .whitespaces)
                guard expression.wholeMatch(of: /\w+(\.\w+)*/) != nil else { return nil }
                if let other = all[expression] { return other }
                let members = expression.split(separator: ".")
                guard members.count == 1 || members.count == 2 && (members[0] == "Self" || members[0] == "self") else { return nil }
                return named[String(members[members.count - 1])]
            }
            /// Apple's hosts left out, so that a whole URL is the same path.
            func local(_ path: String) -> String {
                for host in ["https://api.appstoreconnect.apple.com", "https://appstoreconnect.apple.com", "https://developer.apple.com/services-account/"]
                where path.hasPrefix(host) { return String(path.dropFirst(host.count)) }
                return path
            }
            func path(_ text: String) -> String { String(local(text).split(separator: "?", maxSplits: 1)[safe: 0] ?? "") }
            func value(_ l: Scan.Literal) -> String {
                var parts = l.text.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
                var text = parts.removeFirst()
                for (expression, rest) in zip(l.interpolations, parts) { text += ((text.isEmpty ? constant(expression) : nil) ?? "{}") + rest }
                return text
            }
            let parts = Parts(scan, value: value, constant: constant)
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
            func add(_ text: String, from start: Int, to end: Int) {
                let path = path(text)
                guard isPath(path) else { return }
                let call = call(before: start)
                out.uses.append(Use(file: name, line: line(start), call: call, path: path + relationship(call, after: end)))
            }
            // Each sum once, from where it begins; a literal on its own is one of one operand.
            var sums = Set<Int>()
            for l in scan.literals {
                let start = parts.sumStart(l.start)
                guard sums.insert(start).inserted else { continue }
                if let sum = parts.sum(start) { add(sum.text, from: start, to: sum.end) }
                if let list = parts.joined(firstAt: start) { add(list.text, from: list.start, to: list.end) }
            }
            // A constant passed as it is: `resources.list(Self.path, …)`.
            for (constant, path) in constants {
                for m in code.matches(of: try! Regex("(?:Self|[A-Z]\\w*)\\.\(constant)(?!\\w)")) {
                    let offset = code.distance(from: code.startIndex, to: m.range.lowerBound)
                    let end = code.distance(from: code.startIndex, to: m.range.upperBound)
                    if scan.literals.contains(where: { $0.start < offset && offset < $0.end }) || sums.contains(offset) { continue }
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
        if Set(left.map(\.file)).count > 1 {
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

/// Outside XlessASC a path reaches Apple through a service. The compiler sees to it that nothing there calls `ASCClient`
/// (its calls, and `ASCResources.client`, are internal); what sends without a service names `ASCDirectRequests`.
@Test func onlyTheServicesCallTheClient() throws {
    var needed = Set<String>()
    for (name, text) in try SourcePaths.files() where !name.hasPrefix("XlessASC/") {
        guard String(SourcePaths.Scan(text).code).contains(/\bASCDirectRequests\b/) else { continue }
        if clientCallers[name] != nil { needed.insert(name) } else { Issue.record("\(name) sends without a service") }
    }
    #expect(needed == Set(clientCallers.keys), "an exception nothing needs any more")
    // Nothing the compiler keeps inside the module is made public again.
    let own = try SourcePaths.files().filter { $0.name.hasPrefix("XlessASC/") }
    for (name, text) in own {
        let code = String(SourcePaths.Scan(text).code)
        #expect(!code.contains(/public +(let|var) +client\b/), "\(name)")
        guard name == "XlessASC/ASCClient.swift" else { continue }
        let client = try #require(code.range(of: "public struct ASCClient"))
        let body = code[client.lowerBound...].prefix { _ in true }
        let end = body.range(of: "\n}\n")?.upperBound ?? body.endIndex
        #expect(!body[..<end].contains(/public +(?:static +)?func/))
    }
}

/// A checkout below a symlink, named either way (`/private/tmp` is `/tmp` on macOS), gives the same names.
@Test func theFilesAreNamedFromTheRootInACheckoutBelowASymlink() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xless-owners-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("a/Sources"), link = base.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real.appendingPathComponent("M"), withIntermediateDirectories: true)
    try Data("let x = 1".utf8).write(to: real.appendingPathComponent("M/A.swift"))
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
    let physical = try #require(realpath(real.path, nil).map { p in defer { free(p) }; return String(cString: p) })
    for root in [real, link.appendingPathComponent("Sources"), URL(fileURLWithPath: physical)] {
        #expect(try SourcePaths.files(root).map(\.name) == ["M/A.swift"], "\(root.path)")
    }
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

/// A path put together from parts is found as if it were written out.
@Test func theScanFindsAPathInParts() {
    let source = ##"""
    public struct Parts {
        static let base = "/v1"
        static let name = "/v1/" + "constants"
        func a() { try await resources.get("/v1/builds/" + id, as: X.self) }
        func b() { try await resources.get("/v1" + "/bundleIds", as: X.self) }
        func c() { try await resources.delete("\(Self.base)/profiles") }
        func d() { try await resources.delete(["", "v1", "certificates"].joined(separator: "/")) }
        func e() { try await resources.delete(["/v1", "devices", id(1, 2)].joined(separator: "/")) }
        func f() { try await resources.delete(Self.base + "/apps/" + f(id) + "/relationships/x") }
        func g() { try await resources.delete(
            base
                + "/users") }
        func h() { print("a" + "/v1", "b") }
    }
    """##
    let other = ##"func o() { try await resources.delete("\(Parts.base)/territories"); x(Parts.base + "/betaGroups") }"##
    let found = SourcePaths.read([("A.swift", source), ("B.swift", other)])
    #expect(Set(found.uses.map { "\($0.file) \($0.call) \($0.path)" }) == [
        "A.swift  /v1/constants", "A.swift get /v1/builds/{}", "A.swift get /v1/bundleIds", "A.swift delete /v1/profiles",
        "A.swift delete /v1/certificates", "A.swift delete /v1/devices/{}", "A.swift delete /v1/apps/{}/relationships/x", "A.swift delete /v1/users",
        "B.swift delete /v1/territories", "B.swift  /v1/betaGroups",
    ])
}
