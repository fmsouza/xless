#if os(Windows)
import CXlessWindows
import Foundation

/// Files that nobody but this user has access to (and Windows' own system and administrators, who are root's counterpart; xless never
/// gives them any), as the secret store and whatever holds a key are on Windows: what mode 0600 in a directory of mode 0700 is
/// elsewhere. Each is made with that access list and its owner, checked through the handle it is used by, and refused when anything is
/// not as it should be (`xless_private_problem` says what). Nothing is repaired.
public enum PrivateFile {
    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public enum Kind: Sendable, Equatable {
            /// There is none, or there is one already.
            case missing, exists
            /// A link, or anything else that is not a plain file; or one that is too large.
            case link, notFile, tooLarge
            /// Somebody else has, or may have, access to it, or it is not what it should be.
            case unsafe
            /// Windows would not.
            case failed
        }
        public let kind: Kind
        public let cause: String
        public let fix: String
        public var description: String { "\(cause) — \(fix)" }
    }

    /// The store's files are on a built-in drive (`local`); what a person names may be on another one that keeps access lists.
    public enum Place: Sendable { case builtInDrive, anyDrive }

    /// Makes the directory, unless it is there, and its missing parents (those as any directory of the user's). Not checked.
    public static func makeDirectory(_ path: String) throws {
        guard UserPaths.isOnDrive(path) else { throw Refusal(kind: .unsafe, cause: "\(path) is not a directory on a drive", fix: "keep it on a drive built into this computer") }
        let parent = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
            throw Refusal(kind: .failed, cause: "cannot create \(parent.path): \(error.localizedDescription)", fix: "check the parent directory's permissions")
        }
        var why = xless_private()
        guard path.withWide({ xless_private_make_directory($0, &why) }) == 0 else { throw refusal(path, why, sid: "", making: true, directory: true) }
    }

    /// Runs `body` with the directory checked and held: while it runs, nobody renames or removes it. Nil when there is none.
    public static func inDirectory<T>(_ path: String, _ place: Place, _ body: () throws -> T) throws -> T? {
        guard let handle = try open(path, directory: true, { xless_private_open_directory($0, place == .builtInDrive ? 1 : 0, $1, $2) }) else { return nil }
        defer { xless_private_close(handle) }
        return try body()
    }

    /// The bytes of the file, at most `limit` and then one more; nil when there is none.
    public static func read(_ path: String, _ place: Place, limit: Int) throws -> Data? {
        guard let handle = try open(path, directory: false, { xless_private_open($0, place == .builtInDrive ? 1 : 0, $1, $2) }) else { return nil }
        defer { xless_private_close(handle) }
        return try readAll(handle, path, limit: limit)
    }

    /// Writes a new file: one that is there is never replaced, and what could not be written whole is removed.
    public static func create(_ path: String, _ contents: Data, _ place: Place = .anyDrive) throws {
        let handle = try make(path, place)
        defer { xless_private_close(handle) }
        do { try write(contents, to: handle, path) } catch {
            _ = xless_private_remove(handle)
            throw error
        }
    }

    /// Replaces `path` in one step by a new file, which is written to `temporary` (beside it) and is on the disk first.
    public static func replace(_ path: String, with contents: Data, through temporary: String, _ place: Place) throws {
        let handle = try make(temporary, place)
        defer { xless_private_close(handle) }
        do {
            try write(contents, to: handle, temporary)
            let code = path.withWide { xless_private_replace(handle, $0) }
            guard code == 0 else { throw failure("cannot replace \(path)", code) }
        } catch {
            _ = xless_private_remove(handle)
            throw error
        }
    }

    /// Runs `body` while this process alone has the lock file, which is made when it is missing.
    public static func withLock<T>(_ path: String, _ place: Place, _ body: () throws -> T) throws -> T {
        guard let handle = try open(path, directory: false, { xless_private_open_lock($0, place == .builtInDrive ? 1 : 0, $1, $2) }) else {
            throw Refusal(kind: .failed, cause: "cannot open the lock file \(path)", fix: "check its directory")
        }
        defer { xless_private_close(handle) }
        let code = xless_private_lock(handle)
        guard code == 0 else { throw failure("cannot lock \(path)", code) }
        return try body()
    }

    /// Whether there is anything of that name (a link is not followed), as far as it can be told.
    public static func exists(_ path: String) -> Bool { path.withWide { xless_path_exists($0) } != 0 }

    // MARK: -

    private typealias Handle = UnsafeMutableRawPointer

    private static func open(_ path: String, directory: Bool,
                             _ body: (UnsafePointer<UInt16>, UnsafeMutablePointer<xless_private>, UnsafeMutablePointer<UInt16>) -> Handle?) throws -> Handle? {
        var why = xless_private()
        var sid = [UInt16](repeating: 0, count: Int(XLESS_SID_LENGTH))
        if let handle = path.withWide({ body($0, &why, &sid) }) { return handle }
        if why.problem == Int32(XLESS_PRIVATE_MISSING.rawValue) { return nil }
        throw refusal(path, why, sid: String(wide: sid), making: false, directory: directory)
    }

    private static func make(_ path: String, _ place: Place) throws -> Handle {
        var why = xless_private()
        var sid = [UInt16](repeating: 0, count: Int(XLESS_SID_LENGTH))
        if let handle = path.withWide({ xless_private_create($0, place == .builtInDrive ? 1 : 0, &why, &sid) }) { return handle }
        throw refusal(path, why, sid: String(wide: sid), making: true, directory: false)
    }

    fileprivate static func write(_ contents: Data, to handle: UnsafeMutableRawPointer, _ path: String, flush: Bool = true) throws {
        try contents.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                var code: UInt32 = 0
                let put = xless_private_write(handle, bytes.baseAddress! + offset, bytes.count - offset, &code)
                guard put > 0 else { throw failure("cannot write \(path)", code) }
                offset += Int(put)
            }
        }
        guard flush else { return }
        let code = xless_private_flush(handle)
        guard code == 0 else { throw failure("cannot write \(path)", code) }
    }

    fileprivate static func readAll(_ handle: UnsafeMutableRawPointer, _ path: String, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 << 10, limit + 1))
        defer { buffer.withUnsafeMutableBytes { SecretBytes.zero($0) } }
        while data.count <= limit {
            var code: UInt32 = 0
            let got = buffer.withUnsafeMutableBytes { xless_private_read(handle, $0.baseAddress, min($0.count, limit + 1 - data.count), &code) }
            guard got >= 0 else { throw failure("cannot read \(path)", code) }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<Int(got)])
        }
        return data
    }

    fileprivate static func failure(_ what: String, _ code: UInt32) -> Refusal {
        Refusal(kind: .failed, cause: "\(what): \(WindowsError.text(code))", fix: "check the disk and the directory's permissions")
    }

    fileprivate static func refusal(_ path: String, _ why: xless_private, sid: String, making: Bool, directory: Bool) -> Refusal {
        func unsafe(_ cause: String, _ fix: String, _ kind: Refusal.Kind = .unsafe) -> Refusal { Refusal(kind: kind, cause: "\(path) \(cause)", fix: fix) }
        let kind = directory ? "directory" : "file"
        let reset = "icacls \"\(path)\" /inheritance:r /grant:r \"\(user):\(directory ? "(OI)(CI)" : "")F\""
        switch why.problem {
        case Int32(XLESS_PRIVATE_MISSING.rawValue) where !making:
            return Refusal(kind: .missing, cause: "there is no \(kind) \(path)", fix: "check the path")
        case Int32(XLESS_PRIVATE_EXISTS.rawValue):
            return Refusal(kind: .exists, cause: "cannot create \(path): it already exists", fix: "choose another path")
        case Int32(XLESS_PRIVATE_BAD_PATH.rawValue):
            return unsafe("is not a file on a drive", "give a path such as C:\\Users\\…, not a device nor a stream of a file")
        case Int32(XLESS_PRIVATE_LINK.rawValue):
            return unsafe("is a link (or a placeholder of a cloud folder), which xless refuses to follow", "replace it with the real \(kind)", .link)
        case Int32(XLESS_PRIVATE_NOT_FILE.rawValue): return unsafe("is not a regular file", "move it aside", .notFile)
        case Int32(XLESS_PRIVATE_NOT_DIRECTORY.rawValue): return unsafe("is not a directory", "move it aside")
        case Int32(XLESS_PRIVATE_HARD_LINKS.rawValue):
            return unsafe("has more than one name (hard links)", "remove the others, and consider who made them")
        case Int32(XLESS_PRIVATE_OWNER.rawValue):
            return unsafe("belongs to another user (\(sid))", "it must belong to the user running xless; check who created it")
        case Int32(XLESS_PRIVATE_NO_DACL.rawValue):
            return unsafe("is open to everyone (it has no access list)", "\(reset), and consider whether its content was exposed")
        case Int32(XLESS_PRIVATE_INHERITED.rawValue):
            return unsafe("has the access list of the directory it is in, not one of its own", reset)
        case Int32(XLESS_PRIVATE_SHARED.rawValue):
            return unsafe("is accessible to other users (\(sid))", "\(reset) /remove:g *\(sid), and consider whether its content was exposed")
        case Int32(XLESS_PRIVATE_UNKNOWN_ACE.rawValue):
            return unsafe("has an access list that xless cannot judge", "\(reset), then look at what is left with icacls \"\(path)\" and remove it; move the \(kind) aside when that does not do")
        case Int32(XLESS_PRIVATE_NOT_LOCAL.rawValue):
            return unsafe("is not on a drive built into this computer", "keep it on one (a share or a removable drive answers to other rules than Windows')")
        case Int32(XLESS_PRIVATE_NO_ACLS.rawValue):
            return unsafe("is on a file system that keeps no access lists (FAT, exFAT): everybody could read it", "use a drive formatted with NTFS")
        default:
            return Refusal(kind: .failed, cause: "cannot \(making ? "create" : "open") \(path): \(WindowsError.text(why.code))", fix: "check the path's permissions")
        }
    }

    /// The user, for icacls.
    private static var user: String {
        var text = [UInt16](repeating: 0, count: Int(XLESS_SID_LENGTH))
        return xless_user_sid(&text) == 1 ? "*" + String(wide: text) : "%USERNAME%"
    }
}

/// A file that the user named to read a secret (or anything else) from: a regular file on a drive, whoever it belongs to; never a
/// device, a pipe or a path `\\server\\…`. (What a mapped drive or a link leads to may be a share's.)
public enum InputFile {
    /// Its bytes; a file of more than `limit` is refused.
    public static func read(_ path: String, limit: Int, throughLinks: Bool = true) throws -> Data {
        var why = xless_private()
        guard let handle = path.withWide({ xless_input_open($0, throughLinks ? 0 : 1, &why) }) else {
            throw PrivateFile.refusal(path, why, sid: "", making: false, directory: false)
        }
        defer { xless_private_close(handle) }
        let data = try PrivateFile.readAll(handle, path, limit: limit)
        guard data.count <= limit else {
            throw PrivateFile.Refusal(kind: .tooLarge, cause: "\(path) is larger than \(limit) bytes", fix: "check that it is the right file")
        }
        return data
    }

    /// Removes the file; what Windows says when it would not.
    public static func remove(_ path: String) -> String? {
        let code = path.withWide { xless_delete($0) }
        return code == 0 ? nil : WindowsError.text(code)
    }
}

/// A new file that is no secret (a report): as any file made in its directory. Not synchronised.
public final class OutputFile: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer?
    private let path: String

    /// Fails when there is a file of that name.
    public init(creating path: String) throws {
        self.path = path
        var why = xless_private()
        handle = path.withWide { xless_output_create($0, &why) }
        if handle == nil { throw PrivateFile.refusal(path, why, sid: "", making: true, directory: false) }
    }

    deinit { close() }

    public func write(_ data: Data) throws {
        guard let handle else { throw PrivateFile.failure("cannot write \(path)", 6) }   // ERROR_INVALID_HANDLE
        try PrivateFile.write(data, to: handle, path, flush: false)
    }

    /// On the disk.
    public func synchronize() throws {
        guard let handle else { return }
        try PrivateFile.write(Data(), to: handle, path, flush: true)
    }

    public func close() {
        xless_private_close(handle)
        handle = nil
    }

    /// Gives the file at `from` the name `to`. Without `replacing`, never another file's (`PrivateFile.Refusal.Kind.exists`).
    public static func move(_ from: String, to: String, replacing: Bool) throws {
        let code = from.withWide { from in to.withWide { xless_move(from, $0, replacing ? 1 : 0) } }
        switch code {
        case 0: return
        case 80, 183: throw PrivateFile.Refusal(kind: .exists, cause: "\(to) already exists", fix: "choose another path")   // ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS
        default: throw PrivateFile.failure("cannot write \(to)", code)
        }
    }
}

extension String {
    /// The NUL-terminated UTF-16 that Windows takes.
    func withWide<R>(_ body: (UnsafePointer<UInt16>) throws -> R) rethrows -> R {
        // A NUL inside would cut the path short: no path that Windows has, instead.
        try (utf8.contains(0) ? "?" : self).withCString(encodedAs: UTF16.self, body)
    }

    /// What comes before the first NUL.
    init(wide units: [UInt16]) { self.init(decoding: units.prefix { $0 != 0 }, as: UTF16.self) }
}
#endif
