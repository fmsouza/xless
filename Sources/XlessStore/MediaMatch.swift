import Foundation

/// Which of a set's local files App Store Connect already has, and what a push must upload, delete and reorder. Pure:
/// planning computes it from the files' MD5s, the set's items and media.lock.
///
/// A local file *is* an item when the item's `sourceFileChecksum` is the file's MD5 (xless sent it), or when
/// media.lock ties the file's MD5 (under its path, else under any path: a renamed copy) to the item's checksum (a copy
/// `pull` downloaded). A lock
/// entry without an MD5 is an item `pull` could not download: it stays, in its path's place. A file that is no item is
/// uploaded; when the lock ties its path to an item (the file changed), that item is replaced. Items that failed
/// processing are removed; any other item the manifest does not have is an extra, kept at the end, or with `prune`
/// left to the planner to delete.
public enum MediaMatcher {
    public struct Local: Sendable, Equatable {
        public var path: String
        public var md5: String
        public init(path: String, md5: String) { self.path = path; self.md5 = md5 }
    }

    public struct Remote: Sendable, Equatable {
        public var id: String
        public var checksum: String?
        public var fileName: String?
        public var state: String?
        public init(id: String, checksum: String?, fileName: String?, state: String?) {
            self.id = id; self.checksum = checksum; self.fileName = fileName; self.state = state
        }
    }

    public enum Slot: Sendable, Equatable {
        case keep(String)
        /// A local file, by path.
        case upload(String)
    }

    public struct Result: Sendable, Equatable {
        /// The set as it should be, in order (kept extras last).
        public var slots: [Slot] = []
        /// Items to delete with the set's change: replaced by a changed file, or failed.
        public var deletes: [String] = []
        /// Paths of changed files whose old upload is replaced.
        public var replaced: [String] = []
        public var failed: [Remote] = []
        /// Items the manifest does not have, kept (no prune).
        public var extras: [Remote] = []
        /// Items the manifest does not have, to delete (prune).
        public var pruned: [Remote] = []
        /// media.lock entries of the files App Store Connect has.
        public var lock: [String: MediaLock.Entry] = [:]
        /// Whether the order must be sent: files are uploaded (App Store Connect appends them), or the kept items'
        /// order differs from the set's.
        public var reorder = false

        public var uploads: [String] { slots.compactMap { if case .upload(let p) = $0 { return p }; return nil } }
    }

    /// - Parameter directory: the set's directory, relative to the manifest (`en-US/screenshots/APP_IPHONE_67`).
    public static func match(files: [Local], remote: [Remote], lock: MediaLock, directory: String, prune: Bool) -> Result {
        var result = Result()
        var claimed: Set<String> = []
        func take(_ match: (Remote) -> Bool) -> Remote? {
            guard let found = remote.first(where: { !claimed.contains($0.id) && match($0) }) else { return nil }
            claimed.insert(found.id)
            return found
        }
        func lockedItem(_ entry: MediaLock.Entry) -> Remote? {
            take { entry.id != nil && $0.id == entry.id && $0.checksum == entry.appleChecksum }
                ?? entry.appleChecksum.flatMap { checksum in take { $0.checksum == checksum } }
        }

        // Position (by file name) → slot.
        var byName: [String: Slot] = [:]
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }

        // 1. Files App Store Connect has: by the lock (a pulled copy), else by checksum.
        var unmatched: [Local] = []
        for file in files {
            var item: Remote?
            if let entry = lock.files[file.path], entry.md5 == file.md5 { item = lockedItem(entry) }
            if item == nil { item = take { $0.checksum == file.md5 } }
            // A pulled copy that was renamed or moved: the lock knows its MD5 under its old path.
            if item == nil {
                for (_, entry) in lock.files.values.sorted(by: { $0.key < $1.key }) where entry.md5 == file.md5 {
                    if let found = lockedItem(entry) { item = found; break }
                }
            }
            guard let item else { unmatched.append(file); continue }
            byName[name(file.path)] = .keep(item.id)
            result.lock[file.path] = MediaLock.Entry(md5: file.md5, appleChecksum: item.checksum, id: item.id)
        }
        // 2. Uploads pull could not download: in place.
        let local = Set(files.map(\.path))
        for (path, entry) in lock.files.values.sorted(by: { $0.key < $1.key })
        where entry.md5 == nil && !local.contains(path) && (path as NSString).deletingLastPathComponent == directory {
            if let item = lockedItem(entry) { byName[name(path)] = .keep(item.id) }
        }
        // 3. The other files are uploaded, replacing the upload the lock ties their path to.
        for file in unmatched {
            byName[name(file.path)] = .upload(file.path)
            if let entry = lock.files[file.path], entry.md5 != nil, let old = lockedItem(entry) {
                result.deletes.append(old.id)
                result.replaced.append(file.path)
            }
        }
        result.slots = MediaOrder.sorted(Array(byName.keys)).map { byName[$0]! }

        // 4. What is left at App Store Connect.
        for item in remote where !claimed.contains(item.id) {
            if item.state == "FAILED" {
                result.failed.append(item)
                result.deletes.append(item.id)
            } else if prune {
                result.pruned.append(item)
            } else {
                result.extras.append(item)
                result.slots.append(.keep(item.id))
            }
        }

        let kept = result.slots.compactMap { if case .keep(let id) = $0 { return id }; return nil }
        let current = remote.map(\.id).filter(kept.contains)
        result.reorder = result.slots.count > 1 && (!result.uploads.isEmpty || kept != current)
        return result
    }
}
