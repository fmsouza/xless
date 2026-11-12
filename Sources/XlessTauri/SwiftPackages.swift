import Foundation
import XlessCore

/// One Tauri plugin's Swift package (`<crate>/ios`).
public struct SwiftPackage: Equatable, Sendable {
    /// The crate name; also the package's directory name once staged (SwiftPM's identity of a path package).
    public var name: String
    /// The package's single library product; `""` until `stage` reads it from `swift package dump-package`.
    public var product: String
    public var sourceDir: URL
    /// The manifest references tauri-plugin's `../.tauri/tauri-api` copy of tauri's `mobile/ios-api`.
    public var needsTauriAPI: Bool

    public init(name: String, product: String, sourceDir: URL, needsTauriAPI: Bool) {
        self.name = name
        self.product = product
        self.sourceDir = sourceDir
        self.needsTauriAPI = needsTauriAPI
    }
}

/// Builds every Swift package of a Tauri app (tauri's `ios-api` plus each plugin's `ios/`) as one static library,
/// `libXlessTauriSwift.a`, which the executable links next to cargo's staticlib (spec §11). On a Mac, swift-rs builds
/// each package inside cargo, so `libapp.a` carries one copy of `Tauri`/`SwiftRs` per package; on Linux tauri skips
/// Swift and xless builds the aggregate instead. Layout, invocation and symbol rules: docs/research/tauri-ios-contract.md,
/// "Linux build — spike A findings" (scripts/spikes/hellotauri-linux.sh, step `swift`).
public enum SwiftPackages {
    public static let aggregateName = "XlessTauriSwift"

    /// SwiftRs, which tauri's `ios-api` requires `from: "1.0.0"`. The crates ship no `Package.resolved`, so without a pin
    /// the aggregate would resolve whatever tag is newest. xless writes `Aggregate/Package.resolved` pinning 1.0.9 (the
    /// release whose `retain_object`/`release_object`/`string_from_bytes` are `public`, which the Mac reference
    /// effectively used) and builds with `--force-resolved-versions`, so the pin is what decides (contract doc, "SwiftRs").
    public static let swiftRs = (url: "https://github.com/Brendonovich/swift-rs", version: "1.0.9",
                                 revision: "207e4bfe5d36fdd0cc08f28d1849ff94ac7e24b8")

    /// The Swift FFI a Tauri crate imports: one `init_plugin_<name>` per plugin, tauri's `ios.rs` (`log_stdout`,
    /// `register_plugin`, `run_plugin_command`, `on_webview_created`) and swift-rs's SRObject/SRString helpers
    /// (contract doc, spike A step 6).
    public static let symbolPatterns = [
        "^_init_plugin_[A-Za-z0-9_]+$",
        "^_log_stdout$", "^_register_plugin$", "^_run_plugin_command$", "^_on_webview_created$",
        "^_retain_object$", "^_release_object$", "^_string_from_bytes$",
    ]

    static func isSwiftFFI(_ symbol: String) -> Bool {
        symbolPatterns.contains { symbol.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: discovery

    private struct Metadata: Decodable {
        struct Package: Decodable {
            struct Dependency: Decodable { var name: String; var kind: String? }
            var name: String
            var manifest_path: String
            var dependencies: [Dependency]
        }
        var packages: [Package]
    }

    /// From `cargo metadata --format-version 1 --filter-platform aarch64-apple-ios`: tauri's `mobile/ios-api`, and every
    /// package with a `tauri-plugin` build-dependency and an `ios/Package.swift`, sorted by name.
    public static func discover(metadata: Data) throws -> (tauriAPI: URL, plugins: [SwiftPackage]) {
        let fm = FileManager.default
        let packages: [Metadata.Package]
        do { packages = try JSONDecoder().decode(Metadata.self, from: metadata).packages } catch {
            throw XlessError(.build, "cannot read cargo metadata: \(error)", fix: "run `cargo metadata --format-version 1` in the Tauri directory to see what fails")
        }
        let tauri = packages.filter { $0.name == "tauri" }
        guard let api = tauri.first else {
            throw XlessError(.build, "tauri crate not found in cargo metadata", fix: "check that the app's Cargo.toml depends on tauri 2 for the iOS target")
        }
        guard tauri.count == 1 else {
            throw XlessError(.build, "cargo metadata lists \(tauri.count) tauri crates", fix: "make the dependency graph use a single tauri version (`cargo tree -i tauri`)")
        }
        let tauriAPI = URL(fileURLWithPath: api.manifest_path).deletingLastPathComponent().appendingPathComponent("mobile/ios-api")

        var plugins: [SwiftPackage] = []
        for p in packages where p.dependencies.contains(where: { $0.name == "tauri-plugin" && $0.kind == "build" }) {
            let ios = URL(fileURLWithPath: p.manifest_path).deletingLastPathComponent().appendingPathComponent("ios")
            let manifest = ios.appendingPathComponent("Package.swift")
            guard fm.fileExists(atPath: manifest.path) else { continue }  // e.g. tauri-plugin-fs: no iOS code
            let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
            plugins.append(SwiftPackage(name: p.name, product: "", sourceDir: ios, needsTauriAPI: text.contains(".tauri/tauri-api")))
        }
        return (tauriAPI, plugins.sorted { $0.name < $1.name })
    }

    // MARK: staging

    /// Copies the packages into `dir` (normally `<work>/.xless/swift`) so that nothing is built inside the sources (the
    /// cargo registry stays untouched; review focus 3). Layout, from spike A ("Swift package identity"):
    ///
    ///     dir/plugins/.tauri/tauri-api/   ← tauriAPI, ONE copy
    ///     dir/plugins/<crate name>/       ← each plugin's ios/
    ///
    /// SwiftPM names a path package after its directory, so N `ios/` copies would collide, and per-plugin
    /// `.tauri/tauri-api` copies collide with each other and with the aggregate's. As siblings, every plugin's
    /// `path: "../.tauri/tauri-api"` (tauri-plugin's convention) and the aggregate's dependency are the same directory.
    /// `.build`, `Package.resolved` and `Tests` at each package root are skipped. `dir/plugins` is recreated on every call.
    /// Returns the plugins with `sourceDir` set to the staged copy and `product` read by `product` (default:
    /// `swift package dump-package`).
    public static func stage(tauriAPI: URL, plugins: [SwiftPackage], into dir: URL,
                             product: (URL) throws -> String = SwiftPackages.libraryProduct(packageDir:)) throws -> [SwiftPackage] {
        let fm = FileManager.default
        var names = Set<String>()
        for p in plugins where !names.insert(p.name).inserted {
            throw XlessError(.build, "two Swift packages for crate \(p.name)", fix: "make the dependency graph use a single version of \(p.name) (`cargo tree -i \(p.name)`)")
        }
        let pluginsDir = dir.appendingPathComponent("plugins", isDirectory: true)
        if (try? fm.attributesOfItem(atPath: pluginsDir.path)) != nil { try fm.removeItem(at: pluginsDir) }
        let skip: Set<String> = [".build", "Package.resolved", "Tests"]
        try copyTree(tauriAPI, to: pluginsDir.appendingPathComponent(".tauri/tauri-api", isDirectory: true), skipping: skip)
        return try plugins.map { p in
            let dest = pluginsDir.appendingPathComponent(p.name, isDirectory: true)
            try copyTree(p.sourceDir, to: dest, skipping: skip)
            return SwiftPackage(name: p.name, product: try product(dest), sourceDir: dest, needsTauriAPI: p.needsTauriAPI)
        }
    }

    /// Copies directories as new (writable) directories, files with their permissions, symlinks as symlinks.
    private static func copyTree(_ src: URL, to dst: URL, skipping: Set<String> = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) where !skipping.contains(name) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            switch try fm.attributesOfItem(atPath: s.path)[.type] as? FileAttributeType {
            case .typeDirectory?: try copyTree(s, to: d)
            case .typeSymbolicLink?: try fm.createSymbolicLink(atPath: d.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: s.path))
            default: try fm.copyItem(at: s, to: d)
            }
        }
    }

    /// The single library product of the package in `packageDir`, from `swift package dump-package`, after checking
    /// that it has no remote dependency xless cannot pin (`checkDependencies`).
    public static func libraryProduct(packageDir: URL) throws -> String {
        let out = try Shell.run("swift", ["package", "dump-package", "--package-path", packageDir.path], stage: .build).stdout
        try checkDependencies(dumpPackage: Data(out.utf8), package: packageDir.lastPathComponent)
        return try libraryProduct(dumpPackage: Data(out.utf8), package: packageDir.lastPathComponent)
    }

    /// The aggregate is built with `--force-resolved-versions` and a `Package.resolved` that pins SwiftRs only, so a
    /// plugin's other remote (source control or registry) dependency would fail resolution with an unhelpful message.
    /// Local path dependencies (the shared `../.tauri/tauri-api`) and SwiftRs itself are fine.
    static func checkDependencies(dumpPackage: Data, package: String) throws {
        guard let json = try? JSONSerialization.jsonObject(with: dumpPackage) as? [String: Any],
              let deps = json["dependencies"] as? [[String: Any]] else { return }
        func normalized(_ url: String) -> String {
            var u = url.lowercased()
            while u.hasSuffix("/") { u.removeLast() }
            if u.hasSuffix(".git") { u.removeLast(4) }
            return u
        }
        for dep in deps {
            var remote: [String] = []
            for sc in (dep["sourceControl"] as? [[String: Any]]) ?? [] {
                let location = sc["location"] as? [String: Any]
                // dump-package writes `remote: [{urlString: …}]` (older toolchains: `remote: ["…"]`), or `local: [path]` for a local git repository.
                let urls = ((location?["remote"] as? [Any]) ?? (location?["local"] as? [Any]) ?? []).compactMap {
                    (($0 as? [String: Any])?["urlString"] as? String) ?? ($0 as? String)
                }
                remote += urls.isEmpty ? [(sc["identity"] as? String) ?? "(unnamed)"] : urls
            }
            remote += ((dep["registry"] as? [[String: Any]]) ?? []).map { ($0["identity"] as? String) ?? "(unnamed)" }
            if let url = remote.first(where: { normalized($0) != normalized(swiftRs.url) }) {
                throw XlessError(.build, "plugin \(package) depends on remote Swift package \(url), which xless does not pin", fix: "report it")
            }
        }
    }

    static func libraryProduct(dumpPackage: Data, package: String) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: dumpPackage) as? [String: Any]
        guard let products = json?["products"] as? [[String: Any]] else {
            throw XlessError(.build, "\(package): cannot read `swift package dump-package` output", fix: "run `swift package dump-package` in its ios/ directory to see what fails")
        }
        let libraries = products.filter { ($0["type"] as? [String: Any])?["library"] != nil }.compactMap { $0["name"] as? String }
        guard libraries.count == 1 else {
            throw XlessError(.build, "\(package): ios/Package.swift declares \(libraries.count) library products\(libraries.isEmpty ? "" : " (\(libraries.joined(separator: ", ")))")",
                             fix: "a Tauri plugin's Swift package must declare exactly one library product")
        }
        return libraries[0]
    }

    // MARK: aggregate

    /// The aggregate package's manifest. `packages` are its dependencies in order (tauri's API first); each contributes
    /// `.package(name: name, path: path)` and `.product(name: product, package: name)`. A static library product carries
    /// its dependencies' objects, so the target itself is empty (spike A step 5).
    public static func aggregateManifest(minimumIOS: String, packages: [(name: String, path: String, product: String)]) -> String {
        let deps = packages.map { "    .package(name: \"\($0.name)\", path: \"\($0.path)\"),\n" }.joined()
        let products = packages.map { "      .product(name: \"\($0.product)\", package: \"\($0.name)\"),\n" }.joined()
        return """
            // swift-tools-version:5.9
            // Generated by xless: links every Tauri Swift package of this app into one static library.
            import PackageDescription

            let package = Package(
              name: "\(aggregateName)",
              platforms: [.iOS("\(minimumIOS)")],
              products: [.library(name: "\(aggregateName)", type: .static, targets: ["\(aggregateName)"])],
              dependencies: [
            \(deps)  ],
              targets: [
                .target(name: "\(aggregateName)", dependencies: [
            \(products)    ], path: "Sources"),
              ]
            )

            """
    }

    /// Writes `dir/Aggregate` (`Package.swift`, the SwiftRs `Package.resolved` pin and the empty source file) next to the
    /// `dir/plugins` tree `stage` produced, and returns it. A package is referenced by its product name (as in spike A).
    /// An existing `Aggregate/.build` is kept for incremental builds.
    public static func writeAggregate(minimumIOS: String, plugins: [SwiftPackage], into dir: URL) throws -> URL {
        let fm = FileManager.default
        var products: Set<String> = ["Tauri", aggregateName]
        for p in plugins where !products.insert(p.product).inserted {
            throw XlessError(.build, "two Swift packages declare the library product \(p.product)", fix: "remove one of the plugins that declare \(p.product)")
        }
        let agg = dir.appendingPathComponent("Aggregate", isDirectory: true)
        let sources = agg.appendingPathComponent("Sources/\(aggregateName)", isDirectory: true)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let packages = [(name: "Tauri", path: "../plugins/.tauri/tauri-api", product: "Tauri")]
            + plugins.map { (name: $0.product, path: "../plugins/\($0.name)", product: $0.product) }
        try aggregateManifest(minimumIOS: minimumIOS, packages: packages)
            .write(to: agg.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "// Intentionally empty: the product carries its dependencies.\n"
            .write(to: sources.appendingPathComponent("\(aggregateName).swift"), atomically: true, encoding: .utf8)
        try """
            {
              "pins" : [
                {
                  "identity" : "swift-rs",
                  "kind" : "remoteSourceControl",
                  "location" : "\(swiftRs.url)",
                  "state" : {
                    "revision" : "\(swiftRs.revision)",
                    "version" : "\(swiftRs.version)"
                  }
                }
              ],
              "version" : 2
            }

            """.write(to: agg.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        return agg
    }

    // MARK: build

    public typealias Runner = (_ executable: String, _ arguments: [String], _ env: [String: String?]) throws -> Void

    /// `swift build` of the aggregate for `arm64-apple-ios<minimumIOS>`, the invocation MacBuilder uses: Swift Build,
    /// the SDK bundle's swb toolset, its platforms through XCODE_EXTRA_PLATFORM_FOLDERS (else "unable to find platform
    /// for 'iphoneos'"), no SDKROOT. The versioned triple gives every module, dependencies included, minos
    /// `minimumIOS`, as swift-rs's `--triple` does on the Mac (contract doc, "Deployment target of the Swift objects").
    /// Returns `.build/out/Products/Release-iphoneos/libXlessTauriSwift.a`, or the only `libXlessTauriSwift.a` under `.build`.
    /// `swift`: the image's app Swift toolchain (Ruling R10). Another release than the image's own builds with its own
    /// SwiftPM and Swift Build (as Xcode builds packages with the SwiftPM it ships), in its own scratch directory
    /// (`.build-swift-<version>`, never a previous toolchain's products), naming the product (SwiftPM 6.2's Swift Build
    /// builds only targets otherwise). Where that SwiftPM leaves no static library but each target prelinked into
    /// `<target>.o` (the SDK linker's `-r` writes an `ar` archive), the archives in its products directory are merged into
    /// `lib<aggregate>.a` with `llvm-libtool-darwin -static`; that directory is deleted before the build, so only this
    /// build's archives are merged.
    public static func build(aggregateDir: URL, minimumIOS: String, sdk: DarwinSDK = DarwinSDK(),
                             env: [String: String] = ProcessInfo.processInfo.environment, swift: SwiftToolchain? = nil,
                             run: Runner = { try Shell.run($0, $1, env: $2, stage: .build, passthrough: true) }) throws -> URL {
        let toolset = sdk.bundle.appendingPathComponent("toolset-swb.json")
        guard FileManager.default.fileExists(atPath: toolset.path) else {
            throw XlessError(.build, "Darwin SDK not installed at \(sdk.bundle.path)", fix: "use the xless SDK image or run `xless sdk install`")
        }
        let own = swift.flatMap { $0.isEngine ? nil : $0 }
        let buildDir = aggregateDir.appendingPathComponent(own.map { ".build-swift-\($0.version)" } ?? ".build", isDirectory: true)
        // The merge below takes every archive in the products directory, which outlives a build: a plugin removed since
        // the last one would leave its archive there. So that directory starts empty (Swift Build writes it again).
        if own != nil, let previous = prelinkedAggregate(under: buildDir) {
            try FileManager.default.removeItem(at: previous.deletingLastPathComponent())
        }
        var args = ["build", "-c", "release", "--package-path", aggregateDir.path, "--build-system", "swiftbuild",
                    "--triple", "arm64-apple-ios\(minimumIOS)", "--toolset", toolset.path, "--force-resolved-versions"]
        if let own { args += ["--scratch-path", buildDir.path, linksLibraryProductWithLibtool(own) ? "--target" : "--product", aggregateName] }
        try run(swift?.tool("swift") ?? "swift", args, [
            "SDKROOT": nil,
            "XCODE_EXTRA_PLATFORM_FOLDERS": sdk.bundle.appendingPathComponent("Developer/Platforms").path,
            "PATH": "\(sdk.bundle.appendingPathComponent("toolset/bin").path):\(swift?.path(env["PATH"]) ?? env["PATH"] ?? "/usr/bin:/bin")",
        ])
        let name = "lib\(aggregateName).a"
        let expected = buildDir.appendingPathComponent("out/Products/Release-iphoneos/\(name)")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        let found = Files.regularFiles(under: buildDir).filter { $0.lastPathComponent == name }
        if found.isEmpty, own != nil, let prelinked = prelinkedAggregate(under: buildDir) {
            let products = prelinked.deletingLastPathComponent()
            let archives = ((try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "o" && isArchive($0) }.map(\.path).sorted()
            let lib = products.appendingPathComponent(name)
            try run("llvm-libtool-darwin", ["-static", "-o", lib.path] + archives, [:])
            return lib
        }
        guard found.count == 1 else {
            throw XlessError(.build, "swift build left \(found.count) \(name) under \(buildDir.path)\(found.isEmpty ? "" : ": \(found.map(\.path).joined(separator: ", "))")",
                             fix: "check the swift build output above; remove \(buildDir.path) and build again")
        }
        return found[0]
    }

    /// SwiftPM 6.3's Swift Build links a library product with `libtool -static` and asks it for its version (`libtool -V`),
    /// which the SDK does not have (measured with Swift 6.3.0: it runs `<package dir>/libtool -V` whatever the toolset's
    /// `librarian` says; 6.2 and 6.4 do not). Naming the target builds the same prelinked per-target archives without that
    /// step, and they are merged below.
    static func linksLibraryProductWithLibtool(_ swift: SwiftToolchain) -> Bool {
        let parts = swift.version.split(separator: ".")
        return parts.count >= 2 && parts[0] == "6" && parts[1] == "3"
    }

    /// The aggregate prelinked into `<aggregate>.o` in a `Release-iphoneos` products directory under `buildDir`.
    static func prelinkedAggregate(under buildDir: URL) -> URL? {
        Files.regularFiles(under: buildDir).first {
            $0.lastPathComponent == "\(aggregateName).o" && $0.deletingLastPathComponent().lastPathComponent == "Release-iphoneos"
        }
    }

    static func isArchive(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 8)) == Data("!<arch>\n".utf8)
    }

    // MARK: checks

    /// `llvm-<tool>` from rustup's `llvm-tools` component (`$(rustc --print sysroot)/lib/rustlib/<host>/bin/<name>`),
    /// else `name` from PATH. The image's LLVM 14 `llvm-nm` cannot read the LLVM 22 bitcode in a Rust 1.97 staticlib
    /// (contract doc, "SwiftRs"). `cwd` selects the toolchain (`rust-toolchain.toml`).
    public static func llvmTool(_ name: String, cwd: URL? = nil, env: [String: String?] = [:]) -> String {
        guard let sysroot = try? Shell.run("rustc", ["--print", "sysroot"], cwd: cwd, env: env, stage: .build).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let info = try? Shell.run("rustc", ["-vV"], cwd: cwd, env: env, stage: .build).stdout,
              let host = info.split(separator: "\n").first(where: { $0.hasPrefix("host: ") })?.dropFirst(6)
        else { return name }
        let path = "\(sysroot)/lib/rustlib/\(host)/bin/\(name)"
        return FileManager.default.isExecutableFile(atPath: path) ? path : name
    }

    /// Swift FFI symbols that `<cargoTargetDir>/lib<crateLib>.a` (cargo's `target/aarch64-apple-ios/release`) leaves undefined.
    public static func requiredSymbols(cargoTargetDir: URL, crateLib: String, nm: String) throws -> [String] {
        let lib = cargoTargetDir.appendingPathComponent("lib\(crateLib).a")
        guard FileManager.default.fileExists(atPath: lib.path) else {
            throw XlessError(.build, "lib\(crateLib).a not found in \(cargoTargetDir.path)", fix: "check the cargo output above")
        }
        let out = try Shell.run(nm, ["-u", lib.path], stage: .build).stdout
        let symbols = out.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) }
        return Set(symbols.filter(isSwiftFFI)).sorted()
    }

    /// Every `required` symbol must be defined and global (`T`/`S`/`D` in `llvm-nm -g --defined-only`). Non-public
    /// `@_cdecl` functions come out `private external` (N_EXT|N_PEXT); `nm -g` lists them too, and they resolve in the
    /// static link of the executable. Only a missing or local symbol fails (contract doc, "SwiftRs").
    public static func checkGlobalSymbols(archive: URL, required: [String], nm: String) throws {
        let out = try Shell.run(nm, ["-g", "--defined-only", archive.path], stage: .build).stdout
        var defined = Set<String>()
        for line in out.split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count >= 3, ["T", "S", "D"].contains(f[f.count - 2]) { defined.insert(String(f[f.count - 1])) }
        }
        let missing = required.filter { !defined.contains($0) }
        guard missing.isEmpty else {
            throw XlessError(.build, missing.count == 1
                                ? "Swift symbol \(missing[0]) is not exported from the aggregate library"
                                : "Swift symbols \(missing.joined(separator: ", ")) are not exported from the aggregate library",
                             fix: "the plugin's ios/ package must define it with @_cdecl, not private or fileprivate (a local symbol does not link); `llvm-nm -m \(archive.path)` shows what was built")
        }
    }

    /// Refuses a crate staticlib holding Swift objects (a `__swift5_*` section): it was built by tauri's swift-rs on a
    /// Mac, and its Swift would be linked twice next to the aggregate.
    public static func checkNoSwiftObjects(staticLib: URL, objdump: String) throws {
        let out = try Shell.run(objdump, ["--section-headers", staticLib.path], stage: .build).stdout
        if out.contains("__swift5_") {
            throw XlessError(.build, "\(staticLib.lastPathComponent) contains Swift objects (__swift5_ sections): it was built on macOS",
                             fix: "remove the cargo target directory of the work copy and build again")
        }
    }
}
