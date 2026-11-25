import Foundation
import Testing
@testable import XlessCore

private func xcode(with tools: [String]) throws -> InstalledXcode {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("xless-tools-\(UUID().uuidString)/Xcode.app")
    let xcode = InstalledXcode(app: app, version: "27.2", build: "27B52", source: "installed")
    let bin = xcode.developer.appendingPathComponent("usr/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for tool in tools { try ExecutableFile.write("#!/bin/sh\n", to: bin.appendingPathComponent(tool), stage: .assets) }
    return xcode
}

@Test func xcodesToolsAreUsedWhereTheyAre() throws {
    let xcode = try xcode(with: ["actool"])
    defer { try? FileManager.default.removeItem(at: xcode.app.deletingLastPathComponent()) }
    for setting in [nil, "", " "] {
        let tools = try NativeTools(setting: setting)
        #expect(try tools.program(.actool, of: xcode, stage: .assets)?.lastPathComponent == "actool")
        #expect(try tools.program(.ibtool, of: xcode, stage: .assets) == nil)
        #expect(tools.summary(of: xcode) == "actool: Xcode's; ibtool: xless's own")
    }
}

@Test func eitherCanBeForced() throws {
    let xcode = try xcode(with: ["actool"])
    defer { try? FileManager.default.removeItem(at: xcode.app.deletingLastPathComponent()) }
    let own = try NativeTools(setting: "xless")
    #expect(try own.program(.actool, of: xcode, stage: .assets) == nil)
    #expect(own.summary(of: xcode) == "actool and ibtool: xless's own")
    // a forced one that is missing is an error, never the other
    #expect(throws: XlessError.self) { try NativeTools(setting: "xcode").program(.ibtool, of: xcode, stage: .assets) }
    let mixed = try NativeTools(setting: "xcode, actool=xless")
    #expect(mixed.forced == [.actool: .xless, .ibtool: .xcode])
}

@Test func anUnknownToolIsRefused() {
    for setting in ["apple", "ld=xless", "actool", "actool=", "=xless", "actool=xcode=xless"] {
        #expect(throws: XlessError.self, "\(setting)") { try NativeTools(setting: setting) }
    }
}
