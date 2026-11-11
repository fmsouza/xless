import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// One entry of Apple's developer downloads ("More Downloads"), e.g. "Xcode 26.2" and its files.
public struct AppleDownload: Decodable, Sendable, Equatable {
    public struct File: Decodable, Sendable, Equatable {
        public let filename: String?
        public let remotePath: String
        public let fileSize: Int64?
        public init(filename: String?, remotePath: String, fileSize: Int64?) {
            self.filename = filename; self.remotePath = remotePath; self.fileSize = fileSize
        }
        /// The file's name on disk: Apple's `filename`, else the last component of its path.
        public var name: String {
            let n = filename ?? ""
            return n.isEmpty || n.contains("/") ? (remotePath as NSString).lastPathComponent : n
        }
    }

    public let name: String
    public let files: [File]

    public init(name: String, files: [File]) { self.name = name; self.files = files }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        files = (try? c.decodeIfPresent([File].self, forKey: .files)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case name, files }
}

public enum DeveloperDownloads {
    public struct Result: Sendable {
        public let url: URL
        /// The file was already there, complete; nothing was downloaded.
        public let skipped: Bool
    }

    static let xarMagic = Data("xar!".utf8)

    /// The Xcode releases (`Xcode <number>…`) Apple offers this signed-in Apple ID, newest first as Apple lists them.
    public static func list(client: AppleWebClient) async throws -> [AppleDownload] {
        struct Listing: Decodable {
            let resultCode: Int?
            let resultString: String?
            let downloads: [AppleDownload]?
        }
        var r = URLRequest(url: AppleEndpoints.listDownloads)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.send(r)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw fail("Apple did not let this Apple ID list the developer downloads (HTTP \(response.statusCode))", fix: agreementFix)
        }
        guard response.statusCode == 200, let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw fail("Apple's download list answered HTTP \(response.statusCode) without a list", fix: AppleSignIn.changedFix)
        }
        if let code = listing.resultCode, code != 0 {
            throw fail("Apple refused the download list (\(code)): \(listing.resultString ?? "no reason given")", fix: agreementFix)
        }
        guard let downloads = listing.downloads else {
            throw fail("Apple's download list was empty", fix: agreementFix)
        }
        return downloads.filter { $0.name.range(of: #"^Xcode [0-9]"#, options: .regularExpression) != nil }
    }

    static let agreementFix = "sign in once at https://developer.apple.com/download/all/ in a browser and accept the agreement it shows, then re-run"

    /// Downloads `file` into `dir` as `<name>.part`, resuming a `.part` left by an earlier run, and renames it to `<name>`
    /// once it is complete and starts like a .xip (`xar!`). A complete `<name>` already there is kept (`skipped`).
    /// `progress` gets the bytes on disk so far.
    public static func download(_ file: AppleDownload.File, into dir: URL, client: AppleWebClient,
                                progress: @escaping @Sendable (Int64) -> Void) async throws -> Result {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(file.name)
        let part = dir.appendingPathComponent(file.name + ".part")
        if fm.fileExists(atPath: dest.path) {
            guard startsLikeXip(dest) else {
                throw fail("\(dest.path) exists and is not an Xcode .xip", fix: "move it away, then re-run")
            }
            return Result(url: dest, skipped: true)
        }
        guard let url = AppleEndpoints.download(path: file.remotePath) else {
            throw fail("Apple listed \(file.name) with an unusable path", fix: AppleSignIn.changedFix)
        }
        // Refreshes the download cookie for this path; Apple answers 403 for Xcodes and still sets it (xcodes ignores it too).
        _ = try? await client.send(URLRequest(url: AppleEndpoints.downloadAuth(path: file.remotePath)))

        let offset = fileSize(part)
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let counter = ByteCounter(offset)
        progress(offset)
        let (_, response, finalURL) = try await client.download(request, to: part) { n in progress(counter.add(n)) }

        if finalURL.lastPathComponent == "unauthorized" || URLSessionAppleTransport.isHTML(response)
            || [401, 403].contains(response.statusCode) {
            throw fail("Apple did not authorise the download of \(file.name) (HTTP \(response.statusCode))",
                       fix: "check that this Apple ID can download it at https://developer.apple.com/download/all/ (accept the agreement there), then re-run")
        }
        if response.statusCode == 416 {
            try? fm.removeItem(at: part)
            throw fail("Apple refused to resume \(file.name)", fix: "re-run to download it from the start")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw fail("Apple answered HTTP \(response.statusCode) for \(file.name)", fix: "re-run (the download resumes where it stopped)")
        }
        guard startsLikeXip(part) else {
            try? fm.removeItem(at: part)
            throw fail("what Apple sent for \(file.name) is not an Xcode .xip", fix: "re-run; if it repeats, download it in a browser")
        }
        let size = fileSize(part)
        if let expected = file.fileSize, expected > 0, size != expected {
            throw fail("\(file.name) is incomplete (\(size) of \(expected) bytes)", fix: "re-run to resume the download")
        }
        do {
            try fm.moveItem(at: part, to: dest)
        } catch {
            throw fail("cannot rename \(part.path) to \(dest.lastPathComponent): \(error.localizedDescription)", fix: "check the directory, then re-run")
        }
        return Result(url: dest, skipped: false)
    }

    static func startsLikeXip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == xarMagic
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// A running byte total shared with the transport's delegate queue.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64
    init(_ start: Int64) { total = start }
    func add(_ n: Int64) -> Int64 { lock.withLock { total += n; return total } }
}
