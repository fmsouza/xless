import Foundation

/// A name that something else has taken the place of, and that stays for a while.
enum OldName {
    /// One line on standard error: never in what a command prints for a program, and not an error.
    static func say(_ old: String, now: String) {
        FileHandle.standardError.write(Data("note: \(old) is \(now) now; the old name stays for a while\n".utf8))
    }
}
