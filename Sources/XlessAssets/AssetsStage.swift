import AssetKit
import Foundation
import XlessCore
import XlessIB
import XlessMachO

public enum AssetsStage {
    /// `profile` gives the image's tools profile (`XcodeToolsProfile.forImage`); it is asked at most once, and only when
    /// an iOS catalog or launch storyboard is compiled (macOS icons do not depend on the Xcode). `xcode`: the tools of a Mac's
    /// Xcode, which then compile in xless's place.
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL, xcode: XcodeAssets? = nil,
                           profile: @escaping () throws -> XcodeToolsProfile) async throws -> URL {
        let once = Once(profile)
        return try await Files.atomicOutput(outputDir) { partial in
            try await compile(into: Files.copyBundle(input, intoFreshDir: partial), platform: platform, config: config, project: project,
                              xcode: xcode, profile: once.value)
        }
    }

    /// The profile, asked for the first time it is needed.
    private final class Once {
        let make: () throws -> XcodeToolsProfile
        var loaded: XcodeToolsProfile?
        init(_ make: @escaping () throws -> XcodeToolsProfile) { self.make = make }
        func value() throws -> XcodeToolsProfile {
            if let loaded { return loaded }
            let p = try make()
            loaded = p
            return p
        }
    }

    @discardableResult
    public static func compile(into app: URL, platform: Platform, config: ProjectConfig, project: URL, xcode: XcodeAssets? = nil,
                               profile: () throws -> XcodeToolsProfile) async throws -> URL {
        if config.distribution(for: platform) == .appStore, xcode?.simulator != true,
           config.assets.map({ appIconSet(catalog: project.appendingPathComponent($0)) == nil }) ?? true {
            // App Store Connect rejects icon-less builds only after a full upload (ITMS-90022/90704).
            let missing = config.assets.map { "\($0) has no .appiconset" } ?? "xless.yml has no `assets:` catalog"
            throw XlessError(.assets, "App Store builds need an app icon, but \(missing)",
                             fix: "add an AppIcon.appiconset with an opaque 1024×1024 PNG to an asset catalog and set `assets:` in xless.yml to it")
        }
        if let assets = config.assets { try await compileCatalog(assets, into: app, platform: platform, config: config, project: project, xcode: xcode, profile: profile) }
        if platform == .ios, let storyboard = config.launchStoryboard {
            try LaunchStoryboard.compile(project.appendingPathComponent(storyboard), into: app, minimumOS: try config.platform(.ios).minimumOS,
                                         xcode: xcode, profile: profile)
        }
        return app
    }

    static func compileCatalog(_ assets: String, into app: URL, platform: Platform, config: ProjectConfig, project: URL, xcode: XcodeAssets? = nil,
                               profile: () throws -> XcodeToolsProfile) async throws {
        let catalog = project.appendingPathComponent(assets)
        let layout = BundleLayout(platform: platform)
        let plistURL = app.appendingPathComponent(layout.infoPlist)
        var info = try Plist.read(plistURL, stage: .assets)
        var added: [String: Any] = [:]
        if let xcode, let actool = xcode.actool {
            added = try xcode.compile(catalog, with: actool, into: layout.resourcesDir.isEmpty ? app : app.appendingPathComponent(layout.resourcesDir),
                                          platform: platform, minimumOS: try config.platform(platform).minimumOS, info: info)
            info.merge(added) { $1 }
        }
        switch platform {
        case .ios where xcode?.actool != nil:
            // what App Store Connect refuses (ITMS-90717), and actool does not
            if xcode?.simulator != true { try checkIconsOpaque(appIconPNGs(catalog: catalog)) }
            if added["CFBundleIcons"] != nil { info.removeValue(forKey: "CFBundleIconFile") }
        case .macos where added["CFBundleIconFile"] != nil: break // actool's .icns
        case .ios:
            let compiled = try await compileIOSCatalog(catalog, deploymentTarget: try config.platform(.ios).minimumOS, profile: try profile())
            try compiled.car.write(to: app.appendingPathComponent("Assets.car"))
            if let icon = compiled.icon {
                for f in icon.files { try f.data.write(to: app.appendingPathComponent(f.name)) }
                let family = (info["UIDeviceFamily"] as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue } ?? [1, 2]
                for (k, v) in XcodeAppIcon.plistAdditions(name: icon.name, deviceFamily: family) { info[k] = v }
                info.removeValue(forKey: "CFBundleIconFile")
            }
        case .macos:
            let icons = try appIconPNGs(catalog: catalog)
            guard !icons.isEmpty else { break }
            let icns: Data
            do { icns = try ICNS.make(pngs: icons) } catch {
                throw XlessError(.assets, "cannot build AppIcon.icns: \(error)", fix: "provide square PNG app icons sized 16–1024")
            }
            try icns.write(to: app.appendingPathComponent("\(layout.resourcesDir)/AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        try Plist.write(info, to: plistURL, stage: .assets)
    }

    /// A compiled iOS asset catalog: the `Assets.car` bytes and, when the catalog's app icon set was compiled, its name
    /// and the loose fallback PNGs that go next to `Assets.car` (`XcodeAppIcon`).
    public struct IOSCatalog {
        public var car: Data
        public var icon: (name: String, files: [LooseFile])?
    }

    /// The one iOS asset-catalog compile path, shared by the `assets` stage and the `actool` shim (`ActoolShim`).
    /// With `includeAppIcon`, the catalog's app icon set is checked (opaque, ITMS-90717) and compiled in Xcode's
    /// single-size form from its 1024px image (`iosIconSource`); without it, app icon sets are left out of the car, as
    /// actool does without `--app-icon`. The car carries `profile`'s actool version fields. Failures are `[assets]` errors.
    public static func compileIOSCatalog(_ catalog: URL, includeAppIcon: Bool = true, deploymentTarget: String,
                                         profile: XcodeToolsProfile) async throws -> IOSCatalog {
        let source: (filename: String, png: Data)?
        if includeAppIcon {
            try checkIconsOpaque(appIconPNGs(catalog: catalog))
            source = try iosIconSource(catalog: catalog)
        } else {
            source = nil
        }
        let result: CompileResult
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("xless-assets-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        do {
            let copy = try normalizedCatalogCopy(catalog, in: scratch, singleSizeIcon: source?.filename)
            if !includeAppIcon {
                for set in (try? fm.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)) ?? [] where set.pathExtension == "appiconset" {
                    try fm.removeItem(at: set)
                }
            }
            result = try await XCAssetCompiler(deploymentTarget: deploymentTarget, header: carHeader(profile)).compile(catalog: copy)
        } catch {
            throw XlessError(.assets, "AssetKit failed on \(catalog.path): \(error)", fix: "remove unsupported asset types (PDF, data sets, stickers) or report to xtool-org/AssetKit")
        }
        guard let bundle = result.appIconBundle, let source else { return IOSCatalog(car: result.carData, icon: nil) }
        return IOSCatalog(car: result.carData, icon: (bundle.primaryIconName, try XcodeAppIcon.looseFiles(name: bundle.primaryIconName, icon1024: source.png)))
    }

    /// The car version fields of `profile`'s actool (AssetKit's `CARHeaderValues`; AssetKit knows nothing of profiles).
    static func carHeader(_ p: XcodeToolsProfile) -> CARHeaderValues {
        CARHeaderValues(coreuiVersion: p.carCoreUIVersion, storageVersion: p.carStorageVersion, mainVersionString: p.carMainVersion,
                        versionString: p.carAssetStorageVersion, authoringTool: p.carAuthoringTool)
    }

    /// Copies the catalog into `dir`, adding the missing "scale" to app icon entries (AssetKit requires it).
    /// With `singleSizeIcon`, the app icon set is first rewritten to Xcode's single-size form around that file.
    static func normalizedCatalogCopy(_ catalog: URL, in dir: URL, singleSizeIcon: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(catalog.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: catalog, to: copy)
        let items = (try? fm.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)) ?? []
        for set in items where set.pathExtension == "appiconset" {
            let url = set.appendingPathComponent("Contents.json")
            guard var data = try? Data(contentsOf: url) else { continue }
            if let singleSizeIcon { data = try singleSizeContents(data, filename: singleSizeIcon) }
            try normalizedAppIconContents(data).write(to: url)
        }
        return copy
    }

    /// Xcode's single-size app icon format omits "scale"; AssetKit needs it. Adds "1x" where missing, and files a
    /// single-size icon under the iphone and ipad idioms as actool does.
    static func normalizedAppIconContents(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var images = root["images"] as? [[String: Any]] else {
            throw XlessError(.assets, "AppIcon Contents.json is not a valid image set", fix: "re-save the asset catalog in Xcode or fix the JSON")
        }
        for i in images.indices where images[i]["scale"] == nil { images[i]["scale"] = "1x" }
        if XcodeAppIcon.isSingleSize(data), let icon = images.first(where: { $0["filename"] != nil }) {
            images = XcodeAppIcon.phoneAndPadImages(icon)
        }
        root["images"] = images
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// `contentsJSON` reduced to one universal 1024x1024 iOS image (`XcodeAppIcon.isSingleSize` form), keeping "info".
    static func singleSizeContents(_ contentsJSON: Data, filename: String) throws -> Data {
        let root = (try? JSONSerialization.jsonObject(with: contentsJSON)) as? [String: Any] ?? [:]
        var out: [String: Any] = ["images": [["filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"]]]
        out["info"] = root["info"]
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    }

    /// The 1024px image an iOS app icon is compiled from, or nil without an app icon set. A single-size set uses its
    /// one image. A multi-size set uses its 1024px image (the ios-marketing one first): xless always compiles iOS icons
    /// as Xcode's single-size form, the only form App Store Connect has validated (per-size AssetKit output was
    /// rejected with 90023, no 152px iPad icon).
    static func iosIconSource(catalog: URL) throws -> (filename: String, png: Data)? {
        guard let set = appIconSet(catalog: catalog) else { return nil }
        let data = (try? Data(contentsOf: set.appendingPathComponent("Contents.json"))) ?? Data()
        let images = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["images"] as? [[String: Any]] ?? []
        let withFiles = images.filter { ($0["filename"] as? String).map { !$0.isEmpty } ?? false }
        func png(_ image: [String: Any]) throws -> Data {
            let name = image["filename"] as! String
            guard let d = try? Data(contentsOf: set.appendingPathComponent(name)) else {
                throw XlessError(.assets, "app icon \(name) referenced but missing", fix: "add \(set.path)/\(name)")
            }
            return d
        }
        func is1024(_ image: [String: Any]) throws -> Bool {
            let points = (image["size"] as? String)?.split(separator: "x").first.flatMap { Double($0) }
            let scale = (image["scale"] as? String).flatMap { Double($0.dropLast()) } ?? 1
            if let points, points * scale == 1024 { return true }
            let h = try? PNGHeader.parse(png(image))
            return h?.width == 1024 && h?.height == 1024
        }
        let pick = try XcodeAppIcon.isSingleSize(data) ? withFiles.first
            : withFiles.first { $0["idiom"] as? String == "ios-marketing" } ?? withFiles.first(where: is1024)
        guard let pick else {
            throw XlessError(.assets, "\(set.path) is a multi-size app icon set without a 1024×1024 image; iOS icons are compiled from it",
                             fix: "add a 1024×1024 ios-marketing icon")
        }
        return (pick["filename"] as! String, try png(pick))
    }

    static func appIconSet(catalog: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "appiconset" }
    }

    /// PNG files referenced by the catalog's single .appiconset.
    public static func appIconPNGs(catalog: URL) throws -> [Data] {
        guard let set = appIconSet(catalog: catalog) else { return [] }
        struct Contents: Decodable { struct Image: Decodable { var filename: String? }; var images: [Image] }
        guard let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
              let contents = try? JSONDecoder().decode(Contents.self, from: data) else {
            throw XlessError(.assets, "\(set.path)/Contents.json is missing or invalid", fix: "re-save the asset catalog in Xcode or fix the JSON")
        }
        return try contents.images.compactMap(\.filename).map { name in
            guard let d = try? Data(contentsOf: set.appendingPathComponent(name)) else {
                throw XlessError(.assets, "app icon \(name) referenced but missing", fix: "add \(set.path)/\(name)")
            }
            return d
        }
    }

    /// App Store Connect rejects iOS app icons with an alpha channel (ITMS-90717).
    public static func checkIconsOpaque(_ pngs: [Data]) throws {
        for png in pngs {
            let h: PNGHeader
            do { h = try PNGHeader.parse(png) } catch {
                throw XlessError(.assets, "an app icon is not a PNG", fix: "export app icons as PNG")
            }
            if h.hasAlpha {
                throw XlessError(.assets, "app icon \(h.width)x\(h.height) has an alpha channel (ITMS-90717)",
                                 fix: "re-export the icon without transparency (e.g. `sips -s format jpeg … | sips -s format png …` or flatten in your editor)")
            }
        }
    }
}
