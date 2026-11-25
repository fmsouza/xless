import CXlessProcess
import Foundation
#if os(macOS)
import Security
#endif

/// A program, as the file it is.
struct AgentExecutable: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    /// The one this process runs, also when it was moved, replaced or removed since.
    static var current: AgentExecutable? { AgentExecutable(runBy: getpid()) }

    init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }

    init?(runBy pid: Int32) {
        var device: UInt64 = 0, inode: UInt64 = 0
        guard xless_process_file(pid, &device, &inode) == 0 else { return nil }
        self.init(device: device, inode: inode)
    }

    #if os(macOS)
    /// The file at `path`.
    init?(at path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        self.init(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: st.st_ino)
    }
    #endif
}

/// The program a process runs: its file, and its code by the hash of the code directory that the kernel started it with. A
/// process can put another program's file where its own is mapped and at its own path; it cannot change that hash. (macOS:
/// on Linux a command that holds secrets hides which program it is.)
struct AgentProgram: Equatable, Sendable {
    let file: AgentExecutable
    let code: [UInt8]

    init(file: AgentExecutable, code: [UInt8]) { self.file = file; self.code = code }

    #if os(macOS)
    /// This process's. Told once: the agent's stays what it was when the file is replaced.
    static let current: AgentProgram? = {
        var me = xless_peer()
        guard xless_own_token(&me) == 0, let file = AgentExecutable.current,
              let code = withUnsafeBytes(of: me.token, { codeHash(token: Data($0)) }) else { return nil }
        return AgentProgram(file: file, code: code)
    }()

    /// Nil when it cannot be told, or is not what is at its path: it has ended, its file was replaced or removed, it is
    /// not signed, or its code is not that of its file.
    init?(of peer: xless_peer) {
        guard peer.exe_inode != 0, let code = withUnsafeBytes(of: peer.token, { Self.codeHash(token: Data($0)) }) else { return nil }
        self.init(file: AgentExecutable(device: peer.exe_device, inode: peer.exe_inode), code: code)
    }

    /// The hash of the code that the process of an audit token (its version included) runs, by the kernel's word.
    ///
    /// The API that tells the hash reads it from the file at the process's path. `SecCodeCheckValidity` is what asks the kernel:
    /// the process must be valid, its file must have this hash, and the kernel's hash for it must be the same one.
    private static func codeHash(token: Data) -> [UInt8]? {
        var found: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &found) == errSecSuccess, let found,
              SecCodeCopyStaticCode(found, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let hash = (information as? [CFString: Any])?[kSecCodeInfoUnique] as? Data, hash.count == 20,
              SecRequirementCreateWithString("cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\"" as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(found, [], requirement) == errSecSuccess else { return nil }
        return Array(hash)
    }
    #else
    init?(of peer: xless_peer) { return nil }
    #endif
}
