import Testing
import Foundation
@testable import XlessCore

private func staleStageDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID())/final", isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Old.app"), withIntermediateDirectories: true)
    return dir
}

@Test func atomicOutputCommitsOnlyOnSuccess() throws {
    let dir = try staleStageDir()
    let result = try Files.atomicOutput(dir) { partial in
        #expect(partial.lastPathComponent == "final.partial")
        #expect(!FileManager.default.fileExists(atPath: dir.path))   // a stale output never survives a new run
        let app = partial.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }
    #expect(result.path == dir.appendingPathComponent("New.app").path)
    #expect(FileManager.default.fileExists(atPath: result.path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Old.app").path))
    #expect(!FileManager.default.fileExists(atPath: dir.path + ".partial"))
}

@Test func atomicOutputLeavesNothingOnFailure() async throws {
    struct Boom: Error {}
    let dir = try staleStageDir()
    await #expect(throws: Boom.self) {
        _ = try await Files.atomicOutput(dir) { partial async throws -> URL in
            try FileManager.default.createDirectory(at: partial.appendingPathComponent("Half.app"), withIntermediateDirectories: true)
            throw Boom()
        }
    }
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    #expect(!FileManager.default.fileExists(atPath: dir.path + ".partial"))
}

@Test func temporaryFilesGoWhereTMPDIRSays() throws {
    let path = ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
    #expect(Files.temporary.standardizedFileURL.path == URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path)
}
