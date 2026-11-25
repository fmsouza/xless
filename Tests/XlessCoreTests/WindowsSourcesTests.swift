import Foundation
import Testing

/// Tests/windows/sources.txt: every source file of the targets that Windows builds is said to be built there (`+`) or not (`-`), and the
/// manifest leaves out exactly the latter. A new file is in neither by accident.
private struct WindowsSources {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let built: Set<String>
    let left: Set<String>

    init() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Tests/windows/sources.txt"), encoding: .utf8)
        var found: [Character: [String]] = ["+": [], "-": []]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let mark = line.first!
            found[mark, default: []].append(String(line.dropFirst(2)))
        }
        #expect(Set(found.keys) == ["+", "-"], "a line is `+ <path>`, `- <path>` or a comment")
        let all = found["+"]! + found["-"]!
        #expect(all.count == Set(all).count, "a file is listed once")
        #expect(text.hasSuffix("\n"))
        built = Set(found["+"]!)
        left = Set(found["-"]!)
    }

    /// The manifest's part about Windows.
    static func manifest() throws -> Substring {
        let text = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "#if os(Windows) || XLESS_WINDOWS_TARGETS\n"))
        return text[start.upperBound...]
    }

    /// Target → its files that the manifest leaves out.
    static func excluded() throws -> [String: Set<String>] {
        let part = try manifest()
        let list = try #require(part.firstMatch(of: /let notOnWindows: \[String: \[String\]\] = \[\n((?s:.*?))\n\]\n/)).1
        var out: [String: Set<String>] = [:]
        for target in list.matches(of: /"(\w+)": \[((?s:.*?))\]/) {
            out[String(target.1)] = Set(target.2.matches(of: /"([^"]+)"/).map { String($0.1) })
        }
        return out
    }

    static func targets() throws -> [String] {
        let list = try #require(try manifest().firstMatch(of: /let windowsTargets: Set<String> = \[\n((?s:.*?))\n\]\n/)).1
        return list.matches(of: /"(\w+)"/).map { String($0.1) }.filter { $0 != "CXlessProcess" }
    }

    static func directory(_ target: String) -> String { target.hasSuffix("Tests") ? "Tests/\(target)" : "Sources/\(target)" }

    static func files(_ target: String) throws -> [String] {
        let dir = directory(target)
        let names = try #require(FileManager.default.enumerator(atPath: root.appendingPathComponent(dir).path))
        return names.compactMap { ($0 as? String)?.replacingOccurrences(of: "\\", with: "/") }.filter { $0.hasSuffix(".swift") }.map { "\(dir)/\($0)" }
    }
}

@Test func everySourceFileOfAWindowsTargetIsListed() throws {
    let sources = try WindowsSources()
    let targets = try WindowsSources.targets()
    #expect(targets.count == 17)
    let there = Set(try targets.flatMap(WindowsSources.files))
    let listed = sources.built.union(sources.left)
    #expect(there.subtracting(listed).sorted() == [], "say in Tests/windows/sources.txt whether Windows builds these (`+`) or not (`-`, and in Package.swift's notOnWindows)")
    #expect(listed.subtracting(there).sorted() == [], "these are gone")
}

@Test func theManifestLeavesOutWhatTheListLeavesOut() throws {
    let sources = try WindowsSources()
    var excluded: Set<String> = []
    for (target, files) in try WindowsSources.excluded() { excluded.formUnion(files.map { "\(WindowsSources.directory(target))/\($0)" }) }
    #expect(excluded.subtracting(sources.left).sorted() == [])
    #expect(sources.left.subtracting(excluded).sorted() == [])
    // and nothing else of the manifest leaves a file out
    #expect(try WindowsSources.manifest().matches(of: /exclude|sources:/).count == 1)
}
