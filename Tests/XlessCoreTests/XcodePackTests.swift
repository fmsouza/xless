import Testing
import Foundation
@testable import XlessCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-pack-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func manifest(parts: [String: String] = ["sdk": "h"]) -> PackManifest {
    PackManifest(format: 1, xcode: "26.2", build: "17C52", arch: "arm64", swift: "6.2.3", mode: .own, parts: parts)
}

@Test func manifestRoundTrips() throws {
    let url = try tempDir().appendingPathComponent("pack.json")
    let m = manifest(parts: ["sdk": "a", "swift-build": "b"])
    try m.write(to: url)
    #expect(try PackManifest.load(from: url) == m)
    let text = try String(contentsOf: url, encoding: .utf8)
    let keys = ["arch", "build", "format", "mode", "parts", "swift", "xcode"]
    let positions = keys.map { text.range(of: "\"\($0)\"")!.lowerBound }
    #expect(positions == positions.sorted())
}

@Test func openWithoutManifestIsNil() throws {
    let root = try tempDir()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
    #expect(try XcodePack.open(root) == nil)
}

@Test func openRejectsBrokenManifest() throws {
    let root = try tempDir()
    try "{ nope".write(to: root.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
    #expect {
        try XcodePack.open(root)
    } throws: { ($0 as? XlessError).map { "\($0)".contains("pack.json") || $0.cause.contains("pack.json") } ?? false }
}

@Test func pathsAreUnderRoot() {
    let root = URL(fileURLWithPath: "/s/26.2-17C52-arm64")
    let p = XcodePack(root: root, manifest: manifest())
    #expect(p.name == "26.2-17C52-arm64")
    #expect(p.manifestFile.path == "/s/26.2-17C52-arm64/pack.json")
    #expect(p.configHome.path == "/s/26.2-17C52-arm64/config")
    #expect(p.sdkBundle.path == "/s/26.2-17C52-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle")
    #expect(p.meta.path == "/s/26.2-17C52-arm64/toolchain-meta.json")
    #expect(p.toolchain.path == "/s/26.2-17C52-arm64/toolchain")
    #expect(p.record.path == "/s/26.2-17C52-arm64/swift-toolchain.json")
    #expect(p.include.path == "/s/26.2-17C52-arm64/include")
    #expect(p.swiftBuild.path == "/s/26.2-17C52-arm64/swift-build")
}

@Test func nameIsVersionBuildArch() {
    #expect(XcodePack.name(xcode: "26.2", build: "17C52", arch: "arm64") == "26.2-17C52-arm64")
}

@Test func hasPart() {
    let p = XcodePack(root: URL(fileURLWithPath: "/s/x"), manifest: manifest(parts: ["sdk": "h"]))
    #expect(p.has(.sdk))
    #expect(!p.has(.swiftBuild))
}
