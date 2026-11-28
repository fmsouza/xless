import Foundation
import XlessCore

/// What makes an Xcode one that xless can prepare a pack of, checked by `xless setup` (native and --docker alike) as soon as
/// the Xcode is identified, before anything is downloaded, built or started: versions.env maps its build to an open-source
/// Swift (`XCODE_SWIFT_<build>`, Ruling R10), the share has its target-OS fixture (`docker/toolchain/target-os/<build>.txt`,
/// which scripts/fit-toolchain.sh fits the toolchain with), and xless has measured its asset and storyboard tools
/// (`XcodeToolsProfile`, which the actool and ibtool shims answer with; scripts/xcode-tools.sh is the same check). Without the
/// last two the preparation would fail minutes in (the fit, or scripts/pack-check.sh).
public enum XcodeSupport {
    /// Why xless cannot prepare a pack of `xcode`: nil when it can.
    public static func problem(_ xcode: KnownXcode, table: [String: String], share: URL) -> String? {
        let x = "Xcode \(xcode.shortVersion) (\(xcode.build))"
        if (table["XCODE_SWIFT_\(xcode.build)"] ?? "").isEmpty {
            return "versions.env maps \(x) to no Swift toolchain (XCODE_SWIFT_\(xcode.build))"
        }
        let fixture = share.appendingPathComponent("docker/toolchain/target-os/\(xcode.build).txt")
        if !FileManager.default.fileExists(atPath: fixture.path) {
            return "xless has no target-OS fixture for \(x) (\(fixture.path)), which its toolchain is fitted to the SDK with"
        }
        if XcodeToolsProfile.all[xcode.build] == nil {
            return "xless has not measured the asset catalog and storyboard tools of \(x) (it has no XcodeToolsProfile for \(xcode.build)): a pack of it could not compile asset catalogs or storyboards"
        }
        return nil
    }

    /// Refuses `xcode` when xless cannot prepare a pack of it, naming the Xcodes of `known` it can.
    public static func require(_ xcode: KnownXcode, known: [KnownXcode], table: [String: String], share: URL) throws {
        guard let cause = problem(xcode, table: table, share: share) else { return }
        let supported = known.filter { problem($0, table: table, share: share) == nil }
            .map { "Xcode \($0.shortVersion) (\($0.build))" }.joined(separator: ", ")
        throw XlessError(.sdk, cause, fix: "use an Xcode this xless supports (\(supported.isEmpty ? "none" : supported)), or an xless that supports this one")
    }
}
