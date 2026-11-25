import Foundation
import Testing
import XlessCore
import XlessTauri
@testable import XlessXcode

/// In-image check (xless's image, gated on XLESS_SWBUILD_IT): samples/HelloPIF, asset catalog included, through the PIF
/// writer, the stock `swbuild` and the image's Xcode tool shims (`actool` on PATH, no stand-in), compared with the Mac
/// reference with no allowed gaps: `Assets.car`, the loose icons and the `CFBundleIcons` keys must all be there.
///
///   docker --context colima-xless run --rm -v "$PWD":/repo -v xless-m3-t6:/scratch -w /repo -e XLESS_SWBUILD_IT=1 \
///     xless:local-arm64-xcode27.0 swift test --scratch-path /scratch/build --filter helloPIFWithAssetCatalogMatchesTheMacReference
@Test(.enabled(if: ProcessInfo.processInfo.environment["XLESS_SWBUILD_IT"] != nil))
func helloPIFWithAssetCatalogMatchesTheMacReference() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sample = repo.appendingPathComponent("samples/HelloPIF")
    let bundle = "/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle"
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("hellopif-it-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let ws = try XcodeWorkspace.load(sample.appendingPathComponent("HelloPIF.xcodeproj"))
    let pif = try PIFWriter.write(ws, to: work)
    // The gate-G2 overrides (docs/research/react-native-ios-contract.md, settings table).
    let request = try BuildRequest.make(workspace: ws, scheme: ws.scheme(named: "HelloPIF"), configuration: "Release", overrides: [
        "SWIFT_SDK_TOOLSETS": "\(bundle)/toolset-swb.json", "CODE_SIGNING_ALLOWED": "NO", "LM_SKIP_METADATA_EXTRACTION": "YES",
        "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO", "STRIP_BITCODE_FROM_COPIED_FILES": "NO", "SWIFT_STDLIB_TOOL_STRIP_BITCODE": "NO",
    ])
    let requestURL = work.appendingPathComponent("request.json")
    try request.write(to: requestURL)

    let dd = work.appendingPathComponent("dd")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swbuild", "build", pif.path, "--derivedDataPath", dd.path, "--buildRequestFile", requestURL.path]
    var env = ProcessInfo.processInfo.environment
    env["SDKROOT"] = nil
    env["XCODE_EXTRA_PLATFORM_FOLDERS"] = "\(bundle)/Developer/Platforms"
    env["PATH"] = "\(bundle)/toolset/bin:" + (env["PATH"] ?? "")
    p.environment = env
    let log = work.appendingPathComponent("swbuild.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    p.standardOutput = handle
    p.standardError = handle
    try p.run()
    p.waitUntilExit()
    try handle.close()
    let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
    try #require(p.terminationStatus == 0, "swbuild failed:\n\(output.suffix(4000))")
    // The real shim ran: Swift Build's asset tasks went through it, not a stand-in.
    #expect(output.contains("CompileAssetCatalogVariant thinned"))
    #expect(output.contains("GenerateAssetSymbols"))

    let app = dd.appendingPathComponent("Products/Release-iphoneos/HelloPIF.app")
    let reference = try JSONDecoder().decode(BundleReport.self, from: Data(contentsOf: sample.appendingPathComponent("reference/reference.json")))
    let allowed = BundleReport.parseAllow(try String(contentsOf: sample.appendingPathComponent("reference/allowed-gaps.txt"), encoding: .utf8))
    for key in ["file:Assets.car", "file:AppIcon60x60@2x.png", "file:AppIcon76x76@2x~ipad.png", "plist:CFBundleIcons", "plist:CFBundleIcons~ipad"] {
        #expect(!allowed.contains(key), "\(key) must not be an allowed gap any more")
    }
    let actual = try BundleReport.make(app: app)
    #expect(BundleReport.diff(reference: reference, actual: actual, allowed: allowed) == [])
    #expect(actual.files.contains("Assets.car"))
    #expect(actual.infoPlist["CFBundleIcons"] == reference.infoPlist["CFBundleIcons"])
    #expect(actual.infoPlist["CFBundleIcons~ipad"] == reference.infoPlist["CFBundleIcons~ipad"])
    // The asset-symbols file's imports keep the SwiftUI overlay chain linked (libswiftCoreAudio, gate G2).
    #expect(actual.executable.linkedLibraries.contains("/usr/lib/swift/libswiftCoreAudio.dylib"))
}
