import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// A file sent to App Store Connect, read from disk a piece at a time: never mapped or loaded whole.
public enum AssetFile {
    public static func size(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    /// The MD5 (hex) of the file, read in 1 MB pieces: what App Store Connect calls `sourceFileChecksum`.
    public static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        // At the end Foundation answers empty data, or nil on Linux.
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file to upload as an App Store Connect asset resource (appScreenshots, appPreviews, appStoreReviewAttachments,
/// appEncryptionDeclarationDocuments): reserved with its name and size under its parent, sent in the parts App Store
/// Connect asks for, committed with its MD5.
public struct AssetUpload: Sendable, Equatable {
    /// The resource type, which is also its path: `appScreenshots` → POST /v1/appScreenshots.
    public var type: String
    public var file: URL
    public var fileName: String
    public var fileSize: Int
    public var md5: String
    /// The to-one relationship to the parent (`appScreenshotSet`), its type and ID.
    public var relationship: String
    public var parentType: String
    public var parentID: String
    /// Extra attributes of the reservation (`mimeType`) and of the commit (`previewFrameTimeCode`).
    public var attributes: [String: JSONValue] = [:]
    public var commit: [String: JSONValue] = [:]
    /// How messages name the file (`en-US/screenshots/APP_IPHONE_67/01-home.png`).
    public var display: String

    public init(type: String, file: URL, fileName: String, fileSize: Int, md5: String, relationship: String, parentType: String, parentID: String,
                attributes: [String: JSONValue] = [:], commit: [String: JSONValue] = [:], display: String) {
        self.type = type; self.file = file; self.fileName = fileName; self.fileSize = fileSize; self.md5 = md5
        self.relationship = relationship; self.parentType = parentType; self.parentID = parentID
        self.attributes = attributes; self.commit = commit; self.display = display
    }
}


public enum AssetUploadResult: Sendable, Equatable {
    /// Processed: App Store Connect shows it.
    case complete(String)
    /// Uploaded and committed, still being processed when the wait ended (its last state).
    case pending(String, state: String)

    public var id: String {
        switch self { case .complete(let id), .pending(let id, _): id }
    }
}

/// App Store Connect's upload protocol: reserve (POST with the file's name and size) → PUT each upload operation's
/// part to Apple's storage (its headers, no credentials, each part retried on its own) → commit (`uploaded: true` and
/// the MD5 as `sourceFileChecksum`) → poll the delivery state until COMPLETE or FAILED. `transfer` is the first three,
/// `wait` the last, so a caller can bound the transfers and wait for many files at once. Polling backs off (×1.5 per
/// poll, up to `maxPollInterval`) so that many waits at once stay well inside App Store Connect's hourly request
/// limit. `BuildUploader` uses its part upload for builds.
public struct AssetUploader: Sendable {
    let client: ASCClient
    let stage: Stage
    /// How to start again, for messages: "re-run `xless store push`".
    let rerun: String
    let sleep: @Sendable (Duration) async throws -> Void
    let pollInterval: Duration
    let timeout: Duration
    let maxPollInterval: Duration

    public init(client: ASCClient, stage: Stage, rerun: String, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                pollInterval: Duration = .seconds(3), timeout: Duration = .seconds(600), maxPollInterval: Duration = .seconds(30)) {
        self.client = client; self.stage = stage; self.rerun = rerun; self.sleep = sleep; self.pollInterval = pollInterval; self.timeout = timeout
        self.maxPollInterval = maxPollInterval
    }

    /// The wait after `interval`: half as long again, at most `cap`.
    static func nextInterval(after interval: Duration, cap: Duration) -> Duration { min(interval * 1.5, cap) }

    /// Sends each operation's part of `file` (`size` bytes), read from disk just before it is sent.
    func putParts(_ operations: [UploadOperation], file: URL, size: Int, context: String = "", invalidFix: String, fix: String) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        for op in operations {
            guard let url = URL(string: op.url), op.offset >= 0, op.length >= 0, op.offset + op.length <= size else {
                throw XlessError(stage, "App Store Connect returned an invalid upload operation", fix: invalidFix)
            }
            try handle.seek(toOffset: UInt64(op.offset))
            let part = op.length == 0 ? Data() : (try handle.read(upToCount: op.length) ?? Data())
            guard part.count == op.length else {
                throw XlessError(stage, "\(context.isEmpty ? file.lastPathComponent : context) changed while it was being uploaded", fix: fix)
            }
            var req = URLRequest(url: url)
            req.httpMethod = op.method
            for h in op.requestHeaders ?? [] { req.setValue(h.value, forHTTPHeaderField: h.name) }
            req.httpBody = part
            _ = try await uploadStep("uploading bytes \(op.offset)..<\(op.offset + op.length)" + (context.isEmpty ? "" : " of \(context)"), stage: stage, fix: fix) {
                try await client.raw(req)
            }
        }
    }

    struct Reserved: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable { var uploadOperations: [UploadOperation]? }
            var id: String
            var attributes: Attributes?
        }
        var data: Resource
    }

    struct Polled: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable { var assetDeliveryState: BuildUploadState?; var videoDeliveryState: BuildUploadState? }
            var attributes: Attributes?
        }
        var data: Resource
    }

    static func body(_ data: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(JSONValue.object(["data": .object(data)]))
    }

    /// Reserves, uploads, commits and waits for `asset`. A failure before the commit removes the reservation; a file
    /// App Store Connect could not process is removed too, and its messages are the error.
    public func upload(_ asset: AssetUpload) async throws -> AssetUploadResult {
        try await wait(id: try await transfer(asset), asset: asset)
    }

    /// Reserves, uploads and commits `asset`; its ID. A failure removes the reservation.
    public func transfer(_ asset: AssetUpload) async throws -> String {
        let path = "/v1/\(asset.type)"
        var attributes = asset.attributes
        attributes["fileName"] = .string(asset.fileName)
        attributes["fileSize"] = .int(asset.fileSize)
        let reserve = try Self.body(["type": .string(asset.type), "attributes": .object(attributes), "relationships": .object([
            asset.relationship: .object(["data": .object(["type": .string(asset.parentType), "id": .string(asset.parentID)])]),
        ])])
        let reserved: Reserved = try await uploadStep("reserving the upload of \(asset.display)", stage: stage, fix: rerun) {
            try JSONDecoder().decode(Reserved.self, from: try await client.request("POST", path, body: reserve, maxAttempts: 1).data)
        }
        let id = reserved.data.id
        do {
            try await putParts(reserved.data.attributes?.uploadOperations ?? [], file: asset.file, size: asset.fileSize, context: asset.display,
                               invalidFix: rerun, fix: rerun)
            var commit = asset.commit
            commit["uploaded"] = .bool(true)
            commit["sourceFileChecksum"] = .string(asset.md5)
            let body = try Self.body(["type": .string(asset.type), "id": .string(id), "attributes": .object(commit)])
            _ = try await uploadStep("committing the upload of \(asset.display)", stage: stage, fix: rerun) {
                try await client.request("PATCH", "\(path)/\(id)", body: body)
            }
        } catch {
            try? await client.delete("\(path)/\(id)")
            throw error
        }
        return id
    }

    /// Waits until App Store Connect has processed the committed upload `id` of `asset`: complete, or still pending when
    /// the timeout ends. A file it could not process is removed, and its messages are the error.
    public func wait(id: String, asset: AssetUpload) async throws -> AssetUploadResult {
        let path = "/v1/\(asset.type)"
        let deadline = ContinuousClock.now + timeout
        var interval = pollInterval
        while true {
            let polled: Polled = try await uploadStep("checking the upload of \(asset.display)", stage: stage,
                                                      fix: "it was uploaded; \(rerun) (it is not uploaded again)") {
                try JSONDecoder().decode(Polled.self, from: try await client.request("GET", "\(path)/\(id)").data)
            }
            let attributes = polled.data.attributes
            // A preview reports in videoDeliveryState; a failure in either is final.
            let state = attributes?.assetDeliveryState?.state == "FAILED" ? attributes?.assetDeliveryState
                : attributes?.videoDeliveryState ?? attributes?.assetDeliveryState
            switch state?.state {
            case "COMPLETE": return .complete(id)
            case "FAILED":
                let render: (BuildUploadState.Message) -> String = { [$0.code, $0.description].compactMap { $0 }.joined(separator: " ") }
                let messages = (state?.errors ?? []).map(render) + (state?.warnings ?? []).map { "warning: " + render($0) }
                try? await client.delete("\(path)/\(id)")
                throw XlessError(stage, "App Store Connect could not process \(asset.display): \(messages.isEmpty ? "no reason given" : messages.joined(separator: "; "))",
                                 fix: "fix the file, then \(rerun) (the failed upload was removed)")
            default:
                if ContinuousClock.now > deadline { return .pending(id, state: state?.state ?? "UNKNOWN") }
                try await sleep(interval)
                interval = Self.nextInterval(after: interval, cap: maxPollInterval)
            }
        }
    }
}
