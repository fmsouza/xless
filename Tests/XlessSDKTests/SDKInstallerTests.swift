import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private func executable(_ url: URL, _ script: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ExecutableFile.write(script, to: url, stage: .sdk)
}

@Test func theToolchainGoesFirstOnPath() {
    let tc = URL(fileURLWithPath: "/n/toolchains/swift-6.4.0")
    #expect(SDKInstaller.path(toolchain: tc, env: ["PATH": "/usr/bin:/bin"]) == "/n/toolchains/swift-6.4.0/usr/bin:/usr/bin:/bin")
    #expect(SDKInstaller.path(toolchain: tc, env: [:]) == "/n/toolchains/swift-6.4.0/usr/bin:/usr/local/bin:/usr/bin:/bin")
}

/// A pack's Swift toolchain is on no PATH while the pack is prepared; xtool's `sdk install` runs `swiftc` from PATH, so it
/// must find the pack's (a fresh machine has no other).
@Test func xtoolFindsThePacksToolchainOnItsPath() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("xless-sdkinstaller-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let toolchain = tmp.appendingPathComponent("pack.partial/toolchain")
    try executable(toolchain.appendingPathComponent("usr/bin/swiftc"), "#!/bin/sh\necho 'Swift version 6.4'\n")
    let seen = tmp.appendingPathComponent("swiftc-seen")
    // As xtool: refuses without swiftc on PATH; else installs the SDK under $XDG_CONFIG_HOME.
    let xtool = tmp.appendingPathComponent("bin/xtool")
    try executable(xtool, """
        #!/bin/sh
        s="$(command -v swiftc)" || { echo "Could not find executable 'swiftc' in PATH" >&2; exit 1; }
        echo "$s" > '\(seen.path)'
        mkdir -p "$XDG_CONFIG_HOME/swiftpm/swift-sdks/darwin.artifactbundle"
        """)
    // A PATH holding only mkdir: a host's own swiftc (/usr/bin/swiftc on a Mac or in the Swift image) stays out of it.
    let sysbin = tmp.appendingPathComponent("sysbin")
    try fm.createDirectory(at: sysbin, withIntermediateDirectories: true)
    let mkdir = try #require(["/bin/mkdir", "/usr/bin/mkdir"].first { fm.isExecutableFile(atPath: $0) })
    try fm.createSymbolicLink(atPath: sysbin.appendingPathComponent("mkdir").path, withDestinationPath: mkdir)
    let env = ["HOME": tmp.appendingPathComponent("home").path, "PATH": sysbin.path]
    let config = tmp.appendingPathComponent("pack.partial/config"), xtoolsdk = tmp.appendingPathComponent("darwin.xtoolsdk")

    // Without the pack's toolchain, xtool finds no swiftc (the bug a fresh machine hit).
    #expect(throws: XlessError.self) {
        try PackPlan.installSDK(xtoolSDK: xtoolsdk, config: config, toolchain: tmp.appendingPathComponent("nowhere"), xtool: xtool.path, env: env)
    }
    try PackPlan.installSDK(xtoolSDK: xtoolsdk, config: config, toolchain: toolchain, xtool: xtool.path, env: env)
    #expect(try String(contentsOf: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            == toolchain.appendingPathComponent("usr/bin/swiftc").path)
    #expect(fm.fileExists(atPath: config.appendingPathComponent("swiftpm/swift-sdks/darwin.artifactbundle").path))
}
