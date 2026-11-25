import Foundation

/// Rulings R8 and R10 at the start of a build: the image's SDK (toolchain metadata) against the project's `xcode:` pin,
/// and its Swift toolchain against the SDK's Xcode. `prepare` runs the same checks first (nothing recorded), so a wrong
/// image is refused before the JS install, prebuild and CocoaPods run; `build` checks again and records the result
/// (`BuildSDKRecord`, `<stage dir>/sdk.json`).
public enum BuildSDKCheck {
    public struct Result {
        /// nil without toolchain metadata (a host with no SDK installed, no pin).
        public var meta: ToolchainMeta?
        public var swift: BuildSwiftRecord?
        public var toolchain: SwiftToolchain?
    }

    /// The checks, without recording. `file` words the refusal ("the overlay", "xless.yml"). A pinned project needs
    /// metadata and a toolchain record; the pin must be the metadata's Xcode, and the toolchain the Swift that Xcode ships.
    public static func check(pin: String?, platform: Platform, file: String, stage: Stage,
                             metaURL: URL = ToolchainMeta.defaultLocation(),
                             loadToolchain: () throws -> SwiftToolchain? = { try SwiftToolchain.load(stage: .build) }) throws -> Result {
        var meta: ToolchainMeta?
        do { meta = try ToolchainMeta.load(from: metaURL) } catch let e as XlessError {
            if let pin {
                throw XlessError(stage, "xcode: \"\(pin)\" is pinned, but \(e.cause)", fix: "install Xcode \(pin) (`xless setup --xcode <path to Xcode \(pin)'s .xip>`), or build in an xless image made from it (`xless setup --docker --xcode …`, tags *-xcode\(pin))")
            }
        }
        if let meta { try XcodePin.check(pin: pin, meta: meta, platform: platform, file: file, stage: stage) }
        let toolchain: SwiftToolchain?
        do { toolchain = try loadToolchain() } catch let e as XlessError { throw XlessError(stage, e.cause, fix: e.fix) }
        let swift = try SwiftToolchain.check(toolchain, meta: meta, pin: pin, stage: stage)
        return Result(meta: meta, swift: swift, toolchain: toolchain)
    }

    /// The build stage's form: the previous record is deleted first (a refused build leaves none), then `check`, then the
    /// record is written when there is metadata.
    public static func checkAndRecord(stageRoot: URL, pin: String?, platform: Platform, file: String,
                                      metaURL: URL = ToolchainMeta.defaultLocation(),
                                      loadToolchain: () throws -> SwiftToolchain? = { try SwiftToolchain.load(stage: .build) }) throws -> (Result, BuildSDKRecord?) {
        try? FileManager.default.removeItem(at: BuildSDKRecord.url(in: stageRoot))
        let result = try check(pin: pin, platform: platform, file: file, stage: .build, metaURL: metaURL, loadToolchain: loadToolchain)
        guard let meta = result.meta else { return (result, nil) }
        let record = BuildSDKRecord(pin: pin, toolchain: meta, swift: result.swift)
        try record.write(in: stageRoot)
        return (result, record)
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
