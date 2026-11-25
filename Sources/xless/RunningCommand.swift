import ArgumentParser
import Foundation
import XlessCore

/// The command this process runs, as what it asks is announced: `xless certs create`.
enum RunningCommand {
    nonisolated(unsafe) private static var running = "xless"
    private static let lock = NSLock()

    static var name: String { lock.withLock { running } }

    static func set(_ command: any ParsableCommand.Type) { set(path(of: command)) }

    static func set(_ name: String) { lock.withLock { running = name } }

    /// Its names, from the root's.
    static func path(of command: any ParsableCommand.Type) -> String {
        func find(_ parent: any ParsableCommand.Type, _ path: [String]) -> [String]? {
            let here = path + [parent.configuration.commandName ?? ""]
            if parent == command { return here }
            for child in parent.configuration.subcommands { if let found = find(child, here) { return found } }
            return nil
        }
        return find(Xless.self, [])?.joined(separator: " ") ?? "xless"
    }
}

/// `xless session -- <command…>`, as the commands inside see it.
enum XlessSession {
    /// The path of the session's agent.
    static let variable = ChildProcess.session

    /// The session this command was told of.
    nonisolated(unsafe) private(set) static var agent: String?

    /// Takes it out of this process's environment, which whatever it starts is given (the shims' tools too): what is to
    /// have it is given it (`SessionCommand`, `ProjectRun`).
    static func take() {
        let path = ProcessInfo.processInfo.environment[variable] ?? ""
        agent = path.isEmpty ? nil : path
        unsetenv(variable)
    }
}
