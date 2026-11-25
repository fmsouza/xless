import Foundation

/// What the build in the sandbox (`BuildSandbox`) has of this Mac, beside its own directories: variables by name, and the tools on
/// PATH where they are in a home directory.
public enum BuildPlaces {
    /// Variables that the build gets as they are; no other of the user's is there (a token that is exported is not, for one). The
    /// images get none of them either, but for what `docker` itself passes on.
    static let variables: Set<String> = [
        "PATH", "LANG", "LANGUAGE", "TERM", "COLORTERM", "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "CI", "TZ", "USER", "LOGNAME", "SHELL", "SOURCE_DATE_EPOCH",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE", "CARGO_HTTP_CAINFO", "GIT_SSL_CAINFO",
        "XLESS_RN_CLEAN", "XLESS_SHARE",
    ]

    /// The build's environment: those variables, and a home and a directory for temporary files of its own.
    public static func environment(_ base: [String: String], home: String, temporary: String) -> [String: String] {
        var out = base.filter { variables.contains($0.key) || $0.key.hasPrefix("LC_") }
        out["PATH"] = searchPath(base).joined(separator: ":")
        if out["LANG"] == nil, out["LC_ALL"] == nil { out["LANG"] = "en_US.UTF-8" } // (CocoaPods asks for UTF-8)
        out["HOME"] = home
        out["CFFIXED_USER_HOME"] = home // what Foundation takes for it
        out["TMPDIR"] = temporary
        out["GIT_TERMINAL_PROMPT"] = "0"
        out["GIT_CONFIG_NOSYSTEM"] = "1" // (Xcode's asks the keychain)
        return out
    }

    static func searchPath(_ env: [String: String]) -> [String] {
        (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    /// The version managers of tools in a home directory: the variable that says where they are, the directory below the home that it
    /// is without it, and what of that the tools are.
    private static let managers: [(variable: String, directory: String, parts: [String])] = [
        ("RUSTUP_HOME", ".rustup", ["toolchains", "settings.toml", "update-hashes"]),
        ("RBENV_ROOT", ".rbenv", ["bin", "shims", "libexec", "versions", "version", "plugins", "completions", "rbenv.d"]),
        ("PYENV_ROOT", ".pyenv", ["bin", "shims", "libexec", "versions", "version", "plugins", "pyenv.d"]),
        ("NODENV_ROOT", ".nodenv", ["bin", "shims", "libexec", "versions", "version", "plugins", "nodenv.d"]),
        ("ASDF_DATA_DIR", ".asdf", ["bin", "shims", "lib", "libexec", "installs", "plugins", "completions"]),
        ("MISE_DATA_DIR", ".local/share/mise", ["shims", "installs", "plugins"]),
        ("VOLTA_HOME", ".volta", ["bin", "tools", "hooks.json"]),
        ("PROTO_HOME", ".proto", ["bin", "shims", "tools", "plugins"]),
    ]

    /// Beside a `bin`, what the tools in it need.
    private static let beside = ["bin", "sbin", "lib", "libexec", "include", "share", "Frameworks", "Cellar", "opt", "etc"]

    /// The tools that a build of these kinds starts by name.
    private static let tools = ["node", "npm", "npx", "corepack", "pnpm", "yarn", "bun", "ruby", "gem", "bundle", "bundler", "pod", "rustup", "cargo", "rustc", "git", "python3", "cmake", "ninja", "watchman"]

    /// What the sandbox is to open for the tools of `env`, of what is closed, and the variables that tell the version managers where
    /// they are, now that the home is another one.
    public static func tools(_ env: [String: String], home: String, closed: [String]) -> (reads: [String], variables: [String: String]) {
        let fm = FileManager.default, home = BuildSandbox.real(home)
        var reads: [String] = [], variables: [String: String] = [:]
        func add(_ path: String) {
            let real = BuildSandbox.real(path)
            guard fm.fileExists(atPath: real), closed.contains(where: { BuildSandbox.isBelow(real, $0) }), !isBroad(real, home: home), !reads.contains(real) else { return }
            reads.append(real)
        }
        /// A directory that programs are in, with what they need beside it.
        func addPrograms(_ directory: String) {
            add(directory)
            let url = URL(fileURLWithPath: BuildSandbox.real(directory))
            guard url.lastPathComponent == "bin" else { return }
            let parent = url.deletingLastPathComponent().path
            if BuildSandbox.isBelow(home, parent) { return } // ~/bin: what is beside it is the user's
            for name in beside where !(name == "share" && parent == home + "/.local") { add("\(parent)/\(name)") }
        }
        for manager in managers {
            let directory = env[manager.variable].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/\(manager.directory)"
            guard fm.fileExists(atPath: directory) else { continue }
            variables[manager.variable] = directory
            for part in manager.parts { add("\(directory)/\(part)") }
        }
        let path = searchPath(env)
        for directory in path { addPrograms(directory) }
        for tool in tools {
            guard let found = path.map({ "\($0)/\(tool)" }).first(where: { fm.isExecutableFile(atPath: $0) }) else { continue }
            addPrograms(URL(fileURLWithPath: BuildSandbox.real(found)).deletingLastPathComponent().path)
        }
        for name in ["SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE", "CARGO_HTTP_CAINFO", "GIT_SSL_CAINFO"] {
            if let file = env[name], file.hasPrefix("/") { add(file) }
        }
        return (reads, variables)
    }

    /// Whether opening `path` would open a home directory, or more.
    public static func isBroad(_ path: String, home: String) -> Bool {
        BuildSandbox.isBelow(BuildSandbox.real(home), path) || BuildSandbox.privatePlaces.contains { BuildSandbox.isBelow($0, path) }
            || ["/Users", "/Volumes"].contains { BuildSandbox.isBelow(path, $0) && BuildSandbox.names(path).count == 2 }
    }

    /// What is never opened, wherever it is: xless's own and the usual places of keys, and the files that secret variables name.
    public static func secrets(_ env: [String: String], home: String) -> [String] {
        func base(_ variable: String, _ directory: String) -> String { env[variable].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "\(home)/\(directory)" }
        let own = ["\(base("XDG_CONFIG_HOME", ".config"))/xless", "\(base("XDG_DATA_HOME", ".local/share"))/xless", "\(base("XDG_CACHE_HOME", ".cache"))/xless/secrets"]
            + (env["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? ["\($0)/xless", "\($0)/xless-agent"] : nil } ?? [])
            + (BuildSandbox.userTemporaryDirectory.map { ["\($0)/xless-agent"] } ?? [])
        let keys = [".ssh", ".gnupg", ".aws", ".netrc", ".git-credentials", ".npmrc", ".docker", ".kube", ".config/gh", ".cargo/credentials", ".cargo/credentials.toml",
                    ".gem/credentials", "Library/Keychains"].map { "\(home)/\($0)" }
        let files = (SecretEnvironment.scrubbed.filter { $0.hasSuffix("_FILE") } + ["XLESS_TESTFLIGHT_ENV"]).compactMap { env[$0] }.filter { $0.hasPrefix("/") }
        return own + keys + files
    }
}
