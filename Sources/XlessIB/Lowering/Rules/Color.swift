import Foundation
import XlessCore

/// `UIColor` (docs/research/nib-encoding.md, section 6 "UIColor"; corpus `color-*`).
///
/// Keys, in order: [`UISystemColorName`] or [`UIDynamicCatalogName`, `UIDynamicCatalogUseNibBundle`],
/// `UIColorComponentCount`, the components (`UIRed`/`UIGreen`/`UIBlue` or `UIWhite`) each followed by its `-Double`
/// key when needed, `UIAlpha` [+ `UIAlpha-Double`], `NSRGB`/`NSWhite` (`%.3g` text), `NSColorSpace` (2 RGB, 4 gray).
/// Equal colors are one shared object (`order-uniquing`).
struct ColorEncoding: Hashable, CustomStringConvertible {
    enum Name: Hashable { case none, system(String), catalog(String) }
    var name: Name
    /// RGB (three values) or gray (one value).
    var components: [Double]
    var alpha: Double
    /// The values come straight from decimal input (sRGB, gray 2.2, named-color resource, system table): they are
    /// rounded to 10 significant digits, and a `-Double` key follows each rounded value whose float differs from it
    /// (`color-srgb-precision`, `color-srgb-small-grid`). False for the missing-color placeholder.
    var decimalInput: Bool

    /// `rounded` colors hold their values rounded to 10 significant digits (`round10`), so colors equal after
    /// rounding are one object (`color-srgb-small-grid`). Named-color resources keep the input values
    /// (`color-named-small-grid`: 13/255 stays 0.050980392156862744).
    init(name: Name, components: [Double], alpha: Double, decimalInput: Bool, rounded: Bool = true) {
        let round = decimalInput && rounded
        self.name = name
        self.components = round ? components.map(Self.round10) : components
        self.alpha = round ? Self.round10(alpha) : alpha
        self.decimalInput = decimalInput
    }

    var description: String { "\(name)|\(components)|\(alpha)|\(decimalInput)" }

    /// The placeholder for a named color without a `<namedColor>` resource (`color-named-missing`).
    static func missingNamed(_ name: String) -> ColorEncoding {
        ColorEncoding(name: .catalog(name), components: [0.329, 0.324, 0.478], alpha: 0.33, decimalInput: false)
    }

    func encode(_ b: ArchiveBuilder) -> ObjectRef {
        b.unique("UIColor|\(self)") {
            let c = b.object("UIColor", fallback: "NSColor")
            switch name {
            case .none: break
            case .system(let n): b.set(c, "UISystemColorName", b.string(n))
            case .catalog(let n):
                b.set(c, "UIDynamicCatalogName", b.string(n))
                b.set(c, "UIDynamicCatalogUseNibBundle", .bool(true))
            }
            let gray = components.count == 1
            b.set(c, "UIColorComponentCount", .int8(gray ? 2 : 4))
            func component(_ key: String, _ v: Double) {
                b.set(c, key, .float(Float(v)))
                if decimalInput, Double(Float(v)) != v { b.set(c, key + "-Double", .double(v)) }
            }
            for (key, v) in zip(gray ? ["UIWhite"] : ["UIRed", "UIGreen", "UIBlue"], components) { component(key, v) }
            component("UIAlpha", alpha)
            let text = (components + (alpha == 1 ? [] : [alpha])).map { String(format: "%.3g", $0) }.joined(separator: " ")
            b.set(c, gray ? "NSWhite" : "NSRGB", .data(Data(text.utf8)))
            b.set(c, "NSColorSpace", .int8(gray ? 4 : 2))
            return c
        }
    }

    /// ibtool's value of a decimal component: the input rounded to 10 significant digits like C `%.10g`
    /// (`color-srgb-precision`, `color-white-inexact`, `color-srgb-small-grid`: 13/255 → 0.05098039216, 1e-11 stays,
    /// 0.0999999999949 → 0.09999999999). The float key is this value rounded to float (0.3000000268220902 →
    /// 0.3000000268 → 0.3, not 0.30000004).
    static func round10(_ v: Double) -> Double {
        guard v != 0, v.isFinite, let r = Double(String(format: "%.10g", v)) else { return v }
        return r
    }
}

enum ColorRule {
    static let knownAttributes: Set<String> = [
        "key", "systemColor", "name", "red", "green", "blue", "white", "alpha", "colorSpace", "customColorSpace",
        "xcode11CocoaTouchSystemColor", "cocoaTouchSystemColor",
    ]

    /// Lowers a `<color>` element to its encoding in the nib `l` is building (system colors follow its encoding).
    /// `encoded: false` checks the element for a color that is not written (the default tint): a system color then needs
    /// no measurement under the nib's encoding.
    static func encoding(_ color: IBColor, lowering l: ViewNibLowering, encoded: Bool = true) throws -> ColorEncoding {
        let doc = l.doc
        let line = doc.element(at: color.rawPath)?.line
        let a = color.rawAttributes
        try LoweringError.checkAttributes(a, known: knownAttributes, element: "color", line: line)
        // Only the pair Xcode 11 wrote in its template is verified (`xcode-template`).
        let legacyKeys = ["xcode11CocoaTouchSystemColor", "cocoaTouchSystemColor"]
        if legacyKeys.contains(where: { a[$0] != nil }) {
            guard case .other = color.value, a["xcode11CocoaTouchSystemColor"] == "systemBackgroundColor", a["cocoaTouchSystemColor"] == "whiteColor" else {
                throw LoweringError.unsupported("color \(describe(a))", line: line)
            }
        }
        // Component colors: every corpus color spells out alpha, and all values lie in [0, 1].
        if case .rgba = color.value, a["alpha"] == nil { throw LoweringError.unsupported("color without alpha", line: line) }
        if case .white = color.value, a["alpha"] == nil { throw LoweringError.unsupported("color without alpha", line: line) }
        for key in ["red", "green", "blue", "white", "alpha"] {
            if let s = a[key], let v = Double(s), !(0...1).contains(v) {
                throw LoweringError.unsupported("color component \(key)=\"\(s)\" (outside 0…1)", line: line)
            }
        }
        switch color.value {
        case .system(let name):
            return try system(name, line: line, lowering: l, encoded: encoded)
        case .other:
            // Xcode 11 era: `xcode11CocoaTouchSystemColor` (with a legacy `cocoaTouchSystemColor` fallback) is the
            // system color (`xcode-template`).
            guard let name = color.rawAttributes["xcode11CocoaTouchSystemColor"] else {
                throw LoweringError.unsupported("color \(describe(color.rawAttributes))", line: line)
            }
            return try system(name, line: line, lowering: l)
        case .named(let name):
            // ibtool fails (exit status 255, no message) on a named text or tint color without a `<namedColor>`
            // resource; as a background it compiles to the placeholder (`color-named-missing`, `label-color-forms`).
            if let key = a["key"], key != "backgroundColor", !doc.resources.contains(where: { if case .namedColor(name, .some) = $0 { true } else { false } }) {
                throw LoweringError.unsupported("named color \"\(name)\" as \(key) without a <namedColor> resource (ibtool fails on it)", line: line)
            }
            return try named(name, lowering: l, line: line)
        case .rgba(let r, let g, let bl, let a, let space, let custom):
            guard space == "custom", custom == "sRGB" else { throw unsupportedSpace(space, custom, line: line) }
            return ColorEncoding(name: .none, components: [r, g, bl], alpha: a, decimalInput: true)
        case .white(let w, let a, let space, let custom):
            guard space == "custom", custom == "genericGamma22GrayColorSpace" else { throw unsupportedSpace(space, custom, line: line) }
            let (w, a) = (ColorEncoding.round10(w), ColorEncoding.round10(a))
            // ibtool snaps a gray within a small tolerance of 0 or 1 to black, white or clear (1.1e-07 → blackColor,
            // 0.99999999 → whiteColor; 1e-06 and 0.999999 stay), with a tolerance that is not pinned down.
            for (key, v) in [("white", w), ("alpha", a)] where v != 0 && v != 1 && !(grayBand...(1 - grayBand)).contains(v) {
                throw LoweringError.openQuestion("gray color \(key)=\"\(color.rawAttributes[key] ?? "")\" within \(grayBand) of 0 or 1 (ibtool snaps such grays to black or white with an unverified tolerance)",
                                                 line: line, fix: "use 0 or 1 exactly, or a value further from them")
            }
            // Gray black, white and clear are the named UIKit colors (`color-white-black`, `-white`, `color-clear`).
            let name: ColorEncoding.Name = switch (w, a) {
            case (0, 1): .system("blackColor")
            case (1, 1): .system("whiteColor")
            case (0, 0): .system("clearColor")
            default: .none
            }
            return ColorEncoding(name: name, components: [w], alpha: a, decimalInput: true)
        }
    }

    /// Gray components closer than this to 0 or 1 (but not equal) are refused (`color-white-near-black`,
    /// `color-white-near-white`; `color-white-small-grid` proves 1e-06 and 0.999999).
    static let grayBand = 1e-06

    static func encode(_ color: IBColor, lowering l: ViewNibLowering) throws -> ObjectRef {
        try encoding(color, lowering: l).encode(l.b)
    }

    /// A system color as the image's ibtool writes it into this nib (`XcodeToolsProfile.NibEncoding`): the table below,
    /// with the encoding's overrides, its components rounded to 10 digits or not; a color the encoding was not measured
    /// with is refused.
    static func system(_ name: String, line: Int?, lowering l: ViewNibLowering, encoded: Bool = true) throws -> ColorEncoding {
        guard var (components, alpha) = systemColors[name] else {
            throw LoweringError.unsupported("system color \"\(name)\" (not in the verified table of docs/research/nib-encoding.md)", line: line)
        }
        let e = l.encoding, p = l.profile
        if encoded, let verified = e.verifiedSystemColors, !verified.contains(name) {
            throw XlessError(.ib, "unsupported: system color \"\(name)\"\(LoweringError.at(line)) in a storyboard of plain views under Xcode \(p.xcodeVersion) (\(p.xcodeBuild)): that ibtool writes such a nib with its own system colors, measured only for \(verified.sorted().joined(separator: ", ")) (see docs/research/xcode-tools-by-version.md)",
                             fix: "use one of those system colors or an sRGB color, or pin an Xcode that writes it and prepare its pack (xless setup --xcode <Xcode.xip>): (\(XcodeToolsProfile.all.values.filter { $0.nibPlainViews.verifiedSystemColors == nil }.map(\.xcodeBuild).sorted().joined(separator: ", ")))")
        }
        if let rgb = e.systemColorOverrides[name] { components = rgb.map { Double($0) / 255 } }
        return ColorEncoding(name: .system(name), components: components, alpha: alpha, decimalInput: true, rounded: e.roundsSystemColors)
    }

    /// A named (asset catalog) color takes its components from the `<namedColor>` resource; the catalog is never read
    /// (`color-named-exists`, `color-named-missing`).
    static func named(_ name: String, lowering l: ViewNibLowering, line: Int?) throws -> ColorEncoding {
        let doc = l.doc
        for case .namedColor(let n, let resource) in doc.resources where n == name {
            guard let resource else { return .missingNamed(name) }
            let resolved = try encoding(resource, lowering: l)
            guard case .none = resolved.name, case .rgba(let r, let g, let bl, let a, _, _) = resource.value else {
                throw LoweringError.unsupported("named color \"\(name)\" whose resource is not an sRGB color (only sRGB resources are verified)",
                                                line: doc.element(at: resource.rawPath)?.line)
            }
            return ColorEncoding(name: .catalog(name), components: [r, g, bl], alpha: a, decimalInput: true, rounded: false)
        }
        return .missingNamed(name)
    }

    static func unsupportedSpace(_ space: String?, _ custom: String?, line: Int?) -> XlessError {
        let s = space == "custom" ? (custom ?? "custom") : (space ?? "(none)")
        if ["displayP3", "calibratedRGB", "calibratedWhite"].contains(s) {
            return LoweringError.openQuestion("\(s) color (ibtool's conversion to sRGB is not reproduced)", line: line,
                                              fix: "use an sRGB or Generic Gray Gamma 2.2 color, or a named color")
        }
        return LoweringError.unsupported("color space \(s)", line: line)
    }

    /// `name="value" …` in key order (without `key` unless `keepKey`), for error messages.
    static func describe(_ a: [String: String], keepKey: Bool = false) -> String {
        a.keys.sorted().filter { keepKey || $0 != "key" }.map { "\($0)=\"\(a[$0]!)\"" }.joined(separator: " ")
    }

    // MARK: System colors

    /// ibtool's own values for system colors, light appearance (`color-system-table`; the storyboard's
    /// `<resources><systemColor>` value is ignored, `color-system-altered-resource`). Components are n/255. Xcode 26.2
    /// writes the same values except in a nib of plain views (`XcodeToolsProfile.NibEncoding.systemColorOverrides`).
    static let systemColors: [String: (components: [Double], alpha: Double)] = {
        func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> ([Double], Double) { ([r, g, b].map { Double($0) / 255 }, a) }
        func gray(_ w: Int, _ a: Double = 1) -> ([Double], Double) { ([Double(w) / 255], a) }
        let label = (60, 60, 67), background2 = rgb(242, 242, 247), blue = rgb(0, 136, 255)
        return [
            "systemBackgroundColor": gray(255), "tertiarySystemBackgroundColor": gray(255), "secondarySystemGroupedBackgroundColor": gray(255),
            "secondarySystemBackgroundColor": background2, "systemGroupedBackgroundColor": background2,
            "tertiarySystemGroupedBackgroundColor": background2, "systemGray6Color": background2, "groupTableViewBackgroundColor": background2,
            "labelColor": gray(0), "darkTextColor": gray(0),
            "secondaryLabelColor": rgb(label.0, label.1, label.2, 0.6),
            "tertiaryLabelColor": rgb(label.0, label.1, label.2, 76.0 / 255), "placeholderTextColor": rgb(label.0, label.1, label.2, 76.0 / 255),
            "quaternaryLabelColor": rgb(label.0, label.1, label.2, 45.0 / 255),
            "separatorColor": rgb(label.0, label.1, label.2, 0.12),
            "opaqueSeparatorColor": rgb(198, 198, 200),
            "linkColor": rgb(0, 122, 255),
            "systemFillColor": rgb(120, 120, 128, 0.2), "secondarySystemFillColor": rgb(120, 120, 128, 0.16),
            "tertiarySystemFillColor": rgb(118, 118, 128, 0.12), "quaternarySystemFillColor": rgb(116, 116, 128, 0.08),
            "systemRedColor": rgb(255, 56, 60), "systemOrangeColor": rgb(255, 141, 40), "systemYellowColor": rgb(255, 204, 0),
            "systemGreenColor": rgb(52, 199, 89), "systemMintColor": rgb(0, 200, 179), "systemTealColor": rgb(0, 195, 208),
            "systemCyanColor": rgb(0, 192, 232), "systemBlueColor": blue, "tintColor": blue,
            "systemIndigoColor": rgb(97, 85, 245), "systemPurpleColor": rgb(203, 48, 224), "systemPinkColor": rgb(255, 45, 85),
            "systemBrownColor": rgb(172, 127, 94),
            "systemGrayColor": rgb(142, 142, 147), "systemGray2Color": rgb(174, 174, 178), "systemGray3Color": rgb(199, 199, 204),
            "systemGray4Color": rgb(209, 209, 214), "systemGray5Color": rgb(229, 229, 234),
            "lightTextColor": gray(255, 0.6),
        ]
    }()
}
