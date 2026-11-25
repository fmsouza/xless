import CXlessProcess
import Foundation
import XlessCore
#if os(macOS)
import IOKit
#endif

/// The agent's side of its start (`AgentLauncher.start`).
public enum AgentHost {
    /// Runs the agent when `arguments` are an agent's, and returns its exit status; nil: this is another command.
    public static func runIfAsked(_ arguments: [String]) -> Int32? {
        guard arguments.count == 2, arguments[1] == AgentLauncher.argument else { return nil }
        // No core file, no debugger, nothing of the memory for another process (Linux); and nothing of the login's keyring.
        SecretScope.enter()
        _ = xless_deny_attach()
        KernelKeyring.leaveSession()
        AgentSignals.install()
        guard let channel = bootstrapChannel() else {
            FileHandle.standardError.write(Data("error: xless \(AgentLauncher.argument) is started by xless itself (see `xless unlock`)\n".utf8))
            return 64
        }
        return serve(channel)
    }

    /// The socket pair's end a command started this process with.
    private static func bootstrapChannel() -> AgentChannel? {
        var st = stat()
        guard fstat(AgentLauncher.channel, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        _ = fcntl(AgentLauncher.channel, F_SETFD, FD_CLOEXEC)
        _ = fcntl(AgentLauncher.channel, F_SETFL, O_NONBLOCK)
        return try? AgentChannel(fd: AgentLauncher.channel)
    }

    private static func serve(_ channel: AgentChannel) -> Int32 {
        let server: AgentServer
        do {
            guard let message = try channel.wait(limit: AgentLimits.items * AgentLimits.message, milliseconds: 10_000), message.code == .configure,
                  message.header.version == AgentProtocol.version else { return 64 }
            server = try configure(message)
        } catch {
            var w = WireWriter()
            w.put(AgentRefusal.limit.rawValue)
            w.put((error as? AgentError)?.cause ?? "the xless agent cannot start")
            channel.send(w.frame(code: .refused))
            try? channel.flush()
            return 1
        }
        channel.send(WireWriter().frame(code: .ok))
        try? channel.flush()
        channel.end()
        _ = server.run()
        return 0
    }

    private static func configure(_ message: AgentMessage) throws -> AgentServer {
        let state = AgentState(clock: .system)
        var options = AgentServer.Options()
        let directory = try message.body { r in
            let directory = AgentDirectory(path: try r.string(max: 4096))
            let wanted = try r.int64()
            let session = AgentSession.current
            // It serves the session it is in: anything else would be a session it cannot vouch for.
            guard session.isUsable, Int64(session.id) == wanted else { throw AgentError.limit("a session it is not in") }
            state.grant(session)
            options.lockOnSleep = try r.bool()
            options.lockOnScreenLock = try r.bool()
            for _ in 0..<(try r.uint32()) {
                let name = try r.string(max: AgentLimits.nameBytes), label = try r.string(max: AgentLimits.labelBytes)
                let hold = AgentHold(seconds: try r.int(), idle: try r.int(), maximum: try r.int())
                let secret = try r.secret(max: AgentLimits.itemBytes)
                defer { secret.wipe() }
                try state.put(name, label: label, secret, hold: hold, typed: true)
            }
            return directory
        }
        #if os(macOS)
        options.executable = AgentExecutable.current
        #endif
        options.screenIsLocked = ScreenLock.isLocked
        return AgentServer(bound: try directory.bind(), directory: directory, state: state, clock: .system, options: options)
    }
}

/// Whether the screen is locked, where the system says so without a dependency.
enum ScreenLock {
    static func isLocked() -> Bool {
        #if os(macOS)
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
        #else
        // On Linux it takes the session bus; `xless lock` can be run by the screen locker (docs/security.md).
        return false
        #endif
    }
}
