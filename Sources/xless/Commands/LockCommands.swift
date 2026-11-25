import ArgumentParser
import Foundation
import XlessAppleID
import XlessCore
import XlessVault

struct UnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Keep the secret store unlocked for the commands of this terminal, so they ask no passphrase.",
        discussion: """
        Asks the passphrase once and keeps the store's key in memory, in the xless agent: a process of yours that gives it \
        to xless commands of this terminal session only. It ends after the time given (8 h by default, at most 7 days), \
        after 2 h without use, when the terminal is closed, when the system sleeps or (macOS) the screen is locked, and \
        with `xless lock`. The tools xless runs (compilers, build scripts, npm) never reach it. Run it again in another \
        terminal to use the store there too. Where no agent can run (it says why), the Linux kernel keyring keeps it, for \
        an hour at most; there only that time and `xless lock` end it, and --idle is refused.

        config.yml (~/.config/xless/config.yml) sets the times: `unlock: { duration: 8h, idle: 2h, maximum: 7d }`. \
        `xless auth status` shows what is held. An Apple ID session is kept by `xless auth login --keep`. docs/secrets.md.
        """)

    @Option(name: .customLong("for"), help: ArgumentHelp("How long, e.g. 30m, 8h or 2d (default: config.yml's unlock.duration, else 8h; at most 7d).", valueName: "duration"))
    var time: String?
    @Option(help: ArgumentHelp("End it after this long without use (default: config.yml's unlock.idle, else 2h).", valueName: "duration"))
    var idle: String?

    func run() throws {
        try SecretStoreCLI.run {
            guard case .vault(let vault) = try SecretStoreCLI.backend() else {
                print("the credential helper keeps its own lock (unlock your keyring or agent with its own tools); nothing to do")
                return
            }
            let hold = try HeldSecrets.settings.get().hold(time, idle: idle, option: "--for", stage: .config)
            try SecretStoreCLI.cache.require(hold)
            print(try SecretStoreCLI.unlock(vault, hold: hold))
        }
    }
}

struct LockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Forget everything held for later commands, now: the store's unlock and a kept Apple ID session.",
        discussion: """
        Ends every xless agent of yours, in every terminal, drops what is in the Linux kernel keyring and removes a session \
        saved across reboots. Your screen \
        locker can run it too (docs/security.md).
        """)

    func run() throws {
        try SecretStoreCLI.run {
            let agents = Result { try HeldSecrets.agents.lockAll() }
            let keys = try KernelKeyringCache().forgetAll() + KernelKeyring.revokeAll(prefix: AppleSessionCache.prefix)
            let saved = AppleWebCLI.saved.expires == nil ? 0 : try AppleWebCLI.saved.remove() ? 1 : 0
            let ended = try agents.get()
            print(ended + keys + saved > 0 ? "locked: everything held was dropped" : "nothing was held")
        }
    }
}
