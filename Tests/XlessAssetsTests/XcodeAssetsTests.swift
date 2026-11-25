import Foundation
import Testing
@testable import XlessAssets
@testable import XlessCore

/// Stand-ins for Xcode's actool and ibtool: they write down their arguments, and an output each. (`partial`: actool's Info.plist.)
private struct Tools {
    let dir: URL
    var assets: XcodeAssets

    init(partial: String = "<key>CFBundleIcons</key><dict/>", actool: Bool = true, ibtool: Bool = true, simulator: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-xcassets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let act = dir.appendingPathComponent("actool"), ib = dir.appendingPathComponent("ibtool")
        try ExecutableFile.write("""
        #!/bin/sh
        printf '%s\\n' "$DEVELOPER_DIR" "$@" > '\(dir.path)/actool.args'
        out= plist=
        while [ $# -gt 0 ]; do
          case $1 in --compile) out=$2 ;; --output-partial-info-plist) plist=$2 ;; esac
          shift
        done
        echo car > "$out/Assets.car"
        printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict>\(partial)</dict></plist>' > "$plist"
        """, to: act, stage: .assets)
        try ExecutableFile.write("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(dir.path)/ibtool.args'
        mkdir "$2" && echo nib > "$2/x.nib"
        """, to: ib, stage: .assets)
        assets = XcodeAssets(actool: actool ? act : nil, ibtool: ibtool ? ib : nil, environment: ["DEVELOPER_DIR": "/X/Contents/Developer"], simulator: simulator)
    }

    func arguments(_ tool: String) throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("\(tool).args"), encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

private func app(_ platform: Platform, info: [String: Any]) throws -> URL {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("xless-in-\(UUID())/X.app")
    let layout = BundleLayout(platform: platform)
    let resources = layout.resourcesDir.isEmpty ? app : app.appendingPathComponent(layout.resourcesDir)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Plist.write(["CFBundleExecutable": "X"].merging(info) { $1 }, to: app.appendingPathComponent(layout.infoPlist), stage: .assets)
    return app
}

private func config(_ platforms: String, _ rest: String) throws -> ProjectConfig {
    try ProjectConfig.parse(yaml: "bundleID: a.b\nteamID: ABCDE12345\nversion: \"1\"\nbuild: 1\nplatforms:\n  \(platforms)\n\(rest)\n")
}

private let ios = #"ios: { minimumOS: "17.0", product: X }"#, mac = #"macos: { minimumOS: "14.0", product: X, distribution: developer-id }"#
private func noProfile() throws -> XcodeToolsProfile { throw XlessError(.assets, "asked for a profile", fix: "") }

@Test func xcodesActoolCompilesAnIOSCatalog() async throws {
    let tools = try Tools(), catalog = try catalog(icon: fakePNG(1024, colorType: 2))
    defer { try? FileManager.default.removeItem(at: tools.dir) }
    let app = try app(.ios, info: ["UIDeviceFamily": [1], "CFBundleIconFile": "old"])
    try await AssetsStage.compile(into: app, platform: .ios, config: config(ios, "assets: \(catalog.path)"), project: URL(fileURLWithPath: "/"), xcode: tools.assets, profile: noProfile)
    let arguments = try tools.arguments("actool")
    #expect(arguments.prefix(8) == ["/X/Contents/Developer", catalog.path, "--compile", app.path, "--platform", "iphoneos", "--minimum-deployment-target", "17.0"])
    #expect(arguments[8...].prefix(4) == ["--target-device", "iphone", "--app-icon", "AppIcon"])
    #expect(FileManager.default.fileExists(atPath: app.path + "/Assets.car"))
    let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .assets)
    #expect(info["CFBundleIcons"] != nil && info["CFBundleIconFile"] == nil)
}

@Test func anIconWithAlphaIsRefusedWithXcodesActoolToo() async throws {
    let catalog = try catalog(icon: fakePNG(1024, colorType: 6)), config = try config(ios, "assets: \(catalog.path)")
    for simulator in [false, true] {
        let tools = try Tools(simulator: simulator)
        defer { try? FileManager.default.removeItem(at: tools.dir) }
        var refused = false
        do {
            try await AssetsStage.compile(into: app(.ios, info: [:]), platform: .ios, config: config, project: URL(fileURLWithPath: "/"), xcode: tools.assets, profile: noProfile)
        } catch let e as XlessError { refused = e.cause.contains("alpha") }
        #expect(refused == !simulator)
        #expect(try tools.arguments("actool").contains(simulator ? "iphonesimulator" : "iphoneos"))
    }
}

@Test func aMacCatalogKeepsXlesssIconWhereActoolMakesNone() async throws {
    let catalog = try catalog(icon: fakePNG(1024, colorType: 2)), config = try config(mac, "assets: \(catalog.path)")
    for (partial, ours) in [("", true), ("<key>CFBundleIconFile</key><string>AppIcon</string>", false)] {
        let tools = try Tools(partial: partial)
        defer { try? FileManager.default.removeItem(at: tools.dir) }
        let app = try app(.macos, info: [:])
        try await AssetsStage.compile(into: app, platform: .macos, config: config, project: URL(fileURLWithPath: "/"), xcode: tools.assets, profile: noProfile)
        #expect(FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/Assets.car"))
        #expect(FileManager.default.fileExists(atPath: app.path + "/Contents/Resources/AppIcon.icns") == ours)
        #expect(try Plist.read(app.appendingPathComponent("Contents/Info.plist"), stage: .assets)["CFBundleIconFile"] as? String == "AppIcon")
        #expect(try tools.arguments("actool").contains("macosx") && tools.arguments("actool").contains("mac"))
    }
}

@Test func xcodesIbtoolCompilesTheLaunchStoryboard() async throws {
    let tools = try Tools(), storyboard = tools.dir.appendingPathComponent("Launch.storyboard")
    defer { try? FileManager.default.removeItem(at: tools.dir) }
    try Data().write(to: storyboard)
    let app = try app(.ios, info: ["UILaunchScreen": [String: Any]()])
    try LaunchStoryboard.compile(storyboard, into: app, minimumOS: "17.0", xcode: tools.assets, profile: noProfile)
    #expect(try tools.arguments("ibtool").prefix(4) == ["--compile", app.path + "/Launch.storyboardc", storyboard.path, "--minimum-deployment-target"])
    #expect(FileManager.default.fileExists(atPath: app.path + "/Launch.storyboardc/x.nib"))
    let info = try Plist.read(app.appendingPathComponent("Info.plist"), stage: .assets)
    #expect(info["UILaunchStoryboardName"] as? String == "Launch" && info["UILaunchScreen"] == nil)
}

@Test func withoutThemXlesssOwnToolsDoTheWork() async throws {
    let tools = try Tools(actool: false, ibtool: false)
    defer { try? FileManager.default.removeItem(at: tools.dir) }
    let catalog = try helloShipLikeCatalog()
    let app = try app(.ios, info: ["UIDeviceFamily": [1, 2]])
    try await AssetsStage.compile(into: app, platform: .ios, config: config(ios, "assets: \(catalog.path)"), project: URL(fileURLWithPath: "/"), xcode: tools.assets, profile: testProfile())
    #expect(FileManager.default.fileExists(atPath: app.path + "/Assets.car"))
    #expect(!FileManager.default.fileExists(atPath: tools.dir.path + "/actool.args"))
}
