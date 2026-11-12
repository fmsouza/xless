import Testing
import Foundation
@testable import XlessTauri
@testable import XlessCore

private var fm: FileManager { .default }

private func tmp() -> URL {
    fm.temporaryDirectory.appendingPathComponent("swiftpkgs-\(UUID().uuidString)", isDirectory: true)
}

private func write(_ text: String, to url: URL, mode: Int? = nil) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
}

/// A shell script standing in for llvm-nm / llvm-objdump / rustc.
private func script(_ body: String, in dir: URL, name: String = "tool") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try write("#!/bin/sh\n\(body)\n", to: url, mode: 0o755)
    return url
}

/// Every path under `dir` with its size, to prove a tree was left untouched.
private func snapshot(_ dir: URL) -> [String] {
    guard let e = fm.enumerator(atPath: dir.path) else { return [] }
    return e.compactMap { $0 as? String }.sorted().map { rel in
        let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(rel).path))?[.size] as? Int ?? -1
        return "\(rel) \(size)"
    }
}

private func paths(_ dir: URL) -> [String] {
    ((fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []).sorted()
}

private let pluginManifest = """
    // swift-tools-version:5.3
    import PackageDescription
    let package = Package(name: "p", products: [.library(name: "p", type: .static, targets: ["p"])],
      dependencies: [.package(name: "Tauri", path: "../.tauri/tauri-api")], targets: [.target(name: "p", path: "Sources")])
    """

/// The fixture metadata with /WORK and /REGISTRY pointing at a temp tree in which hello-plugin and tauri-plugin-dialog have
/// an `ios/Package.swift` and tauri-plugin-fs (a `tauri-plugin` build-dependency like the others) has none.
private func fixtureMetadata() throws -> (data: Data, work: URL, registry: URL) {
    let root = tmp(), work = root.appendingPathComponent("work"), registry = root.appendingPathComponent("registry")
    try write(pluginManifest, to: work.appendingPathComponent("src-tauri/plugins/hello-plugin/ios/Package.swift"))
    try write(pluginManifest, to: registry.appendingPathComponent("tauri-plugin-dialog-2.7.1/ios/Package.swift"))
    try write("[package]\n", to: registry.appendingPathComponent("tauri-plugin-fs-2.5.1/Cargo.toml"))
    try write("// api\n", to: registry.appendingPathComponent("tauri-2.12.0/mobile/ios-api/Package.swift"))
    let text = try String(contentsOf: fixturesDir.appendingPathComponent("cargo-metadata.json"), encoding: .utf8)
        .replacingOccurrences(of: "/WORK", with: work.path)
        .replacingOccurrences(of: "/REGISTRY", with: registry.path)
    return (Data(text.utf8), work, registry)
}

@Suite struct SwiftPackagesTests {
    // MARK: discover

    @Test func discoversTauriAPIAndPluginsWithAnIOSPackage() throws {
        let (data, work, registry) = try fixtureMetadata()
        let found = try SwiftPackages.discover(metadata: data)
        #expect(found.tauriAPI.path == registry.appendingPathComponent("tauri-2.12.0/mobile/ios-api").path)
        #expect(found.plugins == [
            SwiftPackage(name: "tauri-plugin-dialog", product: "", sourceDir: registry.appendingPathComponent("tauri-plugin-dialog-2.7.1/ios"), needsTauriAPI: true),
            SwiftPackage(name: "tauri-plugin-hello", product: "", sourceDir: work.appendingPathComponent("src-tauri/plugins/hello-plugin/ios"), needsTauriAPI: true),
        ])
    }

    @Test func pluginWithoutTauriAPIReferenceIsMarked() throws {
        let (data, work, _) = try fixtureMetadata()
        try write("// swift-tools-version:5.3\n", to: work.appendingPathComponent("src-tauri/plugins/hello-plugin/ios/Package.swift"))
        let hello = try SwiftPackages.discover(metadata: data).plugins.first { $0.name == "tauri-plugin-hello" }
        #expect(hello?.needsTauriAPI == false)
    }

    @Test func missingTauriCrateIsABuildError() throws {
        let data = Data(#"{"packages": [{"name": "serde", "manifest_path": "/R/serde/Cargo.toml", "dependencies": []}]}"#.utf8)
        #expect(throws: XlessError(.build, "tauri crate not found in cargo metadata",
                                   fix: "check that the app's Cargo.toml depends on tauri 2 for the iOS target")) {
            try SwiftPackages.discover(metadata: data)
        }
    }

    // MARK: stage

    @Test func stagesIntoOneTreeWithoutWritingToReadOnlySources() throws {
        let src = tmp(), out = tmp()
        let api = src.appendingPathComponent("tauri-2.12.0/mobile/ios-api")
        try write("// api\n", to: api.appendingPathComponent("Package.swift"))
        try write("public struct A {}\n", to: api.appendingPathComponent("Sources/Tauri/A.swift"))
        try write("{}\n", to: api.appendingPathComponent("Package.resolved"))
        try write("// test\n", to: api.appendingPathComponent("Tests/TauriTests/T.swift"))
        try write("junk\n", to: api.appendingPathComponent(".build/x.o"))
        let dialog = src.appendingPathComponent("tauri-plugin-dialog-2.7.1/ios")
        try write(pluginManifest, to: dialog.appendingPathComponent("Package.swift"))
        try write("// d\n", to: dialog.appendingPathComponent("Sources/D.swift"))
        try write("// nested Tests stays\n", to: dialog.appendingPathComponent("Sources/Tests/N.swift"))
        let hello = src.appendingPathComponent("hello-plugin/ios")
        try write(pluginManifest, to: hello.appendingPathComponent("Package.swift"))
        try write("// h\n", to: hello.appendingPathComponent("Sources/H.swift"), mode: 0o444)

        // Mimic the cargo registry: every source directory read-only.
        let dirs = [src] + ((fm.enumerator(atPath: src.path)?.allObjects as? [String]) ?? [])
            .map { src.appendingPathComponent($0) }
            .filter { (try? fm.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeDirectory }
        for d in dirs { try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: d.path) }
        defer { for d in dirs { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) } }
        let before = snapshot(src)

        let plugins = [
            SwiftPackage(name: "tauri-plugin-dialog", product: "", sourceDir: dialog, needsTauriAPI: true),
            SwiftPackage(name: "tauri-plugin-hello", product: "", sourceDir: hello, needsTauriAPI: true),
        ]
        let products = ["tauri-plugin-dialog": "tauri-plugin-dialog", "tauri-plugin-hello": "hello-product"]
        var staged: [SwiftPackage] = []
        for _ in 0..<2 {  // re-staging over a previous run (read-only copied files included) works
            staged = try SwiftPackages.stage(tauriAPI: api, plugins: plugins, into: out) { dir in products[dir.lastPathComponent]! }
        }

        #expect(snapshot(src) == before)
        let pluginsDir = out.appendingPathComponent("plugins")
        #expect(staged == [
            SwiftPackage(name: "tauri-plugin-dialog", product: "tauri-plugin-dialog", sourceDir: pluginsDir.appendingPathComponent("tauri-plugin-dialog"), needsTauriAPI: true),
            SwiftPackage(name: "tauri-plugin-hello", product: "hello-product", sourceDir: pluginsDir.appendingPathComponent("tauri-plugin-hello"), needsTauriAPI: true),
        ])
        // .build, Package.resolved and Tests are skipped at the package root.
        #expect(paths(pluginsDir.appendingPathComponent(".tauri/tauri-api")) == ["Package.swift", "Sources", "Sources/Tauri", "Sources/Tauri/A.swift"])
        #expect(fm.fileExists(atPath: pluginsDir.appendingPathComponent("tauri-plugin-dialog/Sources/Tests/N.swift").path))
        #expect(fm.fileExists(atPath: pluginsDir.appendingPathComponent("tauri-plugin-hello/Sources/H.swift").path))
        // Each plugin's `path: "../.tauri/tauri-api"` resolves to the single shared copy.
        let resolved = pluginsDir.appendingPathComponent("tauri-plugin-hello").appendingPathComponent("../.tauri/tauri-api/Package.swift").standardizedFileURL
        #expect(fm.fileExists(atPath: resolved.path))
        #expect(Set(try fm.contentsOfDirectory(atPath: out.path)) == ["plugins"])
    }

    @Test func duplicatePluginNamesAreRefused() throws {
        let src = tmp()
        let api = src.appendingPathComponent("api")
        try write("// api\n", to: api.appendingPathComponent("Package.swift"))
        let p = SwiftPackage(name: "tauri-plugin-x", product: "", sourceDir: api, needsTauriAPI: false)
        #expect(throws: XlessError.self) {
            try SwiftPackages.stage(tauriAPI: api, plugins: [p, p], into: tmp()) { _ in "x" }
        }
    }

    // MARK: products

    @Test func libraryProductComesFromDumpPackage() throws {
        func dump(_ products: String) -> Data { Data(#"{"name": "p", "products": [\#(products)]}"#.utf8) }
        let lib = #"{"name": "tauri-plugin-hello", "type": {"library": ["static"]}, "targets": ["t"]}"#
        let exe = #"{"name": "tool", "type": {"executable": null}, "targets": ["t"]}"#
        #expect(try SwiftPackages.libraryProduct(dumpPackage: dump("\(exe), \(lib)"), package: "p") == "tauri-plugin-hello")
        #expect(throws: XlessError.self) { try SwiftPackages.libraryProduct(dumpPackage: dump(exe), package: "p") }
        #expect(throws: XlessError.self) { try SwiftPackages.libraryProduct(dumpPackage: dump("\(lib), \(lib)"), package: "p") }
    }

    @Test func remoteDependenciesOtherThanSwiftRsAreRefused() throws {
        func dump(_ deps: String) -> Data { Data(#"{"name": "p", "products": [], "dependencies": [\#(deps)]}"#.utf8) }
        let api = #"{"fileSystem": [{"identity": "tauri-api", "path": "/w/plugins/.tauri/tauri-api"}]}"#
        let swiftRs = #"{"sourceControl": [{"identity": "swift-rs", "location": {"remote": [{"urlString": "https://github.com/Brendonovich/swift-rs.git"}]}}]}"#
        let other = #"{"sourceControl": [{"identity": "other", "location": {"remote": [{"urlString": "https://example.com/other.git"}]}}]}"#
        let legacy = #"{"sourceControl": [{"identity": "old", "location": {"remote": ["https://example.com/old"]}}]}"#
        let registry = #"{"registry": [{"identity": "example.pkg"}]}"#
        try SwiftPackages.checkDependencies(dumpPackage: dump("\(api), \(swiftRs)"), package: "tauri-plugin-x")
        try SwiftPackages.checkDependencies(dumpPackage: dump(""), package: "tauri-plugin-x")
        for (dep, name) in [(other, "https://example.com/other.git"), (legacy, "https://example.com/old"), (registry, "example.pkg")] {
            do {
                try SwiftPackages.checkDependencies(dumpPackage: dump("\(api), \(dep)"), package: "tauri-plugin-x")
                Issue.record("accepted \(dep)")
            } catch let e as XlessError {
                #expect(e.stage == .build)
                #expect(e.cause == "plugin tauri-plugin-x depends on remote Swift package \(name), which xless does not pin")
                #expect(e.fix == "report it")
            }
        }
    }

    @Test func dumpPackageOfAPluginWithARemoteDependencyIsRefused() throws {
        let dir = tmp().appendingPathComponent("tauri-plugin-remote")
        try write("""
            // swift-tools-version:5.3
            import PackageDescription
            let package = Package(name: "tauri-plugin-remote", platforms: [.iOS(.v14)],
              products: [.library(name: "remote-product", type: .static, targets: ["t"])],
              dependencies: [.package(name: "Tauri", path: "../.tauri/tauri-api"), .package(url: "https://example.com/dep.git", from: "1.0.0")],
              targets: [.target(name: "t", dependencies: [.byName(name: "Tauri")], path: "Sources")])
            """, to: dir.appendingPathComponent("Package.swift"))
        do {
            _ = try SwiftPackages.libraryProduct(packageDir: dir)
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.cause == "plugin tauri-plugin-remote depends on remote Swift package https://example.com/dep.git, which xless does not pin", "\(e.cause)")
        }
    }

    @Test func libraryProductRunsDumpPackage() throws {
        let dir = tmp().appendingPathComponent("tauri-plugin-hello")
        try write("""
            // swift-tools-version:5.3
            import PackageDescription
            let package = Package(name: "tauri-plugin-hello", platforms: [.iOS(.v14)],
              products: [.library(name: "hello-product", type: .static, targets: ["t"])],
              dependencies: [.package(name: "Tauri", path: "../.tauri/tauri-api")],
              targets: [.target(name: "t", dependencies: [.byName(name: "Tauri")], path: "Sources")])
            """, to: dir.appendingPathComponent("Package.swift"))
        #expect(try SwiftPackages.libraryProduct(packageDir: dir) == "hello-product")
    }

    // MARK: aggregate

    @Test func aggregateManifestIsExact() {
        let text = SwiftPackages.aggregateManifest(minimumIOS: "16.0", packages: [
            (name: "Tauri", path: "../plugins/.tauri/tauri-api", product: "Tauri"),
            (name: "tauri-plugin-example", path: "../plugins/tauri-plugin-example", product: "tauri-plugin-example"),
        ])
        #expect(text == """
            // swift-tools-version:5.9
            // Generated by xless: links every Tauri Swift package of this app into one static library.
            import PackageDescription

            let package = Package(
              name: "XlessTauriSwift",
              platforms: [.iOS("16.0")],
              products: [.library(name: "XlessTauriSwift", type: .static, targets: ["XlessTauriSwift"])],
              dependencies: [
                .package(name: "Tauri", path: "../plugins/.tauri/tauri-api"),
                .package(name: "tauri-plugin-example", path: "../plugins/tauri-plugin-example"),
              ],
              targets: [
                .target(name: "XlessTauriSwift", dependencies: [
                  .product(name: "Tauri", package: "Tauri"),
                  .product(name: "tauri-plugin-example", package: "tauri-plugin-example"),
                ], path: "Sources"),
              ]
            )

            """)
    }

    @Test func writeAggregateLaysOutThePackageAndPinsSwiftRs() throws {
        let out = tmp()
        let staged = [SwiftPackage(name: "tauri-plugin-hello", product: "hello-product", sourceDir: out.appendingPathComponent("plugins/tauri-plugin-hello"), needsTauriAPI: true)]
        let agg = try SwiftPackages.writeAggregate(minimumIOS: "16.0", plugins: staged, into: out)
        #expect(agg == out.appendingPathComponent("Aggregate"))
        let manifest = try String(contentsOf: agg.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest == SwiftPackages.aggregateManifest(minimumIOS: "16.0", packages: [
            (name: "Tauri", path: "../plugins/.tauri/tauri-api", product: "Tauri"),
            (name: "hello-product", path: "../plugins/tauri-plugin-hello", product: "hello-product"),
        ]))
        let source = try String(contentsOf: agg.appendingPathComponent("Sources/XlessTauriSwift/XlessTauriSwift.swift"), encoding: .utf8)
        #expect(source == "// Intentionally empty: the product carries its dependencies.\n")
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: agg.appendingPathComponent("Package.resolved"))) as! [String: Any]
        #expect(resolved["version"] as? Int == 2)
        let pin = (resolved["pins"] as! [[String: Any]]).first!
        #expect(pin["identity"] as? String == "swift-rs")
        #expect(pin["location"] as? String == "https://github.com/Brendonovich/swift-rs")
        #expect((pin["state"] as? [String: String]) == ["version": "1.0.9", "revision": "207e4bfe5d36fdd0cc08f28d1849ff94ac7e24b8"])
    }

    // MARK: build

    @Test func buildRunsSwiftBuildForTheVersionedTripleAndFindsTheProduct() throws {
        let bundle = tmp(), agg = tmp()
        try write("{}", to: bundle.appendingPathComponent("toolset-swb.json"))
        var calls: [(String, [String], [String: String?])] = []
        let lib = try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: ["PATH": "/usr/bin"]) { exe, args, env in
            calls.append((exe, args, env))
            try write("!<arch>\n", to: agg.appendingPathComponent(".build/out/Products/Release-iphoneos/libXlessTauriSwift.a"))
        }
        #expect(lib == agg.appendingPathComponent(".build/out/Products/Release-iphoneos/libXlessTauriSwift.a"))
        #expect(calls.count == 1)
        #expect(calls[0].0 == "swift")
        #expect(calls[0].1 == ["build", "-c", "release", "--package-path", agg.path, "--build-system", "swiftbuild",
                               "--triple", "arm64-apple-ios16.0", "--toolset", bundle.appendingPathComponent("toolset-swb.json").path,
                               "--force-resolved-versions"])
        #expect(calls[0].2["SDKROOT"] == .some(nil))
        #expect(calls[0].2["XCODE_EXTRA_PLATFORM_FOLDERS"] == bundle.appendingPathComponent("Developer/Platforms").path)
        #expect(calls[0].2["PATH"] == "\(bundle.appendingPathComponent("toolset/bin").path):/usr/bin")
    }

    @Test func buildSearchesForTheProductAndRefusesUnlessExactlyOne() throws {
        let bundle = tmp()
        try write("{}", to: bundle.appendingPathComponent("toolset-swb.json"))
        func run(_ places: [String]) throws -> URL {
            let agg = tmp()
            return try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: [:]) { _, _, _ in
                for p in places { try write("!<arch>\n", to: agg.appendingPathComponent(p)) }
            }
        }
        #expect(try run([".build/elsewhere/libXlessTauriSwift.a"]).path.hasSuffix(".build/elsewhere/libXlessTauriSwift.a"))
        #expect(throws: XlessError.self) { try run([]) }
        #expect(throws: XlessError.self) { try run([".build/a/libXlessTauriSwift.a", ".build/b/libXlessTauriSwift.a"]) }
    }

    /// Ruling R10: another Swift than the image's own builds with its own SwiftPM, in its own scratch directory; the
    /// per-target archives SwiftPM 6.2 leaves are merged into the library.
    @Test func buildWithTheAppSwiftToolchainUsesItsSwiftPMAndMergesTargetArchives() throws {
        let bundle = tmp(), agg = tmp()
        try write("{}", to: bundle.appendingPathComponent("toolset-swb.json"))
        let swift = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
        let products = agg.appendingPathComponent(".build-swift-6.2.3/arm64-apple-ios/Products/Release-iphoneos")
        var calls: [(String, [String])] = []
        let lib = try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: ["PATH": "/x:/usr/bin"], swift: swift) { exe, args, env in
            calls.append((exe, args))
            if exe.hasSuffix("/swift") {
                #expect(env["PATH"] == "\(bundle.appendingPathComponent("toolset/bin").path):/x:/opt/xless/toolchains/swift-6.2.3/usr/bin:/usr/bin")
                for t in ["XlessTauriSwift", "Tauri", "SwiftRs"] { try write("!<arch>\n", to: products.appendingPathComponent("\(t).o")) }
                try write("not an archive", to: products.appendingPathComponent("stray.o"))
            }
        }
        func real(_ u: URL) -> String { u.path.replacingOccurrences(of: "/private/var/", with: "/var/") }
        #expect(real(lib) == real(products.appendingPathComponent("libXlessTauriSwift.a")))
        #expect(calls.count == 2)
        #expect(calls[0].0 == "/opt/xless/toolchains/swift-6.2.3/usr/bin/swift")
        #expect(calls[0].1.suffix(4) == ["--scratch-path", agg.appendingPathComponent(".build-swift-6.2.3").path, "--product", "XlessTauriSwift"])
        #expect(calls[1].0 == "llvm-libtool-darwin")
        #expect(calls[1].1.map { $0.hasPrefix("/") ? real(URL(fileURLWithPath: $0)) : $0 }
            == ["-static", "-o", real(products.appendingPathComponent("libXlessTauriSwift.a"))]
            + ["SwiftRs.o", "Tauri.o", "XlessTauriSwift.o"].map { real(products.appendingPathComponent($0)) })
    }

    /// Every 6.3.x names the target (6.3.0 for Xcode 26.4, 6.3.1 for Xcode 26.4.1); 6.2 and 6.4 name the product.
    @Test func libtoolWorkaroundCoversEverySwift63Release() {
        func links(_ v: String) -> Bool { SwiftPackages.linksLibraryProductWithLibtool(SwiftToolchain(version: v, root: "/opt/xless/toolchains/swift-\(v)")) }
        #expect(links("6.3.0") && links("6.3.1"))
        #expect(!links("6.2.4") && !links("6.4.0") && !links("6.4.2"))
    }

    /// SwiftPM 6.3's Swift Build links a library product with `libtool` (its toolset support has no librarian yet), which
    /// the SDK does not have; the targets build the same prelinked archives without it, so that build names the target.
    @Test func buildWithSwift63NamesTheTargetNotTheProductAndMergesTargetArchives() throws {
        let bundle = tmp(), agg = tmp()
        try write("{}", to: bundle.appendingPathComponent("toolset-swb.json"))
        let swift = SwiftToolchain(version: "6.3.0", root: "/opt/xless/toolchains/swift-6.3.0")
        let products = agg.appendingPathComponent(".build-swift-6.3.0/out/Products/Release-iphoneos")
        var calls: [(String, [String])] = []
        let lib = try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: [:], swift: swift) { exe, args, _ in
            calls.append((exe, args))
            if exe.hasSuffix("/swift") { for t in ["XlessTauriSwift", "Tauri"] { try write("!<arch>\n", to: products.appendingPathComponent("\(t).o")) } }
        }
        func real(_ u: URL) -> String { u.path.replacingOccurrences(of: "/private/var/", with: "/var/") }
        #expect(real(lib) == real(products.appendingPathComponent("libXlessTauriSwift.a")))
        #expect(calls[0].0 == "/opt/xless/toolchains/swift-6.3.0/usr/bin/swift")
        #expect(calls[0].1.suffix(4) == ["--scratch-path", agg.appendingPathComponent(".build-swift-6.3.0").path, "--target", "XlessTauriSwift"])
        #expect(!calls[0].1.contains("--product"))
        #expect(calls[1].0 == "llvm-libtool-darwin")
        // The other releases keep naming the product.
        for v in ["6.2.3", "6.4.2"] {
            var args: [String] = []
            _ = try? SwiftPackages.build(aggregateDir: tmp(), minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: [:],
                                         swift: SwiftToolchain(version: v, root: "/opt/xless/toolchains/swift-\(v)")) { exe, a, _ in if exe.hasSuffix("/swift") { args = a } }
            #expect(args.suffix(2) == ["--product", "XlessTauriSwift"], "\(v)")
        }
    }

    @Test func theArchiveMergeTakesOnlyThisBuildsArchives() throws {
        // A plugin removed since the last build leaves its archive in the products directory, which outlives builds.
        let bundle = tmp(), agg = tmp()
        try write("{}", to: bundle.appendingPathComponent("toolset-swb.json"))
        let swift = SwiftToolchain(version: "6.2.3", root: "/opt/xless/toolchains/swift-6.2.3")
        let products = agg.appendingPathComponent(".build-swift-6.2.3/arm64-apple-ios/Products/Release-iphoneos")
        for t in ["XlessTauriSwift", "Tauri", "RemovedPlugin"] { try write("!<arch>\n", to: products.appendingPathComponent("\(t).o")) }
        try write("!<arch>\n", to: products.appendingPathComponent("libXlessTauriSwift.a"))
        var merged: [String] = []
        _ = try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0", sdk: DarwinSDK(bundle: bundle), env: [:], swift: swift) { exe, args, _ in
            if exe.hasSuffix("/swift") {
                #expect(!FileManager.default.fileExists(atPath: products.path))
                for t in ["XlessTauriSwift", "Tauri"] { try write("!<arch>\n", to: products.appendingPathComponent("\(t).o")) }
            } else {
                merged = args.dropFirst(3).map { URL(fileURLWithPath: $0).lastPathComponent }
            }
        }
        #expect(merged == ["Tauri.o", "XlessTauriSwift.o"])
    }

    @Test func buildWithoutTheSDKIsABuildError() {
        #expect(throws: XlessError.self) {
            try SwiftPackages.build(aggregateDir: tmp(), minimumIOS: "16.0", sdk: DarwinSDK(bundle: tmp()), env: [:]) { _, _, _ in }
        }
    }

    // MARK: symbols

    @Test func localRequiredSymbolIsReportedMissing() throws {
        let dir = tmp()
        let nm = try script("echo '0000 T _init_plugin_a'; echo '0000 t _init_plugin_b'", in: dir)
        do {
            try SwiftPackages.checkGlobalSymbols(archive: dir.appendingPathComponent("x.a"), required: ["_init_plugin_a", "_init_plugin_b"], nm: nm.path)
            Issue.record("expected throw")
        } catch let e as XlessError {
            #expect(e.stage == .build)
            #expect(e.cause == "Swift symbol _init_plugin_b is not exported from the aggregate library")
            #expect(!e.fix.isEmpty)
        }
    }

    @Test func globalSymbolsPassIncludingPrivateExternalOnes() throws {
        let dir = tmp()
        // llvm-nm -g lists private external (N_PEXT) symbols as T too; they resolve in a static link.
        let nm = try script("""
            [ "$1 $2" = "-g --defined-only" ] || exit 9
            printf '\\n%s:\\n' "lib.a(Tauri.o)"
            echo '0000000000001000 T _init_plugin_a'
            echo '0000000000002000 S _retain_object'
            echo '0000000000003000 D _log_stdout'
            """, in: dir)
        try SwiftPackages.checkGlobalSymbols(archive: dir.appendingPathComponent("x.a"), required: ["_init_plugin_a", "_retain_object", "_log_stdout"], nm: nm.path)
    }

    @Test func requiredSymbolsAreTheSwiftFFIImportsOfTheCrateLibrary() throws {
        let dir = tmp()
        try write("!<arch>\n", to: dir.appendingPathComponent("libhello_tauri_lib.a"))
        let nm = try script("""
            [ "$1" = "-u" ] || exit 9
            printf '\\n%s:\\n' "x.o"
            echo '                 U _init_plugin_hello'
            echo '                 U _retain_object'
            echo '                 U _objc_msgSend'
            echo '                 U _log_stdout'
            printf '\\n%s:\\n' "y.o"
            echo '                 U _init_plugin_dialog'
            echo '                 U _retain_object'
            echo '                 U _string_from_bytes_extra'
            """, in: dir)
        let required = try SwiftPackages.requiredSymbols(cargoTargetDir: dir, crateLib: "hello_tauri_lib", nm: nm.path)
        #expect(required == ["_init_plugin_dialog", "_init_plugin_hello", "_log_stdout", "_retain_object"])
    }

    @Test func symbolPatternsMatchTheNineSpikeSymbols() {
        let spike = ["_init_plugin_dialog", "_init_plugin_hello", "_log_stdout", "_register_plugin", "_run_plugin_command",
                     "_on_webview_created", "_retain_object", "_release_object", "_string_from_bytes"]
        for s in spike { #expect(SwiftPackages.isSwiftFFI(s), "\(s)") }
        for s in ["_init_plugin_", "_log_stdout2", "init_plugin_x", "_objc_msgSend"] { #expect(!SwiftPackages.isSwiftFFI(s), "\(s)") }
    }

    @Test func swiftSectionsInTheCrateLibraryAreRefused() throws {
        let dir = tmp()
        let swift = try script("echo 'Sections:'; echo '  4 __swift5_typeref 0000 0000 DATA'", in: dir, name: "objdump-swift")
        let clean = try script("echo 'Sections:'; echo '  0 __text 0000 0000 TEXT'", in: dir, name: "objdump-clean")
        let lib = dir.appendingPathComponent("libapp.a")
        #expect(throws: XlessError.self) { try SwiftPackages.checkNoSwiftObjects(staticLib: lib, objdump: swift.path) }
        try SwiftPackages.checkNoSwiftObjects(staticLib: lib, objdump: clean.path)
    }

    // MARK: llvm tools

    @Test func llvmToolsComeFromRustupsSysrootWhenPresent() throws {
        let bin = tmp(), sysroot = tmp()
        _ = try script("""
            case "$*" in
              "--print sysroot") echo '\(sysroot.path)' ;;
              "-vV") printf 'rustc 1.97.0\\nhost: aarch64-unknown-linux-gnu\\nrelease: 1.97.0\\n' ;;
              *) exit 9 ;;
            esac
            """, in: bin, name: "rustc")
        let env: [String: String?] = ["PATH": "\(bin.path):/usr/bin:/bin"]
        #expect(SwiftPackages.llvmTool("llvm-nm", env: env) == "llvm-nm")
        let nm = sysroot.appendingPathComponent("lib/rustlib/aarch64-unknown-linux-gnu/bin/llvm-nm")
        try write("", to: nm, mode: 0o755)
        #expect(SwiftPackages.llvmTool("llvm-nm", env: env) == nm.path)
        #expect(SwiftPackages.llvmTool("llvm-objdump", env: env) == "llvm-objdump")
        #expect(SwiftPackages.llvmTool("llvm-nm", env: ["PATH": "/nonexistent"]) == "llvm-nm")
    }
}


// MARK: - Integration (needs the Darwin SDK, rustup's llvm-tools, network for SwiftRs, and a real Tauri build)

/// Runs only when XLESS_TAURI_IT_METADATA (a `cargo metadata --format-version 1 --filter-platform aarch64-apple-ios`
/// JSON of a Tauri app whose crates are on disk) and XLESS_TAURI_IT_CRATE_LIB (the cargo-built `lib<crate>.a`) are set,
/// e.g. in xless-tauri:<tag> against the spike A work copy.
@Test(.enabled(if: ProcessInfo.processInfo.environment["XLESS_TAURI_IT_METADATA"] != nil))
func aggregateBuildsAndExportsEverySymbolTheCrateImports() throws {
    let env = ProcessInfo.processInfo.environment
    let metadata = URL(fileURLWithPath: env["XLESS_TAURI_IT_METADATA"]!)
    let crateLib = URL(fileURLWithPath: env["XLESS_TAURI_IT_CRATE_LIB"]!)
    let out = tmp()
    let found = try SwiftPackages.discover(metadata: Data(contentsOf: metadata))
    let staged = try SwiftPackages.stage(tauriAPI: found.tauriAPI, plugins: found.plugins, into: out)
    let agg = try SwiftPackages.writeAggregate(minimumIOS: "16.0", plugins: staged, into: out)
    let lib = try SwiftPackages.build(aggregateDir: agg, minimumIOS: "16.0")
    // rustup picks the app's toolchain (rust-toolchain.toml) by walking up from the cargo output dir.
    let cwd = crateLib.deletingLastPathComponent()
    let nm = SwiftPackages.llvmTool("llvm-nm", cwd: cwd), objdump = SwiftPackages.llvmTool("llvm-objdump", cwd: cwd)
    let name = String(crateLib.deletingPathExtension().lastPathComponent.dropFirst(3))
    try SwiftPackages.checkNoSwiftObjects(staticLib: crateLib, objdump: objdump)
    let required = try SwiftPackages.requiredSymbols(cargoTargetDir: crateLib.deletingLastPathComponent(), crateLib: name, nm: nm)
    #expect(required.contains { $0.hasPrefix("_init_plugin_") })
    try SwiftPackages.checkGlobalSymbols(archive: lib, required: required, nm: nm)
    #expect(throws: XlessError.self) { try SwiftPackages.checkNoSwiftObjects(staticLib: lib, objdump: objdump) }  // the aggregate is Swift
    print("aggregate: \(lib.path); plugins: \(staged.map(\.product)); required: \(required); nm: \(nm); objdump: \(objdump)")
}
