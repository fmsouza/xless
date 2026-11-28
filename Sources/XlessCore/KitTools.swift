import Foundation

/// Where an overlay's build finds the tools of its kit (docker/tauri, docker/react-native) that are not taken from PATH alone: one
/// definition for the build and for what checks that a machine has them (`ProjectRun.missingForOverlay`).
public enum KitTools {
    /// hermesc for the machine it runs on, which the React Native build gives the app's Xcode project: React Native's npm one is
    /// macOS / x86_64. docker/react-native builds it from source and installs it here.
    public static let hermesc = "/usr/local/bin/hermesc"

    /// Where rustup is, and puts cargo: CARGO_HOME, else ~/.cargo. Its `bin` comes first on the PATH of a Rust build.
    public static func cargoHome(env: [String: String]) -> String {
        env["CARGO_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (env["HOME"] ?? NSHomeDirectory()) + "/.cargo"
    }
}
