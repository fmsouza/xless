import Foundation

/// `--no-input` (or XLESS_NO_INPUT=1): nothing is asked for; a command that would ask fails at once, with an exit code
/// of its own (`Stage.input`, 21), so a script never waits for an answer nobody gives.
///
/// The one gate. Whatever asks calls `require` first: the terminal (`TerminalPrompter`, the only opener of /dev/tty that
/// asks anything), the store's unlock (`VaultUnlocker`), a confirmation (`AccountConfirm`). A credential helper, which asks by
/// itself, is started with nothing to ask on (`CredentialHelper`). The variable is inherited, so a run's other
/// processes (scripts/testflight.sh and its xless commands) do not ask either.
public enum InputGate {
    public static let variable = "XLESS_NO_INPUT"
    public static let option = "--no-input"

    /// Instead of the environment's, in tests.
    @TaskLocal static var forced: Bool?

    public static var isOff: Bool { forced ?? !allows(env: ProcessInfo.processInfo.environment) }

    static func allows(env: [String: String]) -> Bool { ["", "0"].contains(env[variable] ?? "") }

    /// Throws when input is off.
    /// - Parameter what: "xless would ask for …": "the secret store's passphrase (exporting NOTE)".
    public static func require(_ what: @autoclosure () -> String, fix: @autoclosure () -> String) throws {
        guard isOff else { return }
        throw refusal(what(), fix: fix())
    }

    /// The error of a question that is not asked. It is remembered: whatever becomes of the error, the command ends with
    /// its exit code (`Main`).
    public static func refusal(_ what: String, fix: String) -> XlessError {
        let error = XlessError(.input, "\(option) (\(variable)): xless would ask for \(what)", fix: fix)
        lock.withLock { if first == nil { first = error } }
        return error
    }

    /// The first question this process did not ask.
    public static var refused: XlessError? { lock.withLock { first } }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var first: XlessError?

    /// The arguments without `--no-input`, which any command takes, anywhere before a `--`; and whether it was there.
    public static func taking(_ arguments: [String]) -> (arguments: [String], isOff: Bool) {
        guard let program = arguments.first else { return ([], false) }
        let rest = arguments.dropFirst()
        let own = rest.prefix { $0 != "--" }
        return ([program] + own.filter { $0 != option } + rest.dropFirst(own.count), own.contains(option))
    }
}
