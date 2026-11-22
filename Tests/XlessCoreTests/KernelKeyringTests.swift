import Foundation
import Testing
@testable import XlessCore

/// Keyring tests run where the kernel lets this process use a session keyring; Docker's default seccomp profile (and
/// so CI's containers) blocks add_key/keyctl, and macOS has none: there they are skipped.
private let keyringAvailable = KernelKeyring.isAvailable

private func uniqueName() -> String { "xless-test-\(UUID().uuidString)" }

@Test(.enabled(if: keyringAvailable)) func keyringStoresFindsAndReadsASecret() throws {
    let name = uniqueName()
    let key = try KernelKeyring.store(name: name, secret: SecretBytes(utf8: "unwrapped-data-key"), timeout: 60)
    defer { try? KernelKeyring.revoke(key) }
    #expect(try KernelKeyring.find(name: name) == key)
    #expect(try KernelKeyring.read(key) == SecretBytes(utf8: "unwrapped-data-key"))
}

@Test(.enabled(if: keyringAvailable)) func revokedKeysCannotBeReadOrFound() throws {
    let name = uniqueName()
    let key = try KernelKeyring.store(name: name, secret: SecretBytes(utf8: "x"), timeout: 60)
    try KernelKeyring.revoke(key)
    #expect(throws: KernelKeyring.Failure.self) { try KernelKeyring.read(key) }
    #expect(try KernelKeyring.find(name: name) == nil)
}

@Test(.enabled(if: keyringAvailable)) func unknownKeysAreNotFound() throws {
    #expect(try KernelKeyring.find(name: uniqueName()) == nil)
}

@Test(.enabled(if: keyringAvailable)) func storedKeysArePossessorOnly() throws {
    let key = try KernelKeyring.store(name: uniqueName(), secret: SecretBytes(utf8: "x"), timeout: 600)
    defer { try? KernelKeyring.revoke(key) }
    #expect(try KernelKeyring.permissions(key) == 0x3b00_0000)
}

/// The kernel, not xless, ends a key's life: after its timeout it can no longer be read or found.
@Test(.enabled(if: keyringAvailable)) func keysExpireWhenTheirTimeoutEnds() async throws {
    let name = uniqueName()
    let key = try KernelKeyring.store(name: name, secret: SecretBytes(utf8: "x"), timeout: 1)
    defer { try? KernelKeyring.revoke(key) }
    try await Task.sleep(for: .milliseconds(2200))
    #expect(throws: KernelKeyring.Failure.self) { try KernelKeyring.read(key) }
    #expect(try KernelKeyring.find(name: name) == nil)
}

@Test func keyringRefusesATimeoutOutsideOneSecondToOneHour() {
    for timeout in [0, -5, 3601] {
        #expect(throws: KernelKeyring.Failure.self) {
            try KernelKeyring.store(name: uniqueName(), secret: SecretBytes(utf8: "x"), timeout: timeout)
        }
    }
}

@Test func keyringFailuresNameTheOperationAndNeverTheSecret() {
    let failure = KernelKeyring.Failure(operation: "add_key", code: EPERM)
    #expect(failure.description == "kernel keyring: add_key failed: Operation not permitted")
}
