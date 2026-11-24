import Testing
import Foundation
@testable import XlessPackage
@testable import XlessCore

/// `Fixtures/dmg/early.hfs.gz` and `late.hfs.gz`: the same tree made into an HFS+ volume by the real mkfs.hfsplus and
/// libdmg-hfsplus `hfsplus`, the way DmgBuilder makes it, two seconds apart and the second under a umask of 002
/// (Fixtures/README.md). The tools stamp every date with the time of the run and mkfs draws a random volume UUID.
private func fixture(_ name: String, into root: URL) throws -> URL {
    let gz = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dmg/\(name).hfs.gz")
    let out = root.appendingPathComponent("\(name).hfs")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Shell.run("sh", ["-c", "exec gzip -dc \"$1\" > \"$2\"", "sh", gz.path, out.path], stage: .package)
    return out
}

private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hfsdates-\(UUID())") }

private let app = "Hello Tauri.app"
private let appDate = Date(timeIntervalSince1970: 1_767_225_600)      // 2026-01-01 00:00:00 UTC
private let sourceDates: [String: Date] = [
    app: appDate,
    "\(app)/Contents": Date(timeIntervalSince1970: 1_767_225_000),
    "\(app)/Contents/MacOS": Date(timeIntervalSince1970: 1_767_224_000),
    "\(app)/Contents/MacOS/x": Date(timeIntervalSince1970: 1_748_779_200.75),   // 2025-06-01 12:00:00.75: seconds kept
    "\(app)/Contents/Resources": Date(timeIntervalSince1970: 1_767_223_000),
    "\(app)/Contents/Resources/Résumé.txt": Date(timeIntervalSince1970: 1_767_222_000),
    "\(app)/Contents/Frameworks": Date(timeIntervalSince1970: 1_767_221_000),
    "\(app)/Contents/Frameworks/F.framework": Date(timeIntervalSince1970: 1_767_220_000),
    "\(app)/Contents/Frameworks/F.framework/F": Date(timeIntervalSince1970: 1_767_219_000),
    "\(app)/Contents/Frameworks/F.framework/Versions": Date(timeIntervalSince1970: 1_767_218_000),
    "\(app)/Contents/Frameworks/F.framework/Versions/A": Date(timeIntervalSince1970: 1_767_217_000),
    "\(app)/Contents/Frameworks/F.framework/Versions/A/F": Date(timeIntervalSince1970: 1_767_216_000),
    "\(app)/Contents/Frameworks/F.framework/Versions/Current": Date(timeIntervalSince1970: 1_740_787_200),   // 2025-03-01
]
private let fallback = Date(timeIntervalSince1970: 1_767_225_600)

private func hfs(_ date: Date) -> UInt32 { UInt32(Int64(date.timeIntervalSince1970.rounded(.down)) + 2_082_844_800) }

private func pin(_ image: URL) throws { try HFSPlusDates.pin(image: image, fallback: fallback) { sourceDates[$0] } }

@Test func pinnedImagesMadeApartAndUnderAnotherUmaskAreIdentical() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let early = try fixture("early", into: root), late = try fixture("late", into: root)
    #expect(try Data(contentsOf: early) != Data(contentsOf: late))   // the tools' dates and random UUID
    try pin(early); try pin(late)
    #expect(try Data(contentsOf: early) == Data(contentsOf: late))
}

/// Every date a tool stamped becomes the source's own date for that path; what has no source (the volume root, the
/// `/Applications` link mkfs or `hfsplus symlink` made) and the volume header take the fallback; a date the tools left
/// zero (never backed up) stays zero.
@Test func pinnedDatesAreTheSourceDatesElseTheFallback() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let image = try fixture("late", into: root)
    let before = try HFSPlusDates.read(image: image)
    #expect(Set(before.entries.keys) == Set(sourceDates.keys).union(["", "Applications"]))
    try pin(image)
    let after = try HFSPlusDates.read(image: image)
    for (path, dates) in after.entries {
        let wanted = hfs(sourceDates[path] ?? fallback)
        for (old, new) in zip(before.entries[path]!, dates) { #expect(new == (old == 0 ? 0 : wanted), "\(path)") }
    }
    #expect(after.entries["\(app)/Contents/MacOS/x"]?[1] == hfs(Date(timeIntervalSince1970: 1_748_779_200)))
    // The image is not a whole number of 4 KiB blocks: mkfs's alternate header ends the file, libdmg's the last block.
    #expect(after.alternateVolumeDates.count == 2)
    for (old, new) in zip(([before.volumeDates] + before.alternateVolumeDates).joined(), ([after.volumeDates] + after.alternateVolumeDates).joined()) {
        #expect(new == (old == 0 ? 0 : hfs(fallback)))
    }
    #expect(after.alternateVolumeDates.allSatisfy { $0 == after.volumeDates })
}

/// The volume UUID mkfs drew at random becomes a digest of the pinned volume: the same in every header, never zero, the
/// same for the same content and another for other content.
@Test func theVolumeIDIsStableNonZeroAndFollowsTheContent() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let early = try fixture("early", into: root), late = try fixture("late", into: root)
    try pin(early); try pin(late)
    let a = try HFSPlusDates.read(image: early)
    #expect(a.alternateVolumeIDs == [a.volumeID, a.volumeID] && a.volumeID.count == 8 && a.volumeID.contains { $0 != 0 })
    #expect(try HFSPlusDates.read(image: late).volumeID == a.volumeID)
    try HFSPlusDates.pin(image: late, fallback: fallback.addingTimeInterval(1)) { sourceDates[$0] }
    #expect(try HFSPlusDates.read(image: late).volumeID != a.volumeID)
}

/// Pinning twice changes nothing more: the second pass finds the dates it wrote and the same content.
@Test func pinningIsIdempotent() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let image = try fixture("early", into: root)
    try pin(image)
    let once = try Data(contentsOf: image)
    try pin(image)
    #expect(try Data(contentsOf: image) == once)
}

/// libdmg cannot grow the catalog past the eight extents the volume header holds; a catalog that would continue in the
/// extents overflow file is refused, not half pinned.
@Test func aCatalogPastItsExtentsIsRefused() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let image = try fixture("early", into: root)
    let handle = try FileHandle(forUpdating: image)
    try handle.seek(toOffset: 1024 + 272 + 12)                         // catalogFile.totalBlocks
    var blocks = try #require(try handle.read(upToCount: 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    blocks += 1
    try handle.seek(toOffset: 1024 + 272 + 12)
    try handle.write(contentsOf: withUnsafeBytes(of: blocks.bigEndian) { Data($0) })
    try handle.close()
    let original = try Data(contentsOf: image)
    do { try pin(image); Issue.record("accepted") } catch let e as XlessError {
        #expect(e.stage == .package && e.cause.contains("extents overflow"))
    }
    #expect(try Data(contentsOf: image) == original)
}

@Test func aFileThatIsNotAnHFSPlusVolumeIsRefused() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, data) in [("short", Data("H+".utf8)), ("zeros", Data(count: 64 * 1024))] {
        let image = root.appendingPathComponent(name)
        try data.write(to: image)
        do { try pin(image); Issue.record("accepted \(name)") } catch let e as XlessError {
            #expect(e.stage == .package && e.cause.contains("not an HFS+ volume"), "\(name)")
        }
    }
}

/// A broken catalog (a leaf chain that loops, a record offset outside its node) is an error, never a crash or a hang.
@Test func aCorruptCatalogIsAnErrorNotACrash() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let image = try fixture("early", into: root)
    var data = try Data(contentsOf: image)
    func u32(_ at: Int) -> Int { data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    let blockSize = u32(1024 + 40), catalog = u32(1024 + 272 + 16) * blockSize
    let nodeSize = Int(data[catalog + 32]) << 8 | Int(data[catalog + 33])
    let leaf = catalog + u32(catalog + 24) * nodeSize
    // Every leaf points forward to itself: the chain never ends.
    var looped = data
    let first = u32(catalog + 24)
    looped.replaceSubrange(leaf..<leaf + 4, with: withUnsafeBytes(of: UInt32(first).bigEndian) { Data($0) })
    try looped.write(to: image)
    do { try pin(image); Issue.record("accepted a loop") } catch let e as XlessError { #expect(e.stage == .package) }
    // The first record's offset points past the node.
    data.replaceSubrange(leaf + nodeSize - 2..<leaf + nodeSize, with: [0xFF, 0xF0])
    try data.write(to: image)
    do { try pin(image); Issue.record("accepted a bad offset") } catch let e as XlessError { #expect(e.stage == .package) }
}

/// DmgBuilder's pin over the fixture volumes, with a signed app of the same tree on disk: each entry takes its date from
/// the app (a symlink's own), what the app does not hold takes the app's date, and the two volumes become the same bytes.
@Test func dmgBuilderPinsTheVolumeWithTheSignedAppsDates() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let early = try fixture("early", into: root), late = try fixture("late", into: root)
    let signed = root.appendingPathComponent("signed/\(app)")
    let fw = signed.appendingPathComponent("Contents/Frameworks/F.framework")
    let fm = FileManager.default
    try fm.createDirectory(at: signed.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.createDirectory(at: signed.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fw.appendingPathComponent("Versions/A"), withIntermediateDirectories: true)
    for (path, text) in [("Contents/MacOS/x", "bin"), ("Contents/Resources/Résumé.txt", "cv"), ("Contents/Frameworks/F.framework/Versions/A/F", "fw")] {
        try Data(text.utf8).write(to: signed.appendingPathComponent(path))
    }
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fm.createSymbolicLink(atPath: fw.appendingPathComponent("F").path, withDestinationPath: "Versions/Current/F")
    for (path, date) in sourceDates.sorted(by: { $0.key > $1.key }) {   // children before their parents
        try PkgBuilder.setLinkDate(root.appendingPathComponent("signed/\(path)").path, date)
    }
    try DmgBuilder.pinDates(image: early, app: signed)
    try DmgBuilder.pinDates(image: late, app: signed)
    #expect(try Data(contentsOf: early) == Data(contentsOf: late))
    let pinned = try HFSPlusDates.read(image: early)
    for (path, date) in sourceDates { #expect(pinned.entries[path]?[1] == hfs(date), "\(path)") }
    #expect(pinned.entries["Applications"]?[1] == hfs(appDate) && pinned.entries[""]?[1] == hfs(appDate))
    #expect(pinned.volumeDates[1] == hfs(appDate))
}
