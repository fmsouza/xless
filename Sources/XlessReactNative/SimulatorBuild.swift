import Foundation
import XlessCore
import XlessMachO
import XlessXcode

/// What a React Native build for the iOS Simulator (`--destination simulator`) does differently from a device build,
/// matched black-box to an Xcode 27.0 simulator build of the same workspace (docs/react-native.md, "Simulator builds"):
/// - Swift Build builds for `iphonesimulator`, arm64 only (`SDKROOT`, `ARCHS`: an Apple-silicon Mac's simulator; Xcode's
///   generic simulator destination would also build x86_64), into its own derived data and stage directory;
/// - each bundle's executable carries its entitlements in `__TEXT,__entitlements` (XML) and `__TEXT,__ents_der` (DER),
///   linked in through Swift Build's simulator-only `LD_ENTITLEMENTS_SECTION(_DER)` settings, as Xcode links its
///   `<product>-Simulated.xcent(.der)`: the target's entitlements file plus `application-identifier`;
/// - the app is signed ad hoc (no key, no profile, no secret) with empty entitlements, every framework and extension
///   included, as Xcode's "Sign to Run Locally" signs it. The simulator refuses an unsigned arm64 app.
/// There is no assets, finalize, sign, package or upload stage: the build's `.app` is what `simctl install` takes.
public enum SimulatorBuild {
    /// Command-line settings added to the device build's for the simulator, as `xcodebuild -sdk iphonesimulator` sets
    /// `SDKROOT`; arm64 only.
    public static let buildSettings = ["SDKROOT": "iphonesimulator", "ARCHS": "arm64"]

    /// What Xcode's `ProcessProductPackaging` writes for a simulator build (`<product>-Simulated.xcent`): the target's
    /// entitlements (`entitlements.json`'s value for it), with `$(AppIdentifierPrefix)` / `$(TeamIdentifierPrefix)` as
    /// `<teamID>.`, plus `application-identifier` = `<teamID>.<bundle ID>`. The overlay's `entitlements:` edits are
    /// applied as the sign stage applies them, so the simulator app sees the groups the device app is signed with.
    public static func simulatedEntitlements(_ e: BuiltApp.Entitlements, teamID: String, rewrites: EntitlementRewrites) -> JSON {
        func map(_ v: JSON) -> JSON {
            switch v {
            case .string(let s):
                var s = s
                for name in ["AppIdentifierPrefix", "TeamIdentifierPrefix"] {
                    for ref in ["$(\(name))", "${\(name)}"] { s = s.replacingOccurrences(of: ref, with: teamID + ".") }
                }
                return .string(rewrites.apply(to: s))
            case .array(let a): return .array(a.map(map))
            case .object(let o): return .object(o.mapValues(map))
            default: return v
            }
        }
        guard case .object(let top) = e.entitlements else { return .object(["application-identifier": .string("\(teamID).\(e.bundleID)")]) }
        var out = top.filter { !rewrites.remove.contains($0.key) }.mapValues(map)
        out["application-identifier"] = .string("\(teamID).\(e.bundleID)")
        return .object(out)
    }

    /// Writes `<dir>/<target>-Simulated.xcent` and `.xcent.der` and returns the per-target settings that link them.
    public static func entitlementSections(_ simulated: JSON, target: String, in dir: URL) throws -> [String: String] {
        let xml = dir.appendingPathComponent("\(target)-Simulated.xcent"), der = dir.appendingPathComponent("\(target)-Simulated.xcent.der")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try EntitlementsEncoding.xml(simulated).write(to: xml, options: .atomic)
            try EntitlementsEncoding.der(simulated).write(to: der, options: .atomic)
        } catch {
            throw XlessError(.build, "cannot write the simulated entitlements of \(target) in \(dir.path): \(error.localizedDescription)",
                             fix: "check the derived data directory")
        }
        return ["LD_ENTITLEMENTS_SECTION": xml.path, "LD_ENTITLEMENTS_SECTION_DER": der.path]
    }

    /// `rcodesign sign` arguments for an ad-hoc signature (no `--pem-file`) of `app` and everything nested in it, the
    /// app and each of `nested` (bundle-relative `PlugIns/X.appex`) with the empty entitlements in `emptyEntitlements`,
    /// as Xcode signs simulator builds (`codesign --force --sign - --entitlements <empty>`). Frameworks get no
    /// entitlements.
    public static func adHocSignArguments(app: URL, nested: [String], emptyEntitlements: URL) -> [String] {
        var a = ["sign", "--entitlements-xml-file", emptyEntitlements.path]
        for path in nested { a += ["--entitlements-xml-file", "\(path):\(emptyEntitlements.path)"] }
        return a + [app.path]
    }

    /// Signs `app` ad hoc in place with `rcodesign` (on PATH; the xless images have it).
    public static func signAdHoc(_ app: URL, nested: [String], scratch: URL, baseEnvironment: [String: String]) throws {
        let empty = scratch.appendingPathComponent("empty.xcent")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try EntitlementsEncoding.xml(.object([:])).write(to: empty, options: .atomic)
        } catch {
            throw XlessError(.build, "cannot write \(empty.path): \(error.localizedDescription)", fix: "check the derived data directory")
        }
        try Shell.run("rcodesign", adHocSignArguments(app: app, nested: nested, emptyEntitlements: empty), baseEnvironment: baseEnvironment, stage: .build)
    }

    /// The same by a Mac's codesign, from the inside out: the frameworks, each extension, the app.
    static func signAdHocOnAMac(_ app: URL, nested: [String], scratch: URL, baseEnvironment: [String: String]) throws {
        let empty = scratch.appendingPathComponent("empty.xcent")
        do { try EntitlementsEncoding.xml(.object([:])).write(to: empty, options: .atomic) } catch {
            throw XlessError(.build, "cannot write \(empty.path): \(error.localizedDescription)", fix: "check the derived data directory")
        }
        func sign(_ code: URL, _ more: [String] = []) throws {
            try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none"] + more + [code.path], baseEnvironment: baseEnvironment, stage: .build)
        }
        for bundle in nested.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }).map({ app.appendingPathComponent($0) }) + [app] {
            let frameworks = (try? FileManager.default.contentsOfDirectory(at: bundle.appendingPathComponent("Frameworks"), includingPropertiesForKeys: nil)) ?? []
            for code in frameworks.sorted(by: { $0.path < $1.path }) { try sign(code) }
            try sign(bundle, ["--entitlements", empty.path])
        }
    }

    /// The Mach-O images under `app` whose LINKEDIT tables dyld would refuse (as `finalize` checks device builds), as
    /// `<path>: <problems>`.
    public static func linkeditProblems(in app: URL) throws -> [String] {
        let root = app.standardizedFileURL.path
        var out: [String] = []
        for file in Files.regularFiles(under: app) {
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped), (try? MachO.containsLoadableImage(data)) == true else { continue }
            let problems = (try? MachO.linkeditAlignmentProblems(in: data)) ?? ["unreadable load commands"]
            if !problems.isEmpty {
                out.append("\(String(file.standardizedFileURL.path.dropFirst(root.count + 1))): \(problems.joined(separator: "; "))")
            }
        }
        return out
    }
}
