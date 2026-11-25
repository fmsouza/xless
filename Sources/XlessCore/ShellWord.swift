import Foundation

/// One word of a command line that xless prints to be pasted into a shell.
public enum ShellWord {
    /// `word` as is when it is made of safe characters, else single-quoted.
    public static func quoted(_ word: String) -> String {
        let safe = !word.isEmpty && word.first != "=" && word.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_./@:=+,-".unicodeScalars.contains($0))
        }
        return safe ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
