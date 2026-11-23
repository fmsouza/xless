import Foundation
@testable import XlessStore

/// A PNG's signature, IHDR (and optionally a tRNS chunk) and IEND: all `ImageInfo` reads.
func pngHeader(_ width: Int, _ height: Int, colorType: UInt8 = 2, transparency: Bool = false) -> Data {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    b += be32(13) + Array("IHDR".utf8) + be32(width) + be32(height) + [8, colorType, 0, 0, 0] + [0, 0, 0, 0]
    if transparency { b += be32(6) + Array("tRNS".utf8) + [0, 0, 0, 0, 0, 0] + [0, 0, 0, 0] }
    b += be32(0) + Array("IDAT".utf8) + [0, 0, 0, 0]
    b += be32(0) + Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82]
    return Data(b)
}

/// A JPEG's SOI, an APP0 segment and a start-of-frame segment (`sof` 0xC0 baseline, 0xC2 progressive).
func jpegHeader(_ width: Int, _ height: Int, sof: UInt8 = 0xC0) -> Data {
    var b: [UInt8] = [0xFF, 0xD8]
    b += [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
    b += [0xFF, sof, 0x00, 0x11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3]
    b += [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
    b += [0xFF, 0xD9]
    return Data(b)
}

/// A fresh temporary directory (removed by the caller with `defer`).
func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xless-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func write(_ text: String, _ path: String, in dir: URL) throws {
    try write(Data(text.utf8), path, in: dir)
}

func write(_ data: Data, _ path: String, in dir: URL) throws {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func read(_ path: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8) }

let completeAppYAML = """
    bundleID: com.example.app
    sku: EXAMPLE1
    platform: IOS
    primaryLocale: en-US
    version: "1.0"
    copyright: 2026 Example Inc.
    contentRights: DOES_NOT_USE_THIRD_PARTY_CONTENT
    categories:
      primary: UTILITIES
    ageRating:
      violenceCartoonOrFantasy: NONE
      gambling: false
    review:
      contact:
        firstName: Ada
        lastName: Lovelace
        phone: "+1 555 0100"
        email: ada@example.com
    eula: standard
    pricing:
      baseTerritory: USA
      price: free
    availability:
      territories: all
      newTerritories: true

    """

/// A manifest `validate` finds nothing wrong with: `appstore/` inside a fresh directory.
func completeManifest() throws -> URL {
    let root = try tempDir()
    let dir = root.appendingPathComponent("appstore")
    try write(completeAppYAML, "app.yml", in: dir)
    try write("Example\n", "en-US/name.txt", in: dir)
    try write("Does things.\n", "en-US/description.txt", in: dir)
    try write("tools,example\n", "en-US/keywords.txt", in: dir)
    try write("https://example.com/support\n", "en-US/support_url.txt", in: dir)
    try write("https://example.com/privacy\n", "en-US/privacy_url.txt", in: dir)
    try write(pngHeader(1320, 2868), "en-US/screenshots/APP_IPHONE_67/01-home.png", in: dir)
    try write(jpegHeader(2868, 1320), "en-US/screenshots/APP_IPHONE_67/02-landscape.jpg", in: dir)
    return dir
}
