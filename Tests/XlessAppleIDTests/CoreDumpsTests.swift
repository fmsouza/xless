import XCTest
import XlessAppleID

final class CoreDumpsTests: XCTestCase {
    /// The process that holds the sign-in can neither write a core file nor (on Linux) be read through ptrace or
    /// /proc/<pid>/mem by another process of the same user.
    func testDisableTurnsOffCoreFilesAndDumpability() {
        CoreDumps.disable()
        XCTAssertEqual(CoreDumps.coreFileLimit, 0)
        #if os(Linux)
        XCTAssertEqual(CoreDumps.isDumpable, false)
        #else
        XCTAssertNil(CoreDumps.isDumpable)
        #endif
    }
}
