#if os(macOS)
import Foundation
import Testing
@testable import XlessCore

@Test func aProgramOfApplesIsTheOneItIsSignedAs() {
    #expect(AppleSignature.problem(program: "/bin/ls", identifier: "com.apple.ls") == nil)
    #expect(AppleSignature.problem(program: "/bin/ls", identifier: nil) == nil)
    // Apple's shell in the place of its actool would run what it is given
    #expect(AppleSignature.problem(program: "/bin/sh", identifier: "com.apple.actool") == "/bin/sh is not signed by Apple")
}

@Test func whatIsNotApplesProgramIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xless-signature-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("actool"), own = root.appendingPathComponent("own"), changed = root.appendingPathComponent("changed")
    try ExecutableFile.write(Data("#!/bin/sh\n".utf8), to: script, stage: .build)
    #expect(AppleSignature.problem(program: script.path, identifier: nil) == "\(script.path) is no program")
    #expect(AppleSignature.problem(program: root.path, identifier: nil) == "\(root.path) is no program")
    #expect(AppleSignature.problem(program: root.path + "/none", identifier: nil) != nil)
    // Apple's, signed by anybody; and with a changed byte
    try FileManager.default.copyItem(atPath: "/bin/ls", toPath: own.path)
    #expect(AppleSignature.problem(program: own.path, identifier: "com.apple.ls") == nil) // (a copy is Apple's still)
    try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.apple.ls", own.path], stage: .build)
    #expect(AppleSignature.problem(program: own.path, identifier: "com.apple.ls") == "\(own.path) is not signed by Apple")
    var bytes = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"))
    for at in stride(from: bytes.count / 8, to: bytes.count, by: bytes.count / 8) { bytes[at] ^= 0xff }
    try bytes.write(to: changed)
    #expect(AppleSignature.problem(program: changed.path, identifier: nil) != nil)
}

@Test func anotherAppOfApplesIsNoXcode() {
    for app in ["/System/Applications/Calculator.app", "/nowhere/Xcode.app"] { #expect(AppleSignature.problem(xcode: app) == "\(app) is not signed by Apple") }
    #expect(AppleSignature.xcodeRequirement.hasPrefix(#"identifier "com.apple.dt.Xcode" and "#))
}
#endif
