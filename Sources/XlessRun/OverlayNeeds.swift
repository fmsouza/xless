import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// What an overlay's build needs off a Mac: Swift Build (a part of the Xcode's pack), the Xcode tool shims, and the tools of
/// its kit (docker/tauri, docker/react-native). A container of a kit's image is a machine that has them all; a bare Linux host
/// has none of them, and builds an overlay with `xless run --docker`. What is there is looked at, not where this runs. (A Mac
/// builds an overlay with its own Xcode, in a sandbox: `NativeOverlay`.)
extension ProjectRun {
    /// What an overlay's build needs that this machine lacks; empty: it can build here.
    public static func missingForOverlay(kind: Kit, env: [String: String], which: (String) -> String?) -> [String] {
        var missing: [String] = []
        if !hasSwiftBuild(env) { missing.append("Swift Build (no pack with it: xless setup)") }
        if !PackPlan.abilities(env: env).swiftBuild { missing.append("the Xcode tool shims (XLESS_SHIM_DIR)") }
        switch kind {
        case .tauri:
            if which("node") == nil { missing.append("node") }
            if which("rustup-init") == nil, which("rustup") == nil { missing.append("rustup-init or rustup") }
        case .reactNative:
            for tool in ["node", "ruby", "bundle", "hermesc"] where which(tool) == nil { missing.append(tool) }
        }
        return missing
    }

    /// The Xcode's pack has Swift Build (`XcodeEnvironment`, as the build looks for it). A pack that has it but cannot be used as
    /// it is (prepared by another recipe) is not missing it: the build says so, and what prepares it again.
    static func hasSwiftBuild(_ env: [String: String]) -> Bool {
        do { return try XcodeEnvironment.current(env: env, needs: [.swiftBuild]).swbuild != nil } catch is XcodeProblem {
            guard let found = try? XcodeEnvironment.lookup(env: env, needs: []), let pack = found.pack else { return false }
            return pack.has(.swiftBuild)
        } catch { return false }
    }

    /// A native run of an overlay off a Mac: refused, before anything else, when the machine lacks what its build needs.
    func refuseMissingForOverlay(kind: Kit) throws {
        guard !docker, !host.isMac, let lacks = context.overlayLacks else { return }
        let missing = lacks(kind, environment(.nothing))
        guard !missing.isEmpty else { return }
        throw XlessError(.config, "the overlay \(pinFile) needs, and this machine lacks: \(missing.joined(separator: ", "))",
                         fix: "`xless run --docker` has them all (made once: xless setup --docker --xcode <path to Xcode's .xip> --with \(kind.rawValue))",
                         code: 2)
    }
}
