// What the tests on Windows start as a program of its own, with made-up secrets only:
// - `open|secret fault|abort|trap`: ends as a program error does, with a secret in its memory. With `secret` it is what a process that
//   reads a secret is (SecretScope); with `open` it is as any other. Tests/windows/no-dump.test.ps1 looks for what is left of it.
// - `ask secret|line`: asks on its console, and says what it was answered (WindowsConsoleTests).
// - `lock <file>`: holds a lock of PrivateFile's until it is ended (Tests/windows/process.test.ps1).
// - `derive`: whether deriving a store's key makes the process one that reads secrets.
// - `get <url>`: what an https request comes to (Tests/windows/https.test.ps1).
// - `load|load-open <dll>`: whether a DLL of that name is found, as xless looks for one, and as any other program does.
import CXlessWindowsTestSupport
import Foundation
import FoundationNetworking
import XlessCore
import XlessVault

func say(_ text: String) { FileHandle.standardOutput.write(Data("\(text)\n".utf8)) }

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("\(text)\n".utf8))
    exit(10)
}

func crash(_ how: String, secret: Bool) {
    xless_test_allow_reports()
    if secret { SecretScope.enter() }
    let text = SecretBytes(utf8: String("ELGRAM-TERCES-SSELX".reversed()))
    say("ready \(text)")
    if how == "trap" {
        let none: Int? = CommandLine.arguments.count > 3 ? 1 : nil
        print(none!)
    }
    xless_test_crash(how)
}

func ask(_ kind: String, _ standard: [String]) {
    WindowsProcess.start()
    for (which, name) in ["input=", "output=", "error="].enumerated() {
        guard let given = standard.first(where: { $0.hasPrefix(name) }) else { continue }
        let code = given.dropFirst(name.count).withCString(encodedAs: UTF16.self) { xless_test_set_standard(Int32(which), $0) }
        if code != 0 { fail("\(given): Windows error \(code)") }
    }
    do {
        let console = try WindowsConsole()
        if kind == "secret" {
            let secret = try console.askSecret("Passphrase: ")
            console.say("answer \(secret.withUnsafeBytes { $0.map { String(format: "%02x", Int($0)) }.joined(separator: " ") })\n")
        } else {
            let line = try console.ask("Name: ")
            console.say("answer \(line.utf8.map { String(format: "%02x", Int($0)) }.joined(separator: " "))\n")
        }
    } catch let problem as WindowsConsole.Problem {
        fail("refused: \(problem.cause)")
    } catch {
        fail("\(error)")
    }
}

func get(_ url: URL) async {
    SecretScope.enter() // as the commands that go to Apple do
    do {
        let session = try WinHTTPSession(env: ProcessInfo.processInfo.environment)
        let response = try await session.exchange(URLRequest(url: url), idle: 20, response: { _ in }, body: { _ in })
        say("status \(response.statusCode)")
    } catch let error as URLError {
        say("error \(error.code.rawValue) \(error.localizedDescription)")
    } catch {
        say("error \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count > 1 ? arguments[1] : nil) {
case ("open", let how?): crash(how, secret: false)
case ("secret", let how?): crash(how, secret: true)
case ("ask", let kind?): ask(kind, Array(arguments.dropFirst(2)))
case ("lock", let file?):
    do {
        try PrivateFile.withLock(file, .anyDrive) {
            say("locked")
            Thread.sleep(forTimeInterval: 600)
        }
    } catch { fail("\(error)") }
case ("derive", _):
    xless_test_allow_reports() // the starting process may have said otherwise
    let before = xless_test_hardening()
    do { _ = try VaultCrypto.newVault(passphrase: SecretBytes(utf8: "a made-up passphrase"), kdf: .fresh(rounds: 1 << 10, blockSize: 8, parallelism: 1)) } catch { fail("\(error)") }
    say("hardened \(before & 1) \(xless_test_hardening() & 1)")
case ("get", let url?): await get(URL(string: url)!)
case ("load", let name?), ("load-open", let name?):
    if arguments[0] == "load" { WindowsProcess.start() }
    say(name.withCString(encodedAs: UTF16.self) { xless_test_load($0) } == 0 ? "found" : "not found")
default: fatalError("usage")
}
