import Foundation
import XlessCore

/// `xless shim actool`: the `actool` command lines Swift Build runs for an iOS asset catalog on Linux
/// (`SWBApplePlatform/AssetCatalogCompiler.swift`; argv and outputs recorded in docs/research/react-native-ios-contract.md,
/// "Tool shims"). The compile goes through `AssetsStage.compileIOSCatalog`, the same AssetKit path as the `assets`
/// stage. Any flag or value outside that subset is refused with exit 70 and the argv (`Unsupported`), as `XcrunShim`.
/// The shim answers as the image's Xcode's actool (`XcodeToolsProfile`, from `/opt/xless/toolchain-meta.json`, read once
/// per call): its `--version`, the dependency info and the car's version fields. An image whose Xcode has no profile is
/// refused with exit 70.
public enum ActoolShim {
    public struct Unsupported: Error, CustomStringConvertible, Equatable {
        public let argv: [String]
        public let reason: String
        public var description: String { "actool shim: unsupported call (\(reason)): actool \(argv.joined(separator: " "))" }
    }

    public struct Result: Equatable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
    }

    enum Invocation: Equatable {
        case version
        case tagCombinations(catalogs: [URL])
        case compile(Compile)
    }

    struct Compile: Equatable {
        var catalogs: [URL] = []
        var outputDir: URL
        var dependencyInfo: URL?
        var partialInfoPlist: URL?
        var appIcon: String?
        var accentColor: String?
        var deviceFamily: [Int]
        var deploymentTarget: String
        var bundleIdentifier: String?
        var swiftSymbols: URL?
        var objcSymbols: URL?
        var symbolIndex: URL?

        /// Swift Build's `GenerateAssetSymbols` task: actool then writes only the symbol files.
        var generatesSymbols: Bool { swiftSymbols != nil || objcSymbols != nil || symbolIndex != nil }
    }

    // MARK: - Arguments

    static func parse(_ args: [String], cwd: URL) throws(Unsupported) -> Invocation {
        func refuse(_ reason: String) -> Unsupported { Unsupported(argv: args, reason: reason) }
        func path(_ p: String) -> URL { URL(fileURLWithPath: p, relativeTo: cwd).standardizedFileURL }
        var values: [String: String] = [:], flags = Set<String>(), devices: [String] = [], catalogs: [URL] = []
        let valued: Set<String> = ["--compile", "--output-format", "--export-dependency-info", "--output-partial-info-plist",
                                   "--app-icon", "--accent-color", "--enable-on-demand-resources", "--development-region",
                                   "--minimum-deployment-target", "--platform", "--bundle-identifier",
                                   "--generate-swift-asset-symbol-extensions", "--generate-swift-asset-symbols",
                                   "--generate-objc-asset-symbols", "--generate-asset-symbol-index"]
        let boolean: Set<String> = ["--version", "--print-asset-tag-combinations", "--notices", "--warnings", "--errors", "--compress-pngs"]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--target-device" {
                guard i + 1 < args.count else { throw refuse("--target-device needs a value") }
                devices.append(args[i + 1]); i += 2; continue
            }
            if valued.contains(a) {
                guard i + 1 < args.count else { throw refuse("\(a) needs a value") }
                guard values[a] == nil else { throw refuse("\(a) given twice") }
                values[a] = args[i + 1]; i += 2; continue
            }
            if boolean.contains(a) { flags.insert(a); i += 1; continue }
            guard !a.hasPrefix("-") else { throw refuse("unknown option \(a)") }
            guard a.hasSuffix(".xcassets") else { throw refuse("input \(a) is not an .xcassets catalog") }
            catalogs.append(path(a)); i += 1
        }

        if flags.contains("--version") {
            guard args.count == 1 || (args.count == 3 && values["--output-format"] == "xml1") else { throw refuse("--version takes only --output-format xml1") }
            return .version
        }
        if flags.contains("--print-asset-tag-combinations") {
            guard values == ["--output-format": "xml1"], flags.count == 1, devices.isEmpty, !catalogs.isEmpty else {
                throw refuse("--print-asset-tag-combinations takes only --output-format xml1 and catalogs")
            }
            return .tagCombinations(catalogs: catalogs)
        }
        guard let out = values["--compile"] else { throw refuse("no --compile, --version or --print-asset-tag-combinations") }
        guard !catalogs.isEmpty else { throw refuse("no input catalog") }
        guard values["--output-format"] == "human-readable-text" else { throw refuse("--output-format must be human-readable-text") }
        // Xcode 27.0's actool writes the same Assets.car for both (measured); only its loose icon PNGs differ
        // (iPhone-optimized for the device), and the shim writes standard PNGs for both.
        guard ["iphoneos", "iphonesimulator"].contains(values["--platform"]) else { throw refuse("--platform must be iphoneos or iphonesimulator") }
        guard let target = values["--minimum-deployment-target"], DottedVersion(target) != nil else { throw refuse("--minimum-deployment-target must be a version") }
        if let odr = values["--enable-on-demand-resources"], odr != "YES" && odr != "NO" { throw refuse("--enable-on-demand-resources must be YES or NO") }
        guard !devices.isEmpty else { throw refuse("no --target-device") }
        var family: [Int] = []
        for d in devices {
            switch d {
            case "iphone": family.append(1)
            case "ipad": family.append(2)
            default: throw refuse("--target-device \(d) (supported: iphone, ipad)")
            }
        }
        var c = Compile(catalogs: catalogs, outputDir: path(out), deviceFamily: family, deploymentTarget: target)
        c.dependencyInfo = values["--export-dependency-info"].map(path)
        c.partialInfoPlist = values["--output-partial-info-plist"].map(path)
        c.appIcon = values["--app-icon"]
        c.accentColor = values["--accent-color"]
        c.bundleIdentifier = values["--bundle-identifier"]
        c.swiftSymbols = values["--generate-swift-asset-symbols"].map(path)
        c.objcSymbols = values["--generate-objc-asset-symbols"].map(path)
        c.symbolIndex = values["--generate-asset-symbol-index"].map(path)
        if c.generatesSymbols {
            guard c.bundleIdentifier != nil else { throw refuse("asset symbols need --bundle-identifier") }
            if c.swiftSymbols != nil, values["--generate-swift-asset-symbol-extensions"] != "NO" {
                throw refuse("Swift asset symbol extensions are not supported (set ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = NO)")
            }
        } else if values["--bundle-identifier"] != nil || values["--generate-swift-asset-symbol-extensions"] != nil {
            throw refuse("asset symbol options without an asset symbol output")
        }
        return .compile(c)
    }

    // MARK: - Running

    /// Runs one actool command line. Tool errors (a missing app icon set, an alpha icon, an asset type AssetKit cannot
    /// write) are reported the way actool reports them (exit 1, `<catalog>: error: …` under `/* com.apple.actool.errors */`).
    /// `profile` gives the image's tools profile (default: from the image's toolchain metadata); it is asked once.
    public static func run(_ args: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                           profile loadProfile: () throws -> XcodeToolsProfile = { try XcodeToolsProfile.forImage(stage: .assets) }) async -> Result {
        let invocation: Invocation
        do { invocation = try parse(args, cwd: cwd) } catch {
            return Result(stdout: "", stderr: "\(error)\n", exitCode: 70)
        }
        let profile: XcodeToolsProfile
        do { profile = try loadProfile() } catch {
            return Result(stdout: "", stderr: "\(error)\n", exitCode: 70)
        }
        switch invocation {
        case .version:
            return Result(stdout: xmlPlist("""
                <dict>
                \t<key>com.apple.actool.version</key>
                \t<dict>
                \t\t<key>bundle-version</key>
                \t\t<string>\(profile.actoolBundleVersion)</string>
                \t\t<key>short-bundle-version</key>
                \t\t<string>\(profile.actoolShortVersion)</string>
                \t</dict>
                </dict>
                """), stderr: "", exitCode: 0)
        case .tagCombinations(let catalogs):
            if let tagged = catalogs.lazy.compactMap(firstOnDemandResourceTag).first {
                return Result(stdout: xmlPlist("""
                    <dict>
                    \t<key>com.apple.actool.errors</key>
                    \t<array>
                    \t\t<dict>
                    \t\t\t<key>description</key>
                    \t\t\t<string>\(xmlEscape("\(tagged): on-demand resource tags are not supported by xless"))</string>
                    \t\t</dict>
                    \t</array>
                    </dict>
                    """), stderr: "", exitCode: 1)
            }
            return Result(stdout: xmlPlist("<dict>\n\t<key>com.apple.actool.asset-tag-combinations</key>\n\t<array/>\n</dict>"), stderr: "", exitCode: 0)
        case .compile(let c):
            var report = Report()
            var stderr = ""
            do {
                try await compile(c, profile: profile, report: &report)
            } catch {
                // actool's own wording on stdout (a Swift Build error); xless's cause and fix on stderr, as IbtoolShim.
                let e = (error as? XlessError) ?? XlessError(.assets, "\(error)", fix: "check the asset catalog")
                report.errors.append("\(c.catalogs[0].path): error: \(e.cause)")
                stderr = "xless actool shim: \(e)\n"
            }
            return Result(stdout: report.text, stderr: stderr, exitCode: report.errors.isEmpty ? 0 : 1)
        }
    }

    struct Report {
        var errors: [String] = []
        var warnings: [String] = []
        var outputs: [URL] = []
        var text: String {
            var s = ""
            if !errors.isEmpty { s += "/* com.apple.actool.errors */\n" + errors.map { $0 + "\n" }.joined() }
            if !warnings.isEmpty { s += "/* com.apple.actool.notices */\n" + warnings.map { $0 + "\n" }.joined() }
            return s + "/* com.apple.actool.compilation-results */\n" + outputs.map { $0.path + "\n" }.joined() + "\n"
        }
    }

    static func compile(_ c: Compile, profile: XcodeToolsProfile, report: inout Report) async throws {
        let fm = FileManager.default
        if c.generatesSymbols {
            let assets = try AssetSymbols.assets(in: c.catalogs)
            let backDeploy = DottedVersion(c.deploymentTarget)! < DottedVersion("17.0")!
            let out = try AssetSymbols.generate(assets, bundleIdentifier: c.bundleIdentifier!, backDeploy: backDeploy)
            report.warnings += out.warnings
            for (url, data) in [(c.symbolIndex, out.index), (c.objcSymbols, Data(out.objc.utf8)), (c.swiftSymbols, Data(out.swift.utf8))] {
                guard let url else { continue }
                try write(data, to: url)
                report.outputs.append(url)
            }
            return
        }

        let scratch = fm.temporaryDirectory.appendingPathComponent("xless-actool-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let catalog = c.catalogs.count == 1 ? c.catalogs[0] : try merged(c.catalogs, in: scratch)
        let sets = try setNames(catalog)
        if let icon = c.appIcon, !sets.appIcons.contains(icon) {
            throw XlessError(.assets, "None of the input catalogs contained a matching stickers icon set, app icon set, or icon stack named  \"\(icon)\".",
                             fix: "add \(icon).appiconset to the catalog or fix ASSETCATALOG_COMPILER_APPICON_NAME")
        }
        // Top-level sets only: those are the ones the car writer handles as app icons (or leaves out without --app-icon).
        if let nested = sets.nestedAppIcons.sorted().first {
            throw XlessError(.assets, "app icon set \(nested) is inside a folder of the catalog; xless compiles app icon sets only at the top level",
                             fix: "move \(nested) to the top level of the asset catalog")
        }
        if let icon = c.appIcon, sets.appIcons.count > 1 {
            throw XlessError(.assets, "the catalogs hold app icon sets \(sets.appIcons.sorted().joined(separator: ", ")); xless compiles only the primary one (\(icon)) and needs it to be the only one",
                             fix: "move alternate app icons out of the catalog")
        }
        var plist: [String: Any] = [:]
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: c.outputDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw XlessError(.assets, "The output directory \"\(c.outputDir.path)\" does not exist.", fix: "create it first (Swift Build does)")
        }
        if c.appIcon != nil || !sets.other.isEmpty {
            let compiled = try await AssetsStage.compileIOSCatalog(catalog, includeAppIcon: c.appIcon != nil, deploymentTarget: c.deploymentTarget,
                                                                       profile: profile)
            if let icon = compiled.icon {
                for f in icon.files {
                    try write(f.data, to: c.outputDir.appendingPathComponent(f.name))
                    report.outputs.append(c.outputDir.appendingPathComponent(f.name))
                }
                plist.merge(XcodeAppIcon.plistAdditions(name: icon.name, deviceFamily: c.deviceFamily)) { $1 }
            }
            try write(compiled.car, to: c.outputDir.appendingPathComponent("Assets.car"))
            report.outputs.append(c.outputDir.appendingPathComponent("Assets.car"))
        }
        if let accent = c.accentColor {
            if sets.colors.contains(accent) {
                plist["NSAccentColorName"] = accent
            } else {
                report.warnings.append("\(c.catalogs[0].path): warning: Accent color ‘\(accent)’ is not present in any asset catalogs.")
            }
        }
        if let url = c.partialInfoPlist {
            try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: url)
            report.outputs.insert(url, at: 0)
        }
        if let url = c.dependencyInfo {
            try write(dependencyInfo(inputs: c.catalogs, outputs: report.outputs, actoolBundleVersion: profile.actoolBundleVersion), to: url)
        }
    }

    /// ld64-style dependency info, as actool writes it: a version record, one input record per catalog, one output
    /// record per file written (`builtin-linkAssetCatalog` and llbuild read it).
    static func dependencyInfo(inputs: [URL], outputs: [URL], actoolBundleVersion: String) -> Data {
        var d = Data([0x00]) + Data("actool-\(actoolBundleVersion)".utf8) + Data([0x00])
        for i in inputs { d += Data([0x10]) + Data(i.path.utf8) + Data([0x00]) }
        for o in outputs { d += Data([0x40]) + Data(o.path.utf8) + Data([0x00]) }
        return d
    }

    struct SetNames { var appIcons: Set<String> = [], nestedAppIcons: [String] = [], colors: Set<String> = [], other: Set<String> = [] }

    /// App icon set names, color set names, and the names of every other set, anywhere in the catalog.
    static func setNames(_ catalog: URL) throws -> SetNames {
        var names = SetNames()
        guard let e = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil) else { return names }
        for case let url as URL in e {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            switch url.pathExtension {
            case "appiconset":
                names.appIcons.insert(name)
                if url.deletingLastPathComponent().resolvingSymlinksInPath().path != catalog.resolvingSymlinksInPath().path {
                    names.nestedAppIcons.append(url.lastPathComponent)
                }
                e.skipDescendants()
            case "colorset": names.colors.insert(name); names.other.insert(name); e.skipDescendants()
            case "": continue
            default: names.other.insert(name); e.skipDescendants()
            }
        }
        return names
    }

    /// One catalog holding the top-level items of `catalogs` (Swift Build passes all of a target's catalogs to one
    /// actool call). Two catalogs with an item of the same name are refused.
    static func merged(_ catalogs: [URL], in scratch: URL) throws -> URL {
        let fm = FileManager.default
        let out = scratch.appendingPathComponent("Merged.xcassets", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: out.appendingPathComponent("Contents.json"))
        for catalog in catalogs {
            for item in try fm.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil) where item.lastPathComponent != "Contents.json" {
                let dst = out.appendingPathComponent(item.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else {
                    throw XlessError(.assets, "\(item.lastPathComponent) is in more than one asset catalog of the target", fix: "rename one of them")
                }
                try fm.copyItem(at: item, to: dst)
            }
        }
        return out
    }

    /// The first set in `catalog` that declares on-demand resource tags, if any.
    static func firstOnDemandResourceTag(_ catalog: URL) -> String? {
        guard let e = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == "Contents.json" {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = root["properties"] as? [String: Any], props["on-demand-resource-tags"] != nil else { continue }
            return url.deletingLastPathComponent().path
        }
        return nil
    }

    static func write(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            throw XlessError(.assets, "cannot write \(url.path): \(error.localizedDescription)", fix: "check disk space and permissions")
        }
    }

    static func xmlPlist(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(body)
        </plist>

        """
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacing(scalar: "&", with: "&amp;").replacing(scalar: "<", with: "&lt;").replacing(scalar: ">", with: "&gt;")
    }
}
