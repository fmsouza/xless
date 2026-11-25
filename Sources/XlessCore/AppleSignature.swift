import Foundation
#if os(macOS)
import Security
#endif

/// Whether a program is the one of Apple's that it says it is, by its signature (Security, which `codesign --verify` uses too). It is
/// read, not started.
public enum AppleSignature {
    /// Why the program at `path` is not Apple's; nil: it is. `identifier` is what Apple signs it as: without it any program of Apple's
    /// would do (its shell, under another's name); nil: not told. A script is none: what runs it does not look at a signature.
    public static func problem(program path: String, identifier: String?) -> String? {
        guard isMachO(path) else { return "\(path) is no program" }
        return problem(path: path, requirement: programRequirement(identifier: identifier), resources: true).map { $0 + (identifier.map { " as \($0)" } ?? "") }
    }

    static func programRequirement(identifier: String?) -> String { (identifier.map { "identifier \"\($0)\" and " } ?? "") + "anchor apple" }

    /// Why the bundle at `path` is not Apple's own Xcode, as the App Store or developer.apple.com has it. Its main program, its
    /// Info.plist and the list of its files are looked at, not the files on it (gigabytes).
    public static func problem(xcode path: String) -> String? {
        problem(path: path, requirement: xcodeRequirement, team: "59GAB85EFG", resources: false)
    }

    static let xcodeRequirement = #"identifier "com.apple.dt.Xcode" and (anchor apple or anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] or anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "59GAB85EFG")"#

    private static func isMachO(_ path: String) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular,
              let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let magic = (try? file.read(upToCount: 4)).map { [UInt8]($0) } ?? []
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf]].contains(magic)
    }

    private static func problem(path: String, requirement text: String, team: String? = nil, resources: Bool) -> String? {
        #if os(macOS)
        var code: SecStaticCode?, requirement: SecRequirement?, information: CFDictionary?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code
        else { return "\(path) is not signed by Apple" }
        let flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate | SecCSFlags.noNetworkAccess.rawValue | (resources ? 0 : kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), requirement) == errSecSuccess else { return "\(path) is not signed by Apple" }
        guard let team else { return nil }
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              (information as? [CFString: Any])?[kSecCodeInfoTeamIdentifier] as? String == team else { return "\(path) is not signed by Apple" }
        return nil
        #else
        return "\(path) is not signed by Apple"
        #endif
    }
}
