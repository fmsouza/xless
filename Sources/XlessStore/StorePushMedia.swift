import Foundation
import XlessASC
import XlessCore

// The `media` part: per locale and display type, the screenshot and preview sets. A set's files are compared with
// App Store Connect's by MD5 (`MediaMatcher`): only new and changed files are uploaded, the set is put in the
// directory's order, and what App Store Connect has beyond the directory is kept (noted) or, with --prune, deleted.
// App Review attachments (`review`) and the export compliance document (`declarations`) use the same helpers.

extension PushContext {
    mutating func planMedia() async throws {
        // A version push creates is planned again once it exists.
        guard !manifest.locales.isEmpty, let versionID = target.versionID else { return }
        let lock = MediaLock.read(dir)
        let remote = Dictionary(try await asc.versionLocalizations(of: versionID).compactMap { l in l.attributes.locale.map { ($0, l.id) } },
                                uniquingKeysWith: { a, _ in a })
        for locale in manifest.orderedLocales {
            let listing = manifest.locales[locale]!
            let localization: StoreMediaWork.Localization
            var screenshotSets: [StoreRemoteSet] = [], previewSets: [StoreRemoteSet] = []
            if let id = remote[locale] {
                localization = .id(id)
                screenshotSets = try await asc.screenshotSets(of: id)
                previewSets = try await asc.previewSets(of: id)
            } else {
                guard !(listing.screenshots + listing.previews).allSatisfy({ $0.files.isEmpty }) else { continue }
                guard options.parts.contains(.text) else {
                    throw XlessError(.account, "App Store Connect has no version text for \(locale) yet, so \(name)/\(locale)'s screenshots and previews have nowhere to go",
                                     fix: "push the text part too (drop --only, or add text to it): it creates the locale")
                }
                localization = .locale(locale, versionID: versionID)
            }
            try planSets(.screenshots, locale: locale, local: listing.screenshots, remote: screenshotSets, localization: localization, lock: lock)
            try planSets(.previews, locale: locale, local: listing.previews, remote: previewSets, localization: localization, lock: lock)
        }
    }

    /// One locale's screenshot (or preview) sets: each directory against App Store Connect's set of its type, and
    /// App Store Connect's sets with no directory.
    mutating func planSets(_ kind: StoreMediaKind, locale: String, local: [MediaSet], remote: [StoreRemoteSet],
                           localization: StoreMediaWork.Localization, lock: MediaLock) throws {
        let folder = kind == .screenshots ? "screenshots" : "previews"
        var sets = local
        // A set whose every upload pull could not download has no directory, only media.lock entries: still the manifest's.
        for set in remote where !sets.contains(where: { $0.type == set.type }) {
            let directory = "\(locale)/\(folder)/\(set.type)"
            if lock.files.values.contains(where: { $0.value.md5 == nil && ($0.key as NSString).deletingLastPathComponent == directory }) {
                sets.append(MediaSet(type: set.type, files: []))
            }
        }
        for set in sets {
            try planSet(kind, locale: locale, set, remote: remote.first { $0.type == set.type }, localization: localization, lock: lock)
        }
        for set in remote where !sets.contains(where: { $0.type == set.type }) {
            let subject = "\(folder) \(locale) \(set.type)"
            guard options.prune else {
                note("\(subject) is on App Store Connect but has no directory in \(name)/\(locale)/\(folder)/: kept (--prune deletes it)")
                continue
            }
            try requireEditableVersion("\(subject) (to delete)")
            add(StoreChange(.delete, .media, subject, fields: [StoreFieldChange("files", from: "\(set.items.count)", to: nil)],
                            requests: [.delete(kind.setType!, id: set.id)]))
        }
    }

    mutating func planSet(_ kind: StoreMediaKind, locale: String, _ set: MediaSet, remote: StoreRemoteSet?,
                          localization: StoreMediaWork.Localization, lock: MediaLock) throws {
        let folder = kind == .screenshots ? "screenshots" : "previews"
        let directory = "\(locale)/\(folder)/\(set.type)"
        let subject = "\(folder) \(locale) \(set.type)"
        let files = try set.files.map { try localFile($0) }
        let items = remote?.items ?? []
        let match = MediaMatcher.match(files: files.map(\.local), remote: items.map(Self.remote), lock: lock, directory: directory, prune: options.prune)
        plan.lock.merge(match.lock) { _, new in new }

        let max = kind.maxItems ?? Int.max
        if match.slots.count > max {
            throw XlessError(.account, "\(subject) would hold \(match.slots.count) files, Apple allows \(max): App Store Connect has \(match.extras.count) the directory does not",
                             fix: "re-run with --prune to delete them, or add them to \(name)/\(directory)/ (`xless store pull`)")
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func shown(_ id: String) -> String { byID[id]?.attributes.fileName ?? id }

        // Poster frames of previews App Store Connect has.
        var requests: [StoreRequest] = []
        var fields: [StoreFieldChange] = []
        if kind == .previews, let frames = app.previewFrames {
            for (path, entry) in match.lock.sorted(by: { $0.key < $1.key }) {
                guard let wanted = frames[path], let id = entry.id, byID[id]?.attributes.previewFrameTimeCode != wanted else { continue }
                requests.append(.update("appPreviews", id: id, attributes: ["previewFrameTimeCode": .string(wanted)]))
                fields.append(StoreFieldChange("\((path as NSString).lastPathComponent) previewFrameTimeCode", from: byID[id]?.attributes.previewFrameTimeCode, to: wanted))
            }
        }

        for item in match.pruned {
            try requireEditableVersion("\(subject) (to delete \(shown(item.id)))")
            add(StoreChange(.delete, .media, "\(subject) \(shown(item.id))", requests: [.delete(kind.itemType, id: item.id)]))
        }
        if !match.extras.isEmpty {
            note("\(subject) has \(match.extras.count) file\(match.extras.count == 1 ? "" : "s") on App Store Connect that \(name)/\(directory)/ does not (\(match.extras.map { shown($0.id) }.joined(separator: ", "))): kept, after the directory's (--prune deletes them)")
        }

        let uploads = Dictionary(files.map { ($0.local.path, $0.upload) }, uniquingKeysWith: { a, _ in a })
        for path in match.uploads {
            fields.append(StoreFieldChange((path as NSString).lastPathComponent, from: match.replaced.contains(path) ? "old upload" : nil, to: "upload"))
        }
        for item in match.failed { fields.append(StoreFieldChange(shown(item.id), from: "failed upload", to: nil)) }
        if match.uploads.isEmpty, match.reorder { fields.append(StoreFieldChange("order", from: nil, to: "as in \(directory)")) }
        guard !fields.isEmpty || !match.deletes.isEmpty else { return }
        try requireEditableVersion(subject)

        let frames = app.previewFrames
        let slots: [StoreMediaWork.Slot] = match.slots.map { slot in
            switch slot {
            case .keep(let id): return .keep(id)
            case .upload(let path):
                var upload = uploads[path]!
                if kind == .previews, let frame = frames?[path] { upload.commit["previewFrameTimeCode"] = .string(frame) }
                return .upload(upload)
            }
        }
        let before = items.count - match.pruned.count + match.uploads.count
        let work: StoreMediaWork? = match.uploads.isEmpty && match.deletes.isEmpty && !match.reorder ? nil
            : StoreMediaWork(kind: kind, container: remote.map { .set($0.id) } ?? .newSet(type: set.type, localization: localization),
                             slots: slots, deletes: match.deletes, deleteFirst: before > max, reorder: match.reorder)
        add(StoreChange(remote == nil ? .create : .update, .media, subject, fields: fields, requests: requests, media: work))
    }

    static func remote(_ item: ASCKeptResource<StoreMediaAttributes>) -> MediaMatcher.Remote {
        MediaMatcher.Remote(id: item.id, checksum: item.attributes.sourceFileChecksum, fileName: item.attributes.fileName, state: item.attributes.state)
    }

    /// A file of the manifest (path relative to it), read for its size and MD5.
    func localFile(_ path: String) throws -> (local: MediaMatcher.Local, upload: StoreUpload) {
        guard let url = StoreManifest.resolve(path, in: dir), let size = try? AssetFile.size(url), let md5 = MD5Hex.file(url) else {
            throw XlessError(.account, "\(name)/\(path) cannot be read", fix: "`xless store validate` says why")
        }
        return (MediaMatcher.Local(path: path, md5: md5), StoreUpload(path: path, file: url, fileName: url.lastPathComponent, fileSize: size, md5: md5))
    }

    /// Files a resource holds without order (App Review attachments, the compliance document): the uploads and
    /// deletions to make it hold `paths`, its plan lines, and what to note. A resource whose files cannot be deleted
    /// (`deletable: false`, the compliance document) only gets uploads.
    mutating func planFiles(_ kind: StoreMediaKind, subject: String, paths: [String], remote: [ASCKeptResource<StoreMediaAttributes>],
                            parent: String, deletable: Bool = true) throws -> (work: StoreMediaWork?, fields: [StoreFieldChange], pruned: [StoreChange]) {
        let files = try paths.map { try localFile($0) }
        var match = MediaMatcher.match(files: files.map(\.local), remote: remote.map(Self.remote), lock: MediaLock.read(dir), directory: "",
                                       prune: options.prune && deletable)
        if !deletable { match.deletes = []; match.replaced = []; match.failed = []; match.extras = [] }
        plan.lock.merge(match.lock) { _, new in new }
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func shown(_ id: String) -> String { byID[id]?.attributes.fileName ?? id }
        if !match.extras.isEmpty {
            note("\(subject): App Store Connect has \(match.extras.map { shown($0.id) }.joined(separator: ", ")), which app.yml does not list: kept (--prune deletes \(match.extras.count == 1 ? "it" : "them"))")
        }
        let pruned = match.pruned.map { StoreChange(.delete, kind == .reviewAttachments ? .review : .declarations, "\(subject) \(shown($0.id))", requests: [.delete(kind.itemType, id: $0.id)]) }
        var fields = match.uploads.map { StoreFieldChange(($0 as NSString).lastPathComponent, from: match.replaced.contains($0) ? "old upload" : nil, to: "upload") }
        fields += match.failed.map { StoreFieldChange(shown($0.id), from: "failed upload", to: nil) }
        guard !match.uploads.isEmpty || !match.deletes.isEmpty else { return (nil, fields, pruned) }
        let uploads = Dictionary(files.map { ($0.local.path, $0.upload) }, uniquingKeysWith: { a, _ in a })
        let slots = match.uploads.map { StoreMediaWork.Slot.upload(uploads[$0]!) }
        return (StoreMediaWork(kind: kind, container: .parent(parent), slots: slots, deletes: match.deletes), fields, pruned)
    }
}
