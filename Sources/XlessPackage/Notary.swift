import Foundation
import XlessCore
import XlessSign

/// Notarization with rcodesign: the DMG's and the zipped app's.
enum Notary {
    /// Submits `file` (a DMG or an `.app`) to the notary service, waits and staples the ticket in place. The App Store
    /// Connect key is read by rcodesign from private files that are gone when the call ends.
    static func notarize(_ file: URL, secrets: Secrets,
                         encodeKey: ([String]) throws -> Void = { try RCodesign.run($0, stage: .package) },
                         run: ([String]) throws -> Run = rcodesign) throws {
        try PrivateFiles.with(stage: .package) { files in
            let p8 = try files.write(try p8Contents(secrets), as: "key.p8"), keyJSON = try files.make("key.json")
            try encodeKey(RCodesign.encodeKeyArguments(issuerID: secrets.identifier("ASC_ISSUER_ID", stage: .package),
                                                       keyID: secrets.identifier("ASC_KEY_ID", stage: .package), p8: p8, out: keyJSON))
            try submit(file, apiKeyJSON: keyJSON, run: run)
        }
    }

    /// ASC_KEY_P8 as rcodesign should read it: normalized like every PEM secret, newline-terminated.
    static func p8Contents(_ secrets: Secrets) throws -> Data {
        Data((PEM.normalize(try secrets.required("ASC_KEY_P8", stage: .package)) + "\n").utf8)
    }

    /// One `rcodesign notary-submit` run: its full output and, when it exited non-zero, the error.
    struct Run { var log: String; var failure: XlessError? }

    static func rcodesign(_ args: [String]) throws -> Run {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("xless-notary-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        do {
            try RCodesign.run(args, stage: .package, captureTo: logURL)
            return Run(log: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "", failure: nil)
        } catch let e as XlessError where !e.cause.hasPrefix("cannot start ") {
            return Run(log: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "", failure: e)
        }
    }

    /// rcodesign streams its output to the terminal (see `rcodesign`); this logs the submission id and the final status, and
    /// reports a rejection only when Rejected/Invalid was parsed. Any other failure (network, auth, wait timeout, staple after
    /// Accepted) is rethrown as it is, with the id when known.
    static func submit(_ file: URL, apiKeyJSON: URL, run: ([String]) throws -> Run) throws {
        let r = try run(RCodesign.notarizeArguments(bundle: file, apiKeyJSON: apiKeyJSON))
        let id = submissionID(in: r.log), status = status(in: r.log)
        FileHandle.standardError.write(Data("notary submission \(id ?? "unknown"): \(status ?? (r.failure == nil ? "status unknown (rcodesign exited 0)" : "status unknown"))\n".utf8))
        if let status, status == "Rejected" || status == "Invalid" { throw rejection(file: file.lastPathComponent, status: status) }
        if let f = r.failure {
            throw XlessError(f.stage, f.cause + (id.map { " (notary submission \($0))" } ?? ""), fix: f.fix)
        }
    }

    /// Fails unless the DMG's signature carries a stapled notarization ticket (read back with `rcodesign print-signature-info`).
    static func checkStapled(dmg: URL, signatureInfo: (URL) throws -> String = { try RCodesign.run(["print-signature-info", $0.path], stage: .package).stdout }) throws {
        try checkStapled(dmg, hasStapledTicket(signatureInfo: signatureInfo(dmg)))
    }

    /// Fails unless the app holds a stapled ticket: the file `Contents/CodeResources`, which is not the signature's own
    /// `_CodeSignature/CodeResources` nor (in an old layout) a link to it.
    static func checkStapled(app: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Contents/CodeResources").path)
        try checkStapled(app, attributes?[.type] as? FileAttributeType == .typeRegular && (attributes?[.size] as? NSNumber)?.intValue ?? 0 > 0)
    }

    private static func checkStapled(_ file: URL, _ stapled: Bool) throws {
        guard stapled else {
            throw XlessError(.package, "\(file.lastPathComponent) has no stapled notarization ticket after notary-submit --staple",
                             fix: "re-run from package; if notarization was accepted, `rcodesign staple \(file.lastPathComponent)` staples the ticket")
        }
        FileHandle.standardError.write(Data("notarization ticket stapled to \(file.lastPathComponent)\n".utf8))
    }

    /// A stapled DMG's embedded signature has a `Ticket` blob (slot 65538), listed by `rcodesign print-signature-info` as
    /// `- slot: Ticket (65538)` among the superblob's blobs; an unstapled one has CodeDirectory, RequirementSet and CMS only
    /// (rcodesign 0.29.0, checked against the spike's stapled and unstapled DMGs).
    static func hasStapledTicket(signatureInfo: String) -> Bool {
        signatureInfo.contains(/(?m)^\s*-\s*slot:\s*Ticket\s*\(65538\)\s*$/)
    }

    static func rejection(file: String, status: String) -> XlessError {
        XlessError(.package, "notarization of \(file) was rejected (\(status))",
                   fix: "read the notary log printed above, fix the reported binaries, then re-run from package")
    }

    /// The first "submission ID" in rcodesign's output.
    static func submissionID(in text: String) -> String? {
        text.firstMatch(of: /(?i)submission ID[: ]+([0-9a-f-]{36})/).map { String($0.1).lowercased() }
    }

    /// The last status from rcodesign's poll or status lines (`poll state after …: Accepted`, `status: Invalid`), never from
    /// words inside the notary log's issue text.
    static func status(in text: String) -> String? {
        text.matches(of: /(?im)^\s*(?:poll state after[^\n]*?|status)[: ]+(Accepted|Rejected|Invalid|InProgress)\s*$/).last.map { String($0.1) }
    }
}
