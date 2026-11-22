import Foundation
import Testing
@testable import XlessCore

/// A process holding a secret can neither write a core file nor (on Linux) be read through ptrace or /proc/<pid>/mem by
/// another process of the same user.
@Test func secretScopeTurnsOffCoreFilesAndDumpability() {
    SecretScope.enter()
    SecretScope.enter() // idempotent
    #expect(SecretScope.coreFileLimit == 0)
    #if os(Linux)
    #expect(SecretScope.isDumpable == false)
    #else
    #expect(SecretScope.isDumpable == nil)
    #endif
}

/// Handing out a secret enters the scope, so a stage that reads a key is covered whatever command runs it.
@Test func secretsEnterTheScopeWhenTheyHandOutAValue() throws {
    _ = try Secrets(env: ["X_TEST_SECRET": "v"]).optional("X_TEST_SECRET")
    #expect(SecretScope.coreFileLimit == 0)
}
