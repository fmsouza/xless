import ArgumentParser
import Foundation
import XlessCore
import XlessVault

@main
enum Main {
    static func main() async {
        // A native install's xtool, rcodesign and Swift, first on PATH for this process and every child.
        NativeLayout.activate()
        // A secret missing from the environment comes from the encrypted store, when it holds one (`xless secrets`).
        Secrets.install(VaultResolver(store: VaultStore(location: .standard()), prompter: { try? TerminalPrompter.forSecretStore() }))
        do {
            var command = try Xless.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as XlessError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exit(error.stage.exitCode)
        } catch {
            Xless.exit(withError: error)
        }
    }
}
