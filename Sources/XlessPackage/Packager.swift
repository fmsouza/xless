import Foundation
import XlessCore
import XlessSign

public enum Packager {
    /// Entries that must never ship in a bundle archive (Finder / AppleDouble litter from macOS hosts).
    static let junkExclusions = ["*.DS_Store", "*/._*", "._*"]

    /// A name as an argument of `zip` (which keeps it without the `./`): what a build names `-T` is a file, and no option. An option
    /// of `zip` can run a command, and it runs where the secrets are.
    static func argument(_ entry: String) -> String { "./" + entry }

    /// The `.ipa`, and `<name>.app.dSYM.zip` of `dSYMs` (the build's debug symbols) when it has any, as
    /// fastlane's `gym` names it. The same app zips to the same bytes at any time and under any umask: the staged copy
    /// takes the app's own dates back (`PkgBuilder.copyDates`), `Payload/` is 755 and dated like the app, and `zip -X`
    /// leaves out the extra fields that would carry access times and the builder's uid and gid.
    public static func ipa(signedApp: URL, outputDir: URL, dSYMs: URL? = nil) throws -> URL {
        let name = signedApp.deletingPathExtension().lastPathComponent
        return try Files.atomicOutput(outputDir) { out in
            try zipDSYMs(dSYMs, app: signedApp, into: out)
            let staging = out.appendingPathComponent(".staging")
            let payload = staging.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payload.path)   // not the umask's
            try FileManager.default.copyItem(at: signedApp, to: payload.appendingPathComponent(signedApp.lastPathComponent))
            try PkgBuilder.copyDates(from: signedApp, to: payload.appendingPathComponent(signedApp.lastPathComponent))
            try PkgBuilder.setLinkDate(payload.path, try PkgBuilder.lstatInfo(signedApp.path).date)
            let ipa = out.appendingPathComponent("\(name).ipa")
            try Shell.run("zip", ["-qryX", ipa.path, "Payload", "-x"] + junkExclusions, cwd: staging, stage: .package)
            try FileManager.default.removeItem(at: staging)
            return ipa
        }
    }

    /// Zips everything in `dSYMs` (the build's debug symbols, `StagePaths.dSYMs`) into `<out>/<App>.app.dSYM.zip`, the
    /// name fastlane's `gym` gives it, next to the package of `app`. Returns nil, writing nothing, when there is none.
    @discardableResult
    public static func zipDSYMs(_ dSYMs: URL?, app: URL, into out: URL) throws -> URL? {
        if let dSYMs, (try? FileManager.default.destinationOfSymbolicLink(atPath: dSYMs.path)) != nil {
            throw XlessError(.package, "\(dSYMs.path) is a link: the symbols of the build are a directory of its own", fix: "remove it and build again")
        }
        guard let dSYMs, let entries = try? FileManager.default.contentsOfDirectory(atPath: dSYMs.path), !entries.isEmpty else { return nil }
        let zip = out.appendingPathComponent("\(app.lastPathComponent).dSYM.zip")
        try Shell.run("zip", ["-qry", zip.path] + entries.sorted().map(argument) + ["-x"] + junkExclusions, cwd: dSYMs, stage: .package)
        return zip
    }

    /// Notarizes and staples the .app with rcodesign, checks that the ticket is there, then zips the app (macOS Developer ID
    /// distribution), with the dSYMs zipped next to it (`zipDSYMs`).
    public static func notarizedZip(signedApp: URL, outputDir: URL, secrets: Secrets, dSYMs: URL? = nil) throws -> URL {
        try notarizedZip(signedApp: signedApp, outputDir: outputDir, secrets: secrets, dSYMs: dSYMs,
                         encodeKey: { try RCodesign.run($0, stage: .package) }, submit: Notary.rcodesign)
    }

    static func notarizedZip(signedApp: URL, outputDir: URL, secrets: Secrets, dSYMs: URL? = nil, encodeKey: ([String]) throws -> Void,
                             submit: ([String]) throws -> Notary.Run) throws -> URL {
        let name = signedApp.deletingPathExtension().lastPathComponent
        return try Files.atomicOutput(outputDir) { out in
            let app = out.appendingPathComponent(signedApp.lastPathComponent)
            try FileManager.default.copyItem(at: signedApp, to: app)
            try Notary.notarize(app, secrets: secrets, encodeKey: encodeKey, run: submit)
            try Notary.checkStapled(app: app)
            let zip = out.appendingPathComponent("\(name)-macOS.zip")
            try Shell.run("zip", ["-qry", zip.path, argument(app.lastPathComponent), "-x"] + junkExclusions, cwd: out, stage: .package)
            try zipDSYMs(dSYMs, app: signedApp, into: out)
            return zip
        }
    }
}
