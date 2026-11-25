#if os(Windows)
import CXlessWindows
import Foundation

/// What xless makes of its own process on Windows, before anything else.
public enum WindowsProcess {
    /// What `xless_process_start` says; a process that cannot be made so does not go on.
    public static func start() {
        let code = xless_process_start()
        guard code != 0 else { return }
        FileHandle.standardError.write(Data("error: [config] cannot start: \(WindowsError.text(code)) — update Windows (xless needs Windows 10 1809 or later)\n".utf8))
        exit(Stage.config.exitCode)
    }

    public static func setEnvironment(_ name: String, _ value: String) {
        _ = name.withWide { name in value.withWide { xless_set_environment(name, $0) } }
    }
}

/// What Windows says of an error's number.
public enum WindowsError {
    public static func text(_ code: UInt32) -> String {
        var text = [UInt16](repeating: 0, count: 512)
        _ = xless_error_text(code, &text, text.count)
        let words = String(wide: text)
        return words.isEmpty ? "Windows error \(code)" : "\(words) (Windows error \(code))"
    }
}
#endif
