import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private let xcode27 = KnownXcode(build: "27A266a", shortVersion: "27.0", appleSwift: "6.4", buildMachineOSBuild: "26A434", xipSHA256: [])
private let xcode26 = KnownXcode(build: "17C52", shortVersion: "26.2", appleSwift: "6.2.3", buildMachineOSBuild: "26A434", xipSHA256: [])
private let layout = NativeLayout(root: URL(fileURLWithPath: "/n"))
private let share = URL(fileURLWithPath: "/share")
private let cache = URL(fileURLWithPath: "/cache/xless")
private let bundle = URL(fileURLWithPath: "/home/u/.swiftpm/swift-sdks/darwin.artifactbundle")
private let metaDest = URL(fileURLWithPath: "/home/u/.config/xless/toolchain-meta.json")
private let table: [String: String] = [
    "SWIFT_VERSION": "6.4.0", "XTOOL_VERSION": "1.21.0", "RCODESIGN_VERSION": "0.29.0",
    "XTOOL_SHA256_AARCH64": "xa", "XTOOL_SHA256_X86_64": "xx", "RCODESIGN_SHA256_AARCH64": "ra", "RCODESIGN_SHA256_X86_64": "rx",
    "XCODE_SWIFT_27A266a": "6.4.0", "XCODE_SWIFT_17C52": "6.2.3",
    "SWIFT_TOOLCHAIN_6_4_0_URL_AARCH64": "https://example.com/s640-a.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64": "s640a",
    "SWIFT_TOOLCHAIN_6_4_0_URL_X86_64": "https://example.com/s640-x.tar.gz", "SWIFT_TOOLCHAIN_6_4_0_SHA256_X86_64": "s640x",
    "SWIFT_TOOLCHAIN_6_2_3_URL_AARCH64": "https://example.com/s623-a.tar.gz", "SWIFT_TOOLCHAIN_6_2_3_SHA256_AARCH64": "s623a",
]

private func plan(_ x: KnownXcode = xcode27, arch: String = "arm64", table t: [String: String] = table, reexport: Bool = false,
                  installed: NativeSetupPlan.Installed? = nil, existing: @escaping (URL) -> Bool = { _ in false }) throws -> [SetupStep] {
    try NativeSetupPlan.make(source: (x, .xip, URL(fileURLWithPath: "/home/u/Downloads/Xcode_27.xip")), arch: arch, share: share,
                             cacheRoot: cache, layout: layout, sdkBundle: bundle, metaDest: metaDest, table: t,
                             reexport: reexport, installed: installed, existing: existing)
}

private func downloads(_ steps: [SetupStep]) -> [NativeDownload] {
    steps.compactMap { if case let .download(d) = $0.action { return d } else { return nil } }
}

@Test func aFreshMachineGetsEveryStepInOrder() throws {
    let steps = try plan()
    #expect(steps.count == 7)
    let d = downloads(steps)
    #expect(d.map(\.kind) == [.appImage, .rcodesign, .swiftToolchain])
    #expect(d[0].url.absoluteString == "https://github.com/xtool-org/xtool/releases/download/1.21.0/xtool-aarch64.AppImage")
    #expect(d[0].sha256 == "xa" && d[0].final.path == "/n/tools/xtool-1.21.0")
    #expect(d[0].partial.path == "/n/tools/xtool-1.21.0.partial")
    #expect(d[1].url.absoluteString == "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-aarch64-unknown-linux-musl.tar.gz")
    #expect(d[1].sha256 == "ra" && d[1].final.path == "/n/tools/rcodesign-0.29.0")
    #expect(d[2].url.absoluteString == "https://example.com/s640-a.tar.gz" && d[2].sha256 == "s640a")
    #expect(d[2].final.path == "/n/toolchains/swift-6.4.0")

    // The export runs the native xtool, into the cache the Docker path uses too; nothing runs docker.
    let sdk = "/cache/xless/sdk/xcode27.0-27A266a"
    #expect(steps[3].argv == ["/n/bin/xtool", "sdk", "build", "/home/u/Downloads/Xcode_27.xip", "\(sdk)/arm64.partial"])
    #expect(steps[3].action == .export(partial: URL(fileURLWithPath: "\(sdk)/arm64.partial"), final: URL(fileURLWithPath: "\(sdk)/arm64")))
    #expect(steps[4].action == .meta(xtoolSDK: URL(fileURLWithPath: "\(sdk)/arm64/darwin.xtoolsdk"), out: URL(fileURLWithPath: "\(sdk)/toolchain-meta.json")))
    #expect(steps[5].action == .sdkInstall(xtoolSDK: URL(fileURLWithPath: "\(sdk)/arm64/darwin.xtoolsdk"), meta: URL(fileURLWithPath: "\(sdk)/toolchain-meta.json")))
    #expect(steps[6].argv == ["/share/scripts/native-toolchain.sh", "/n/toolchains/swift-6.4.0", "own", bundle.path, metaDest.path,
                              "/share/docker/toolchain", "/n/swift-toolchain.json"])
    #expect(steps[6].action == .run)
    #expect(!steps.contains { $0.argv.first == "docker" })
}

@Test func amd64DownloadsTheX86Pins() throws {
    let d = downloads(try plan(arch: "amd64"))
    #expect(d[0].url.lastPathComponent == "xtool-x86_64.AppImage" && d[0].sha256 == "xx")
    #expect(d[1].url.lastPathComponent == "apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz" && d[1].sha256 == "rx")
    #expect(d[2].sha256 == "s640x")
}

@Test func anotherSwiftReleaseIsFittedAsSeparate() throws {
    let steps = try plan(xcode26)
    #expect(downloads(steps).last?.final.path == "/n/toolchains/swift-6.2.3")
    #expect(steps.last?.argv[1] == "/n/toolchains/swift-6.2.3")
    #expect(steps.last?.argv[2] == "separate")
}

@Test func installedToolsAndAnExistingExportAreSkipped() throws {
    let present: Set<String> = ["/n/bin/xtool", "/n/bin/rcodesign", "/n/toolchains/swift-6.4.0/usr/bin/swiftc",
                                "/cache/xless/sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk", "/cache/xless/sdk/xcode27.0-27A266a/toolchain-meta.json"]
    // Another Xcode installed: the SDK is installed again and the toolchain fitted again.
    let other = try plan(installed: .init(xcodeBuild: "17C52", swiftVersion: "6.2.3")) { present.contains($0.path) }
    #expect(other.count == 2)
    #expect(other.first?.action == .sdkInstall(xtoolSDK: URL(fileURLWithPath: "/cache/xless/sdk/xcode27.0-27A266a/arm64/darwin.xtoolsdk"),
                                              meta: URL(fileURLWithPath: "/cache/xless/sdk/xcode27.0-27A266a/toolchain-meta.json")))
    // Everything in place: nothing to do.
    let done = present.union(["/n/swift-toolchain.json"])
    #expect(try plan(installed: .init(xcodeBuild: "27A266a", swiftVersion: "6.4.0")) { done.contains($0.path) }.isEmpty)
    #expect(try plan(installed: .init(xcodeBuild: "27A266a", swiftVersion: "6.4")) { done.contains($0.path) }.isEmpty)
    // A tool unpacked but not linked into bin/ (a run stopped in between): installed again, and everything after it.
    let unlinked = try plan(installed: .init(xcodeBuild: "27A266a", swiftVersion: "6.4.0")) { done.subtracting(["/n/bin/xtool"]).contains($0.path) }
    #expect(downloads(unlinked).map(\.final.path) == ["/n/tools/xtool-1.21.0"])
    #expect(unlinked.count == 3)
    // --reexport: the export, then everything after it.
    let again = try plan(reexport: true, installed: .init(xcodeBuild: "27A266a", swiftVersion: "6.4.0")) { done.contains($0.path) }
    #expect(again.count == 4)
    if case .export = again[0].action {} else { Issue.record("first step is not the export: \(again[0].title)") }
}

@Test func aMissingPinIsRefusedNamingIt() throws {
    var t = table; t["SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64"] = nil
    #expect { try plan(table: t) } throws: { ($0 as? XlessError)?.cause.contains("SWIFT_TOOLCHAIN_6_4_0_SHA256_AARCH64") == true }
    #expect { try plan(xcode26, arch: "amd64") } throws: { ($0 as? XlessError)?.cause.contains("SWIFT_TOOLCHAIN_6_2_3_URL_X86_64") == true }
    var u = table; u["XCODE_SWIFT_27A266a"] = nil
    #expect { try plan(table: u) } throws: { ($0 as? XlessError)?.cause.contains("XCODE_SWIFT_27A266a") == true }
}

@Test func theRepositorysVersionsEnvPinsEverySupportedXcodeForBothArchitectures() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let t = KnownXcodes.parseEnv(try String(contentsOf: root.appendingPathComponent("versions.env"), encoding: .utf8))
    for x in try KnownXcodes.load(versionsEnv: root.appendingPathComponent("versions.env")) {
        for a in ["arm64", "amd64"] { #expect(throws: Never.self) { try plan(x, arch: a, table: t) } }
    }
}
