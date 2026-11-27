/// The docker context of every xless command that talks to docker (`xless setup --docker`, `xless run --docker`, `xless clean`,
/// `xless sdk export`, and a native setup's check of a pack in use), decided here alone: `DOCKER_CONTEXT` when it is set, else
/// `colima-xless` when docker has that context, else docker's current one (no `--context`). A `DOCKER_CONTEXT` that docker does
/// not have stops the command before it does anything (`Problem`, exit 2), with where it was set and the contexts there are.
/// scripts/docker-context.sh is the same rule for the scripts; docs/maintainers.md says it for both.
public enum DockerContext {
    /// The context a setup of Colima for xless makes, preferred when nothing names one.
    public static let preferred = "colima-xless"
    public static let variable = "DOCKER_CONTEXT"
    /// What `Setting.source` is when the environment set it.
    public static let environmentSource = "the environment"
    /// docker's words that list its contexts, one name per line. They are run without `DOCKER_CONTEXT`: docker lists the context
    /// that variable names as one of its own even when it does not exist.
    public static let listing = ["context", "ls", "--format", "{{.Name}}"]

    /// A `DOCKER_CONTEXT` that is set, and where: the environment, or a file of settings (its path).
    public struct Setting: Equatable, Sendable {
        public var name: String
        public var source: String
        public init(name: String, source: String) { self.name = name; self.source = source }
    }

    public struct Problem: Error, Equatable, Sendable {
        public let cause: String
        public let fix: String
        public init(cause: String, fix: String) { self.cause = cause; self.fix = fix }
    }

    /// The setting: `file`'s `DOCKER_CONTEXT` when the file sets it (the file of `xless run`, whose values win over the
    /// environment's), else the environment's. Empty is unset, as for docker.
    public static func setting(environment: [String: String], file: (path: String, value: String?)?) -> Setting? {
        if let file, let value = file.value { return value.isEmpty ? nil : Setting(name: value, source: file.path) }
        guard let value = environment[variable], !value.isEmpty else { return nil }
        return Setting(name: value, source: environmentSource)
    }

    /// The names of a listing; nil when it names none (docker always has `default`: it did not answer).
    public static func listed(_ output: String) -> [String]? {
        let names = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// The context, nil for docker's current one. `contexts`: those docker has; nil when it could not list them, and then a set
    /// one is used as it is (docker's own error says the rest).
    public static func choose(_ setting: Setting?, contexts: [String]?) throws(Problem) -> String? {
        guard let setting else { return contexts?.contains(preferred) == true ? preferred : nil }
        guard let contexts, !contexts.contains(setting.name) else { return setting.name }
        throw Problem(cause: "\(variable) is \(setting.name) (set in \(setting.source)), but docker has no context of that name; its contexts: \(contexts.joined(separator: ", "))",
                      fix: "set \(variable) to one of them in \(setting.source), or remove it there: xless then uses \(preferred) when that context exists, else docker's current one")
    }

    /// docker's words for the context.
    public static func arguments(_ name: String?) -> [String] { name.map { ["--context", $0] } ?? [] }
}
