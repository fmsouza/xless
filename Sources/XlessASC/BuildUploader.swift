import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

public struct UploadRecord: Codable, Sendable, Equatable {
    public var buildUploadID: String
    public var buildID: String?
    public var state: String
    public var processingState: String?
    public var messages: [String]
}

struct AppAttributes: Codable, Sendable { var bundleId: String? }
struct UploadOperation: Codable, Sendable {
    struct Header: Codable, Sendable { var name: String; var value: String }
    var method: String; var url: String; var offset: Int; var length: Int; var requestHeaders: [Header]?
}
struct BuildUploadFileAttributes: Codable, Sendable {
    var assetType: String?; var fileName: String?; var fileSize: Int?; var uti: String?; var uploadOperations: [UploadOperation]?
}
struct BuildUploadState: Codable, Sendable {
    struct Message: Codable, Sendable { var code: String?; var description: String? }
    var state: String?; var errors: [Message]?; var warnings: [Message]?
}
struct BuildUploadAttributes: Codable, Sendable {
    var cfBundleShortVersionString: String?; var cfBundleVersion: String?; var platform: String?; var state: BuildUploadState?
}
/// BuildUpload resource; the `build` relationship is returned with `?include=build`.
struct BuildUploadResource: Codable, Sendable {
    struct Relationships: Codable, Sendable { var build: ASCToOne? }
    var type: String
    var id: String
    var attributes: BuildUploadAttributes
    var relationships: Relationships?
}
struct BuildAttributes: Codable, Sendable { var processingState: String? }

public struct BuildUploader: Sendable {
    let client: ASCClient
    let sleep: @Sendable (Duration) async throws -> Void
    let pollInterval: Duration
    let timeout: Duration

    public init(client: ASCClient, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                pollInterval: Duration = .seconds(30), timeout: Duration = .seconds(3600)) {
        self.client = client; self.sleep = sleep; self.pollInterval = pollInterval; self.timeout = timeout
    }

    private func step<T>(_ what: String, fix: String, _ op: () async throws -> T) async throws -> T {
        try await uploadStep(what, fix: fix, op)
    }

    public func upload(ipa: URL, bundleID: String, version: String, build: String, platform: Platform,
                       onRecord: @Sendable (UploadRecord) throws -> Void = { _ in }) async throws -> UploadRecord {
        let apps: ASCDocument<[ASCResource<AppAttributes>]> = try await step("looking up the app record", fix: "check the ASC_* credentials and network, then re-run `xless upload`") {
            try await client.get("/v1/apps", query: [("filter[bundleId]", bundleID)])
        }
        guard let app = apps.data.first(where: { $0.attributes.bundleId == bundleID }) else {
            throw XlessError(.upload, "no app record for \(bundleID)", fix: "create it with `xless apps create --bundle-id \(bundleID) --name <name> --sku <sku> --locale <locale>` (Apple ID sign-in: the API cannot create app records), or in App Store Connect (Apps → +)")
        }

        struct UploadRels: Codable, Sendable { var app: ASCToOne }
        let upload: ASCDocument<ASCResource<BuildUploadAttributes>> = try await step("creating the build upload", fix: "see the App Store Connect error above") {
            try await client.post("/v1/buildUploads", body: ASCCreate<BuildUploadAttributes, UploadRels>(
                type: "buildUploads",
                attributes: .init(cfBundleShortVersionString: version, cfBundleVersion: build, platform: platform.ascPlatform, state: nil),
                relationships: .init(app: .init(.init(type: "apps", id: app.id)))))
        }

        let bytes = try Data(contentsOf: ipa, options: .alwaysMapped)
        struct FileRels: Codable, Sendable { var buildUpload: ASCToOne }
        let file: ASCDocument<ASCResource<BuildUploadFileAttributes>> = try await step("registering the .ipa", fix: "re-run `xless upload`") {
            try await client.post(
            "/v1/buildUploadFiles", body: ASCCreate<BuildUploadFileAttributes, FileRels>(
                type: "buildUploadFiles",
                attributes: .init(assetType: "ASSET", fileName: ipa.lastPathComponent, fileSize: bytes.count,
                                  uti: platform == .ios ? "com.apple.ipa" : "com.apple.pkg", uploadOperations: nil),
                relationships: .init(buildUpload: .init(.init(type: "buildUploads", id: upload.data.id)))))
        }

        for op in file.data.attributes.uploadOperations ?? [] {
            guard let url = URL(string: op.url), op.offset >= 0, op.length >= 0, op.offset + op.length <= bytes.count else {
                throw XlessError(.upload, "App Store Connect returned an invalid upload operation", fix: "re-run the upload stage")
            }
            var req = URLRequest(url: url)
            req.httpMethod = op.method
            for h in op.requestHeaders ?? [] { req.setValue(h.value, forHTTPHeaderField: h.name) }
            req.httpBody = bytes.subdata(in: op.offset..<(op.offset + op.length))
            _ = try await step("uploading bytes \(op.offset)..<\(op.offset + op.length)",
                               fix: "upload URLs expire, so re-run `xless upload` to start a fresh upload") {
                try await client.raw(req)
            }
        }

        struct Checksum: Codable, Sendable { var hash: String; var algorithm: String }
        struct Checksums: Codable, Sendable { var file: Checksum }
        struct Commit: Codable, Sendable { var uploaded: Bool; var sourceFileChecksums: Checksums }
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let _: ASCDocument<ASCResource<BuildUploadFileAttributes>> = try await step("committing the upload", fix: "re-run `xless upload`") {
            try await client.patch(
                "/v1/buildUploadFiles/\(file.data.id)",
                body: ASCUpdate(type: "buildUploadFiles", id: file.data.id,
                                attributes: Commit(uploaded: true, sourceFileChecksums: .init(file: .init(hash: md5, algorithm: "MD5")))))
        }

        var record = UploadRecord(buildUploadID: upload.data.id, buildID: nil, state: "AWAITING_UPLOAD", processingState: nil, messages: [])
        var reported: UploadRecord?
        func report() throws { if record != reported { try onRecord(record); reported = record } }
        try report()
        let sent = "the .ipa was sent; check App Store Connect → TestFlight before re-running — re-uploading the same build number is rejected (bump it with --build-number)"
        let deadline = ContinuousClock.now + timeout
        var buildID: String?
        while true {
            let u: ASCDocument<BuildUploadResource> = try await step("polling the upload", fix: sent) {
                try await client.get("/v1/buildUploads/\(upload.data.id)", query: [("include", "build")])
            }
            let st = u.data.attributes.state
            record.state = st?.state ?? "UNKNOWN"
            let render: (BuildUploadState.Message) -> String = { [$0.code, $0.description].compactMap { $0 }.joined(separator: " ") }
            record.messages = (st?.errors ?? []).map(render) + (st?.warnings ?? []).map { "warning: " + render($0) }
            if record.state == "COMPLETE", let id = u.data.relationships?.build?.data?.id { record.buildID = id }
            try report()
            if record.state == "FAILED" {
                let all = record.messages.joined(separator: "; ")
                throw XlessError(.upload, "App Store Connect rejected the build: \(all)", fix: KnownIssues.explain(all) ?? "see the messages above")
            }
            if record.state == "COMPLETE", let id = record.buildID { buildID = id; break }
            if ContinuousClock.now > deadline { throw XlessError(.upload, "upload still \(record.state) after \(timeout)", fix: sent) }
            try await sleep(pollInterval)
        }
        let uploaded = "the build is uploaded (build \(buildID!)); watch App Store Connect → TestFlight — don't re-upload with the same build number"
        while true {
            let b: ASCDocument<ASCResource<BuildAttributes>> = try await step("polling build processing", fix: uploaded) {
                try await client.get("/v1/builds/\(buildID!)")
            }
            record.buildID = b.data.id
            record.processingState = b.data.attributes.processingState
            try report()
            switch record.processingState {
            case "VALID": return record
            case "INVALID", "FAILED":
                let extra = record.messages.isEmpty ? "" : " (" + record.messages.joined(separator: "; ") + ")"
                throw XlessError(.upload, "build \(b.data.id) processing ended \(record.processingState ?? "")\(extra)",
                                 fix: "open App Store Connect → TestFlight → build \(b.data.id) for Apple's email/details")
            default:
                if ContinuousClock.now > deadline { throw XlessError(.upload, "build still processing after \(timeout)", fix: uploaded) }
                try await sleep(pollInterval)
            }
        }
    }
}
