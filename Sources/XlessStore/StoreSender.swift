import Foundation
import XlessASC
import XlessCore

/// Sends a plan's requests with the API key. A POST is sent once, never retried (a retry could create a second
/// resource); so is a request carrying the demo account's password, which is read from its secret only here, put into
/// that one body, and scrubbed from whatever App Store Connect answers. Media changes are uploaded with `uploader`;
/// what was uploaded and deleted is kept in `record` (for media.lock).
///
/// Files go up `concurrency` at a time across the whole push (one `limiter`; several media changes may run at once,
/// see `StorePush.apply`), and their processing is waited for in parallel. Once an upload fails, no other transfer
/// starts; those already started finish and are recorded.
public struct StoreSender: Sendable {
    /// How many files are sent to App Store Connect at once.
    public static let uploadConcurrency = 4

    public let client: ASCClient
    /// The value of a secret, by name (`Secrets.required`).
    public let secret: @Sendable (String) throws -> String
    public let uploader: AssetUploader
    public let record = MediaRecord()
    /// Bounds the transfers (reserve, parts, commit) of the whole push.
    public let limiter: AsyncLimiter

    let cache = SecretCache()
    let halt = HaltFlag()

    public init(client: ASCClient, secret: @escaping @Sendable (String) throws -> String, uploader: AssetUploader? = nil,
                concurrency: Int = StoreSender.uploadConcurrency) {
        self.client = client; self.secret = secret
        self.uploader = uploader ?? AssetUploader(client: client, stage: .account, rerun: "re-run `xless store push` (it uploads only what App Store Connect still lacks)")
        limiter = AsyncLimiter(concurrency)
    }

    /// A transfer not started because another upload of this push failed.
    struct Halted: Error, CustomStringConvertible {
        var description: String { "not uploaded: another upload of this push failed" }
    }

    /// A secret's value, read once per push (a store passphrase is asked at most once).
    public func value(of name: String) throws -> String {
        if let v = cache.get(name) { return v }
        let v = try secret(name)
        HTTPTrace.hide(v)
        cache.set(name, v)
        return v
    }

    /// Sends a change's requests in order, then its media; `{id}` in a path (or a media parent) is the ID the change's
    /// first creating request created.
    public func apply(_ change: StoreChange) async throws {
        var created: String?
        for request in change.requests {
            var request = request
            if request.path.contains("{id}") {
                guard let created else { throw XlessError(.account, "App Store Connect did not say which \(change.subject) it created", fix: "re-run `xless store push`") }
                request.path = request.path.replacingOccurrences(of: "{id}", with: created)
                if case .object(var doc)? = request.body, case .object(var data)? = doc["data"], data["id"] == .string("{id}") {
                    data["id"] = .string(created)
                    doc["data"] = .object(data)
                    request.body = .object(doc)
                }
            }
            let id = try await send(request, path: request.path)
            if created == nil { created = id }
            // A media file deleted (--prune) leaves media.lock.
            if request.method == "DELETE", let type = request.path.split(separator: "/").dropFirst().first,
               StoreMediaKind.allItemTypes.contains(String(type)) {
                record.deleted(String(request.path.split(separator: "/").last!))
            }
        }
        if let media = change.media { try await applyMedia(media, created: created, subject: change.subject) }
    }

    /// Creates the set if needed, uploads, deletes, and puts the set in the manifest's order.
    func applyMedia(_ work: StoreMediaWork, created: String?, subject: String) async throws {
        let kind = work.kind
        let holder: String
        switch work.container {
        case .set(let id): holder = id
        case .parent(let id):
            guard id != "{id}" || created != nil else {
                throw XlessError(.account, "App Store Connect did not say which \(subject) it created", fix: "re-run `xless store push`")
            }
            holder = id == "{id}" ? created! : id
        case .newSet(let type, let localization):
            guard let setType = kind.setType, let attribute = kind.setAttribute else { preconditionFailure("\(kind) has no sets") }
            let localizationID = try await resolve(localization)
            let request = StoreRequest.create(setType, attributes: [attribute: .string(type)],
                                              relationships: ["appStoreVersionLocalization": StoreRequest.link("appStoreVersionLocalizations", localizationID)])
            guard let id = try await send(request, path: request.path) else {
                throw XlessError(.account, "App Store Connect did not say which \(subject) it created", fix: "re-run `xless store push`")
            }
            holder = id
        }
        func deletes() async throws {
            for id in work.deletes {
                _ = try await send(.delete(kind.itemType, id: id), path: "/v1/\(kind.itemType)/\(id)")
                record.deleted(id)
            }
        }
        if work.deleteFirst { try await deletes() }
        let ids = try await uploadAll(work.slots, kind: kind, holder: holder)
        let order = work.slots.enumerated().map { i, slot -> String in
            if case .keep(let id) = slot { return id }
            return ids[i]!
        }
        if !work.deleteFirst { try await deletes() }
        if work.reorder, let setType = kind.setType {
            let path = "/v1/\(setType)/\(holder)/relationships/\(kind.itemType)"
            _ = try await send(StoreRequest(method: "PATCH", path: path, body: StoreRequest.links(kind.itemType, order)), path: path)
        }
    }

    /// Uploads the set's new files at once (transfers bounded by `limiter`, started in slot order), each waited for as
    /// soon as it is committed; their IDs by slot index. Every file App Store Connect accepted is recorded, even when
    /// another failed; the first failure (in the set's order) is then thrown and the others are noted.
    func uploadAll(_ slots: [StoreMediaWork.Slot], kind: StoreMediaKind, holder: String) async throws -> [Int: String] {
        let uploads = slots.enumerated().compactMap { i, slot -> (Int, StoreUpload)? in
            if case .upload(let u) = slot { return (i, u) }
            return nil
        }
        guard !uploads.isEmpty else { return [:] }
        let outcomes = await withTaskGroup(of: (Int, StoreUpload, Result<AssetUploadResult, any Error>).self) { group in
            for (index, u) in uploads {
                // The permit is taken here, before the file's task starts, so transfers start in slot order (one at a
                // time: exactly that order) whatever order the tasks run in; the task gives it back.
                await limiter.acquirePermit()
                group.addTask {
                    do {
                        return (index, u, .success(try await upload(u, kind: kind, holder: holder)))
                    } catch {
                        if !(error is Halted) { halt.set() }
                        return (index, u, .failure(error))
                    }
                }
            }
            var all: [(Int, StoreUpload, Result<AssetUploadResult, any Error>)] = []
            for await outcome in group { all.append(outcome) }
            return all.sorted { $0.0 < $1.0 }
        }
        var ids: [Int: String] = [:]
        var notes: [String] = []
        var failures: [(StoreUpload, any Error)] = []
        for (index, u, outcome) in outcomes {
            switch outcome {
            case .success(let result):
                ids[index] = result.id
                record.uploaded(u.path, MediaLock.Entry(md5: u.md5, appleChecksum: u.md5, id: result.id))
                if case .pending(_, let state) = result { notes.append("\(u.path) is uploaded; App Store Connect is still processing it (\(state))") }
            case .failure(let error):
                failures.append((u, error))
            }
        }
        let real = failures.filter { !($0.1 is Halted) }
        for (u, error) in real.dropFirst() {
            notes.append("\(u.path) was not uploaded either: \((error as? XlessError)?.cause ?? "\(error)")")
        }
        record.note(notes)
        if let first = real.first ?? failures.first { throw first.1 }
        return ids
    }

    /// One file, holding the permit `uploadAll` took for it: transferred (unless the push already failed), the permit
    /// given back, then waited for without one.
    func upload(_ u: StoreUpload, kind: StoreMediaKind, holder: String) async throws -> AssetUploadResult {
        let asset = AssetUpload(type: kind.itemType, file: u.file, fileName: u.fileName, fileSize: u.fileSize, md5: u.md5,
                                relationship: kind.parent.relationship, parentType: kind.parent.type, parentID: holder,
                                commit: u.commit, display: u.path)
        let id: String
        do {
            if halt.isSet { throw Halted() }
            id = try await uploader.transfer(asset)
        } catch {
            await limiter.releasePermit()
            throw error
        }
        await limiter.releasePermit()
        return try await uploader.wait(id: id, asset: asset)
    }

    /// The ID of a version localization, looked up by locale when this push created it.
    func resolve(_ localization: StoreMediaWork.Localization) async throws -> String {
        switch localization {
        case .id(let id): return id
        case .locale(let locale, let versionID):
            let all = try await ASCResources(client: client).list("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
                                                                  as: ASCKeptResource<StoreVersionLocalizationAttributes>.self).items
            guard let found = all.first(where: { $0.attributes.locale == locale }) else {
                throw XlessError(.account, "App Store Connect has no version text for \(locale), so its screenshots and previews have nowhere to go",
                                 fix: "push the text part too (it creates the locale), then re-run `xless store push`")
            }
            return found.id
        }
    }

    /// The created resource's ID, for a POST.
    func send(_ request: StoreRequest, path: String) async throws -> String? {
        guard let name = request.secret else {
            do {
                let response = try await client.request(request.method, path, body: try request.body.map { try JSONEncoder().encode($0) },
                                                        maxAttempts: request.method == "POST" ? 1 : ASCClient.maxAttempts)
                return Self.createdID(response.data)
            } catch let e as ASCError where request.method == "DELETE" && e.status == 404 {
                return nil  // already gone (a retried DELETE whose first attempt went through)
            }
        }
        let value = try value(of: name)
        let body = Self.inject(value, into: request.body ?? .object([:]))
        do {
            let response = try await client.request(request.method, path, body: try JSONEncoder().encode(body), maxAttempts: 1)
            return Self.createdID(response.data)
        } catch let error as ASCError {
            throw Self.scrub(error, value)
        } catch {
            if !value.isEmpty, "\(error)".contains(value) {
                throw XlessError(.account, "sending the App Review details failed", fix: "re-run `xless store push`")
            }
            throw error
        }
    }

    /// The body with `data.attributes.demoAccountPassword` set.
    static func inject(_ value: String, into body: JSONValue) -> JSONValue {
        guard case .object(var doc) = body, case .object(var data)? = doc["data"] else { return body }
        var attributes: [String: JSONValue] = [:]
        if case .object(let a)? = data["attributes"] { attributes = a }
        attributes["demoAccountPassword"] = .string(value)
        data["attributes"] = .object(attributes)
        doc["data"] = .object(data)
        return .object(doc)
    }

    /// Apple's error without the secret's value, wherever its answer repeated it.
    static func scrub(_ error: ASCError, _ value: String) -> ASCError { error.scrubbing(value) }

    struct Created: Decodable {
        struct Data: Decodable { var id: String }
        var data: Data
    }

    static func createdID(_ data: Data) -> String? { (try? JSONDecoder().decode(Created.self, from: data))?.data.id }
}

/// The secrets one push has read, kept for its own requests only.
/// Set once an upload of the push fails: no other transfer starts.
final class HaltFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class SecretCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ name: String) -> String? { lock.withLock { values[name] } }
    func set(_ name: String, _ value: String) { lock.withLock { values[name] = value } }
}

/// What a push's media changes did: the uploads (media.lock entries by path), the files deleted, and notes.
public final class MediaRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: MediaLock.Entry] = [:]
    private var deletedIDs: Set<String> = []
    private var pending: [String] = []

    public init() {}

    func uploaded(_ path: String, _ entry: MediaLock.Entry) { lock.withLock { entries[path] = entry } }
    func deleted(_ id: String) { lock.withLock { _ = deletedIDs.insert(id) } }
    func note(_ text: String) { lock.withLock { pending.append(text) } }
    /// Several notes, kept together.
    func note(_ texts: [String]) { lock.withLock { pending += texts } }

    public var uploads: [String: MediaLock.Entry] { lock.withLock { entries } }
    public var deleted: Set<String> { lock.withLock { deletedIDs } }

    /// The notes not yet taken.
    public func takeNotes() -> [String] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }
}
