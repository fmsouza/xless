import Testing
import Foundation
@testable import XlessSign
@testable import XlessCore

/// Its configuration file would be the build's: `rcodesign.toml` of the directory it runs in.
@Suite struct RCodesignConfigurationTests {
    @Test func itReadsNoConfigurationFileAndRunsWhereNoBuildWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rcodesign-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("rcodesign")
        try ExecutableFile.write(Data("#!/bin/sh\npwd\nprintf '%s\\n' \"$@\"\n".utf8), to: fake, stage: .sign)
        let said = try RCodesign.run(["sign", "--pem-file", "/k.pem", "/b/X.app"], program: fake.path, stage: .sign).stdout
        #expect(said == "/\nsign\n-C\n/dev/null\n--pem-file\n/k.pem\n/b/X.app\n")
    }

    /// On a Mac it is a file of xless's own (MacSigner), whatever PATH says.
    @Test func theOneThatIsUsedIsStartedByItsPath() {
        #expect(RCodesign.program == "rcodesign")
        let chosen = RCodesign.Choice()
        chosen.use(URL(fileURLWithPath: "/x/rcodesign"))
        #expect(chosen.program == "/x/rcodesign")
    }

    /// Every step that has a secret starts it that way. (A simulator build's, which signs ad hoc without one, is a build step.)
    @Test func nothingElseStartsIt() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardizedFileURL
        var direct: [String] = []
        for case let file as URL in try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)) where file.pathExtension == "swift" {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") where ["Shell.run(\"rcodesign\"", "[\"rcodesign\"]", "[RCodesign.program]"].contains(where: line.contains) {
                if !line.contains("RCodesign.arguments(") { direct.append(file.lastPathComponent) }
            }
        }
        #expect(direct == ["SimulatorBuild.swift"])
    }
}

private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

@Test func appStoreSigningDisablesTimestamp() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .appStore)
    #expect(a.first == "sign")
    #expect(a.contains("--pem-file") && a.contains("/k.pem") && a.contains("/c.pem"))
    #expect(a.contains("--entitlements-xml-file") && a.contains("/e.plist"))
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--timestamp-url", "none") })
    #expect(!a.contains("--for-notarization"))
    #expect(a.last == "/b/X.app")
}

@Test func developerIDUsesHardenedRuntimeAndTimestamp() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .developerID)
    #expect(a.contains("--for-notarization"))
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "runtime") })
    #expect(!a.contains("none"))
}

@Test func notarizeArguments() {
    #expect(RCodesign.notarizeArguments(bundle: u("/X.app"), apiKeyJSON: u("/k.json"))
            == ["notary-submit", "--api-key-file", "/k.json", "--max-wait-seconds", "3600", "--staple", "/X.app"])
}

@Test func encodeKeyArguments() {
    #expect(RCodesign.encodeKeyArguments(issuerID: "I", keyID: "K", p8: u("/a.p8"), out: u("/o.json"))
            == ["encode-app-store-connect-api-key", "-o", "/o.json", "I", "K", "/a.p8"])
}

/// rcodesign applies an unscoped --code-signature-flags to the main executable only; every other Mach-O that must carry
/// the hardened runtime is named with a path-scoped flag.
@Test func developerIDScopesTheRuntimeFlagToNestedMachOs() {
    let a = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .developerID,
                                    runtimePaths: ["Contents/Resources/lib.dylib", "Contents/Frameworks/libx.dylib"])
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "Contents/Resources/lib.dylib:runtime") })
    #expect(zip(a, a.dropFirst()).contains { $0 == ("--code-signature-flags", "Contents/Frameworks/libx.dylib:runtime") })
    #expect(a.last == "/b/X.app")
    let store = RCodesign.signArguments(bundle: u("/b/X.app"), keyPEM: u("/k.pem"), certPEM: u("/c.pem"), entitlements: u("/e.plist"), distribution: .appStore,
                                        runtimePaths: ["Contents/Resources/lib.dylib"])
    #expect(!store.contains { $0.hasSuffix(":runtime") })
}

/// The Mach-O images of a macOS bundle that get a path-scoped runtime flag: all but the main executable.
@Test func findsHardenedRuntimePaths() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("loose-\(UUID())/X.app")
    let image = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(count: 28)
    for (path, data) in [("Contents/MacOS/X", image), ("Contents/Resources/lib/a.dylib", image), ("Contents/Resources/notes.txt", Data("t".utf8)),
                         ("Contents/Frameworks/libx.dylib", image), ("Contents/Frameworks/Y.framework/Versions/A/Y", image),
                         ("Contents/Resources/static.a", Data("!<arch>\n".utf8))] {
        let url = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    // Loose Mach-Os and the binaries inside nested bundles, by their real path (not via symlinks); no non-Mach-O files.
    let resources = app.appendingPathComponent("Contents/Resources/Assets.bundle/Contents/Resources/a.txt")
    try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("t".utf8).write(to: resources)
    try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Frameworks/Y.framework/Y").path, withDestinationPath: "Versions/A/Y")
    #expect(try RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "Contents/MacOS/X")
            == ["Contents/Frameworks/Y.framework/Versions/A/Y", "Contents/Frameworks/libx.dylib", "Contents/Resources/lib/a.dylib"])
}

/// `--code-signature-flags <path>:runtime` is read by rcodesign's rules: a scope ends at the first colon, `@0` is a slice, and a path
/// that starts with a hyphen is an option.
@Test func aMachOWhosePathIsNoScopeIsRefused() throws {
    try RCodesign.requireScopes(["Contents/Resources/a.dylib", "Contents/Resources/node_modules/@scope/a@2x.node", "Contents/a-b c.dylib", "Contents/-x"])
    for path in ["Contents/a:b.dylib", "-x", "--pem-file", "Contents/a@0", "Contents/a@12", "Contents/a@[cpu_type=12]", "@0", "@main"] {
        #expect { try RCodesign.requireScopes(["Contents/ok", path]) } throws: { ($0 as? XlessError)?.stage == .sign && "\($0)".contains(path) }
    }
}

@Test func theRuntimePathsOfAnAppAreScopes() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("scopes-\(UUID())/X.app")
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try miniMachO(filetype: 6).write(to: app.appendingPathComponent("Contents/a.dylib"))
    #expect(try RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "") == ["Contents/a.dylib"])
    try miniMachO(filetype: 6).write(to: app.appendingPathComponent("Contents/a:b.dylib"))
    #expect(throws: XlessError.self) { try RCodesign.hardenedRuntimePaths(in: app, mainExecutable: "") }
}
