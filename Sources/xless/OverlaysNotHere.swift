#if os(Windows) || XLESS_WINDOWS_TARGETS
import Foundation
import XlessCore

// Reading an overlay takes the models of Tauri, cargo and React Native apps, which are not built for Windows: what each of Overlays.swift's
// says instead.

enum Overlays {
    static let notHere = XlessError(.config, "Tauri, Cargo and React Native overlays (--config) are not read on Windows yet",
                                    fix: "give --app or --bundle-id, or run this inside WSL2 (wsl --install), or on a Mac or Linux")
}

extension StoreProject {
    static func overlay(_ url: URL) throws -> StoreProject { throw Overlays.notHere }
}

extension StoreDirOption {
    static func workRoot(_ overlay: URL, env: [String: String]) -> URL { overlay.deletingLastPathComponent() }
}

extension RunSecretNames {
    static func overlay(_ config: URL, platform: Platform) throws -> TestFlightConfig? { throw Overlays.notHere }
}

extension ProvisionInputs {
    static func overlay(_ url: URL, source: String?, env: [String: String]) throws -> ProvisionInputs { throw Overlays.notHere }
}
#endif
