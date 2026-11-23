import Foundation
import Testing
@testable import XlessStore

private let set = "en-US/screenshots/APP_IPHONE_67"
private func local(_ name: String, _ md5: String) -> MediaMatcher.Local { .init(path: "\(set)/\(name)", md5: md5) }
private func remote(_ id: String, _ checksum: String?, state: String? = "COMPLETE") -> MediaMatcher.Remote {
    .init(id: id, checksum: checksum, fileName: "\(id).png", state: state)
}

@Test func filesAppleHasAreKeptByChecksum() {
    let r = MediaMatcher.match(files: [local("01-a.png", "m1"), local("02-b.png", "m2")], remote: [remote("R1", "m1"), remote("R2", "m2")],
                               lock: MediaLock(), directory: set, prune: false)
    #expect(r.slots == [.keep("R1"), .keep("R2")])
    #expect(r.uploads.isEmpty && r.deletes.isEmpty && !r.reorder)
    #expect(r.lock == ["\(set)/01-a.png": .init(md5: "m1", appleChecksum: "m1", id: "R1"), "\(set)/02-b.png": .init(md5: "m2", appleChecksum: "m2", id: "R2")])
}

@Test func aPulledCopyIsTheUploadTheLockNames() {
    let lock = MediaLock(files: ["\(set)/01-a.png": .init(md5: "copy", appleChecksum: "orig", id: "R1")])
    let r = MediaMatcher.match(files: [local("01-a.png", "copy")], remote: [remote("R1", "orig")], lock: lock, directory: set, prune: false)
    #expect(r.slots == [.keep("R1")] && r.uploads.isEmpty)
}

@Test func aChangedFileReplacesItsUpload() {
    let lock = MediaLock(files: ["\(set)/01-a.png": .init(md5: "old", appleChecksum: "old", id: "R1")])
    let r = MediaMatcher.match(files: [local("01-a.png", "new"), local("02-b.png", "m2")], remote: [remote("R1", "old"), remote("R2", "m2")],
                               lock: lock, directory: set, prune: false)
    #expect(r.slots == [.upload("\(set)/01-a.png"), .keep("R2")])
    #expect(r.deletes == ["R1"] && r.replaced == ["\(set)/01-a.png"])
    #expect(r.reorder, "the new upload goes first")
}

@Test func anUploadPullCouldNotDownloadStaysInItsPlace() {
    let lock = MediaLock(files: ["\(set)/02-intro.png": .init(md5: nil, appleChecksum: "stream", id: "R2")])
    let r = MediaMatcher.match(files: [local("01-a.png", "m1"), local("03-c.png", "m3")], remote: [remote("R1", "m1"), remote("R2", "stream"), remote("R3", "m3")],
                               lock: lock, directory: set, prune: true)
    #expect(r.slots == [.keep("R1"), .keep("R2"), .keep("R3")])
    #expect(r.pruned.isEmpty && r.deletes.isEmpty && !r.reorder)
}

@Test func extrasAreKeptAtTheEndOrPruned() {
    let files = [local("01-a.png", "m1")]
    let remotes = [remote("RX", "other"), remote("R1", "m1")]
    let kept = MediaMatcher.match(files: files, remote: remotes, lock: MediaLock(), directory: set, prune: false)
    #expect(kept.slots == [.keep("R1"), .keep("RX")] && kept.extras.map(\.id) == ["RX"] && kept.pruned.isEmpty)
    #expect(kept.reorder, "the extra goes after the manifest's files")
    let pruned = MediaMatcher.match(files: files, remote: remotes, lock: MediaLock(), directory: set, prune: true)
    #expect(pruned.slots == [.keep("R1")] && pruned.pruned.map(\.id) == ["RX"] && pruned.deletes.isEmpty && !pruned.reorder)
}

@Test func aFailedUploadIsRemoved() {
    let r = MediaMatcher.match(files: [local("01-a.png", "m1")], remote: [remote("RF", nil, state: "FAILED")], lock: MediaLock(), directory: set, prune: false)
    #expect(r.slots == [.upload("\(set)/01-a.png")] && r.deletes == ["RF"] && r.failed.map(\.id) == ["RF"] && r.extras.isEmpty)
}

@Test func identicalFilesNeedAnUploadEach() {
    let r = MediaMatcher.match(files: [local("01-a.png", "same"), local("02-b.png", "same")], remote: [remote("R1", "same")], lock: MediaLock(), directory: set, prune: false)
    #expect(r.slots == [.keep("R1"), .upload("\(set)/02-b.png")])
}

@Test func aRenamedFileIsNotUploadedAgain() {
    let lock = MediaLock(files: ["\(set)/01-a.png": .init(md5: "m1", appleChecksum: "m1", id: "R1")])
    let r = MediaMatcher.match(files: [local("05-a.png", "m1")], remote: [remote("R1", "m1")], lock: lock, directory: set, prune: false)
    #expect(r.slots == [.keep("R1")] && r.uploads.isEmpty && r.deletes.isEmpty)
}

@Test func onlyTheOrderDiffers() {
    let r = MediaMatcher.match(files: [local("01-b.png", "m2"), local("02-a.png", "m1")], remote: [remote("R1", "m1"), remote("R2", "m2")],
                               lock: MediaLock(), directory: set, prune: false)
    #expect(r.slots == [.keep("R2"), .keep("R1")] && r.uploads.isEmpty && r.reorder)
}
