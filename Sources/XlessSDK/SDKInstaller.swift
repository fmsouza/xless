import Foundation
import XlessCore

/// What preparing a pack runs xtool with: it runs `swiftc` from PATH. (`xless sdk install --image`, which copied the SDK out of an
/// image into xtool's config directory, is gone with the images that held an SDK.)
public enum SDKInstaller {
    /// `env`'s PATH with the toolchain's `usr/bin` first (xtool runs `swiftc` from PATH; a pack's toolchain is on none yet).
    static func path(toolchain: URL, env: [String: String]) -> String {
        let bin = toolchain.appendingPathComponent("usr/bin").path
        guard let rest = env["PATH"], !rest.isEmpty else { return "\(bin):/usr/local/bin:/usr/bin:/bin" }
        return "\(bin):\(rest)"
    }
}
