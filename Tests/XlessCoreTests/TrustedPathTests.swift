import Foundation
import Testing
@testable import XlessCore

private func temporary() throws -> String {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("xless-trusted-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: made.path) // any umask
    return realpath(made.path, nil).map { String(cString: $0) } ?? made.path
}

private func make(_ path: String, directory: Bool = false, mode: Int = 0o755) throws {
    if directory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) } else { try Data().write(to: URL(fileURLWithPath: path)) }
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

@Test func whoMayWriteAFile() {
    func reason(_ owner: UInt32, _ group: UInt32, _ mode: UInt16, directory: Bool = true) -> String? {
        TrustedPath.problem(path: "/x", owner: owner, group: group, mode: mode, isDirectory: directory, user: 501)
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

@Test func whatNobodyElseCanChangeIsTrusted() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try make(root + "/d", directory: true)
    try make(root + "/d/f")
    #expect(TrustedPath.problem(root + "/d/f") == nil)
    #expect(TrustedPath.problem(root + "/d/no") == "\(root)/d/no is not there")
    #expect(TrustedPath.problem("d/f") != nil)
    #expect(TrustedPath.problem(root + "/d/f", user: 4_000_000)?.contains("belongs to another user") == (geteuid() == 0 ? nil : true)) // (root's is trusted)
    try FileManager.default.setAttributes([.posixPermissions: 0o757], ofItemAtPath: root + "/d")
    #expect(TrustedPath.problem(root + "/d/f") == "\(root)/d can be written by other users")
}

@Test func everyDirectoryOnTheWayOfALinkIsLookedAt() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(atPath: root) }
    for name in ["a", "open", "c"] { try make("\(root)/\(name)", directory: true) }
    try make(root + "/c/f")
    // a/f -> open/hop -> c/f: who may write `open` chooses what a/f is
    try FileManager.default.createSymbolicLink(atPath: root + "/a/f", withDestinationPath: "../open/./hop")
    try FileManager.default.createSymbolicLink(atPath: root + "/open/hop", withDestinationPath: root + "/c/f")
    let entries = try #require(TrustedPath.entries(to: root + "/a/f"))
    for name in ["/a", "/a/f", "/open", "/open/hop", "/c", "/c/f"] { #expect(entries.contains(root + name), "\(name)") }
    #expect(TrustedPath.problem(root + "/a/f") == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root + "/open")
    #expect(TrustedPath.problem(root + "/a/f") == "\(root)/open can be written by other users")
    // a link to itself goes nowhere
    try FileManager.default.createSymbolicLink(atPath: root + "/a/loop", withDestinationPath: "loop")
    #expect(TrustedPath.entries(to: root + "/a/loop") == nil)
}

#if os(macOS)
@Test func whoAnAccessControlListLetsWrite() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(atPath: root) }
    func with(_ entries: [String]) throws -> String? {
        let path = "\(root)/\(UUID().uuidString)"
        try make(path, directory: true)
        for entry in entries { try Shell.run("/bin/chmod", ["+a", entry, path], stage: .build) }
        return TrustedPath.problem(path)?.replacingOccurrences(of: path, with: "P")
    }
    let refused = "P can be written by other users (its access control list: ls -led)"
    for right in ["add_file", "add_subdirectory", "delete", "delete_child", "writesecurity", "chown", "writeextattr"] {
        #expect(try with(["everyone allow \(right)"]) == refused, "\(right)")
    }
    #expect(try with(["everyone allow list,search,readattr"]) == nil)
    #expect(try with(["everyone deny delete"]) == nil) // what macOS gives a home directory
    #expect(try with(["staff allow add_file"]) == refused)
    #expect(try with(["everyone deny delete", "nobody allow add_file"]) == refused)
    for administrator in ["root", "group:admin", "group:wheel"] { #expect(try with(["\(administrator) allow add_file,delete_child"]) == nil, "\(administrator)") }
    if let me = NSUserName() as String?, !me.isEmpty { #expect(try with(["user:\(me) allow add_file"]) == nil) }
}
#endif

#if os(macOS)
@Test func aVolumeThatIgnoresOwnersIsNotTrusted() throws {
    let root = try temporary()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try make(root + "/d", directory: true)
    try make(root + "/d/f")
    func problem(_ flags: UInt32?) -> String? {
        TrustedPath.problem(root + "/d/f", user: geteuid()) { $0.hasPrefix(root + "/d") ? flags : TrustedPath.volumeFlags(of: $0) }
    }
    #expect(problem(TrustedPath.volumeFlags(of: root)) == nil)
    #expect(problem(UInt32(MNT_IGNORE_OWNERSHIP)) == "the volume of \(root)/d ignores who owns its files")
    #expect(problem(nil) == "the volume of \(root)/d cannot be looked at")
    #expect(TrustedPath.volumeFlags(of: root + "/none") == nil)
}
#endif
