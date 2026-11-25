import Foundation
import XlessCore
import XlessMachO

public enum RCodesign {
    /// `arguments` (a subcommand and its own), without a configuration file. By itself rcodesign reads `rcodesign.toml` of the directory
    /// it runs in, and the user's: they can name another signer, other entitlements or another API key than its arguments do, and a
    /// project's directory is one the build can write. (rcodesign 0.29.0 `--help`: "The special value `/dev/null` can be used to
    /// specify an empty/null config file".)
    public static func arguments(_ arguments: [String]) -> [String] {
        arguments.prefix(1) + ["-C", "/dev/null"] + arguments.dropFirst()
    }

    /// Which one is run.
    final class Choice: @unchecked Sendable {
        private let lock = NSLock()
        private var chosen = "rcodesign" // of PATH: a Linux install's, and an image's
        var program: String { lock.withLock { chosen } }
        func use(_ program: URL) { lock.withLock { chosen = program.path } }
    }

    private static let choice = Choice()

    public static var program: String { choice.program }

    /// From here on this one is run, whatever PATH says (on a Mac).
    public static func use(_ program: URL) { choice.use(program) }

    /// Runs it, in a directory that no build can write.
    @discardableResult
    public static func run(_ arguments: [String], program: String = RCodesign.program, stage: Stage, captureTo: URL? = nil) throws -> ShellResult {
        try Shell.run(program, self.arguments(arguments), cwd: URL(fileURLWithPath: "/"), stage: stage, captureTo: captureTo)
    }

    /// `runtimePaths` (Developer ID only): bundle-relative Mach-Os (`hardenedRuntimePaths`) that get the hardened runtime
    /// too. rcodesign signs loose Mach-Os (e.g. a dylib in Contents/Resources) and nested bundles, but an unscoped
    /// `--code-signature-flags` applies to the main executable only, so each one is named with a path-scoped flag.
    ///
    /// `nestedEntitlements`: bundle-relative nested bundles (`PlugIns/X.appex`) signed with their own entitlements. An
    /// rcodesign setting scoped to a nested bundle's path (`<path>:<file>`) applies to that bundle only, and the unscoped
    /// one to the main bundle only (rcodesign 0.29.0 `sign --help`, "Settings Scope"). rcodesign signs nested bundles
    /// before the bundle that contains them, so one invocation signs each extension, then the app.
    public static func signArguments(bundle: URL, keyPEM: URL, certPEM: URL, entitlements: URL, distribution: Distribution,
                                     runtimePaths: [String] = [], nestedEntitlements: [(path: String, file: URL)] = []) -> [String] {
        var a = ["sign", "--pem-file", keyPEM.path, "--pem-file", certPEM.path, "--entitlements-xml-file", entitlements.path]
        for nested in nestedEntitlements { a += ["--entitlements-xml-file", "\(nested.path):\(nested.file.path)"] }
        switch distribution {
        case .appStore:
            a += ["--timestamp-url", "none"]   // ITMS-90135: App Store builds must not carry a secure timestamp
        case .developerID:
            a += ["--code-signature-flags", "runtime", "--for-notarization"]
            for path in runtimePaths { a += ["--code-signature-flags", "\(path):runtime"] }
        }
        return a + [bundle.path]
    }

    /// What gets a path-scoped `runtime` flag for Developer ID: every Mach-O image in the bundle (regular files, by their
    /// real path) except the main executable. That covers loose Mach-Os and the binaries of nested bundles. A bundle scope
    /// is not enough: rcodesign signs a versioned framework's `Versions/A` as its own nested bundle, so
    /// `X.framework:runtime` does not reach `Versions/A/X`, while the binary's own path does. Sorted. One that rcodesign would read otherwise is refused.
    public static func hardenedRuntimePaths(in app: URL, mainExecutable: String) throws -> [String] {
        let root = app.standardizedFileURL.path
        let paths = Files.regularFiles(under: app).filter(isImage)
            .map { String(decoding: $0.standardizedFileURL.path.utf8.dropFirst(root.utf8.count + 1), as: UTF8.self) }
            .filter { $0 != mainExecutable }.sorted()
        try requireScopes(paths)
        return paths
    }

    /// rcodesign 0.29.0 ends a scope at the first colon, and reads `<path>@<int>` and `<path>@[cpu_type=…]` as a slice; a word that starts
    /// with a hyphen is an option.
    static func requireScopes(_ paths: [String]) throws {
        for path in paths where path.contains(scalar: ":") || ["-", "@"].contains(path.unicodeScalars.first) || path.firstMatch(of: /@(\+?[0-9]+|\[.*)$/.matchingSemantics(.unicodeScalar)) != nil {
            throw XlessError(.sign, "the path of \(path) is one that rcodesign reads as an option, or as scope syntax", fix: "rename it in the app: no ':' in its path, no '-' or '@' first, no '@<number>' at the end")
        }
    }

    static func isImage(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return (try? MachO.containsLoadableImage(data)) == true
    }

    /// rcodesign 0.29.0 waits 600 s by default (`notary-submit --help`); notarization queues can take longer.
    public static func notarizeArguments(bundle: URL, apiKeyJSON: URL) -> [String] {
        ["notary-submit", "--api-key-file", apiKeyJSON.path, "--max-wait-seconds", "3600", "--staple", bundle.path]
    }

    public static func encodeKeyArguments(issuerID: String, keyID: String, p8: URL, out: URL) -> [String] {
        ["encode-app-store-connect-api-key", "-o", out.path, issuerID, keyID, p8.path]
    }
}
