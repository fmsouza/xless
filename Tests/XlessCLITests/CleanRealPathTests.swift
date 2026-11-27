import Foundation
import Testing
@testable import xless

/// What `xless clean` compares (`CleanCommand.real`): on a volume that does not tell case apart (a Mac's, by default), a path
/// given in another case is the one on disk, so a store or cache named in another case is still found where it is.
@Test func cleanComparesPathsInTheCaseTheyHaveOnDisk() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("clean-real-\(UUID().uuidString)")
    try fm.createDirectory(at: dir.appendingPathComponent("Lower/inner"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let other = dir.appendingPathComponent("LOWER/INNER")
    guard fm.fileExists(atPath: other.path) else { return } // a volume that tells case apart: nothing to compare
    #expect(CleanCommand.real(other) == CleanCommand.real(dir.appendingPathComponent("Lower/inner")))
    #expect(CleanCommand.real(other).hasSuffix("/Lower/inner"))
}
