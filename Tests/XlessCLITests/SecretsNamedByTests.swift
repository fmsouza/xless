import ArgumentParser
import Foundation
import Testing
import XlessCore
@testable import xless

/// `xless secrets named-by`: what scripts/testflight.sh gives the container that uploads besides the keys.
private struct Files {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xless-named-by-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func review(_ demo: String) -> String {
    """
    testflight:
      whatToTest: Try it
      external:
        groups: [Beta]
        review:
          demoAccount: \(demo)
    """
}

@Test func anXlessYmlNamesTheDemoPasswordSecretItsUploadReads() throws {
    let f = try Files()
    defer { f.cleanup() }
    let yml = """
    bundleID: app.example.helloship
    teamID: ABCDE12345
    version: 1.0.0
    build: 7
    platforms:
      ios: { minimumOS: "17.0", product: HelloShip }

    """
    _ = try f.write("xless.yml", yml + review("{name: demo, required: true}"))
    #expect(try RunSecretNames.upload(config: nil, project: f.dir, platform: .ios) == ["XLESS_DEMO_PASSWORD"])
    _ = try f.write("xless.yml", yml + review("{name: demo, passwordSecret: MY_REVIEW_PW@ABCDE12345}"))
    #expect(try RunSecretNames.upload(config: nil, project: f.dir, platform: .ios) == ["MY_REVIEW_PW@ABCDE12345"])
    _ = try f.write("xless.yml", yml + review("{name: demo, passwordSecret: MY_REVIEW_PW, required: false}"))
    #expect(try RunSecretNames.upload(config: nil, project: f.dir, platform: .ios) == [])
    _ = try f.write("xless.yml", yml)
    #expect(try RunSecretNames.upload(config: nil, project: f.dir, platform: .ios) == [])
    // a broken xless.yml is an error (the script then carries on with a note; the run reports it)
    _ = try f.write("xless.yml", "teamID: ABCDE12345\n")
    #expect(throws: XlessError.self) { try RunSecretNames.upload(config: nil, project: f.dir, platform: .ios) }
}

@Test func anOverlayNamesItForThePlatformsWhoseUploadPublishesToTestFlight() throws {
    let f = try Files()
    defer { f.cleanup() }
    let demo = review("{name: demo, passwordSecret: MY_REVIEW_PW, required: true}")
    let tauri = try f.write("tauri.yml", "type: tauri\nsource: app\nbundleID: com.example.app\nteamID: ABCDE12345\nbuild: dated\n" + demo)
    #expect(try RunSecretNames.upload(config: tauri, project: nil, platform: .ios) == ["MY_REVIEW_PW"])
    #expect(try RunSecretNames.upload(config: tauri, project: nil, platform: .macos) == [])   // a DMG: no TestFlight
    let cargo = try f.write("cargo.yml", """
    type: cargo
    source: app
    bundleID: com.example.hello
    teamID: ABCDE12345
    version: "1.0.0"
    build: dated
    ios: { package: hello-mobile, product: Hello, minimumOS: "17.0", assets: Assets.xcassets, infoPlist: ios/Info.plist }
    macos: { bundleID: com.example.hello.mac, package: hello, product: Hello, minimumOS: "11.0", icon: hello.icns }

    """ + demo)
    #expect(try RunSecretNames.upload(config: cargo, project: nil, platform: .ios) == ["MY_REVIEW_PW"])
    #expect(try RunSecretNames.upload(config: cargo, project: nil, platform: .macos) == ["MY_REVIEW_PW"])   // the App-Store lane
    let rn = try f.write("rn.yml", "type: react-native\nscheme: A\nbundleIDs: { App: com.example.a }\nteamID: ABCDE12345\nbuild: 7\n" + demo)
    #expect(try RunSecretNames.upload(config: rn, project: nil, platform: .ios) == ["MY_REVIEW_PW"])
    let plain = try f.write("plain.yml", "type: tauri\nsource: app\nbundleID: com.example.app\nteamID: ABCDE12345\nbuild: dated\n")
    #expect(try RunSecretNames.upload(config: plain, project: nil, platform: .ios) == [])
}

@Test func namedByTakesAnOverlayOrAProjectDirectory() throws {
    #expect(throws: (any Error).self) { try SecretsNamedByCommand.parse([]) }
    #expect(throws: (any Error).self) { try SecretsNamedByCommand.parse(["--config", "a.yml", "--project", "."]) }
    #expect(try SecretsNamedByCommand.parse(["--config", "a.yml", "--platform", "macos"]).platform == .macos)
}
