import Foundation
import Testing
@testable import XlessCore
#if os(Windows)
import CXlessWindows
import CXlessWindowsTestSupport
#endif

/// A process holding a secret can neither write a core file nor (on Linux) be read through ptrace or /proc/<pid>/mem by
/// another process of the same user.
@Test func secretScopeTurnsOffCoreFilesAndDumpability() {
    SecretScope.enter()
    SecretScope.enter() // idempotent
    expectHardened()
}

/// Handing out a secret enters the scope, so a stage that reads a key is covered whatever command runs it.
@Test func secretsEnterTheScopeWhenTheyHandOutAValue() throws {
    _ = try Secrets(env: ["X_TEST_SECRET": "v"]).optional("X_TEST_SECRET")
    expectHardened()
}

private func expectHardened() {
    #if os(Windows)
    // What must be: no error dialog, no error report with the heap in it.
    let required = UInt32(XLESS_HARDENED_ERROR_MODE | XLESS_HARDENED_NO_HEAP_REPORT)
    #expect(SecretScope.hardening & required == required)
    xless_test_drop_debug_privilege()
    // What the Windows that CI has also gives: no opening of this process's memory, and no DLL of an extension point, a share or a low label.
    let given = UInt32(XLESS_HARDENED_PROCESS_ACCESS | XLESS_HARDENED_EXTENSION_POINTS | XLESS_HARDENED_REMOTE_IMAGES
        | XLESS_HARDENED_LOW_LABEL_IMAGES | XLESS_HARDENED_SYSTEM32_FIRST | XLESS_HARDENED_STRICT_HANDLES)
    #expect(SecretScope.hardening & given == given)
    #elseif os(Linux)
    #expect(SecretScope.coreFileLimit == 0)
    #expect(SecretScope.isDumpable == false)
    #else
    #expect(SecretScope.coreFileLimit == 0)
    #expect(SecretScope.isDumpable == nil)
    #endif
}

#if os(Windows)
/// No secret is read where Windows would not let the process be kept from an error report.
@Test(arguments: [Int32(1), 2, 3]) func aRefusedStepOfTheHardeningIsARefusal(step: Int32) {
    #expect(SecretScope.refusal(step)?.stage == .config)
    #expect(SecretScope.refusal(0) == nil)
}
#endif
