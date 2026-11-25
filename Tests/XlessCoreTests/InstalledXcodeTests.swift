import Foundation
import Testing
@testable import XlessCore

/// Xcodes made for a test, in a directory of its own, and what the machine would say of them.
private final class Machine {
    let root: URL
    var environment: [String: String] = [:]
    var selected: String?
    var genuine: Set<String>? // names of the .app; nil: all are

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("xless-xcodes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        root = URL(fileURLWithPath: realpath(made.path, nil).map { String(cString: $0) } ?? made.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func xcode(_ name: String, _ version: String, _ build: String, in directory: String = "Applications") throws -> URL {
        let app = root.appendingPathComponent("\(directory)/\(name).app")
        let bin = app.appendingPathComponent("Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin")
        let others = app.appendingPathComponent("Contents/Developer/usr/bin")
        for directory in [bin, others, bin.deletingLastPathComponent().appendingPathComponent("lib"), app.appendingPathComponent("Contents/SharedFrameworks")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        for file in [bin.appendingPathComponent("swift"), bin.appendingPathComponent("clang"), others.appendingPathComponent("actool")] { try Data().write(to: file) }
        // any umask
        var at = app
        while at.path.count > root.path.count {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: at.path)
            at.deleteLastPathComponent()
        }
        for path in try FileManager.default.subpathsOfDirectory(atPath: app.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path + "/" + path)
        }
        try Plist.write(["CFBundleShortVersionString": version, "ProductBuildVersion": build], to: app.appendingPathComponent("Contents/version.plist"), stage: .sdk)
        return app
    }

    var finder: XcodeFinder {
        XcodeFinder(environment: environment, selected: { self.selected }, applications: [root.appendingPathComponent("Applications")],
                    isGenuine: { xcode in
                        guard let genuine = self.genuine, !genuine.contains(xcode.app.lastPathComponent) else { return nil }
                        return "its signature is not Apple's"
                    })
    }
}

private func failure(_ body: () throws -> Void) -> XlessError? {
    do { try body() } catch { return error as? XlessError }
    return nil
}

@Test func xcodeSelectsXcodeIsUsed() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    try machine.xcode("Xcode-28", "28.0", "28A1")
    machine.selected = app.path + "/Contents/Developer"
    let found = try machine.finder.find(pin: nil, stage: .build)
    #expect(found.app.path == app.path && found.version == "27.2" && found.build == "27B52" && found.source == "xcode-select")
    #expect(found.summary == "Xcode 27.2 (27B52) at \(app.path) (xcode-select)")
    #expect(found.developer.path == app.path + "/Contents/Developer")
}

@Test func developerDirWinsAndMayNameTheApp() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52"), other = try machine.xcode("Xcode-28", "28.0", "28A1")
    machine.selected = app.path + "/Contents/Developer"
    for path in [other.path, other.path + "/Contents/Developer", other.path + "/Contents/Developer/"] {
        machine.environment = ["DEVELOPER_DIR": path]
        let found = try machine.finder.find(pin: nil, stage: .build)
        #expect(found.build == "28A1" && found.source == "DEVELOPER_DIR")
    }
}

@Test func theNewestInstalledOneWithoutASelection() throws {
    let machine = try Machine()
    try machine.xcode("Xcode-9", "9.4", "9F1")
    try machine.xcode("Xcode_27", "27.2", "27B52")
    try machine.xcode("Xcode-26.2", "26.2", "17C52")
    try machine.xcode("NotXcode", "99.0", "99A1") // only Xcode*.app
    machine.selected = "/Library/Developer/CommandLineTools" // no Xcode
    let found = try machine.finder.find(pin: nil, stage: .build)
    #expect(found.build == "27B52" && found.source == "installed")
}

@Test func thePinChoosesAmongTheInstalledOnes() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    try machine.xcode("Xcode-26.2", "26.2", "17C52")
    machine.selected = app.path + "/Contents/Developer"
    #expect(try machine.finder.find(pin: "26.2.0", stage: .build).build == "17C52")
    #expect(try machine.finder.find(pin: "27.2", stage: .build).source == "xcode-select")
    let none = failure { _ = try machine.finder.find(pin: "26.3", stage: .build) }
    #expect(none?.cause.contains("xcode: \"26.3\" is pinned") == true && none?.cause.contains("27.2 (27B52)") == true && none?.cause.contains("26.2 (17C52)") == true)
}

@Test func aDeveloperDirOfAnotherVersionThanThePinIsRefused() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    try machine.xcode("Xcode-26.2", "26.2", "17C52")
    machine.environment = ["DEVELOPER_DIR": app.path]
    #expect(failure { _ = try machine.finder.find(pin: "26.2", stage: .build) }?.cause.contains("DEVELOPER_DIR") == true)
}

@Test func aDeveloperDirWithoutAnXcodeIsRefused() throws {
    let machine = try Machine()
    try machine.xcode("Xcode", "27.2", "27B52")
    for path in ["/Library/Developer/CommandLineTools", "relative/Xcode.app", machine.root.path] {
        machine.environment = ["DEVELOPER_DIR": path]
        let error = failure { _ = try machine.finder.find(pin: nil, stage: .build) }
        #expect(error?.cause.contains("DEVELOPER_DIR=\(path)") == true)
    }
}

@Test func withoutAnXcodeItSaysWhatIsMissing() throws {
    let machine = try Machine()
    machine.selected = "/Library/Developer/CommandLineTools"
    let error = failure { _ = try machine.finder.find(pin: nil, stage: .build) }
    #expect(error?.cause.contains("no Xcode") == true && error?.fix.contains("App Store") == true && error?.fix.contains("--docker") == true)
    #expect(error?.cause.contains("Command Line Tools") == true)
}

@Test func aSelectedXcodeThatIsNotApplesIsRefused() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    machine.genuine = []
    machine.selected = app.path
    #expect(failure { _ = try machine.finder.find(pin: nil, stage: .build) }?.cause.contains("its signature is not Apple's") == true)
}

@Test func anInstalledOneThatIsNotApplesIsNotChosen() throws {
    let machine = try Machine()
    try machine.xcode("Xcode-28", "28.0", "28A1")
    try machine.xcode("Xcode", "27.2", "27B52")
    machine.genuine = ["Xcode.app"]
    #expect(try machine.finder.find(pin: nil, stage: .build).build == "27B52")
    machine.genuine = []
    let error = failure { _ = try machine.finder.find(pin: nil, stage: .build) }
    #expect(error?.cause.contains("its signature is not Apple's") == true)
}

@Test func anXcodeThatOthersCanWriteIsRefused() throws {
    for part in ["", "/Contents", "/Contents/Developer", "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
                 "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift", "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                 "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib", "/Contents/Developer/usr/bin", "/Contents/Developer/usr/bin/actool", "/Contents/SharedFrameworks"] {
        let machine = try Machine()
        let app = try machine.xcode("Xcode", "27.2", "27B52")
        machine.selected = app.path
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: app.path + part)
        let error = failure { _ = try machine.finder.find(pin: nil, stage: .build) }
        #expect(error?.cause.contains("\(app.path)\(part) can be written by other users") == true, "\(part)")
    }
}

@Test func aDirectoryAboveThatOthersCanWriteIsRefused() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    machine.selected = app.path
    let above = app.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: above)
    #expect(failure { _ = try machine.finder.find(pin: nil, stage: .build) }?.cause.contains("\(above) can be written by other users") == true)
    // sticky: nobody replaces what is another one's there (/tmp)
    try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: above)
    #expect(try machine.finder.find(pin: nil, stage: .build).build == "27B52")
}

@Test func aLinkIsFollowedToTheXcodeItself() throws {
    let machine = try Machine()
    let app = try machine.xcode("Xcode-27.2", "27.2", "27B52", in: "elsewhere")
    let apps = machine.root.appendingPathComponent("Applications")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Xcode.app"), withDestinationURL: app)
    #expect(try machine.finder.find(pin: nil, stage: .build).app.path == app.path)
    machine.selected = apps.appendingPathComponent("Xcode.app/Contents/Developer").path
    #expect(try machine.finder.find(pin: nil, stage: .build).app.path == app.path)
}

@Test func everyProgramThatXlessStartsIsChecked() throws {
    let machine = try Machine()
    machine.selected = try machine.xcode("Xcode", "27.2", "27B52").path
    let xcode = try machine.finder.find(pin: nil, stage: .build)
    let bin = xcode.toolchain.path + "/usr/bin/", others = xcode.developer.path + "/usr/bin/"
    let there = Dictionary(uniqueKeysWithValues: XcodeFinder.programs(of: xcode).map { ($0.path, $0.identifier) })
    #expect(there == [bin + "swift": "com.apple.swift-frontend", bin + "clang": "com.apple.clang", others + "actool": "com.apple.actool"])
    // one of either directory, also a second one of the same name
    try Data().write(to: URL(fileURLWithPath: bin + "actool"))
    #expect(XcodeFinder.programs(of: xcode).filter { $0.path.hasSuffix("/actool") }.count == 2)
    for program in InstalledXcode.Program.allCases {
        try Data().write(to: URL(fileURLWithPath: others + program.rawValue))
        #expect(XcodeFinder.programs(of: xcode).contains { $0.path == others + program.rawValue && $0.identifier == program.identifier })
    }
    for name in ["swift-build", "ld", "ibtoold", "dsymutil"] {
        try Data().write(to: URL(fileURLWithPath: bin + name))
        #expect(XcodeFinder.programs(of: xcode).contains { $0.path == bin + name })
    }
}

#if os(macOS)
@Test func theSignatureOfAnXcodeIsThatOfEachOfItsPrograms() throws {
    // nothing of Apple's in it: refused before its programs are looked at
    let machine = try Machine()
    let app = try machine.xcode("Xcode", "27.2", "27B52")
    let xcode = InstalledXcode(app: app, version: "27.2", build: "27B52", source: "-")
    #expect(XcodeFinder.signatureProblem(xcode) == "it has no swift-build")
    for name in ["swift", "swift-build", "clang", "ld"] { try ExecutableFile.write(Data("#!/bin/sh\n".utf8), to: xcode.toolchain.appendingPathComponent("usr/bin/\(name)"), stage: .build) }
    #expect(XcodeFinder.signatureProblem(xcode) == "\(app.path) is not signed by Apple")
}
#endif

@Test func theToolsOfAnXcodeGetACleanEnvironment() throws {
    let machine = try Machine()
    machine.selected = try machine.xcode("Xcode", "27.2", "27B52").path
    let xcode = try machine.finder.find(pin: nil, stage: .build)
    let base = ["PATH": "/opt/swiftly/bin:/usr/bin", "HOME": "/h", "SDKROOT": "/sdk", "TOOLCHAINS": "org.swift.6", "SWIFT_EXEC": "/evil", "CC": "x", "DYLD_INSERT_LIBRARIES": "/evil.dylib"]
    let changes = xcode.environment(base)
    var env = base
    for (key, value) in changes { env[key] = value }
    #expect(env == ["PATH": "\(xcode.toolchain.path)/usr/bin:/opt/swiftly/bin:/usr/bin", "HOME": "/h", "DEVELOPER_DIR": xcode.developer.path])
}
