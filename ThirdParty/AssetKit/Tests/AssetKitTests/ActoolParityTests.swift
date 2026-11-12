import Foundation
import Testing
@testable import AssetKit

/// Parity with Apple's actool on our own neutral catalog, `Fixtures/Parity.xcassets`: PNGs with and without
/// transparency (RGBA, RGBA whose alpha is all 255 but one, RGB, gray, gray+alpha, palette) and colorsets (sRGB,
/// display P3, extended and linear sRGB, a dark appearance). `Fixtures/Parity.expected.<build>.json` holds what
/// `assetutil --info` reports for that Xcode build's actool car of that catalog (recorded by `scripts/assetkit-golden.sh`;
/// no actool output bytes are committed). Every test runs once per recorded build.
///
/// The byte-level tests run everywhere; the `assetutil` comparison needs macOS.
@Suite("actool parity")
struct ActoolParityTests {
    struct Expected: Decodable {
        var actool: String
        var renditions: [Row]
    }

    struct Row: Decodable {
        var name: String
        var assetType: String
        var opaque: Bool?
        var scale: Int?
        var appearance: String?
        var colorspace: String?
        var components: [Double]?

        enum CodingKeys: String, CodingKey {
            case name = "Name", assetType = "AssetType", opaque = "Opaque", scale = "Scale", appearance = "Appearance"
            case colorspace = "Colorspace", components = "Color components"
        }
    }

    /// Grayscale PNGs: actool stores them as 8-bit gray in "gray gamma 22"; AssetKit expands every PNG to ARGB in
    /// sRGB. Both draw the same pixels (checked through UIKit), so this is a known encoding gap, not a rendering one.
    static let grayEncodingGap: Set<String> = ["Gray", "GrayAlpha", "GrayAlphaOpaque"]

    /// Color space IDs in a named color's body, by `assetutil`'s name for them (measured with actool 27.0).
    static let colorSpaceIDs: [String: UInt32] = ["srgb": 1, "p3": 3, "extended srgb": 4, "extended linear srgb": 5]

    static func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "Parity", withExtension: "xcassets", subdirectory: "Fixtures"))
    }

    /// The Xcode builds whose actool output is recorded (`Fixtures/Parity.expected.<build>.json`).
    static let builds = ["17A400", "17B55", "17B100", "17C52", "27A266a", "27A9275", "27B52"]

    static func expectedURL(_ build: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Parity.expected.\(build)", withExtension: "json", subdirectory: "Fixtures"))
    }

    static func expected(_ build: String) throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: Data(contentsOf: expectedURL(build)))
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }

    @Test("Opacity follows actool: opaque iff every alpha is 255, written as MLEC flags 3 (opaque) or 1", arguments: builds)
    func opacityFlags(_ build: String) throws {
        let images = try Self.expected(build).renditions.filter { $0.assetType == "Image" }
        #expect(images.count == 8)
        for row in images {
            let png = try Data(contentsOf: Self.fixture().appendingPathComponent("\(row.name).imageset/\(row.name).png"))
            let context = PNGSource.Context(assetName: row.name, idiom: .universal, scale: .x2, appearance: nil,
                                            gamut: .sRGB, filename: "\(row.name).png", kind: .image)
            let rendition = try #require(PNGSource.renditions(bytes: png, context: context).first)
            guard case .bitmap(let body) = rendition.body else { Issue.record("\(row.name): not a bitmap"); continue }
            let opaque = try #require(row.opaque, "\(row.name): no Opaque in the expected row")
            #expect(body.isOpaque == opaque, "\(row.name)")

            let csi = CSIWriter.bitmap(name: row.name, body: body, scaleFactor: 200)
            #expect(Self.u32(csi, 8) == 0x10, "\(row.name): renditionFlags (actool writes 0x10 for every imageset bitmap)")
            let mlec = CSIHeader.length + Int(Self.u32(csi, 168))
            #expect(csi.subdata(in: mlec..<(mlec + 4)) == Data("MLEC".utf8), "\(row.name)")
            #expect(Self.u32(csi, mlec + 4) == (opaque ? 3 : 1), "\(row.name): MLEC flags")
            #expect(Self.u32(csi, mlec + 8) == 4, "\(row.name): MLEC compression (LZFSE)")
        }
    }

    @Test("App icons follow the same rule (actool 27.0: flags 3 for an opaque icon, 1 for one with transparency)")
    func appIconOpacity() {
        for (alpha, flags) in [(UInt8(255), UInt32(3)), (UInt8(0), UInt32(1))] {
            var pixels = [UInt8](repeating: 255, count: 16)
            pixels[3] = alpha
            let body = BitmapBody(width: 2, height: 2, pixelsBGRA: pixels, colorSpaceID: 1, kind: .appIcon,
                                  isOpaque: PNGSource.isOpaque(pixels), renditionName: "icon.png")
            let csi = CSIWriter.bitmap(name: "AppIcon", body: body, scaleFactor: 100)
            let mlec = CSIHeader.length + Int(Self.u32(csi, 168))
            #expect(Self.u32(csi, mlec + 4) == flags)
        }
    }

    @Test("Named colors are keyed and encoded as actool writes them", arguments: builds)
    func colors(_ build: String) async throws {
        let rows = try Self.expected(build).renditions.filter { $0.assetType == "Color" }
        #expect(rows.count == 7)
        let loaded = try await CatalogLoader().load(catalog: Self.fixture())
        for row in rows {
            let set = try #require(loaded.colorSets.first { $0.name == row.name }, "\(row.name)")
            let renditions = try ColorRenderer.renditions(for: set)
            let dark = row.appearance == "UIAppearanceDark"
            let rendition = try #require(renditions.first { ($0.appearance?.darkLuminosity ?? false) == dark }, "\(row.name)")
            guard case .color(let body) = rendition.body else { Issue.record("\(row.name): not a color"); continue }

            let key = RenditionKey(rendition: rendition)
            #expect(key.element == 85 && key.part == 217 && key.scale == 1, "\(row.name): key \(key)")

            let csi = CSIWriter.color(name: row.name, body: body)
            #expect(Self.u32(csi, 20) == 0, "\(row.name): header scale")
            #expect(Self.u32(csi, 28) == 0, "\(row.name): header color space")
            #expect(Self.u32(csi, 172) == 1, "\(row.name): bitmap count")
            let tvlLength = Int(Self.u32(csi, 168))
            let tvl = csi.subdata(in: CSIHeader.length..<(CSIHeader.length + tvlLength))
            #expect(tvl == CSITVL.encode([.sliceScale(0), .bitmapFlag]), "\(row.name): TVL")
            let p = CSIHeader.length + tvlLength
            #expect(csi.subdata(in: p..<(p + 4)) == Data("RLOC".utf8), "\(row.name): tag")
            #expect(Self.u32(csi, p + 4) == 1, "\(row.name): version")
            #expect(Self.u32(csi, p + 8) == Self.colorSpaceIDs[row.colorspace ?? ""], "\(row.name): color space ID")
            let components = try #require(row.components)
            #expect(Self.u32(csi, p + 12) == UInt32(components.count), "\(row.name): component count")
            for (i, want) in components.enumerated() {
                #expect(Double(bitPattern: Self.u64(csi, p + 16 + 8 * i)) == want, "\(row.name): component \(i)")
            }
        }
    }

    /// The fields `assetutil --info` reports that change how a rendition draws (not its compression, size or digest).
    static let renderingFields = ["AssetType", "Name", "Scale", "Idiom", "Appearance", "Opaque", "Encoding", "ColorModel",
                                  "Colorspace", "BitsPerComponent", "PixelWidth", "PixelHeight", "RenditionName",
                                  "Template Mode", "Color components"]

    @Test("assetutil reads AssetKit's car of the parity catalog as it reads actool's", .enabled(if: ProcessLauncher.isAvailable), arguments: builds)
    func assetutilFields(_ build: String) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcasset-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer()).compile(catalog: Self.fixture())
        let car = scratch.appendingPathComponent("Assets.car")
        try result.carData.write(to: car)
        let run = try ProcessLauncher.run(executable: "/usr/bin/xcrun", arguments: ["assetutil", "--info", car.path])
        #expect(run.exitCode == 0, "\(String(decoding: run.stderr, as: UTF8.self))")
        let ours = try #require(try JSONSerialization.jsonObject(with: run.stdout) as? [[String: Any]]).dropFirst()

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.expectedURL(build))) as? [String: Any])
        let apple = try #require(root["renditions"] as? [[String: Any]])

        func identity(_ r: [String: Any]) -> String {
            ["Name", "Scale", "Idiom", "Appearance"].map { "\(r[$0] ?? "-")" }.joined(separator: "/")
        }
        func field(_ v: Any?) -> String { v.map { "\($0)" } ?? "<absent>" }
        #expect(Set(ours.map(identity)) == Set(apple.map(identity)))
        for want in apple {
            guard let got = ours.first(where: { identity($0) == identity(want) }) else { continue }
            let name = want["Name"] as? String ?? ""
            for f in Self.renderingFields {
                if Self.grayEncodingGap.contains(name), ["Encoding", "ColorModel", "Colorspace"].contains(f) { continue }
                #expect(field(got[f]) == field(want[f]), "\(identity(want)) \(f)")
            }
        }
    }

    /// Xcode 26.2's actool values (docs/research/xcode-tools-by-version.md), passed in as a caller reproducing it would.
    static let header = CARHeaderValues(coreuiVersion: 973, storageVersion: 17,
                                        mainVersionString: "@(#)PROGRAM:CoreUI  PROJECT:CoreUI-973.1",
                                        versionString: "Xcode 26.2 (17C52) via AssetCatalogSimulatorAgent",
                                        authoringTool: "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.3  [IIO-2784.3.4]")

    @Test("The car's tool version fields are the caller's; AssetKit's own by default")
    func headerValues() async throws {
        let ours = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer(), header: Self.header).compile(catalog: Self.fixture())
        let car = ours.carData
        let start = try #require(car.range(of: Data("RATC".utf8))).lowerBound
        #expect(Self.u32(car, start + 4) == 973)
        #expect(Self.u32(car, start + 8) == 17)
        func string(_ offset: Int, _ length: Int) -> String {
            String(decoding: car.subdata(in: (start + offset)..<(start + offset + length)).prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(string(20, 128) == Self.header.mainVersionString)
        #expect(string(148, 256) == Self.header.versionString)
        #expect(car.range(of: Data(Self.header.authoringTool.utf8)) != nil)

        let plain = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer()).compile(catalog: Self.fixture()).carData
        let p = try #require(plain.range(of: Data("RATC".utf8))).lowerBound
        #expect(Self.u32(plain, p + 4) == CARHeaderValues.default.coreuiVersion)
        #expect(CARHeaderValues.default.coreuiVersion == 970)
        #expect(plain.range(of: Data(ExtendedMetadata.defaultAuthoringTool.utf8)) != nil)
    }

    @Test("assetutil reports the caller's tool version fields", .enabled(if: ProcessLauncher.isAvailable))
    func assetutilHeader() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcasset-header-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer(), header: Self.header).compile(catalog: Self.fixture())
        let car = scratch.appendingPathComponent("Assets.car")
        try result.carData.write(to: car)
        let run = try ProcessLauncher.run(executable: "/usr/bin/xcrun", arguments: ["assetutil", "--info", car.path])
        #expect(run.exitCode == 0, "\(String(decoding: run.stderr, as: UTF8.self))")
        let info = try #require(try JSONSerialization.jsonObject(with: run.stdout) as? [[String: Any]]).first
        #expect(info?["CoreUIVersion"] as? Int == 973)
        #expect(info?["StorageVersion"] as? Int == 17)
        #expect(info?["MainVersion"] as? String == Self.header.mainVersionString)
        #expect(info?["AssetStorageVersion"] as? String == Self.header.versionString)
        #expect(info?["Authoring Tool"] as? String == Self.header.authoringTool)
    }
}
