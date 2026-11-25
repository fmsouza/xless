import Foundation
import XlessCore
import XlessMachO

/// Builds a Swift package's app on a Mac with the installed Xcode: the same generated wrapper package as on Linux (an executable
/// target that links the app's library product), built by that Xcode's `swift build` for its own SDK. No Xcode project is made and
/// no `xcodebuild` runs.
///
/// SwiftPM's sandbox stays on: manifests, plugins and macros have no network there and write nothing outside their own directories.
/// (xless puts no other around it: nested ones fail, and SwiftPM's own would have to go.) `--disable-keychain`: SwiftPM asks the
/// user's keychain for no password.
public enum XcodePackageBuilder {
    public enum Destination: Sendable, Equatable {
        case device, simulator, mac

        var platform: Platform { self == .mac ? .macos : .ios }
    }

    static func wrapperPackage(product: String, minimumOS: String, platform: Platform) -> String {
        let (os, frameworks) = platform == .ios ? ("iOS", "@executable_path/Frameworks") : ("macOS", "@executable_path/../Frameworks")
        return """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(product)-XcodeBuilder",
            platforms: [.\(os)("\(minimumOS)")],
            dependencies: [.package(name: "RootPackage", path: "../..")],
            targets: [
                .executableTarget(name: "\(product)App",
                    dependencies: [.product(name: "\(product)", package: "RootPackage")],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(frameworks)"])]
                )
            ]
        )

        """
    }

    /// An iPhone's and (a Mac's own) simulator's architecture is arm64; a Mac app is universal, as on Linux.
    static func arguments(_ destination: Destination, wrapper: URL, scratch: URL, product: String, minimumOS: String) -> [String] {
        let target: [String] = switch destination {
        case .device: ["--triple", "arm64-apple-ios\(minimumOS)"]
        case .simulator: ["--triple", "arm64-apple-ios\(minimumOS)-simulator"]
        case .mac: MacBuilder.archs.flatMap { ["--arch", $0] }
        }
        return ["build", "--package-path", wrapper.path, "--scratch-path", scratch.path, "-c", "release", "--build-system", "swiftbuild",
                "--disable-keychain", "--product", "\(product)App"] + target
    }

    /// The products directory of `swift build`.
    static func productsDirectory(_ destination: Destination) -> String {
        switch destination {
        case .device: "Release-iphoneos"
        case .simulator: "Release-iphonesimulator"
        case .mac: "Release"
        }
    }

    public static func build(project: URL, config: ProjectConfig, paths: StagePaths, destination: Destination, xcode: InstalledXcode,
                             env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let platform = destination.platform, pc = try config.platform(platform)
        let name = destination == .mac ? "macos" : destination == .device ? "ios" : "ios-simulator"
        let lock = try BuildLock(project: project, note: MacBuilder.note)
        defer { lock.release() }
        let wrapper = project.appendingPathComponent(".xless/xcode-pkg-\(name)", isDirectory: true)
        try writeWrapper(wrapper, project: project, product: pc.product, minimumOS: pc.minimumOS, platform: platform)
        // Another Xcode builds in a directory of its own, and reuses nothing of this one's.
        let scratch = project.appendingPathComponent(".xless/xcode-build-\(name)-\(xcode.build)", isDirectory: true)
        let products = scratch.appendingPathComponent("out/Products/\(productsDirectory(destination))", isDirectory: true)
        let environment = xcode.environment(env), swift = try xcode.require(.swift, stage: .build)
        try ResourceBundles.fresh(scratch: scratch, products: { [products] }, note: MacBuilder.note) {
            try Shell.run(swift.path, arguments(destination, wrapper: wrapper, scratch: scratch, product: pc.product, minimumOS: pc.minimumOS),
                          cwd: project, env: environment, baseEnvironment: env, stage: .build, passthrough: true)
        }
        if let unpinned = PackageResolved.unpinnedNote(project: project, wrapper: wrapper) { MacBuilder.note(unpinned) }
        guard let executable = MacBuilder.builtExecutable(named: "\(pc.product)App", under: products) else {
            throw XlessError(.build, "no \(pc.product)App executable under \(products.path)",
                             fix: "check the swift build output above, and that platforms.\(platform.rawValue).product matches a library product in Package.swift")
        }
        let images = try embedded(executable, products: products)
        let resources = ResourceBundles.of(products)
        let built = try Files.atomicOutput(paths.app) { partial in
            let app = try PackageApp.assemble(in: partial, executable: try Data(contentsOf: executable), resources: resources, frameworks: images.map(\.item),
                                              project: project, config: config, platform: platform)
            let directory = BundleLayout(platform: platform).executableDir
            if destination == .simulator { // (finalize, which stamps a device's, does not run)
                let plist = app.appendingPathComponent("Info.plist")
                var info = try Plist.read(plist, stage: .build)
                info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
                try Plist.write(info, to: plist, stage: .build)
            }
            try removeRunPaths(of: app.appendingPathComponent(directory.isEmpty ? pc.product : "\(directory)/\(pc.product)"), xcode: xcode, environment: environment, where: isForeign)
            // Those of a vendor's are the vendor's: only what names this Mac's Xcode goes.
            let frameworks = app.appendingPathComponent(BundleLayout(platform: platform).frameworksDir)
            for image in images {
                try removeRunPaths(of: frameworks.appendingPathComponent(image.library), xcode: xcode, environment: environment) { isOfXcode($0, xcode) }
            }
            return app
        }
        let dSYMs = try DSYM.keep(executables: [executable], app: built, into: paths.dSYMs)
        FileHandle.standardError.write(Data("xless: dSYMs: \(dSYMs.summary)\n".utf8))
        for image in images { // a library of the app's own packages, which Swift Build wrote one for
            guard case .kept = dSYMs, let dSYM = dSYM(ofLibrary: image.library, item: image.item, products: products) else { continue }
            try FileManager.default.copyItem(at: dSYM, to: paths.dSYMs.appendingPathComponent(dSYM.lastPathComponent))
            FileHandle.standardError.write(Data("xless: dSYMs: \(dSYM.lastPathComponent)\n".utf8))
        }
        return built
    }

    /// The wrapper package, with the app's own Package.resolved: the root package's is the one that SwiftPM keeps to, and the root is
    /// the wrapper here.
    static func writeWrapper(_ wrapper: URL, project: URL, product: String, minimumOS: String, platform: Platform) throws {
        try? FileManager.default.removeItem(at: wrapper)
        let sources = wrapper.appendingPathComponent("Sources/\(product)App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data().write(to: sources.appendingPathComponent("stub.c"))
        try wrapperPackage(product: product, minimumOS: minimumOS, platform: platform)
            .write(to: wrapper.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try PackageResolved.copy(from: project, to: wrapper)
    }

    /// The frameworks and dynamic libraries of the build that `executable` loads, and those that they load. One that is neither of
    /// the build nor of the system would not be there on the device.
    /// Each is what is put into Frameworks (`item`) and the path there of what is loaded (`library`).
    static func embedded(_ executable: URL, products: URL) throws -> [(item: URL, library: String)] {
        var found: [String: (item: URL, library: String)] = [:], open = [executable]
        while let image = open.popLast() {
            for library in try rpathLibraries(of: image) {
                let parts = library.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard !parts.contains(where: { ["", ".", ".."].contains($0) }) else {
                    throw XlessError(.build, "\(image.lastPathComponent) loads @rpath/\(library), which is no place in the app", fix: "fix the install name of that library, or ask who made it")
                }
                let item = parts[0] // X.framework or libX.dylib
                guard found[item] == nil else { continue }
                let places = [products, products.appendingPathComponent("PackageFrameworks")].map { $0.appendingPathComponent(item) }
                guard let place = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw XlessError(.build, "\(image.lastPathComponent) loads @rpath/\(library), which the build did not make",
                                     fix: item.hasPrefix("libswift") ? "raise minimumOS in xless.yml: the systems before it do not have this part of Swift"
                                         : "make it a product of one of the app's packages (a binaryTarget, or a library)")
                }
                found[item] = (place, library)
                open.append(place.deletingLastPathComponent().appendingPathComponent(library))
            }
        }
        return found.values.sorted { $0.item.path < $1.item.path }
    }

    /// The dSYM that Swift Build wrote for a library that is embedded; nil: none, or one of another build.
    static func dSYM(ofLibrary library: String, item: URL, products: URL) -> URL? {
        let dSYM = DSYM.companion(of: products.appendingPathComponent(item.lastPathComponent)), have = DSYM.uuids(ofDSYM: dSYM)
        let binary = item.deletingLastPathComponent().appendingPathComponent(library)
        return !have.isEmpty && have == Set((try? MachO.uuids(in: Data(contentsOf: binary))) ?? []) ? dSYM : nil
    }

    /// What `image` loads by @rpath, without that.
    static func rpathLibraries(of image: URL) throws -> [String] {
        let data: Data
        do { data = try Data(contentsOf: image) } catch { throw XlessError(.build, "cannot read \(image.path): \(error.localizedDescription)", fix: "check the swift build output above") }
        var out: [String] = []
        do {
            for (_, _, range) in try MachO.sliceArchitectures(in: data) {
                out += try MachO.linkedLibraries(in: data, slice: range).filter { $0.hasPrefix("@rpath/") }.map { String($0.dropFirst("@rpath/".count)) }
            }
        } catch { throw XlessError(.build, "cannot read the libraries of \(image.path): \(error)", fix: "report it to the xless maintainers") }
        return out
    }

    /// Swift Build adds directories of the Xcode to where the app looks for its libraries: they name this Mac's files, and are not on
    /// the device. `install_name_tool` takes them out.
    static func removeRunPaths(of executable: URL, xcode: InstalledXcode, environment: [String: String?], where goes: (String) -> Bool) throws {
        try removeRunPaths(of: executable, where: goes) { paths, image in
            try Shell.run(try xcode.require(.installNameTool, stage: .build).path, paths.flatMap { ["-delete_rpath", $0] } + [image.path], env: environment, stage: .build)
        }
    }

    /// `delete` takes run paths out of an image, and fails where one of its architectures does not have one of them: then each is
    /// done by itself.
    static func removeRunPaths(of executable: URL, where goes: (String) -> Bool, delete: ([String], URL) throws -> Void) throws {
        let executable = executable.resolvingSymlinksInPath() // (a framework's is a link into its Versions, and stays one)
        let data = try Data(contentsOf: executable)
        let slices = try MachO.sliceArchitectures(in: data).map { (range: $0.range, paths: Set(try MachO.rpaths(in: data, slice: $0.range).filter(goes)).sorted()) }
        guard let first = slices.first, slices.contains(where: { !$0.paths.isEmpty }) else { return }
        if slices.allSatisfy({ $0.paths == first.paths }) { return try delete(first.paths, executable) }
        let thin = executable.deletingLastPathComponent().appendingPathComponent(".thin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: thin) }
        let done = try slices.map { slice in
            let bytes = Data(data[slice.range])
            if slice.paths.isEmpty { return bytes }
            try bytes.write(to: thin)
            try delete(slice.paths, thin)
            return try Data(contentsOf: thin)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions]
        try MachO.makeFat(done).write(to: executable, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: executable.path) } // (Foundation on Linux does not keep it)
    }

    static func isForeign(_ path: String) -> Bool { path.hasPrefix("/") && path != "/usr/lib/swift" }

    /// (The cryptex is where macOS has the libraries of its newest Swift.)
    static func isOfXcode(_ path: String, _ xcode: InstalledXcode) -> Bool {
        [xcode.app.path + "/", "/var/run/com.apple.security.cryptexd/"].contains { path.hasPrefix($0) }
    }
}
