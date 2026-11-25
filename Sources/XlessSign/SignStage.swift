import Foundation
import XlessASC
import XlessCore

public enum SignStage {
    /// `say`: where the plan of what changes on the account is printed (standard error).
    /// `manifest`: the bundles' entitlements as the build recorded them (React Native). Without it the app's come from
    /// `platforms.<p>.entitlements` and an app extension, if any, gets none.
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                           secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest? = nil,
                           say: (String) -> Void = standardError) async throws -> URL {
        try await run(input: input, outputDir: outputDir, platform: platform, config: config, project: project, secrets: secrets,
                      client: client, manifest: manifest, say: say, codesign: { try Shell.run("rcodesign", $0, stage: .sign) })
    }

    /// `codesign` runs rcodesign with the given arguments (a test seam: tests read the entitlement files it names).
    static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL, secrets: Secrets,
                    client: ASCClient, manifest: EntitlementsManifest?, say: (String) -> Void = { _ in },
                    codesign: ([String]) throws -> Void) async throws -> URL {
        try await Files.atomicOutput(outputDir) { partial in
            try await sign(input: input, into: partial, platform: platform, config: config, project: project, secrets: secrets,
                           client: client, manifest: manifest, say: say, codesign: codesign)
        }
    }

    public static let standardError: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    /// A bundle with the profile it is signed under.
    struct Provisioned {
        var target: SignTarget
        var profile: Data
        var granted: [String: Any]
    }

    static func sign(input: URL, into outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                     secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest?, say: (String) -> Void,
                     codesign: ([String]) throws -> Void) async throws -> URL {
        let pc = try config.platform(platform)
        let distribution = config.distribution(for: platform)
        let kind: CertificateKind = distribution == .appStore ? .distribution : .developerID
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .sign))
        let bundleID = config.bundleID(for: platform)

        // The bundles and their entitlements first: a bad app or a stale manifest is refused before App Store Connect is called.
        // xless.yml paths are project-relative; a Tauri overlay's `macos.entitlements` is already absolute. A manifest
        // (React Native) replaces them.
        func read(_ path: String) throws -> [String: Any] {
            try Plist.read(path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.appendingPathComponent(path), stage: .sign)
        }
        let user = manifest != nil ? [:] : try pc.entitlements.map(read) ?? [:]
        // Extensions the config declares (xless.yml / a Tauri or cargo overlay) are signed with their own entitlements.
        let declared = manifest != nil ? [] : try pc.extensions.map {
            DeclaredExtension(path: $0.path, bundleID: $0.bundleID, entitlements: try $0.entitlements.map(read) ?? [:])
        }
        let targets = try SignTargets.plan(app: input, platform: platform, appBundleID: bundleID, appEntitlements: user,
                                           manifest: manifest, teamID: config.teamID, declared: declared)
        let resources = ASCResources(client: client)
        let cert = try await ASCCertificates(resources: resources).find(for: key, kind: kind)
        let account = APISigningAccount(resources: resources, stage: .sign)
        let plan = try await SigningPlanner(account: account).plan(targets.map {
            SigningTarget(platform: platform, distribution: distribution, bundleID: $0.bundleID, entitlements: $0.entitlements,
                          extensionPath: $0.path.isEmpty ? nil : $0.path)
        }, certificate: cert.id)
        say(plan.text)
        let profiles = try await SigningApplier(account: account).apply(plan)
        let provisioned = try zip(targets, profiles).map { Provisioned(target: $0, profile: $1, granted: try Entitlements.extract(fromProfile: $1)) }

        // Every check runs before the bundle is touched.

        for p in provisioned { try Entitlements.checkTeam(profile: p.granted, teamID: config.teamID) }
        if platform == .ios { try Entitlements.checkAppGroups(provisioned.map { ($0.target.bundleID, $0.target.entitlements, $0.granted) }) }
        let merged = try provisioned.map {
            try Entitlements.merge(user: $0.target.entitlements, profile: $0.granted, platform: platform, teamID: config.teamID, bundleID: $0.target.bundleID)
        }

        let app = try Files.copyBundle(input, intoFreshDir: outputDir)
        let layout = BundleLayout(platform: platform)
        for p in provisioned {
            // An app extension carries its own profile, as Xcode embeds it: `X.appex/embedded.mobileprovision`.
            let profileURL = app.appendingPathComponent(p.target.path.isEmpty ? layout.embeddedProfile : "\(p.target.path)/embedded.mobileprovision")
            try FileManager.default.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try p.profile.write(to: profileURL)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xless-sign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keyURL = tmp.appendingPathComponent("key.pem"), certURL = tmp.appendingPathComponent("cert.pem"), entURL = tmp.appendingPathComponent("ent.plist")
        guard FileManager.default.createFile(atPath: keyURL.path, contents: Data(key.pem.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw XlessError(.sign, "cannot write signing key to temp dir", fix: "check free space and permissions of \(FileManager.default.temporaryDirectory.path)")
        }
        let certPEM = "-----BEGIN CERTIFICATE-----\n\(cert.der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        var nestedEntitlements: [(path: String, file: URL)] = []
        for (i, p) in provisioned.enumerated() {
            if p.target.path.isEmpty { try Plist.write(merged[i], to: entURL, format: .xml, stage: .sign); continue }
            let url = tmp.appendingPathComponent("ent-\(i).plist")
            try Plist.write(merged[i], to: url, format: .xml, stage: .sign)
            nestedEntitlements.append((p.target.path, url))
        }

        // Loose Mach-Os (e.g. a Tauri bundle.resources dylib) and nested code bundles (e.g. an embedded framework) get the
        // hardened runtime like the main executable.
        let info = try Plist.read(app.appendingPathComponent(layout.infoPlist), stage: .sign)
        let main = [layout.executableDir, info["CFBundleExecutable"] as? String ?? pc.product].filter { !$0.isEmpty }.joined(separator: "/")
        let runtimePaths = distribution == .developerID ? RCodesign.hardenedRuntimePaths(in: app, mainExecutable: main) : []
        try codesign(RCodesign.signArguments(bundle: app, keyPEM: keyURL, certPEM: certURL, entitlements: entURL, distribution: distribution,
                                             runtimePaths: runtimePaths, nestedEntitlements: nestedEntitlements))
        return app
    }
}
