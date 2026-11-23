import Testing
import Foundation
@testable import XlessCore

private func scratchDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func anExecutableIsWrittenWithItsModeReplacingTheOldOneAndNothingElse() throws {
    let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let tool = dir.appendingPathComponent("tool")
    try ExecutableFile.write("#!/bin/sh\necho one\n", to: tool, stage: .build)
    #expect(try Shell.run(tool.path, [], stage: .build).stdout == "one\n")
    try ExecutableFile.write("#!/bin/sh\necho two\n", to: tool, mode: 0o700, stage: .build)
    #expect(try Shell.run(tool.path, [], stage: .build).stdout == "two\n")
    let mode = try FileManager.default.attributesOfItem(atPath: tool.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["tool"])
}

@Test func aMissingDirectoryIsAnErrorAndLeavesNothing() throws {
    let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: (any Error).self) { try ExecutableFile.write("#!/bin/sh\n", to: dir.appendingPathComponent("no/tool"), stage: .sign) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

/// Many threads write a script each and run it at once, while the others start children: a script written with a plain
/// `Data.write` fails here now and then with "Text file busy" (a child another thread was starting still held it open
/// for writing); one written with `ExecutableFile` never does. Plain threads, not tasks: every thread blocks in a child.
@Test func scriptsWrittenWhileOtherThreadsStartChildrenRunAtOnce() throws {
    let dir = try scratchDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let body = "#!/bin/sh\necho ok\n" + String(repeating: "# padding the script so that writing it takes a while\n", count: 500)
    let lock = NSLock()
    nonisolated(unsafe) var failures: [String] = []
    let done = DispatchGroup()
    for worker in 0..<16 {
        done.enter()
        Thread {
            defer { done.leave() }
            for i in 0..<40 {
                let tool = dir.appendingPathComponent("tool-\(worker)-\(i)")
                do {
                    try ExecutableFile.write(body, to: tool, stage: .build)
                    _ = try Shell.run(tool.path, [], stage: .build)
                } catch {
                    lock.lock(); failures.append("\(error)"); lock.unlock()
                }
            }
        }.start()
    }
    done.wait()
    #expect(failures.isEmpty, "\(failures.count) runs failed, the first: \(failures.first ?? "")")
}
