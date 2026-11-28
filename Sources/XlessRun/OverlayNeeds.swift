import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// What an overlay is, by its `type:`: what its build needs follows from that (`ProjectRun.missingForOverlay`). The image its build
/// runs in when it is in containers is its kit's (`Kit(overlayType:)`, the same for Tauri and Cargo apps): that is about the image,
/// not about what the build uses.
public enum OverlayKind: String, CaseIterable, Sendable {
    case tauri, cargo
    case reactNative = "react-native"

    /// Of an overlay's `type:`: Tauri when it says neither of the others, as the run reads it.
    public init(type: String?) { self = type == "cargo" ? .cargo : type == "react-native" ? .reactNative : .tauri }

    /// The kit whose image builds it in containers.
    public var kit: Kit { self == .reactNative ? .reactNative : .tauri }
}

/// What an overlay's build needs off a Mac, as each kind's build finds it:
/// - every kind: an Xcode pack (its Darwin SDK, its Swift toolchain);
/// - Tauri: node, and rustup (on PATH or in `KitTools.cargoHome`) or rustup-init (`RustApple.bootstrap`); Cargo: rustup or rustup-init. Neither runs Swift Build or the
///   Xcode tool shims (their Rust code links with the pack's toolchain, their Swift packages build with SwiftPM);
/// - React Native: Swift Build (a part of the pack, `SwiftBuildEnvironment`), the Xcode tool shims (XLESS_SHIM_DIR), node, ruby,
///   bundle, and hermesc where its build takes it (`KitTools.hermesc`).
/// A container of a kit's image is a machine that has them all; a bare Linux host has none of them, and builds an overlay with
/// `xless run --docker`. What is there is looked at, not where this runs. (A Mac builds an overlay with its own Xcode, in a
/// sandbox: `NativeOverlay`.)
extension ProjectRun {
    /// What an overlay's build needs that this machine lacks; empty: it can build here. `which`: the path of a program, given by
    /// name (on PATH) or by its absolute path; nil where there is none.
    public static func missingForOverlay(kind: OverlayKind, env: [String: String], which: (String) -> String?) -> [String] {
        var missing: [String] = []
        switch kind {
        case .tauri, .cargo:
            if !has(.sdk, env) { missing.append("an Xcode pack (none here: xless setup)") }
            if kind == .tauri, which("node") == nil { missing.append("node") }
            // (rustup also where rustup-init puts it, which the build puts first on its PATH)
            if which("rustup-init") == nil, which("rustup") == nil, which(KitTools.cargoHome(env: env) + "/bin/rustup") == nil {
                missing.append("rustup-init or rustup")
            }
        case .reactNative:
            if !has(.swiftBuild, env) { missing.append("Swift Build (no pack with it: xless setup)") }
            if !PackPlan.abilities(env: env).swiftBuild { missing.append("the Xcode tool shims (XLESS_SHIM_DIR)") }
            for tool in ["node", "ruby", "bundle"] where which(tool) == nil { missing.append(tool) }
            if which(KitTools.hermesc) == nil { missing.append("hermesc (\(KitTools.hermesc))") }
        }
        return missing
    }

    /// The Xcode's pack has `part` (`XcodeEnvironment`, as the build looks for it). A pack that has it but cannot be used as it is
    /// (prepared by another recipe) is not missing it: the build says so, and what prepares it again.
    static func has(_ part: PackPart, _ env: [String: String]) -> Bool {
        do {
            let found = try XcodeEnvironment.current(env: env, needs: [part == .sdk ? .sdk : .swiftBuild])
            return part == .sdk || found.swbuild != nil
        } catch is XcodeProblem {
            guard let found = try? XcodeEnvironment.lookup(env: env, needs: []), let pack = found.pack else { return false }
            return pack.has(part)
        } catch { return false }
    }

    /// A native run of an overlay off a Mac that builds (its span starts at prepare or build, where the app's build runs): refused,
    /// before anything else, when the machine lacks what that build needs. A run from assets on builds nothing: assets and
    /// finalize read the pack (its toolchain metadata), and say so when there is none; sign, package and upload read no pack.
    func refuseMissingForOverlay(kind: OverlayKind, span: RunSpan) throws {
        guard !docker, !host.isMac, span.from <= .build, let lacks = context.overlayLacks else { return }
        let missing = lacks(kind, environment(.nothing))
        guard !missing.isEmpty else { return }
        throw XlessError(.config, "the overlay \(pinFile) needs, and this machine lacks: \(missing.joined(separator: ", "))",
                         fix: "`xless run --docker` has them all (made once: xless setup --docker --xcode <path to Xcode's .xip> --with \(kind.kit.rawValue))",
                         code: 2)
    }
}
