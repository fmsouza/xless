// Ends as a program error does, with a secret in its memory: `XlessWindowsProbe open|secret fault|abort|trap`. With `secret` it is what
// a process that reads a secret is (SecretScope); with `open` it is as any other. Tests/windows/no-dump.test.ps1 looks for what is left of it.
import CXlessWindowsTestSupport
import Foundation
import XlessCore

let arguments = CommandLine.arguments
guard arguments.count == 3, ["open", "secret"].contains(arguments[1]) else { fatalError("usage") }
xless_test_allow_reports()
if arguments[1] == "secret" { SecretScope.enter() }
let secret = SecretBytes(utf8: String("ELGRAM-TERCES-SSELX".reversed()))
FileHandle.standardOutput.write(Data("ready \(secret)\n".utf8))
if arguments[2] == "trap" {
    let none: Int? = arguments.count > 3 ? 1 : nil
    print(none!)
}
xless_test_crash(arguments[2])
