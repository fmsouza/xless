import Foundation
import XlessASC
import XlessCore

public enum SignStage {
    /// `updatesOff`: what turned provisioning updates off (`--no-provisioning-updates`): then nothing on the account is
    /// changed, and what would have to be is the error. nil: what signing needs is made.
    /// `say`: where the plan of what changes on the account is printed (standard error).
    /// `manifest`: the bundles' entitlements as the build recorded them (React Native). Without it the app's come from
    /// `platforms.<p>.entitlements` and an app extension, if any, gets none.
    public static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL,
                           secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest? = nil,
                           updatesOff: String? = nil, say: (String) -> Void = standardError) async throws -> URL {
        try await run(input: input, outputDir: outputDir, platform: platform, config: config, project: project, secrets: secrets,
                      client: client, manifest: manifest, updatesOff: updatesOff, say: say, codesign: { try Shell.run("rcodesign", $0, stage: .sign) })
    }

    /// `codesign` runs rcodesign with the given arguments (a test seam: tests read the entitlement files it names).
    static func run(input: URL, outputDir: URL, platform: Platform, config: ProjectConfig, project: URL, secrets: Secrets,
                    client: ASCClient, manifest: EntitlementsManifest?, updatesOff: String? = nil, say: (String) -> Void = { _ in },
                    codesign: ([String]) throws -> Void) async throws -> URL {
        try await Files.atomicOutput(outputDir) { partial in
            try await sign(input: input, into: partial, platform: platform, config: config, project: project, secrets: secrets,
                           client: client, manifest: manifest, updatesOff: updatesOff, say: say, codesign: codesign)
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
                     secrets: Secrets, client: ASCClient, manifest: EntitlementsManifest?, updatesOff: String?, say: (String) -> Void,
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
        if let updatesOff { try plan.requireNothing(off: updatesOff) }
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

        // Loose Mach-Os (e.g. a Tauri bundle.resources dylib) and nested code bundles (e.g. an embedded framework) get the
        // hardened runtime like the main executable.
        let info = try Plist.read(app.appendingPathComponent(layout.infoPlist), stage: .sign)
        let main = [layout.executableDir, info["CFBundleExecutable"] as? String ?? pc.product].filter { !$0.isEmpty }.joined(separator: "/")
        let runtimePaths = distribution == .developerID ? RCodesign.hardenedRuntimePaths(in: app, mainExecutable: main) : []

        try PrivateFiles.with(stage: .sign) { files in
            let signer = try files.signer(key: key, certificate: cert.der), entURL = files.directory.appendingPathComponent("ent.plist")
            var nestedEntitlements: [(path: String, file: URL)] = []
            for (i, p) in provisioned.enumerated() {
                if p.target.path.isEmpty { try Plist.write(merged[i], to: entURL, format: .xml, stage: .sign); continue }
                let url = files.directory.appendingPathComponent("ent-\(i).plist")
                try Plist.write(merged[i], to: url, format: .xml, stage: .sign)
                nestedEntitlements.append((p.target.path, url))
            }
            try codesign(RCodesign.signArguments(bundle: app, keyPEM: signer.key, certPEM: signer.certificate, entitlements: entURL, distribution: distribution,
                                                 runtimePaths: runtimePaths, nestedEntitlements: nestedEntitlements))
        }
        return app
    }
}
