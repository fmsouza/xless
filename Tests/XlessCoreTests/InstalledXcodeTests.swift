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
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data().write(to: bin.appendingPathComponent("swift"))
        // any umask
        var at = bin.appendingPathComponent("swift")
        while at.path.count > root.path.count {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: at.path)
            at.deleteLastPathComponent()
        }
        try Plist.write(["CFBundleShortVersionString": version, "ProductBuildVersion": build], to: app.appendingPathComponent("Contents/version.plist"), stage: .sdk)
        return app
    }

    var finder: XcodeFinder {
        XcodeFinder(environment: environment, selected: { self.selected }, applications: [root.appendingPathComponent("Applications")],
                    isGenuine: { app in
                        guard let genuine = self.genuine, !genuine.contains(app.lastPathComponent) else { return nil }
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
                 "/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"] {
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

@Test func whoMayWriteAFile() {
    func reason(_ owner: UInt32, _ group: UInt32, _ mode: UInt16, directory: Bool = true) -> String? {
        XcodeFinder.problem(path: "/x", owner: owner, group: group, mode: mode, isDirectory: directory, user: 501)
    }
    #expect(reason(0, 0, 0o755) == nil && reason(501, 20, 0o755) == nil)
    #expect(reason(0, 80, 0o775) == nil)               // /Applications
    #expect(reason(0, 0, 0o775) == nil)
    #expect(reason(0, 20, 0o775)?.contains("/x can be written by other users") == true) // staff: every user
    #expect(reason(502, 20, 0o755)?.contains("/x belongs to another user") == true)
    #expect(reason(0, 0, 0o777)?.contains("other users") == true)
    #expect(reason(0, 0, 0o1777) == nil)
    #expect(reason(0, 0, 0o1777, directory: false)?.contains("other users") == true)
}

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
