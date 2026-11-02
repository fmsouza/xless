import Foundation

/// Ruling R8: a project may pin the Xcode whose SDK builds it (`xcode: "26.2"` in xless.yml or an overlay), so an app
/// is built with the SDK its own release pipeline uses. xless images bake one SDK each (`xless setup --xcode …`, tagged
/// `-xcode<version>`); prepare (overlay projects) and the build stage refuse an image whose SDK comes from another Xcode
/// (`BuildSDKCheck`), and the build stage records the SDK it used (`BuildSDKRecord`) for finalize, which stamps the app from that same SDK. Without a pin the image's SDK is used.
public enum XcodePin {
    /// A pin is 1–3 dot-separated integers (`26.2`, `27.0.1`); `27` equals `27.0` and `27.0.0`.
    public static func validate(_ pin: String, key: String = "xcode", file: String) throws {
        guard pin.wholeMatch(of: /\d+(\.\d+){0,2}/) != nil, DottedVersion(pin) != nil else {
            throw XlessError(.config, "\(key) '\(pin)' in \(file) is not an Xcode version",
                             fix: "use the Xcode version the app's release builds use, e.g. xcode: \"26.2\" (quoted, so YAML keeps it a string)")
        }
    }

    /// The Xcode version of `meta` in dotted form: DTXcode "2620" → "26.2", "2601" → "26.0.1", "2700" → "27.0".
    public static func xcodeVersion(_ meta: ToolchainMeta) -> String {
        let v = meta.xcodeVersion
        guard v.count == 4, v.allSatisfy({ $0.isASCII && $0.isWholeNumber }) else { return v }
        let major = Int(v.prefix(2))!, minor = Int(String(v[v.index(v.startIndex, offsetBy: 2)]))!, patch = Int(String(v.last!))!
        return "\(major).\(minor)" + (patch > 0 ? ".\(patch)" : "")
    }

    public static func matches(pin: String, meta: ToolchainMeta) -> Bool {
        guard let p = DottedVersion(pin), let have = DottedVersion(xcodeVersion(meta)) else { return false }
        return p == have
    }

    /// The image's SDK checked against the pin (nil: no pin, anything goes). The refusal names the image tag and the
    /// command that builds images from that Xcode.
    public static func check(pin: String?, meta: ToolchainMeta, platform: Platform, file: String, stage: Stage = .build) throws {
        guard let pin else { return }
        guard matches(pin: pin, meta: meta) else {
            let sdk = (try? meta.sdk(for: platform)).map { "the \($0.sdkName) SDK" } ?? "its SDK"
            throw XlessError(stage, "\(file) pins xcode: \"\(pin)\", but this image has \(sdk) from Xcode \(xcodeVersion(meta)) (\(meta.xcodeBuild))",
                             fix: "install Xcode \(pin) natively (`xless setup --xcode <path to Xcode \(pin)'s .xip>`, which replaces the installed one), or build with --docker in the images made from it (`xless setup --docker --xcode …`, tags *-xcode\(pin); xless run --docker selects them from the pin), or change the pin to \(xcodeVersion(meta))")
        }
    }
}

/// What the build stage records next to its output (`<stage dir>/sdk.json`): the pin and the toolchain metadata of the
/// SDK the app was built with. Finalize stamps the app from the image's metadata and refuses one that differs from this
/// record (an image change between build and finalize).
public struct BuildSDKRecord: Codable, Sendable, Equatable {
    public var pin: String?
    public var toolchain: ToolchainMeta
    /// The Swift toolchain that compiled the app (Ruling R10); nil on a host without an image toolchain record.
    public var swift: BuildSwiftRecord?

    public init(pin: String?, toolchain: ToolchainMeta, swift: BuildSwiftRecord? = nil) {
        self.pin = pin; self.toolchain = toolchain; self.swift = swift
    }

    public static func url(in stageRoot: URL) -> URL { stageRoot.appendingPathComponent("sdk.json") }

    /// One line for the log: `Xcode 27.0 (27A266a), iphoneos27.0 SDK (24A430)`.
    public func summary(platform: Platform) -> String {
        let sdk = (try? toolchain.sdk(for: platform)).map { ", \($0.sdkName) SDK (\($0.sdkBuild))" } ?? ""
        return "Xcode \(XcodePin.xcodeVersion(toolchain)) (\(toolchain.xcodeBuild))\(sdk)" + (pin.map { ", pinned by xcode: \"\($0)\"" } ?? "")
    }

    public func write(in stageRoot: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        try enc.encode(self).write(to: Self.url(in: stageRoot), options: .atomic)
    }

    /// nil when the build wrote no record (an older build, or one without toolchain metadata).
    public static func load(in stageRoot: URL) -> BuildSDKRecord? {
        guard let data = try? Data(contentsOf: url(in: stageRoot)) else { return nil }
        return try? JSONDecoder().decode(BuildSDKRecord.self, from: data)
    }
}
