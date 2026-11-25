import Yams

/// `provisioningUpdates: false` (xless.yml or an overlay): `sign` changes nothing on the account
/// (docs/signing-and-testflight.md#what-sign-changes-on-the-account).
public enum ProvisioningUpdates {
    public static let key = "provisioningUpdates"

    /// Refuses what reads like the restriction and would be dropped without a word: the key without a value, anywhere but at
    /// the top level, or misspelt (xless.yml and some overlays ignore the keys they do not know). A key about something else,
    /// or a name of the person's own, is left alone; YAML that cannot be read is left to the config's own error.
    public static func check(yaml: String, file: String) throws {
        guard let top = try? Yams.compose(yaml: yaml) else { return }
        try check(top, path: "", named: false, file: file)
    }

    /// The maps whose keys are the person's own names (variables, targets, scripts, identifiers), not the schema's.
    private static let named: Set<String> = ["env", "plistVars", "scripts", "bundleIDs", "replace"]

    private static func check(_ node: Node, path: String, named: Bool, file: String) throws {
        if let items = node.sequence {
            for (i, item) in items.enumerated() { try check(item, path: "\(path)[\(i)]", named: named, file: file) }
        }
        for (name, value) in node.mapping.map(Array.init) ?? [] {
            guard let name = name.string else { try check(value, path: "\(path).?", named: named, file: file); continue }
            let at = TerminalText.escaped(path.isEmpty ? name : "\(path).\(name)")
            if name == key, path.isEmpty {
                if value.null != nil { throw XlessError(.config, "\(file): \(key) has no value", fix: "write it as \(key): false") }
            } else if named {
                // Whatever it is called, it is not one of xless's keys.
            } else if name == key {
                throw XlessError(.config, "\(file): \(at) is not read", fix: "write it at the top level, as \(key): false, or remove it")
            } else if reads(name, value) {
                throw XlessError(.config, "\(file): unknown key '\(at)'",
                                 fix: "if `sign` must change nothing on the account, write it as \(key): false; else remove it")
            }
            try check(value, path: path.isEmpty ? name : "\(path).\(name)", named: named || self.named.contains(name), file: file)
        }
    }

    /// Whether `name` can only be meant as the key: whatever its case and separators, with letters missing, doubled or swapped.
    /// A word of it (`provisioningProfile`, `updates`) is not enough; `provisioning` alone is when it says yes or no.
    private static func reads(_ name: String, _ value: Node) -> Bool {
        let text = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if text.contains("provis"), text.contains("updat") { return true }
        return ["", "no", "allow"].contains { prefix in
            text == prefix + "provupdates" || ["provisioningupdates", "provisionupdates"].contains { distance(text, prefix + $0) <= 2 }
                || value.bool != nil && ["provisioning", "provision"].contains { text == prefix + $0 }
        }
    }

    /// The edits (a letter put in, left out or replaced) between two words.
    private static func distance(_ a: String, _ b: String) -> Int {
        let b = Array(b)
        var row = Array(0...b.count)
        for (i, x) in a.prefix(64).enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let next = min(row[j] + 1, row[j + 1] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = row[j + 1]
                row[j + 1] = next
            }
        }
        return row[b.count]
    }
}
