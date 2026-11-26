import Foundation
import XlessCore

/// The asset-symbol files actool writes for Swift Build's `GenerateAssetSymbols` task
/// (`--generate-swift-asset-symbols`, `--generate-objc-asset-symbols`, `--generate-asset-symbol-index`), reproduced
/// black-box from actool 27.0 (25098) output for our own catalogs (docs/research/react-native-ios-contract.md,
/// "Tool shims").
///
/// The Swift file is part of the link contract, not only of the API: its imports decide which Swift overlays the
/// target autolinks (an empty file dropped `libswiftCoreAudio` from HelloPIF). Below iOS 17 actool imports
/// Foundation, AppKit, UIKit, SwiftUI and DeveloperToolsSupport (each behind `canImport`) and declares its own
/// `ColorResource`/`ImageResource` ("backwards deployment support"); from iOS 17 it imports only Foundation and
/// DeveloperToolsSupport and extends that module's types.
public enum AssetSymbols {
    public enum Kind: String, Sendable { case color, image }

    public struct Asset: Equatable, Sendable {
        /// The asset name as the catalog spells it (the set directory name without its extension).
        public var name: String
        public var kind: Kind
        /// The catalog the asset is in, and the set's path relative to it (`Folder/x.imageset`).
        public var catalog: URL
        public var relativePath: String
    }

    /// Color and image sets of `catalogs`, sorted by name (byte order, as actool sorts). Group folders are flattened;
    /// folders that provide a namespace are refused, because the car writer does not namespace asset names.
    public static func assets(in catalogs: [URL]) throws -> [Asset] {
        var out: [Asset] = []
        for catalog in catalogs {
            func walk(_ dir: URL, _ rel: String) throws {
                let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = item.lastPathComponent
                    let path = rel.isEmpty ? name : "\(rel)/\(name)"
                    switch item.pathExtension {
                    case "colorset", "imageset":
                        out.append(Asset(name: item.deletingPathExtension().lastPathComponent,
                                         kind: item.pathExtension == "colorset" ? .color : .image, catalog: catalog, relativePath: path))
                    case "":
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
                        if providesNamespace(item) {
                            throw XlessError(.assets, "\(catalog.path): folder \(path) provides a namespace; asset catalog namespaces are not supported",
                                             fix: "turn off \"Provides Namespace\" for the folder (or move its assets out of it)")
                        }
                        try walk(item, path)
                    default:
                        continue   // app icon sets and other set types have no symbols
                    }
                }
            }
            try walk(catalog, "")
        }
        return out.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    static func providesNamespace(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Contents.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["properties"] as? [String: Any] else { return false }
        return (props["provides-namespace"] as? Bool) == true || (props["provides-namespace"] as? NSNumber)?.boolValue == true
    }

    // MARK: - Names

    /// The words of an asset name, split at spaces, `-`, `_`, lower→upper case changes, the end of an upper-case run
    /// followed by a lower-case letter (`URLIcon` → `URL`, `Icon`) and letter/digit changes. nil for names outside
    /// the verified subset (ASCII letters, digits, space, `-`, `_`; at least one letter or digit).
    static func words(_ name: String) -> [String]? {
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && (isLetter($0) || isDigit($0) || " -_".unicodeScalars.contains($0)) }) else { return nil }
        var words: [String] = []
        for chunk in name.split(whereSeparator: { " -_".contains($0) }) {
            let cs = Array(chunk.unicodeScalars)
            var word = String.UnicodeScalarView()
            for (i, c) in cs.enumerated() {
                if let prev = word.last {
                    let lowerToUpper = isLower(prev) && isUpper(c)
                    let acronymEnd = isUpper(prev) && isUpper(c) && i + 1 < cs.count && isLower(cs[i + 1])
                    let digitChange = isDigit(prev) != isDigit(c)
                    if lowerToUpper || acronymEnd || digitChange { words.append(String(word)); word = .init() }
                }
                word.append(c)
            }
            if !word.isEmpty { words.append(String(word)) }
        }
        return words.isEmpty ? nil : words
    }

    /// actool's Swift symbol: lower camel case of the words, a trailing "Color"/"Image" word dropped (for colors and
    /// images alike), a single all-caps word kept as is, `_` before a leading digit, keywords in backticks.
    public static func swiftSymbol(_ name: String) -> String? {
        guard var w = words(name) else { return nil }
        if w.count > 1, ["color", "image"].contains(w.last!.lowercased()) { w.removeLast() }
        var first = w[0]
        if w.count == 1, first.count > 1, first.unicodeScalars.allSatisfy(isUpper) {
            // kept as is ("ABC")
        } else if first.unicodeScalars.allSatisfy({ !isLower($0) }) {
            first = first.lowercased()
        } else {
            first = first.prefix(1).lowercased() + first.dropFirst()
        }
        var symbol = first + w.dropFirst().map(capitalizedFirst).joined()
        if let c = symbol.unicodeScalars.first, isDigit(c) { symbol = "_" + capitalizedFirst(symbol) }
        return swiftKeywords.contains(symbol) ? "`\(symbol)`" : symbol
    }

    /// actool's Objective-C constant: `ACColorName`/`ACImageName` + the upper camel case of all words.
    public static func objcSymbol(_ name: String, kind: Kind) -> String? {
        guard let w = words(name) else { return nil }
        return (kind == .color ? "ACColorName" : "ACImageName") + w.map(capitalizedFirst).joined()
    }

    static func capitalizedFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func isUpper(_ c: Unicode.Scalar) -> Bool { c >= "A" && c <= "Z" }
    static func isLower(_ c: Unicode.Scalar) -> Bool { c >= "a" && c <= "z" }
    static func isLetter(_ c: Unicode.Scalar) -> Bool { isUpper(c) || isLower(c) }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "Any", "as",
        "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
    ]

    // MARK: - Files

    public struct Output: Sendable {
        public var swift: String
        public var objc: String
        public var index: Data
        /// One line per asset whose name is outside the verified subset (no symbol is generated for it).
        public var warnings: [String]
    }

    /// The three files for `assets` (from `assets(in:)`). `backDeploy` is true below iOS 17.
    public static func generate(_ assets: [Asset], bundleIdentifier: String, backDeploy: Bool) throws -> Output {
        var warnings: [String] = []
        var named: [(asset: Asset, swift: String, objc: String)] = []
        for a in assets {
            guard let s = swiftSymbol(a.name), let o = objcSymbol(a.name, kind: a.kind) else {
                warnings.append("\(a.catalog.path)/\(a.relativePath): warning: xless generates no asset symbol for the name \"\(a.name)\" (supported: ASCII letters, digits, space, - and _)")
                continue
            }
            named.append((a, s, o))
        }
        return Output(swift: swiftFile(named.map { ($0.asset, $0.swift) }, backDeploy: backDeploy),
                      objc: objcFile(named.map { ($0.asset, $0.objc) }, bundleIdentifier: bundleIdentifier),
                      index: try indexPlist(named), warnings: warnings)
    }

    static func swiftFile(_ symbols: [(Asset, String)], backDeploy: Bool) -> String {
        let colorType = backDeploy ? "ColorResource" : "DeveloperToolsSupport.ColorResource"
        let imageType = backDeploy ? "ImageResource" : "DeveloperToolsSupport.ImageResource"
        let colorAvailability = backDeploy ? "@available(iOS 11.0, macOS 10.13, tvOS 11.0, *)" : "@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)"
        let imageAvailability = backDeploy ? "@available(iOS 11.0, macOS 10.7, tvOS 11.0, *)" : "@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)"
        // First symbol wins on a collision (`Color` and `ColorColor` both map to `color`); the later one becomes a
        // `#warning`, as actool writes it.
        func members(_ kind: Kind, _ type: String) -> String {
            var seen = Set<String>()
            return symbols.filter { $0.0.kind == kind }.map { a, s in
                guard seen.insert(s).inserted else {
                    return "\n    #warning(\"The \\\"\(swiftString(a.name))\\\" \(kind.rawValue) asset name resolves to the symbol \\\"\(s)\\\" which already exists. Try renaming the asset.\")\n"
                }
                return "\n    /// The \"\(a.name)\" asset catalog \(kind.rawValue) resource.\n    static let \(s) = \(type)(name: \"\(swiftString(a.name))\", bundle: resourceBundle)\n"
            }.joined()
        }
        var out = "import Foundation\n"
        if backDeploy {
            for module in ["AppKit", "UIKit", "SwiftUI"] { out += "#if canImport(\(module))\nimport \(module)\n#endif\n" }
        }
        out += """
        #if canImport(DeveloperToolsSupport)
        import DeveloperToolsSupport
        #endif

        #if SWIFT_PACKAGE
        private let resourceBundle = Foundation.Bundle.module
        #else
        private class ResourceBundleClass {}
        private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
        #endif

        // MARK: - Color Symbols -

        \(colorAvailability)
        extension \(colorType) {
        \(members(.color, colorType))
        }

        // MARK: - Image Symbols -

        \(imageAvailability)
        extension \(imageType) {
        \(members(.image, imageType))
        }

        """
        out += "\n" + (backDeploy ? backDeploymentSupport : "")
        return out
    }

    /// The declarations actool adds below iOS 17 so that `ColorResource`/`ImageResource` and the framework
    /// initialisers taking them exist on older systems (same API as DeveloperToolsSupport's).
    static let backDeploymentSupport = """
    // MARK: - Backwards Deployment Support -

    /// A color resource.
    struct ColorResource: Swift.Hashable, Swift.Sendable {

        /// An asset catalog color resource name.
        fileprivate let name: Swift.String

        /// An asset catalog color resource bundle.
        fileprivate let bundle: Foundation.Bundle

        /// Initialize a `ColorResource` with `name` and `bundle`.
        init(name: Swift.String, bundle: Foundation.Bundle) {
            self.name = name
            self.bundle = bundle
        }

    }

    /// An image resource.
    struct ImageResource: Swift.Hashable, Swift.Sendable {

        /// An asset catalog image resource name.
        fileprivate let name: Swift.String

        /// An asset catalog image resource bundle.
        fileprivate let bundle: Foundation.Bundle

        /// Initialize an `ImageResource` with `name` and `bundle`.
        init(name: Swift.String, bundle: Foundation.Bundle) {
            self.name = name
            self.bundle = bundle
        }

    }

    #if canImport(AppKit)
    @available(macOS 10.13, *)
    @available(macCatalyst, unavailable)
    extension AppKit.NSColor {

        /// Initialize a `NSColor` with a color resource.
        convenience init(resource: ColorResource) {
            self.init(named: NSColor.Name(resource.name), bundle: resource.bundle)!
        }

    }

    protocol _ACResourceInitProtocol {}
    extension AppKit.NSImage: _ACResourceInitProtocol {}

    @available(macOS 10.7, *)
    @available(macCatalyst, unavailable)
    extension _ACResourceInitProtocol {

        /// Initialize a `NSImage` with an image resource.
        init(resource: ImageResource) {
            self = resource.bundle.image(forResource: NSImage.Name(resource.name))! as! Self
        }

    }
    #endif

    #if canImport(UIKit)
    @available(iOS 11.0, tvOS 11.0, *)
    @available(watchOS, unavailable)
    extension UIKit.UIColor {

        /// Initialize a `UIColor` with a color resource.
        convenience init(resource: ColorResource) {
    #if !os(watchOS)
            self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
    #else
            self.init()
    #endif
        }

    }

    @available(iOS 11.0, tvOS 11.0, *)
    @available(watchOS, unavailable)
    extension UIKit.UIImage {

        /// Initialize a `UIImage` with an image resource.
        convenience init(resource: ImageResource) {
    #if !os(watchOS)
            self.init(named: resource.name, in: resource.bundle, compatibleWith: nil)!
    #else
            self.init()
    #endif
        }

    }
    #endif

    #if canImport(SwiftUI)
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    extension SwiftUI.Color {

        /// Initialize a `Color` with a color resource.
        init(_ resource: ColorResource) {
            self.init(resource.name, bundle: resource.bundle)
        }

    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    extension SwiftUI.Image {

        /// Initialize an `Image` with an image resource.
        init(_ resource: ImageResource) {
            self.init(resource.name, bundle: resource.bundle)
        }

    }
    #endif
    """

    static func objcFile(_ symbols: [(Asset, String)], bundleIdentifier: String) -> String {
        var out = """
        #import <Foundation/Foundation.h>

        #if __has_attribute(swift_private)
        #define AC_SWIFT_PRIVATE __attribute__((swift_private))
        #else
        #define AC_SWIFT_PRIVATE
        #endif


        """
        if !symbols.isEmpty {
            out += "/// The resource bundle ID.\nstatic NSString * const ACBundleID AC_SWIFT_PRIVATE = @\"\(objcString(bundleIdentifier))\";\n\n"
            for kind in [Kind.color, .image] {
                for (a, s) in symbols where a.kind == kind {
                    out += "/// The \"\(a.name)\" asset catalog \(kind.rawValue) resource.\nstatic NSString * const \(s) AC_SWIFT_PRIVATE = @\"\(objcString(a.name))\";\n\n"
                }
            }
        }
        return out + "#undef AC_SWIFT_PRIVATE\n"
    }

    static func indexPlist(_ symbols: [(asset: Asset, swift: String, objc: String)]) throws -> Data {
        func entries(_ kind: Kind) -> [[String: String]] {
            symbols.filter { $0.asset.kind == kind }.map {
                ["catalogPath": $0.asset.catalog.path, "objcSymbol": $0.objc, "relativePath": "./\($0.asset.relativePath)", "swiftSymbol": $0.swift]
            }
        }
        let root: [String: Any] = ["colors": entries(.color), "images": entries(.image), "symbols": [Any]()]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    static func swiftString(_ s: String) -> String { s.replacing(scalar: "\\", with: "\\\\").replacing(scalar: "\"", with: "\\\"") }
    static func objcString(_ s: String) -> String { swiftString(s) }
}
