import Foundation
import XlessCore
import XlessSign

public enum Packager {
    /// Entries that must never ship in a bundle archive (Finder / AppleDouble litter from macOS hosts).
    static let junkExclusions = ["*.DS_Store", "*/._*", "._*"]

    /// The `.ipa`, and `<name>.app.dSYM.zip` of `dSYMs` (the build's debug symbols) when it has any, as
    /// fastlane's `gym` names it.
    public static func ipa(signedApp: URL, outputDir: URL, dSYMs: URL? = nil) throws -> URL {
        let name = signedApp.deletingPathExtension().lastPathComponent
        return try Files.atomicOutput(outputDir) { out in
            try zipDSYMs(dSYMs, app: signedApp, into: out)
            let staging = out.appendingPathComponent(".staging")
            let payload = staging.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: signedApp, to: payload.appendingPathComponent(signedApp.lastPathComponent))
            let ipa = out.appendingPathComponent("\(name).ipa")
            try Shell.run("zip", ["-qry", ipa.path, "Payload", "-x"] + junkExclusions, cwd: staging, stage: .package)
            try FileManager.default.removeItem(at: staging)
            return ipa
        }
    }

    /// Zips everything in `dSYMs` (the build's debug symbols, `StagePaths.dSYMs`) into `<out>/<App>.app.dSYM.zip`, the
    /// name fastlane's `gym` gives it, next to the package of `app`. Returns nil, writing nothing, when there is none.
    @discardableResult
    public static func zipDSYMs(_ dSYMs: URL?, app: URL, into out: URL) throws -> URL? {
        guard let dSYMs, let entries = try? FileManager.default.contentsOfDirectory(atPath: dSYMs.path), !entries.isEmpty else { return nil }
        let zip = out.appendingPathComponent("\(app.lastPathComponent).dSYM.zip")
        try Shell.run("zip", ["-qry", zip.path] + entries.sorted() + ["-x"] + junkExclusions, cwd: dSYMs, stage: .package)
        return zip
    }

    /// ASC_KEY_P8 as rcodesign should read it: normalized like every PEM secret, newline-terminated.
    static func p8Contents(_ secrets: Secrets) throws -> Data {
        Data((PEM.normalize(try secrets.required("ASC_KEY_P8", stage: .package)) + "\n").utf8)
    }

    /// Notarizes and staples the .app with rcodesign, then zips it (macOS Developer ID distribution), with the dSYMs
    /// zipped next to it (`zipDSYMs`).
    public static func notarizedZip(signedApp: URL, outputDir: URL, secrets: Secrets, dSYMs: URL? = nil) throws -> URL {
        let name = signedApp.deletingPathExtension().lastPathComponent
        return try Files.atomicOutput(outputDir) { out in
            let zip = try notarizedZip(signedApp: signedApp, name: name, out: out, secrets: secrets)
            try zipDSYMs(dSYMs, app: signedApp, into: out)
            return zip
        }
    }

    static func notarizedZip(signedApp: URL, name: String, out: URL, secrets: Secrets) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-notary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p8 = tmp.appendingPathComponent("key.p8"), keyJSON = tmp.appendingPathComponent("key.json")
        let p8Contents = try p8Contents(secrets)
        guard FileManager.default.createFile(atPath: p8.path, contents: p8Contents, attributes: [.posixPermissions: 0o600]) else {
            throw XlessError(.package, "cannot write temporary API key file", fix: "check free space and permissions of the temp directory")
        }
        try Shell.run("rcodesign", RCodesign.encodeKeyArguments(issuerID: secrets.identifier("ASC_ISSUER_ID", stage: .package),
                                                                keyID: secrets.identifier("ASC_KEY_ID", stage: .package),
                                                                p8: p8, out: keyJSON), stage: .package)
        let app = out.appendingPathComponent(signedApp.lastPathComponent)
        try FileManager.default.copyItem(at: signedApp, to: app)
        try Shell.run("rcodesign", RCodesign.notarizeArguments(bundle: app, apiKeyJSON: keyJSON), stage: .package, passthrough: true)
        let zip = out.appendingPathComponent("\(name)-macOS.zip")
        try Shell.run("zip", ["-qry", zip.path, app.lastPathComponent, "-x"] + junkExclusions, cwd: out, stage: .package)
        return zip
    }
}
