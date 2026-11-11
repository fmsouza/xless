import Foundation
import XlessCore
import XlessMachO

public enum IOSBuilder {
    /// Runs `xtool dev build --configuration release` (unsigned), copies the .app into paths.app and keeps its dSYM in
    /// paths.dSYMs (`dSYM(of:project:dsymutil:)`).
    public static func build(project: URL, config: ProjectConfig, paths: StagePaths,
                             env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let ios = try config.platform(.ios)
        try XtoolManifest.write(config: config, project: project)
        try Shell.run("xtool", ["dev", "build", "--configuration", "release"], cwd: project, stage: .build, passthrough: true)
        let produced = project.appendingPathComponent("xtool/\(ios.product).app")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw XlessError(.build, "xtool finished but \(produced.path) is missing", fix: "check that platforms.ios.product matches a library product in Package.swift")
        }
        let app = try Files.atomicOutput(paths.app) { try Files.copyBundle(produced, intoFreshDir: $0) }
        let tool = DarwinSDK(bundle: DarwinSDKLocator.bundle(env: env)).dsymutil
        let source = dSYM(of: app, project: project) { exe, out in
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw XlessError(.build, "the SDK's toolset has no dsymutil (\(tool.path))", fix: "reinstall the SDK")
            }
            try Shell.run(tool.path, [exe.path, "-o", out.path], stage: .build)
        }
        let executable = app.appendingPathComponent(DSYM.executableName(of: app))
        FileHandle.standardError.write(Data("xless: dSYMs: \(try DSYM.keep([(executable: executable, dSYM: source)], app: app, into: paths.dSYMs).summary)\n".utf8))
        return app
    }

    /// The dSYM of the executable of `app`, which xtool built in `project`. From Swift 6.4 xtool builds with Swift Build,
    /// which runs dsymutil itself: its `<target>.dSYM` under `.build/out/Products/<configuration>-iphoneos/` whose UUID is
    /// the executable's (xtool copies the executable unchanged). Otherwise (SwiftPM's native build system, older
    /// Swift) dsymutil runs on the executable (`dsymutil(executable, output)`), into `.xless/dsym/ios/<name>.dSYM`, when
    /// its debug map names the objects of the build, which are still there. Never throws: whatever goes wrong
    /// (`dsymutil` included) is the reason there is no dSYM.
    static func dSYM(of app: URL, project: URL, dsymutil: (URL, URL) throws -> Void) -> DSYM.Source {
        let fm = FileManager.default
        let executable = app.appendingPathComponent(DSYM.executableName(of: app))
        let out = project.appendingPathComponent(".xless/dsym/ios/\(executable.lastPathComponent).dSYM", isDirectory: true)
        do {
            let data = try Data(contentsOf: executable)
            let want = Set(try MachO.uuids(in: data))
            let products = project.appendingPathComponent(".build/out/Products", isDirectory: true)
            for configuration in ((try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path }) {
                for bundle in ((try? fm.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
                where bundle.pathExtension == "dSYM" && !want.isEmpty && DSYM.uuids(ofDSYM: bundle) == want {
                    return .found(bundle)
                }
            }
            guard try !MachO.debugMapObjects(in: data).isEmpty else {
                return .missing("\(executable.lastPathComponent) has no debug map (it was built without debug info)")
            }
            try? fm.removeItem(at: out)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try dsymutil(executable, out)
        } catch let e as XlessError {
            return .missing(e.cause)
        } catch {
            return .missing("no dSYM of \(executable.path): \(error)")
        }
        return fm.fileExists(atPath: out.path) ? .found(out) : .missing("dsymutil wrote no \(out.path)")
    }
}
