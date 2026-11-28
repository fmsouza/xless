import Testing
import Foundation
@testable import XlessCore

private let table: [String: String] = [
    "SWIFT_VERSION": "6.4.0", "XLESS_VERSION": "0.0.0-dev", "XTOOL_VERSION": "1.21.0",
    "SWIFT_IMAGE": "swift:6.4.0-jammy@sha256:abc",
    "SWB_TAG": "swift-6.4.0-RELEASE", "SWB_SHA256": "swb1", "SWB_DRIVER_SHA256": "swb2", "SWB_SYSTEM_VERSION": "1.5.0",
    "XCODE_SWIFT_27A266a": "6.4.0", "XCODE_SWIFT_17C52": "6.2.3",
    "XCODE_SHORT_27A266a": "27.0", "XCODE_SHORT_17C52": "26.2", "XCODE_BUILD_MACHINE_OS_17C52": "26A434",
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64": "https://example.com/s640-a.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64": "s640a",
    "SWIFT_TOOLCHAIN_6_4_0_URL_X86_64": "https://example.com/s640-x.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_X86_64": "s640x",
    "SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64": "https://example.com/s623-a.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64": "s623a",
    "SWIFT_TOOLCHAIN_6_2_3_URL_X86_64": "https://example.com/s623-x.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_X86_64": "s623x",
]

private let sdkFiles = [
    "scripts/fit-toolchain.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
    "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt",
    "docker/toolchain/target-os/27A266a.txt", "docker/toolchain/target-os/17C52.txt",
]
private let swiftBuildFiles = ["scripts/pack-swift-build.sh"]

private func makeShare() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-recipe-\(UUID().uuidString)")
    for path in sdkFiles + swiftBuildFiles { try write(path, "original \(path)", in: dir) }
    return dir
}

private func write(_ path: String, _ text: String, in share: URL) throws {
    let url = share.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func digest(_ part: PackPart, build: String = "27A266a", arch: String = "arm64", _ t: [String: String], _ share: URL) throws -> String {
    try PackRecipe.hash(part, build: build, arch: arch, table: t, share: share)
}

private func digest(_ part: PackPart, build: String = "27A266a", arch: String = "arm64", _ share: URL) throws -> String {
    try digest(part, build: build, arch: arch, table, share)
}

@Test func hashesAreSixtyFourHexDigits() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    for part in PackPart.allCases {
        let h = try digest(part, share)
        #expect(h.count == 64 && h.allSatisfy { $0.isHexDigit })
    }
    #expect(try digest(.sdk, share) == digest(.sdk, share))
}

@Test(arguments: sdkFiles.filter { !$0.hasSuffix("/17C52.txt") })
func sdkHashChangesWithEachFile(file: String) throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.sdk, share)
    try write(file, "edited", in: share)
    #expect(try digest(.sdk, share) != before)
}

@Test(arguments: [
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64", "XTOOL_VERSION",
    "XCODE_SWIFT_27A266a", "XCODE_SHORT_27A266a", "SWIFT_VERSION",
])
func sdkHashChangesWithEachKey(key: String) throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    var t = table
    t["XCODE_SHORT_27A266a"] = "27.0"
    let before = try digest(.sdk, t, share)
    t[key] = (t[key] ?? "") + "x"
    // A changed XCODE_SWIFT_ would point at a toolchain the table does not hold; keep the lookup valid.
    if key == "XCODE_SWIFT_27A266a" { t[key] = "6.2.3" }
    #expect(try digest(.sdk, t, share) != before)
}

@Test func sdkHashIgnoresOtherArchAndOtherBuilds() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.sdk, share)
    var t = table
    t["SWIFT_TOOLCHAIN_6_4_0_URL_X86_64"] = "other"
    t["XCODE_SHORT_17C52"] = "other"
    #expect(try digest(.sdk, t, share) == before)
    #expect(try digest(.sdk, arch: "amd64", share) != before)
    #expect(try digest(.sdk, build: "17C52", share) != before)
}

// Another vetted .xip of the same Xcode (XCODE_XIP_SHA256_<build>) makes the same pack: the checksums are no input.
@Test func sdkHashIgnoresTheXipChecksums() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    var t = table
    t["XCODE_XIP_SHA256_27A266a"] = "aaaa"
    let before = try digest(.sdk, t, share)
    t["XCODE_XIP_SHA256_27A266a"] = "aaaa bbbb"
    #expect(try digest(.sdk, t, share) == before)
    t["XCODE_XIP_SHA256_27A266a"] = nil
    #expect(try digest(.sdk, t, share) == before)
}

@Test(arguments: ["SWB_TAG", "SWB_SHA256", "SWB_SYSTEM_VERSION", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64", "SWIFT_IMAGE"])
func swiftBuildHashChangesWithItsPins(key: String) throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.swiftBuild, share)
    var t = table
    t[key] = key == "SWIFT_IMAGE" ? "swift:6.4.0-noble@sha256:abc" : (t[key] ?? "") + "x"
    #expect(try digest(.swiftBuild, t, share) != before)
}

@Test func swiftBuildHashIgnoresTheImageDigest() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    var t = table
    let before = try digest(.swiftBuild, t, share)
    t["SWIFT_IMAGE"] = "swift:6.4.1-jammy@sha256:def"
    #expect(try digest(.swiftBuild, t, share) == before)
}

@Test func swiftBuildHashChangesWithItsScript() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.swiftBuild, share)
    try write("scripts/pack-swift-build.sh", "edited", in: share)
    #expect(try digest(.swiftBuild, share) != before)
}

@Test func hashesIgnoreTheXlessVersion() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try PackPart.allCases.map { try digest($0, share) }
    var t = table
    t["XLESS_VERSION"] = "9.9.9"
    try write("VERSION", "9.9.9", in: share)
    #expect(try PackPart.allCases.map { try digest($0, t, share) } == before)
}

@Test func sdkHashIgnoresSwiftBuildPins() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.sdk, share)
    var t = table
    t["SWB_TAG"] = "other"; t["SWB_SHA256"] = "other"; t["SWIFT_IMAGE"] = "swift:6.4.0-noble@sha256:abc"
    try write("scripts/pack-swift-build.sh", "edited", in: share)
    #expect(try digest(.sdk, t, share) == before)
}

@Test(arguments: sdkFiles.filter { $0 != "scripts/fit-toolchain.sh" })
func swiftBuildHashIgnoresTheFixture(file: String) throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let before = try digest(.swiftBuild, share)
    try write(file, "edited", in: share)
    try write("scripts/fit-toolchain.sh", "edited", in: share)
    #expect(try digest(.swiftBuild, share) == before)
}

@Test func modeFollowsSwiftVersion() throws {
    #expect(PackRecipe.mode(swift: "6.4.0", table: table) == .own)
    #expect(PackRecipe.mode(swift: "6.2.3", table: table) == .separate)
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    var flipped = table
    flipped["SWIFT_VERSION"] = "6.2.3"
    #expect(try digest(.sdk, build: "27A266a", table, share) != digest(.sdk, build: "27A266a", flipped, share))
    #expect(try digest(.sdk, build: "17C52", table, share) != digest(.sdk, build: "17C52", flipped, share))
    // A third engine release: 27A266a's Swift is no longer the engine's (own → separate), 17C52's still is not (separate both times).
    var third = table
    third["SWIFT_VERSION"] = "6.5.0"
    #expect(try digest(.sdk, build: "27A266a", table, share) != digest(.sdk, build: "27A266a", third, share))
    #expect(try digest(.sdk, build: "17C52", table, share) == digest(.sdk, build: "17C52", third, share))
}

// A recipe file that is there but cannot be read is said to be unreadable, not missing.
@Test func anUnreadableRecipeFileIsSaidToBeUnreadable() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    let file = share.appendingPathComponent("docker/toolchain/clang-driver")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
    guard (try? Data(contentsOf: file)) == nil else { return } // root reads it anyway
    do {
        _ = try digest(.sdk, share)
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect(e.cause.contains("docker/toolchain/clang-driver") && e.cause.contains("cannot be read") && !e.cause.contains("missing"), "\(e.cause)")
    }
}

@Test func swiftVersionComesFromTheTable() throws {
    #expect(try PackRecipe.swiftVersion(build: "17C52", table: table) == "6.2.3")
    #expect(throws: XlessError.self) { try PackRecipe.swiftVersion(build: "nope", table: table) }
}

@Test func missingFixtureThrows() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    try FileManager.default.removeItem(at: share.appendingPathComponent("docker/toolchain/target-os/27A266a.txt"))
    do {
        _ = try digest(.sdk, share)
        Issue.record("expected a throw")
    } catch let e as XlessError {
        #expect("\(e)".contains("docker/toolchain/target-os/27A266a.txt") || e.cause.contains("docker/toolchain/target-os/27A266a.txt"))
    }
}

@Test func missingPinThrows() throws {
    let share = try makeShare()
    defer { try? FileManager.default.removeItem(at: share) }
    var t = table
    t["SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64"] = nil
    #expect(throws: XlessError.self) { try digest(.sdk, t, share) }
    #expect(throws: XlessError.self) { try digest(.swiftBuild, t, share) }
}

// The fit's mode is not in the swift-build hash, though pack-swift-build.sh strips by it: it changes only with SWIFT_VERSION,
// and the repository's SWB_TAG is the tag of SWIFT_VERSION, so a new SWIFT_VERSION moves the swift-build hash too (PackPlan).
@Test func theRepositorysSwiftBuildTagIsThatOfItsSwift() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let table = KnownXcodes.parseEnv(try String(contentsOf: root.appendingPathComponent("versions.env"), encoding: .utf8))
    let swift = try #require(table["SWIFT_VERSION"])
    #expect(table["SWB_TAG"] == "swift-\(swift)-RELEASE")
}
