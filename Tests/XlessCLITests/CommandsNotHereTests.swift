import ArgumentParser
import Foundation
import Testing
import XlessAgent
import XlessCore
@testable import xless

/// What an xless on Windows does not do, it says itself: an error of its own with a way out, whatever else is on the line.
#if os(Windows) || XLESS_WINDOWS_TARGETS
private func parsed(_ arguments: [String]) throws -> any ParsableCommand {
    try Xless.parseAsRoot(Array(HoldArguments.withDefaults(["xless"] + arguments).dropFirst()))
}

private func refusal(_ arguments: [String]) throws -> XlessError? {
    var command = try parsed(arguments)
    do { try command.run() } catch { return error as? XlessError }
    return nil
}

@Test(arguments: [
    "ship", "prepare", "build", "assets", "finalize", "sign", "package", "upload", "inspect", "next-build", "sdk", "nib", "storyboard", "shim",
    "tauri", "cargo", "xcode", "setup", "run", "docker", "clean", "live-check", "session", "secrets import-env", "secrets materialize",
])
func aCommandThatWindowsDoesNotHaveSaysSo(name: String) throws {
    let words = name.split(separator: " ").map(String.init)
    for rest in [[], ["some", "thing"], ["--config", "app.yml", "--platform", "ios"], ["--help"], ["--unknown=1", "--", "--x"]] as [[String]] {
        let e = try #require(try refusal(words + rest), "\(words + rest)")
        #expect(e.stage == .config && e.exitCode == Stage.config.exitCode)
        #expect(e.cause.contains("`xless \(name)`") && !e.fix.isEmpty && !e.description.contains("\n"), "\(e.description)")
    }
    // and it is not offered
    let parent = words.dropLast() + []
    let help = parent.isEmpty ? Xless.helpMessage() : Xless.helpMessage(for: SecretsCommand.self)
    #expect(!help.split(separator: "\n").contains { $0.hasPrefix("  \(words.last ?? "") ") }, "\(help)")
}

@Test func nothingIsKeptUnlockedOnWindows() async throws {
    #expect(AgentClient().obstacle != nil)
    #expect(XlessSession.agent == nil)
    for arguments in [["unlock"], ["unlock", "--for", "1h"], ["secrets", "unlock", "--remember"], ["secrets", "init", "--remember"], ["auth", "login", "--keep"],
                      ["auth", "login", "--keep", "--across-reboots"]] as [[String]] {
        var command = try parsed(arguments)
        var said: XlessError?
        do {
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        } catch { said = error as? XlessError }
        let e = try #require(said, "\(arguments)")
        #expect(e.cause.contains("nothing can be kept unlocked on Windows yet") && !e.fix.isEmpty, "\(e.description)")
    }
    // what drops what is held has nothing to drop
    var lock = try Xless.parseAsRoot(["lock"])
    try lock.run()
}

@Test func anOverlayIsRefusedOnWindows() throws {
    for command in [try StorePullCommand.parse(["--config", "o.yml"]).directory, try StorePushCommand.parse(["--config", "o.yml", "--dir", "d"]).directory] {
        let e = #expect(throws: XlessError.self) { _ = try command.project() }
        #expect(e?.stage == .config && e?.cause.contains("overlays") == true && e?.cause.contains("not read on Windows yet") == true, "\(e?.description ?? "")")
    }
    let e = #expect(throws: XlessError.self) { _ = try ReleaseStatusCommand.parse(["--config", "o.yml"]).target.wanted() }
    #expect(e?.cause.contains("overlays") == true)
}
#endif
