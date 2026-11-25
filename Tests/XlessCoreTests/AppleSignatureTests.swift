#if os(macOS)
import Foundation
import Testing
@testable import XlessCore

@Test func aProgramOfApplesIsTheOneItIsSignedAs() {
    #expect(AppleSignature.problem(program: "/bin/ls", identifier: "com.apple.ls") == nil)
    #expect(AppleSignature.problem(program: "/bin/ls", identifier: nil) == nil)
    // Apple's shell in the place of its actool would run what it is given
    #expect(AppleSignature.problem(program: "/bin/sh", identifier: "com.apple.actool") == "/bin/sh is not signed by Apple as com.apple.actool")
    #expect(AppleSignature.problem(program: "/nowhere", identifier: nil) == "/nowhere is no program")
}

@Test func onlyAppleItselfSignsAProgramOfApples() {
    // (`anchor apple generic` is everybody with a Developer ID, too)
    #expect(AppleSignature.programRequirement(identifier: nil) == "anchor apple")
    #expect(AppleSignature.programRequirement(identifier: "com.apple.ls") == #"identifier "com.apple.ls" and anchor apple"#)
}

@Test func everyArchitectureOfAProgramIsLookedAt() throws {
    let whole = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls")), changed = FileManager.default.temporaryDirectory.appendingPathComponent("xless-signature-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: changed) }
    func number(_ at: Int) -> Int { whole[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    try #require(number(0) == 0xcafebabe && number(4) > 1, "/bin/ls has one architecture")
    for slice in 0..<number(4) {
        let (offset, size) = (number(8 + slice * 20 + 8), number(8 + slice * 20 + 12))
        var bytes = whole
        bytes[offset + size / 2] ^= 0xff
        try bytes.write(to: changed)
        #expect(AppleSignature.problem(program: changed.path, identifier: "com.apple.ls") == "\(changed.path) is not signed by Apple as com.apple.ls", "slice \(slice)")
    }
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
    #expect(AppleSignature.problem(program: own.path, identifier: "com.apple.ls") == "\(own.path) is not signed by Apple as com.apple.ls")
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
