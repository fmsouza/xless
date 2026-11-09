import Testing
import Foundation
@testable import XlessCargo
@testable import XlessCore

private var fm: FileManager { .default }

private func git(_ dir: URL, _ args: String...) throws {
    _ = try Shell.run("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-C", dir.path] + args, stage: .prepare)
}

/// A git repo holding `tracked` (path → text, committed) and `untracked` files.
private func repo(_ tracked: [String: String], untracked: [String: String] = [:]) throws -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("cargo-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try git(dir, "init", "-q")
    for (path, text) in tracked.merging(untracked, uniquingKeysWith: { a, _ in a }) {
        let url = dir.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    for path in tracked.keys.sorted() { try git(dir, "add", "--", path) }
    try git(dir, "commit", "-q", "-m", "init")
    return dir
}

private func overlay(version: String? = nil, build: String = "dated", macos: Bool = false) throws -> CargoOverlay {
    try CargoOverlay.parse(yaml: """
    type: cargo
    bundleID: com.example.hello
    teamID: ABCDE12345
    \(version.map { "version: \"\($0)\"" } ?? "")
    build: \(build)
    privacyManifest: /abs/PrivacyInfo.xcprivacy
    testflight: { groups: [Internal] }
    usesNonExemptEncryption: false
    xcode: "26.2"
    ios:
      package: hello-mobile
      product: Hello
      minimumOS: "17.0"
      assets: Assets.xcassets
      entitlements: ios.entitlements
      infoPlist: ios/Info.plist
    macos:
      bundleID: com.example.hello.mac
      package: hello
      product: Hello
      minimumOS: "11.0"
      icon: hello.icns
      entitlements: mac.entitlements
    """, name: "hello")
}

private func expectConfig(_ sourceLocation: SourceLocation = #_sourceLocation, containing needles: [String] = [], _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("expected a config error", sourceLocation: sourceLocation)
    } catch let e as XlessError {
        #expect(e.stage == .config, sourceLocation: sourceLocation)
        for n in needles { #expect(e.cause.contains(n), "cause: \(e.cause)", sourceLocation: sourceLocation) }
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

private let hello = "[package]\nname = \"hello-mobile\"\nversion = \"1.2.3\"\n"

@Suite struct CargoProjectTests {
    @Test func versionFromPackage() throws {
        let dir = try repo(["crates/app/Cargo.toml": "[package]\nname = \"app\"\nversion = \"1.2.3\"\n"])
        #expect(try CargoManifest.version(package: "app", source: dir) == "1.2.3")
    }

    @Test func versionFromWorkspace() throws {
        let dir = try repo([
            "Cargo.toml": "[workspace]\nmembers = [\"crates/*\"]\n[workspace.package]\nversion = \"0.10.0\"\n",
            "crates/app/Cargo.toml": "[package]\nname = \"app\"\nversion.workspace = true\n",
            "crates/inline/Cargo.toml": "[package]\nname = \"inline\"\nversion = { workspace = true }  # inherited\n",
        ])
        #expect(try CargoManifest.version(package: "app", source: dir) == "0.10.0")
        #expect(try CargoManifest.version(package: "inline", source: dir) == "0.10.0")
    }

    @Test func rootPackageInheritsFromItsOwnWorkspacePackage() throws {
        let dir = try repo([
            "sub/Cargo.toml": "[package]\nname = \"app\"\nversion.workspace = true\n[workspace]\n[workspace.package]\nversion = \"1.0.0\"\n",
        ])
        #expect(try CargoManifest.version(package: "app", source: dir) == "1.0.0")
    }

    @Test func workspaceVersionMissing() throws {
        let dir = try repo([
            "Cargo.toml": "[workspace]\nmembers = [\"crates/*\"]\n",
            "crates/app/Cargo.toml": "[package]\nname = \"app\"\nversion.workspace = true\n",
        ])
        expectConfig(containing: ["crates/app/Cargo.toml", "Cargo.toml", "[workspace.package]"]) {
            _ = try CargoManifest.version(package: "app", source: dir)
        }
    }

    @Test func untrackedManifestIgnored() throws {
        let dir = try repo(["README.md": "x"], untracked: ["crates/app/Cargo.toml": "[package]\nname = \"app\"\nversion = \"1.0.0\"\n"])
        expectConfig(containing: ["no package named 'app'"]) {
            _ = try CargoManifest.version(package: "app", source: dir)
        }
    }

    @Test func duplicatePackageNameIsRefused() throws {
        let dir = try repo([
            "a/Cargo.toml": "[package]\nname = \"app\"\nversion = \"1.0.0\"\n",
            "b/Cargo.toml": "[package]\nname = \"app\"\nversion = \"2.0.0\"\n",
        ])
        expectConfig(containing: ["a/Cargo.toml", "b/Cargo.toml"]) {
            _ = try CargoManifest.version(package: "app", source: dir)
        }
    }

    @Test func prereleaseShortVersion() throws {
        let dir = try repo(["Cargo.toml": "[package]\nname = \"hello-mobile\"\nversion = \"0.2.0-rc.1\"\n"])
        let r = try CargoProject.resolve(overlay: overlay(), platform: .ios, source: dir)
        #expect(r.config.version == "0.2.0")
        #expect(r.fullVersion == "0.2.0-rc.1")
        #expect(r.config.build == "0.2.0.2000010101")
        #expect(r.config.buildScheme == .dated)
    }

    @Test func explicitVersionWins() throws {
        let dir = try repo(["README.md": "no cargo here"])
        let r = try CargoProject.resolve(overlay: overlay(version: "2.0.0"), platform: .ios, source: dir)
        #expect(r.config.version == "2.0.0")
        #expect(r.fullVersion == "2.0.0")
    }

    @Test func iosConfig() throws {
        let dir = try repo(["Cargo.toml": hello])
        let r = try CargoProject.resolve(overlay: overlay(build: "7"), platform: .ios, source: dir)
        let c = r.config
        #expect(c.platforms.keys.sorted { $0.rawValue < $1.rawValue } == [.ios])
        #expect(c.build == "7")
        #expect(c.buildScheme == .fixed)
        #expect(c.distribution(for: .ios) == .appStore)
        #expect(c.assets == "Assets.xcassets")
        #expect(c.privacyManifest == "/abs/PrivacyInfo.xcprivacy")
        #expect(c.infoPlist == "ios/Info.plist")
        #expect(c.testflight?.groups == ["Internal"])
        #expect(c.usesNonExemptEncryption == false)
        #expect(c.xcode == "26.2")
        #expect(try c.platform(.ios).entitlements == "ios.entitlements")
        #expect(try c.platform(.ios).product == "Hello")
        #expect(r.platform.package == "hello-mobile")
    }

    @Test func macosUsesOwnBundleID() throws {
        let dir = try repo(["Cargo.toml": "[package]\nname = \"hello\"\nversion = \"1.4.0\"\n"])
        let r = try CargoProject.resolve(overlay: overlay(), platform: .macos, source: dir)
        let c = r.config
        #expect(try c.platform(.macos).bundleID == "com.example.hello.mac")
        #expect(c.bundleID(for: .macos) == "com.example.hello.mac")
        #expect(c.distribution(for: .macos) == .developerID)
        #expect(c.build == "1.4.0.200001010000")
        #expect(c.assets == nil)             // icon-only build
        #expect(c.privacyManifest == nil)
        #expect(c.testflight == nil)
        #expect(try c.platform(.macos).entitlements == "mac.entitlements")
        #expect(c.platforms.count == 1)
    }

    @Test func macosDistributionOverrideReachesTheResolvedConfig() throws {
        let dir = try repo(["Cargo.toml": "[package]\nname = \"hello\"\nversion = \"1.4.0\"\n"])
        let r = try CargoProject.resolve(overlay: overlay(), platform: .macos, source: dir, distribution: .appStore)
        #expect(r.config.distribution(for: .macos) == .appStore)
        let kept = try CargoProject.resolve(overlay: overlay(), platform: .macos, source: dir, distribution: nil)
        #expect(kept.config.distribution(for: .macos) == .developerID)
        #expect(kept.config.testflight == nil)                                  // a DMG has no TestFlight
        #expect(r.config.testflight?.groups == ["Internal"])                    // the lane delivers to the overlay's groups
    }

    @Test func iosRefusesADeveloperIDOverride() throws {
        let dir = try repo(["Cargo.toml": "[package]\nname = \"hello-mobile\"\nversion = \"1.4.0\"\n"])
        expectConfig(containing: ["developer-id"]) {
            _ = try CargoProject.resolve(overlay: overlay(), platform: .ios, source: dir, distribution: .developerID)
        }
    }

    @Test func missingPlatformBlockIsAConfigError() throws {
        let ios = try CargoOverlay.parse(yaml: """
        type: cargo
        bundleID: com.example.hello
        teamID: ABCDE12345
        version: "1.0.0"
        ios: { package: hello-mobile, product: Hello, minimumOS: "17.0", assets: A.xcassets }
        """, name: "hello")
        expectConfig(containing: ["macos"]) {
            _ = try CargoProject.resolve(overlay: ios, platform: .macos, source: URL(fileURLWithPath: "/nonexistent"))
        }
    }

    @Test func manifestReaderIgnoresOtherTablesAndComments() {
        let info = CargoManifest.parse("""
        # version = "9.9.9"
        [package]
        name = "app" # the app
        edition = "2021"
        version = "1.0.0" # not "2.0.0"
        [dependencies]
        version = "8.8.8"
        name = "other"
        [dependencies.foo]
        version = "7.7.7"
        [[bin]]
        name = "bin"
        """)
        #expect(info.name == "app")
        #expect(info.version == .literal("1.0.0"))
        #expect(!info.isWorkspace)
        #expect(info.workspaceVersion == nil)
    }
}
