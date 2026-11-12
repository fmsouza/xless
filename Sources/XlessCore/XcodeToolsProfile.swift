import Foundation

/// What Apple's asset and storyboard tools write under one Xcode build, measured black-box
/// (docs/research/xcode-tools-by-version.md). The `actool`/`ibtool` shims and the `assets` stage write the formats of the
/// image's Xcode (`ToolchainMeta.xcodeBuild`); an image made from an Xcode without a profile is refused, never given
/// another Xcode's output. Only the rows that differ between the measured builds are fields: copypng, the asset
/// rendition fields and the partial Info.plists are the same in every build measured.
///
/// Adding a build: measure it with `scripts/assetkit-golden.sh`, `scripts/ib-golden.sh` and `scripts/copypng-golden.sh`,
/// record the differences in the research document, then add an entry below (`scripts/xcode-tools.sh` finds the
/// profiled builds by grepping the one `xcodeBuild:` string literal of each entry).
public struct XcodeToolsProfile: Sendable, Equatable {
    /// The Xcode build (`xcodebuild -version`), e.g. "27A266a".
    public let xcodeBuild: String
    /// Its marketing version, e.g. "27.0" (messages only).
    public let xcodeVersion: String

    // MARK: actool

    /// `actool --version`: `bundle-version` (also in the dependency info, `actool-<it>`).
    public let actoolBundleVersion: String
    /// `actool --version`: `short-bundle-version`.
    public let actoolShortVersion: String
    /// `Assets.car` header (`assetutil --info`, first entry): `CoreUIVersion`.
    public let carCoreUIVersion: UInt32
    /// `StorageVersion`.
    public let carStorageVersion: UInt32
    /// `MainVersion` (the CARHEADER main version string).
    public let carMainVersion: String
    /// `AssetStorageVersion` (the CARHEADER version string).
    public let carAssetStorageVersion: String
    /// `Authoring Tool` (EXTENDED_METADATA).
    public let carAuthoringTool: String

    // MARK: ibtool

    /// `ibtool --version`: `bundle-version`.
    public let ibtoolBundleVersion: String
    /// `ibtool --version`: `short-bundle-version`. Also the newest document this ibtool accepts: a storyboard whose
    /// `<capability … minToolsVersion="X"/>` is above it is refused ("This document requires at least Xcode X.").
    public let ibtoolShortVersion: String
    /// How the view nib of a storyboard whose views are all plain `UIView`s (safe-area layout, no label, no image view)
    /// is encoded.
    public let nibPlainViews: NibEncoding
    /// How every other view nib is encoded: one with a `UILabel`, a `UIImageView` or the legacy top/bottom layout guides.
    public let nibOtherViews: NibEncoding

    /// One way of encoding a view nib. Xcode 27.0 encodes every view nib one way; Xcode 26.2 two ways, told apart by the
    /// classes in the nib (the corpus goldens: the 51 view nibs with the LNE key are exactly those of plain views).
    public struct NibEncoding: Sendable, Equatable {
        /// `IBUINibLNEVersionKey = 1` in the nib's root object (and the archive's `LNE\0` trailer).
        public let writesLNEVersionKey: Bool
        /// System colors' `-Double` components are the decimal rounded to 10 digits (`0.5333333333`); otherwise the
        /// double nearest n/255 (`0.5333333333333333`). Colors written in the storyboard are rounded either way.
        public let roundsSystemColors: Bool
        /// System colors whose components (0…255 RGB) differ from the table in the storyboard compiler.
        public let systemColorOverrides: [String: [Int]]
        /// The system colors measured for this encoding; nil when the whole table is (`color-system-table`).
        public let verifiedSystemColors: Set<String>?
        /// A label without text writes `UIText = nil`; otherwise no `UIText` key.
        public let writesNilLabelText: Bool
        /// Labels with the same custom (unresolved) font share one `UIFont`; otherwise each label gets its own font,
        /// descriptor and attributes dictionary (`label-custom-font-grid`).
        public let uniquesCustomFonts: Bool
        /// Which italic system fonts share the `{NSCTFontSymbolicTrait: 1}` dictionary.
        public let italicTraits: ItalicTraits
    }

    public enum ItalicTraits: Sendable, Equatable {
        /// Every italic system font of the nib shares one.
        case shared
        /// Sizes up to `low` share one, sizes from `high` share another, each size in `between` has its own; other sizes
        /// were not measured (`label-font-grid`: 0.5, 1, 9, 13 | 20 | 28, 48, 100).
        case opticalSizeBands(low: Double, high: Double, between: [Double])
    }

    // MARK: Measured builds

    /// Xcode 27.0 (27A266a): milestone 3's values.
    public static let xcode27A266a: XcodeToolsProfile = {
        let nib = NibEncoding(writesLNEVersionKey: true, roundsSystemColors: true, systemColorOverrides: [:], verifiedSystemColors: nil,
                              writesNilLabelText: true, uniquesCustomFonts: true, italicTraits: .shared)
        return XcodeToolsProfile(
            xcodeBuild: "27A266a", xcodeVersion: "27.0",
            actoolBundleVersion: "25098", actoolShortVersion: "27.0",
            carCoreUIVersion: 1010, carStorageVersion: 17,
            carMainVersion: "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1010 [LAR]",
            carAssetStorageVersion: "Xcode 27.0 (27A266a) via AssetCatalogAgent-AssetRuntime",
            carAuthoringTool: "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR] [IIO-2851][LAR] AppleJPEG[1][32]  CMPhoto[1][219]] [IR-120(hw)]",
            ibtoolBundleVersion: "25098", ibtoolShortVersion: "27.0",
            nibPlainViews: nib, nibOtherViews: nib)
    }()

    /// Xcode 27.1 (27A9275): the same formats as 27.0 except the version strings (the CAR header's `AssetStorageVersion`, the
    /// tools' short version, and with it the newest document ibtool accepts).
    public static let xcode27A9275: XcodeToolsProfile = {
        let nib = xcode27A266a.nibPlainViews
        return XcodeToolsProfile(
            xcodeBuild: "27A9275", xcodeVersion: "27.1",
            actoolBundleVersion: "25098", actoolShortVersion: "27.1",
            carCoreUIVersion: 1010, carStorageVersion: 17,
            carMainVersion: "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1010 [LAR]",
            carAssetStorageVersion: "Xcode 27.1 (27A9275) via AssetCatalogAgent-AssetRuntime",
            carAuthoringTool: "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-664 [LAR] [IIO-2851][LAR] AppleJPEG[1][32]  CMPhoto[1][219]] [IR-120(hw)]",
            ibtoolBundleVersion: "25098", ibtoolShortVersion: "27.1",
            nibPlainViews: nib, nibOtherViews: nib)
    }()

    /// Xcode 26.2 (17C52).
    public static let xcode17C52 = XcodeToolsProfile(
        xcodeBuild: "17C52", xcodeVersion: "26.2",
        actoolBundleVersion: "24506", actoolShortVersion: "26.2",
        carCoreUIVersion: 973, carStorageVersion: 17,
        carMainVersion: "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-973.1",
        carAssetStorageVersion: "Xcode 26.2 (17C52) via AssetCatalogSimulatorAgent",
        carAuthoringTool: "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.3  [IIO-2784.3.4]",
        ibtoolBundleVersion: "24506", ibtoolShortVersion: "26.2",
        nibPlainViews: NibEncoding(writesLNEVersionKey: true, roundsSystemColors: true, systemColorOverrides: ["systemBlueColor": [0, 122, 255]],
                                   verifiedSystemColors: ["labelColor", "systemBackgroundColor", "systemBlueColor", "systemGroupedBackgroundColor"],
                                   writesNilLabelText: true, uniquesCustomFonts: true, italicTraits: .shared),
        nibOtherViews: NibEncoding(writesLNEVersionKey: false, roundsSystemColors: false, systemColorOverrides: [:], verifiedSystemColors: nil,
                                   writesNilLabelText: false, uniquesCustomFonts: false,
                                   italicTraits: .opticalSizeBands(low: 13, high: 28, between: [20])))

    /// Every measured build, keyed by `xcodeBuild`.
    public static let all: [String: XcodeToolsProfile] = Dictionary(uniqueKeysWithValues: [xcode27A266a, xcode27A9275, xcode17C52].map { ($0.xcodeBuild, $0) })

    /// The profile of the image's Xcode. An image made from an Xcode xless has not measured is refused.
    public static func forImage(meta: ToolchainMeta, stage: Stage) throws -> XcodeToolsProfile {
        guard let p = all[meta.xcodeBuild] else {
            throw XlessError(stage, "this image's Xcode build \(meta.xcodeBuild) has no measured asset/storyboard tools profile",
                             fix: "rebuild the images with xless setup --xcode <Xcode.xip> from an Xcode xless has measured (\(all.keys.sorted().joined(separator: ", ")))")
        }
        return p
    }

    /// `forImage` with the image's toolchain metadata (`ToolchainMeta.defaultLocation`: `/opt/xless/toolchain-meta.json` in
    /// an image), read once per call. Missing or invalid metadata is refused in `stage`.
    public static func forImage(env: [String: String] = ProcessInfo.processInfo.environment, stage: Stage) throws -> XcodeToolsProfile {
        let meta: ToolchainMeta
        do { meta = try ToolchainMeta.load(from: ToolchainMeta.defaultLocation(env: env)) } catch let e as XlessError {
            throw XlessError(stage, e.cause, fix: e.fix)
        }
        return try forImage(meta: meta, stage: stage)
    }

    /// A measured build by name (`xless storyboard compile --xcode-build`).
    public static func named(_ build: String, stage: Stage) throws -> XcodeToolsProfile {
        guard let p = all[build] else {
            throw XlessError(stage, "Xcode build \(build) has no measured asset/storyboard tools profile",
                             fix: "use one of \(all.keys.sorted().joined(separator: ", "))")
        }
        return p
    }
}
