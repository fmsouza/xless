import Testing
import Foundation
@testable import XlessSDK
@testable import XlessCore

private func executable(_ url: URL, _ script: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Test func theToolchainGoesFirstOnPath() {
    let tc = URL(fileURLWithPath: "/n/toolchains/swift-6.4.0")
    #expect(SDKInstaller.path(toolchain: tc, env: ["PATH": "/usr/bin:/bin"]) == "/n/toolchains/swift-6.4.0/usr/bin:/usr/bin:/bin")
    #expect(SDKInstaller.path(toolchain: tc, env: [:]) == "/n/toolchains/swift-6.4.0/usr/bin:/usr/local/bin:/usr/bin:/bin")
}

/// A native setup installs the Swift toolchain into a directory on no PATH; xtool's `sdk install` runs `swiftc` from
/// PATH, so it must find that toolchain's (a fresh machine has no other).
@Test func xtoolFindsTheSetupsToolchainOnItsPath() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("xless-sdkinstaller-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    let toolchain = tmp.appendingPathComponent("toolchains/swift-6.4.0")
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
    let meta = tmp.appendingPathComponent("toolchain-meta.json")
    try ToolchainMeta(xcodeVersion: "2700", xcodeBuild: "27A266a", buildMachineOSBuild: "26A100", compiler: ToolchainMeta.clangCompiler,
                      platforms: [:]).write(to: meta)
    // A PATH holding only mkdir: a host's own swiftc (/usr/bin/swiftc on a Mac or in the Swift image) stays out of it.
    let sysbin = tmp.appendingPathComponent("sysbin")
    try fm.createDirectory(at: sysbin, withIntermediateDirectories: true)
    let mkdir = try #require(["/bin/mkdir", "/usr/bin/mkdir"].first { fm.isExecutableFile(atPath: $0) })
    try fm.createSymbolicLink(atPath: sysbin.appendingPathComponent("mkdir").path, withDestinationPath: mkdir)
    let home = tmp.appendingPathComponent("home")
    let env = ["HOME": home.path, "PATH": sysbin.path, "XLESS_TOOLCHAIN_META": home.appendingPathComponent("meta.json").path]
    let xtoolsdk = tmp.appendingPathComponent("darwin.xtoolsdk")

    // Without the toolchain, xtool finds no swiftc (the bug a fresh machine hit).
    #expect(throws: XlessError.self) { try SDKInstaller.install(xtoolsdk: xtoolsdk, meta: meta, xtool: xtool.path, env: env) }

    let at = try SDKInstaller.install(xtoolsdk: xtoolsdk, meta: meta, xtool: xtool.path, toolchain: toolchain, env: env)
    #expect(try String(contentsOf: seen, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            == toolchain.appendingPathComponent("usr/bin/swiftc").path)
    #expect(at.sdk.path == home.appendingPathComponent(".swiftpm/swift-sdks/darwin.artifactbundle").path)
    #expect(fm.fileExists(atPath: at.sdk.path) && fm.fileExists(atPath: at.meta.path))
}
