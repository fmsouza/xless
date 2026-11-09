import Foundation
import XlessASC
import XlessCore

public enum SignStage {
    /// `manifest`: the bundles' entitlements as the build recorded them (React Native). Without it the app's come from
    /// `platforms.<p>.entitlements` and an app extension, if any, gets none.
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                           secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest? = nil) async throws -> URL {
        try await run(input: input, outputDir: outputDir, platform: platform, config: config, project: project, secrets: secrets,
                      client: client, manifest: manifest, codesign: { try Shell.run("rcodesign", $0, stage: .sign) })
    }

    /// `codesign` runs rcodesign with the given arguments (a test seam: tests read the entitlement files it names).
    static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL, secrets: Secrets,
                    client: ASCClient, manifest: EntitlementsManifest?, codesign: ([String]) throws -> Void) async throws -> URL {
        try await Files.atomicOutput(outputDir) { partial in
            try await sign(input: input, into: partial, platform: platform, config: config, project: project, secrets: secrets,
                           client: client, manifest: manifest, codesign: codesign)
        }
    }

    /// A bundle with the profile it is signed under.
    struct Provisioned {
        var target: SignTarget
        var profile: Data
        var granted: [String: Any]
    }

    static func sign(input: URL, into outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                     secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest?,
                     codesign: ([String]) throws -> Void) async throws -> URL {
        let pc = try config.platform(platform)
        let distribution = config.distribution(for: platform)
        let kind: CertificateKind = distribution == .appStore ? .distribution : .developerID
        let key = try SigningKey(pem: secrets.required(kind.secretName, stage: .sign))
        let bundleID = config.bundleID(for: platform)

        // The bundles and their entitlements first: a bad app or a stale manifest is refused before App Store Connect is called.
        // xless.yml paths are project-relative; a Tauri overlay's `macos.entitlements` is already absolute. A manifest
        // (React Native) replaces them.
        let user = manifest != nil ? [:] : try pc.entitlements.map {
            try Plist.read($0.hasPrefix("/") ? URL(fileURLWithPath: $0) : project.appendingPathComponent($0), stage: .sign)
        } ?? [:]
        let targets = try SignTargets.plan(app: input, platform: platform, appBundleID: bundleID, appEntitlements: user,
                                           manifest: manifest, teamID: config.teamID)
        let certService = CertificateService(client: client)
        let profiles = ProfileService(client: client)
        let cert = try await certService.find(matching: key, kind: kind)
        var provisioned: [Provisioned] = []
        for target in targets {
            provisioned.append(try await provision(target, platform: platform, distribution: distribution, certificateID: cert.id,
                                                    profiles: profiles, client: client))
        }

        // Every check runs before the bundle is touched.

        for p in provisioned { try Entitlements.checkTeam(profile: p.granted, teamID: config.teamID) }
        if platform == .ios { try Entitlements.checkAppGroups(provisioned.map { ($0.target.bundleID, $0.target.entitlements, $0.granted) }) }
        let merged = try provisioned.map {
            try Entitlements.merge(user: $0.target.entitlements, profile: $0.granted, platform: platform, teamID: config.teamID, bundleID: $0.target.bundleID)
        }
        guard let der = cert.attributes.certificateContent.flatMap({ Data(base64Encoded: $0) }) else {
            throw XlessError(.sign, "certificate \(cert.id) has no content", fix: "re-run; if it persists, check the certificate in App Store Connect")
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
        let certPEM = "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]))\n-----END CERTIFICATE-----\n"
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

    /// Registers the bundle ID, enables the capabilities its entitlements need and gets its profile.
    static func provision(_ target: SignTarget, platform: Platform, distribution: Distribution, certificateID: String, profiles: ProfileService,
                          client: ASCClient) async throws -> Provisioned {
        let needed = Capabilities.required(entitlements: target.entitlements, platform: platform)
        let resource = try await profiles.ensureBundleID(identifier: target.bundleID, platform: platform)
        let enabled = try await Capabilities.ensure(needed.types, bundleIDResourceID: resource, client: client)
        let type = ProfileType.for(platform: platform, distribution: distribution)
        var profile = try await profiles.ensureProfile(bundleIDResourceID: resource, certificateID: certificateID,
                                                       type: type, bundleIdentifier: target.bundleID, forceNew: enabled)
        var granted = try Entitlements.extract(fromProfile: profile)
        // A capability enabled (or an app group assigned) by hand in the portal only reaches an existing profile once it
        // is regenerated. A keychain group outside the team's pattern is not something a new profile changes.
        if !enabled, Entitlements.problems(user: target.entitlements, profile: granted, platform: platform)
            .contains(where: { $0.key != Entitlements.keychainGroupsKey }) {
            profile = try await profiles.ensureProfile(bundleIDResourceID: resource, certificateID: certificateID,
                                                       type: type, bundleIdentifier: target.bundleID, forceNew: true)
            granted = try Entitlements.extract(fromProfile: profile)
        }
        return Provisioned(target: target, profile: profile, granted: granted)
    }
}
