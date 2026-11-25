#if os(Windows)
import CXlessWindows
import Foundation

/// Where a user's own files of xless are on Windows: `%LOCALAPPDATA%\xless`, as the system has it for the user (not as the variable
/// says), which is never copied to other computers. An XDG directory (`XDG_CONFIG_HOME`, `XDG_DATA_HOME`) is honoured when it is an
/// absolute path on a drive.
public enum UserPaths {
    public static func directory(xdg variable: String, env: [String: String]) -> URL {
        if let path = env.variable(variable), isOnDrive(path) { return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("xless", isDirectory: true) }
        return localAppData.appendingPathComponent("xless", isDirectory: true)
    }

    /// `C:\…` or `C:/…`; not `C:x`, `\x`, `\\server\share` or a device.
    public static func isOnDrive(_ path: String) -> Bool { path.wholeMatch(of: /[A-Za-z]:[\\\/].*/) != nil }

    private static var localAppData: URL {
        var path = [UInt16](repeating: 0, count: 32768)
        if xless_local_app_data(&path, path.count) > 0 { return URL(fileURLWithPath: String(wide: path), isDirectory: true) }
        // The user's profile, as the system has it; whatever is there is checked before it is used.
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Local", isDirectory: true)
    }
}
#endif
