import Foundation
import XlessCore
import XlessXcode

/// The build settings of one target and configuration as the build sees them, for the few settings xless reads
/// itself (`CODE_SIGN_ENTITLEMENTS`, the setting references in an entitlements file). Lookup order is Swift Build's,
/// highest first: `overrides` (the build's command-line and per-target values), the target, the target's xcconfig,
/// the project, the project's xcconfig, then the build's own values (`SRCROOT`, `TARGET_NAME`, …). Conditional
/// settings (`KEY[sdk=…]`) and `$(inherited)` are not evaluated: a key that needs them is refused.
struct TargetSettings {
    let project: XcodeProject
    let target: Target
    let configuration: String
    let overrides: [String: String]
    /// Highest first. An xcconfig is read when a lookup reaches it (the Pods ones exist only after `pod install`).
    private let levels: [Level]

    enum Level {
        case table([String: String])
        case xcconfig(fileRefID: String)
    }

    /// `platform`: `iphoneos` or `iphonesimulator` (`PLATFORM_NAME`, `SDK_NAME`, `EFFECTIVE_PLATFORM_NAME`).
    init(project: XcodeProject, target: Target, configuration: String, platform: String = "iphoneos", overrides: [String: String]) throws {
        self.project = project; self.target = target; self.configuration = configuration; self.overrides = overrides
        let tc = target.configurations.first { $0.name == configuration }
        let pc = project.configurations.first { $0.name == configuration }
        guard let tc else {
            throw XlessError(.build, "target \(target.name) has no build configuration \(configuration)",
                             fix: "set configuration: in the overlay to one of \(target.configurations.map(\.name).joined(separator: ", "))")
        }
        var levels: [Level] = [.table(overrides), .table(tc.settings)]
        if let base = tc.baseConfigurationID { levels.append(.xcconfig(fileRefID: base)) }
        if let pc { levels.append(.table(pc.settings)) }
        if let base = pc?.baseConfigurationID { levels.append(.xcconfig(fileRefID: base)) }
        let dir = project.directory.path
        levels.append(.table([
            "SRCROOT": dir, "PROJECT_DIR": dir, "SOURCE_ROOT": dir, "PROJECT_NAME": project.name, "TARGET_NAME": target.name,
            "PRODUCT_NAME": "$(TARGET_NAME)", "CONFIGURATION": configuration, "PLATFORM_NAME": platform, "SDK_NAME": platform,
            "EFFECTIVE_PLATFORM_NAME": "-\(platform)",
        ]))
        self.levels = levels
    }

    /// The unexpanded value; nil when no level sets it.
    func raw(_ key: String) throws -> String? {
        for entry in levels {
            let level: [String: String]
            switch entry {
            case .table(let t): level = t
            case .xcconfig(let id): level = try Self.xcconfig(project, id)
            }
            if level.keys.contains(where: { $0.hasPrefix(key + "[") }) {
                throw XlessError(.build, "\(target.name) sets \(key) per SDK or architecture (\(key)[…]), which xless does not evaluate",
                                 fix: "set \(key) without a condition for the configuration the overlay builds")
            }
            if let v = level[key] {
                if v.contains("$(inherited)") || v.contains("${inherited}") {
                    throw XlessError(.build, "\(target.name)'s \(key) uses $(inherited), which xless does not evaluate for this setting",
                                     fix: "set \(key) to a complete value in the target")
                }
                return v
            }
        }
        return nil
    }

    /// The settings of every level, highest first (the xcconfigs read), for `environment`.
    private func tables() throws -> [[String: String]] {
        try levels.map { entry in
            switch entry {
            case .table(let t): t
            case .xcconfig(let id): try Self.xcconfig(project, id)
            }
        }
    }

    /// `key` as Swift Build evaluates it for a script phase: each level's `$(inherited)` is the value of the levels below
    /// it, then every reference is expanded the same way; a reference no level defines (or with a modifier such as
    /// `:rfc1034identifier`) becomes "", as in Xcode. nil when no level sets `key`. Conditional settings are refused.
    func evaluated(_ key: String) throws -> String? {
        try evaluated(key, tables: try tables(), depth: 0)
    }

    private func evaluated(_ key: String, tables: [[String: String]], depth: Int) throws -> String? {
        guard depth < 16 else {
            throw XlessError(.prepare, "build setting \(key) of \(target.name) nests too deeply (a cycle?)", fix: "check the settings it uses")
        }
        var result: String? = nil
        for level in tables.reversed() {
            if level.keys.contains(where: { $0.hasPrefix(key + "[") }) {
                throw XlessError(.prepare, "\(target.name) sets \(key) per SDK or architecture (\(key)[…]), which xless does not evaluate",
                                 fix: "set \(key) without a condition for the configuration the overlay builds")
            }
            guard let v = level[key] else { continue }
            let below = result ?? ""
            result = v.replacingOccurrences(of: "$(inherited)", with: below).replacingOccurrences(of: "${inherited}", with: below)
        }
        guard let result else { return nil }
        var out = "", rest = result[...]
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            guard let open = after.first, open == "(" || open == "{",
                  let close = after.firstIndex(of: open == "(" ? ")" : "}") else {
                out.append("$"); rest = after; continue
            }
            let name = String(after[after.index(after: after.startIndex)..<close])
            rest = after[after.index(after: close)...]
            if name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil, let v = try evaluated(name, tables: tables, depth: depth + 1) { out += v }
        }
        return (out + rest).trimmingCharacters(in: .whitespaces)
    }

    /// Every setting any level defines, evaluated (`evaluated`), as a script phase's environment.
    func environment() throws -> [String: String] {
        let tables = try tables()
        var out: [String: String] = [:]
        for key in Set(tables.flatMap(\.keys)) where !key.contains("[") {
            out[key] = try evaluated(key, tables: tables, depth: 0)
        }
        return out
    }

    /// `value` with every `$(NAME)` / `${NAME}` replaced by the setting's expanded value (recursively). `keep` names
    /// references left as they are; a reference no level defines is refused (Xcode would expand it to "").
    func expand(_ value: String, keep: Set<String> = [], context: String) throws -> String {
        try expand(value, keep: keep, context: context, depth: 0)
    }

    private func expand(_ value: String, keep: Set<String>, context: String, depth: Int) throws -> String {
        guard depth < 16 else {
            throw XlessError(.build, "build setting references in \(context) nest too deeply (a cycle?)", fix: "check the settings it uses")
        }
        var out = "", rest = value[...]
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            guard let open = after.first, open == "(" || open == "{",
                  let close = after.firstIndex(of: open == "(" ? ")" : "}") else {
                out.append("$"); rest = after; continue
            }
            let name = String(after[after.index(after: after.startIndex)..<close])
            rest = after[after.index(after: close)...]
            if keep.contains(name) { out += "$\(open)\(name)\(open == "(" ? ")" : "}")"; continue }
            guard name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil, let v = try raw(name) else {
                throw XlessError(.build, "\(context) uses $(\(name)), which is not a build setting of \(target.name) xless can evaluate",
                                 fix: "set \(name) in the target, or write the value literally")
            }
            out += try expand(v, keep: keep, context: context, depth: depth + 1)
        }
        return out + rest
    }

    /// The `KEY = value` assignments of an xcconfig (and the files it `#include`s, which it overrides), by file
    /// reference in `project`.
    static func xcconfig(_ project: XcodeProject, _ fileRefID: String) throws -> [String: String] {
        guard let url = project.resolvedPath(of: fileRefID) else {
            throw XlessError(.build, "cannot locate the xcconfig \(fileRefID) of \(project.name)", fix: "regenerate the project (expo prebuild, pod install)")
        }
        return try xcconfig(url, depth: 0)
    }

    static func xcconfig(_ url: URL, depth: Int) throws -> [String: String] {
        guard depth < 8, let text = (try? PlainFile.read(url, followsLinks: true)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw XlessError(.build, "cannot read the xcconfig \(url.path)", fix: "run xless prepare (pod install writes the Pods xcconfigs)")
        }
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#include") {
                let optional = l.hasPrefix("#include?")
                guard let q1 = l.firstIndex(of: "\""), let q2 = l[l.index(after: q1)...].firstIndex(of: "\"") else { continue }
                let rel = String(l[l.index(after: q1)..<q2])
                let inc = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : url.deletingLastPathComponent().appendingPathComponent(rel)
                if optional, !FileManager.default.fileExists(atPath: inc.path) { continue }
                out.merge(try xcconfig(inc, depth: depth + 1)) { _, new in new }
                continue
            }
            if let c = l.range(of: "//") { l = String(l[..<c.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let key = l[..<eq].trimmingCharacters(in: .whitespaces)
            var value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
