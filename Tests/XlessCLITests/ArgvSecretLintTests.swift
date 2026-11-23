import ArgumentParser
import Foundation
import Testing
import XlessCore
@testable import xless

/// Secrets never come from argv (every user sees it in `ps` and /proc/<pid>/cmdline, and it lands in shell history):
/// no option or argument of any xless command may be named like one. Account commands (M7) take secrets from the
/// terminal, the environment, a file or the secret store instead. The rule: `SecretEnvironment.argumentLooksSecret`.
@Test func noCommandTakesASecretOnTheCommandLine() throws {
    let tree = try #require(try JSONSerialization.jsonObject(with: Data(Xless._dumpHelp().utf8)) as? [String: Any])
    let root = try #require(tree["command"] as? [String: Any])
    var offenders: [String] = []
    var commands = 0
    func walk(_ command: [String: Any], path: [String]) {
        commands += 1
        let path = path + [command["commandName"] as? String ?? "?"]
        for argument in command["arguments"] as? [[String: Any]] ?? [] {
            let names = (argument["names"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                + [argument["valueName"] as? String].compactMap { $0 }
            for name in names where SecretEnvironment.argumentLooksSecret(name) {
                offenders.append("\(path.joined(separator: " ")): \(name)")
            }
        }
        for sub in command["subcommands"] as? [[String: Any]] ?? [] { walk(sub, path: path) }
    }
    walk(root, path: [])
    #expect(commands > 20, "the command tree was not walked")
    #expect(offenders.isEmpty, "options or arguments named like a secret: \(offenders)")
}

/// The lint would catch one: a command with a secret-like option fails it.
@Test func theLintCatchesASecretOption() throws {
    struct Leaky: ParsableCommand {
        @Option var apiKey: String
        @Argument var password: String
    }
    let json = try #require(try JSONSerialization.jsonObject(with: Data(Leaky._dumpHelp().utf8)) as? [String: Any])
    let arguments = try #require((json["command"] as? [String: Any])?["arguments"] as? [[String: Any]])
    let names = arguments.flatMap { ($0["names"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } + [$0["valueName"] as? String].compactMap { $0 } }
    let flagged = Set(names.filter(SecretEnvironment.argumentLooksSecret))
    #expect(flagged.contains("api-key"))
    #expect(flagged.contains("password"))
}

/// scripts/testflight.sh runs the native build step (the app's build code) without any secret variable: its list is
/// `SecretEnvironment.entries`, every name of which it unsets with its `_FILE` form (fmsouza/xless#102).
@Test func theBuildStepOfTestflightShUnsetsEverySecretVariable() throws {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/testflight.sh")
    let text = try String(contentsOf: script, encoding: .utf8)
    let line = try #require(text.split(separator: "\n").first { $0.contains("scrub=(env); for v in ") })
    let listed = Set(line.split(separator: ";")[1].split(separator: " ").dropFirst(3).map(String.init))
    #expect(listed == Set(SecretEnvironment.entries.map(\.name)))
    #expect(line.contains(#"scrub+=(-u "$v" -u "${v}_FILE")"#))
    #expect(text.contains("scrub+=(XLESS_NO_SECRET_STORE=1)"))
}
