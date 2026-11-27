import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// The Xcode pack of a run in containers: every container of the run has it, read-only, and it is the only pack there
/// (`PackStore.mount`), named outright by `XLESS_XCODE`, so nothing in a container chooses another. The build's container runs
/// the app's code and that of its packages, and the steps with the secrets read the pack after it: no container of a run can
/// write it. Only the container that prepares a pack (`PackSetup`), which has nothing of a project and no secret, writes a store.
struct RunPack: Equatable {
    var manifest: PackManifest
    /// For every container of the run: the read-only mount and `-e XLESS_XCODE=<mount path>`.
    var arguments: [String]

    init(_ manifest: PackManifest, store: PackStore) {
        self.manifest = manifest
        arguments = store.mount(xcode: manifest.xcode, build: manifest.build, arch: manifest.arch, writable: false)
            + ["-e", "XLESS_XCODE=\(PackVolumes.mountPath(Self.name(manifest)))"]
    }

    var name: String { Self.name(manifest) }
    static func name(_ m: PackManifest) -> String { XcodePack.name(xcode: m.xcode, build: m.build, arch: m.arch) }
}

extension ProjectRun {
    /// The pack of the project's pin (else the newest), current for this xless and holding Swift Build. A stale or missing part
    /// is prepared first when the export is in the cache (says so, with the estimate); otherwise RunStop.usage with the command.
    ///
    /// Current: each part's recipe hash in its `pack.json` is the one this xless computes from its share (`SetupPlan.staleness`),
    /// so another xless whose recipes are the same prepares nothing. The volumes are read with one container of `image` (no
    /// network, each read-only); a directory store is read here. A dry run starts no container: it chooses a volume by its name,
    /// and says what a run would do where it can tell.
    func choosePack(image: LocalImage) throws -> RunPack {
        let packs = PackChoice(self, image: image)
        return try packs.choose()
    }
}

/// What `choosePack` reads and decides.
private struct PackChoice {
    let run: ProjectRun
    let image: LocalImage
    let store: PackStore
    let arch: String
    let share: URL
    let table: [String: String]
    let known: [KnownXcode]
    /// The builds of versions.env's Xcode table, in its order.
    let order: [String]
    /// The volumes are read with a container (a run, with the image here), else only listed.
    let reads: Bool

    init(_ run: ProjectRun, image: LocalImage) {
        self.run = run
        self.image = image
        store = PackStore(env: run.environment)
        arch = run.architecture
        share = run.shareDirectory
        table = KnownXcodes.parseEnv((try? String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8)) ?? "")
        known = (try? KnownXcodes.load(versionsEnv: share.appendingPathComponent("versions.env"))) ?? []
        order = (table["XCODE_RELEASES"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        reads = !run.dryRun && !image.id.isEmpty
    }

    private var place: String {
        switch store {
        case .volumes: "the pack volumes (docker volume ls --filter label=\(PackVolumes.label))"
        case let .directory(dir): "\(dir.path) (XLESS_XCODES)"
        }
    }

    private func place(of name: String) -> String {
        switch store {
        case .volumes: "the volume \(PackVolumes.prefix)\(name)"
        case let .directory(dir): dir.appendingPathComponent(name).path
        }
    }

    /// "<file> pins xcode: "26.2", but " when it does.
    private var pinned: String { run.xcodePin.map { "\(run.pinFile) pins xcode: \"\($0)\", but " } ?? "" }
    private var wanted: String { run.xcodePin.map { "Xcode \(XcodeVersion.canonical($0))" } ?? "any Xcode" }

    /// The packs of the store for `arch`. With `reads` false a volume is known by its name alone (its manifest records no part).
    private func packs() throws -> [XcodePack] {
        switch store {
        case let .directory(dir):
            return XcodeStore(root: dir).packs().filter { $0.manifest.arch == arch }
        case .volumes:
            let volumes = PackVolumes(run.askDocker)
            do {
                if reads {
                    return try volumes.manifests(arch: arch, image: image.id).map { XcodePack(root: URL(fileURLWithPath: PackVolumes.mountPath(RunPack.name($0))), manifest: $0) }
                }
                return try volumes.names(arch: arch).compactMap { volume in
                    let p = volume.dropFirst(PackVolumes.prefix.count).split(separator: "-").map(String.init)
                    guard p.count == 3 else { return nil }
                    let m = PackManifest(format: PackRecipe.format, xcode: p[0], build: p[1], arch: p[2], swift: "", mode: .own, parts: [:])
                    return XcodePack(root: URL(fileURLWithPath: PackVolumes.mountPath(RunPack.name(m))), manifest: m)
                }
            } catch let problem as ImageProblem { throw RunStop.usage("\(problem)") }
        }
    }

    /// Why `pack` is not the current pack of this xless; empty: it is.
    private func staleness(_ pack: XcodePack) -> [String] {
        let m = pack.manifest
        var expected: [String: String] = [:]
        // (an Xcode this xless has no recipe for is not stale for it: the stage commands in the container say the same)
        for part in PackPart.allCases { expected[part.rawValue] = try? PackRecipe.hash(part, build: m.build, arch: m.arch, table: table, share: share) }
        let check = SetupStep.PackCheck(volume: PackVolumes.name(xcode: m.xcode, build: m.build, arch: m.arch), pack: pack.name, arch: arch,
                                        image: image.name, build: m.build, expected: expected)
        let reasons = SetupPlan.staleness(m, check: check)
        guard reasons.isEmpty, case .directory = store else { return reasons }
        return SetupPlan.lacking(pack.root, existing: { FileManager.default.fileExists(atPath: $0.path) })
    }

    func choose() throws -> RunPack {
        let here = try packs()
        let chosen = try? XcodeResolver.choose(here, pin: run.xcodePin, arch: arch, order: order)
        let why: String
        if let chosen {
            // A volume not read (a dry run) is said to be read when the run starts.
            guard reads || store != .volumes else { return RunPack(chosen.manifest, store: store) }
            let reasons = staleness(chosen)
            if reasons.isEmpty { return RunPack(chosen.manifest, store: store) }
            why = "the pack \(chosen.name) in \(place(of: chosen.name)) is not current (\(reasons.joined(separator: "; ")))"
        } else {
            why = "there is no pack of \(wanted) for \(arch) in \(place)"
        }

        // Prepared from the SDK export in the cache: of the chosen pack's Xcode, else the newest of the pin's (or of any).
        let cacheRoot = SetupPlan.cacheRoot(env: run.environment, home: URL(fileURLWithPath: run.files.home))
        let candidates = chosen.map { c in known.filter { $0.build == c.manifest.build } }
            ?? known.filter { run.xcodePin == nil || XcodeVersion.canonical($0.shortVersion) == XcodeVersion.canonical(run.xcodePin!) }
                .sorted { XcodeVersion.isOlder($1.shortVersion, than: $0.shortVersion) || ($0.shortVersion == $1.shortVersion && (order.firstIndex(of: $0.build) ?? -1) > (order.firstIndex(of: $1.build) ?? -1)) }
        let export = candidates.lazy.map { (xcode: $0, dir: SetupPlan.sdkDir(cacheRoot: cacheRoot, xcode: $0)) }.first { e in
            XcodeSource.exportedArchs(e.dir).contains(arch) && FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("toolchain-meta.json").path)
        }
        guard let export else {
            let version = chosen?.manifest.xcode ?? run.xcodePin.map(XcodeVersion.canonical)
            let cause = "\(pinned)\(why), and there is no SDK export of \(version.map { "Xcode \($0)" } ?? "an Xcode") for \(arch) in \(cacheRoot.appendingPathComponent("sdk").path) to prepare it from"
            let fix = "xless setup --docker --xcode <path to Xcode \(version ?? "<version>")'s .xip or Xcode.app>"
            guard run.dryRun else { throw RunStop.usage("\(cause); \(fix)") }
            run.host.say("==> note: \(cause): a run would stop here (\(fix))")
            let name = chosen?.manifest ?? candidates.first.map { PackManifest(format: PackRecipe.format, xcode: XcodeVersion.canonical($0.shortVersion), build: $0.build, arch: arch, swift: "", mode: .own, parts: [:]) }
            return RunPack(name ?? PackManifest(format: PackRecipe.format, xcode: version ?? "<version>", build: "<build>", arch: arch, swift: "", mode: .own, parts: [:]), store: store)
        }
        return try prepare(export.xcode, from: export.dir, cacheRoot: cacheRoot, why: why)
    }

    /// The steps of `xless setup --docker --sdk <export>` for this pack (`SetupPlan`: its volume when there is none, then the
    /// container of `PackSetup`, which prepares what is not current), each in the run's own way: shown by a dry run, else run with
    /// the run's label (a stopped run removes it) and nothing secret in docker's environment. Then the pack is read again.
    private func prepare(_ xcode: KnownXcode, from export: URL, cacheRoot: URL, why: String) throws -> RunPack {
        let version = XcodeVersion.canonical(xcode.shortVersion)
        let name = XcodePack.name(xcode: version, build: xcode.build, arch: arch)
        let plan: SetupPlan.Docker
        do {
            try XcodeSupport.require(xcode, known: known, table: table, share: share)
            let source = try XcodeSource.identifyExport(path: export.path, known: known, cwd: export, home: export)
            let rootless = run.askDocker(["info", "--format", "{{json .SecurityOptions}}"]).output.contains("name=rootless")
            plan = try SetupPlan.make(source: source, archs: [arch], hostArch: arch, share: share, cacheRoot: cacheRoot, table: table, xlessBinaries: [:],
                                      store: store, docker: run.askDocker, readVolumes: reads, rootless: rootless, reexport: false,
                                      environment: run.environment, existing: { FileManager.default.fileExists(atPath: $0.path) })
        } catch let e as XlessError {
            throw RunStop.usage("\(pinned)\(why), and it cannot be prepared from \(export.path): \(e.cause); \(e.fix)")
        } catch let problem as ImageProblem {
            throw RunStop.usage("\(problem)")
        }
        // (the image is here, or the run would have stopped: no step builds it)
        let steps = plan.steps.filter { $0.argv.first == "docker" }
        let estimate = steps.last?.estimate ?? "seconds"
        run.host.say("==> \(run.dryRun ? "would prepare" : "preparing") the pack \(name) of Xcode \(version) (\(xcode.build)) first (\(why)): "
            + "what of it is not current, from the SDK export \(export.path); \(estimate)")
        for (n, s) in steps.enumerated() {
            if !run.dryRun {
                run.host.say("==> [\(n + 1)/\(steps.count)] \(s.title)")
                if case let .packRun(job) = s.action {
                    for dir in job.directories { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
                }
            }
            let words = s.argv[1] == "run" ? run.dockerCLI + ["run", "--label", run.runLabel] + s.argv.dropFirst(2) : run.dockerCLI + s.argv.dropFirst()
            let code = run.step(words, .nothing).code
            guard code == 0 else {
                throw RunStop.usage("the pack \(name) was not prepared (\(s.title): docker exited with code \(code)); its output is above. xless setup --docker --sdk \(export.path) prepares it")
            }
        }
        let fresh = PackManifest(format: PackRecipe.format, xcode: version, build: xcode.build, arch: arch, swift: "", mode: .own, parts: [:])
        guard !run.dryRun else { return RunPack(fresh, store: store) }
        guard let pack = try packs().first(where: { $0.name == name }) else {
            throw RunStop.usage("the pack \(name) is not in \(place(of: name)) after it was prepared; xless setup --docker --sdk \(export.path) prepares it, and says why it cannot")
        }
        let reasons = staleness(pack)
        guard reasons.isEmpty else {
            throw RunStop.usage("the pack \(name) is still not current after it was prepared (\(reasons.joined(separator: "; "))); xless setup --docker --sdk \(export.path) prepares it, and says why it cannot")
        }
        run.host.say("==> the pack \(name) is current")
        return RunPack(pack.manifest, store: store)
    }
}
