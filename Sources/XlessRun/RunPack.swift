import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// The Xcode pack of a run in containers: every container of the run has it, read-only, and it is the only pack there
/// (`PackStore.mount`), named outright by `XLESS_XCODE`, so nothing in a container chooses another. The build's container runs
/// the app's code and that of its packages, and the steps with the secrets read the pack after it: no container of a run can
/// write it, through its own mount or another (`refuseWritableReach`: a writable mount that is a pack volume, or holds a directory
/// store or is in it, stops the run). Only the container that prepares a pack (`PackSetup`), which has nothing of a project and no
/// secret, writes a store.
struct RunPack: Equatable {
    var manifest: PackManifest
    /// Where it is: a volume (`PackVolumes.name`), or the directory XLESS_XCODES names.
    var store: PackStore
    /// For every container of the run: the read-only mount and `-e XLESS_XCODE=<mount path>`.
    var arguments: [String]

    init(_ manifest: PackManifest, store: PackStore) {
        self.manifest = manifest
        self.store = store
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

    /// No container of the run can write the pack through another of its mounts: of the mounts that `words` (docker run options
    /// of the run's containers) make writable, none is a pack volume (whatever the store), and none holds a directory store or is
    /// in it, compared as files (links followed, `RunFiles.directory(_:isIn:)`). The pack's own mount is read-only.
    func refuseWritableReach(of pack: RunPack?, in words: [String]) throws {
        guard let pack else { return }
        for mount in RunPack.writableMounts(words) {
            switch mount.kind {
            case .volume:
                guard mount.source.hasPrefix(PackVolumes.prefix) else { continue }
                let fix = setting("XLESS_RN_WORK_VOLUME") == mount.source ? "set XLESS_RN_WORK_VOLUME to a name that does not start with \(PackVolumes.prefix)" : "name another volume"
                throw RunStop.usage("the volume \(mount.source), which a container of this run would mount writable at \(mount.target), is a pack volume "
                    + "(its name starts with \(PackVolumes.prefix)), and no container of a run may write a pack: the build could change what the steps after it read; \(fix)")
            case .bind:
                guard case let .directory(dir) = pack.store, let relation = try overlap(mount.source, store: dir.path) else { continue }
                throw RunStop.usage("XLESS_XCODES (\(dir.path)), the store of the Xcode packs, and \(mount.source), which a container of this run would mount "
                    + "writable at \(mount.target), overlap (\(relation)): the build could change the pack that the steps after it read. "
                    + "Keep the store and \(mount.source) apart: set XLESS_XCODES to a directory outside it, beside it for one")
            }
        }
    }

    /// How `mount` and `store` overlap, as files; nil: they do not. A path that is not there yet is where its nearest parent is.
    private func overlap(_ mount: String, store: String) throws -> String? {
        if try files.isThere(store), try files.directory(files.nearest(mount), isIn: store) { return "\(mount) is in the store" }
        if try files.isThere(mount), try files.directory(files.nearest(store), isIn: mount) { return "the store is in \(mount)" }
        return nil
    }
}

/// A mount that a container can write (`RunPack.writableMounts`).
struct WritableMount: Equatable {
    enum Kind: Equatable { case bind, volume }
    var kind: Kind
    /// The host directory, or the volume's name.
    var source: String
    var target: String
}

extension RunPack {
    /// The mounts that `words` (docker run options) make writable: `--mount` (a volume unless `type=bind`) without `readonly`
    /// or `ro` (or with them false), and `-v`/`--volume` without `ro`. An anonymous volume or a tmpfs is no store.
    static func writableMounts(_ words: [String]) -> [WritableMount] {
        var found: [WritableMount] = []
        var i = words.startIndex
        while i < words.endIndex {
            let word = words[i]
            var value: String?, long = false
            if ["--mount", "-v", "--volume"].contains(word), i + 1 < words.endIndex {
                value = words[i + 1]; long = word == "--mount"; i += 1
            } else if word.hasPrefix("--mount=") { value = String(word.dropFirst("--mount=".count)); long = true }
            else if word.hasPrefix("--volume=") { value = String(word.dropFirst("--volume=".count)) }
            else if word.hasPrefix("-v=") { value = String(word.dropFirst("-v=".count)) }
            i += 1
            guard let value, let mount = long ? mountOption(value) : volumeOption(value) else { continue }
            found.append(mount)
        }
        return found
    }

    /// `--mount`'s value, CSV as docker reads it (a field in quotes may hold a comma; "" is a quote).
    private static func mountOption(_ value: String) -> WritableMount? {
        var fields: [String: String] = [:], flags: Set<String> = []
        for field in csv(value) {
            if let eq = field.firstIndex(of: "=") { fields[field[..<eq].lowercased()] = String(field[field.index(after: eq)...]) }
            else { flags.insert(field.lowercased()) }
        }
        let readOnly = !flags.isDisjoint(with: ["readonly", "ro"])
            || ["readonly", "ro"].contains { fields[$0].map { ["1", "true"].contains($0.lowercased()) } ?? false }
        let source = fields["source"] ?? fields["src"] ?? ""
        let target = fields["target"] ?? fields["destination"] ?? fields["dst"] ?? ""
        guard !readOnly, !source.isEmpty else { return nil }
        switch fields["type"] ?? "volume" {
        case "bind": return WritableMount(kind: .bind, source: source, target: target)
        case "volume": return WritableMount(kind: .volume, source: source, target: target)
        default: return nil
        }
    }

    /// `-v`'s value: <host path or volume>:<target>[:<options>].
    private static func volumeOption(_ value: String) -> WritableMount? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        if parts.count >= 3, parts[2].split(separator: ",").contains(where: { $0 == "ro" || $0 == "readonly" }) { return nil }
        return WritableMount(kind: parts[0].hasPrefix("/") ? .bind : .volume, source: parts[0], target: parts[1])
    }

    private static func csv(_ text: String) -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" { if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false } } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { fields.append(field); field = "" }
            else { field.append(c) }
        }
        fields.append(field)
        return fields
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
        case .volumes: "the pack volumes (\(PackVolumes.prefix)<version>-<build>-<arch>: docker volume ls --filter name=\(PackVolumes.prefix))"
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
                    guard let p = PackVolumes.parse(volume) else { return nil }
                    let m = PackManifest(format: PackRecipe.format, xcode: p.xcode, build: p.build, arch: p.arch, swift: "", mode: .own, parts: [:])
                    return XcodePack(root: URL(fileURLWithPath: PackVolumes.mountPath(RunPack.name(m))), manifest: m)
                }
            } catch let problem as ImageProblem { throw RunStop.usage("\(problem)") }
        }
    }

    /// Why `pack` is not the current pack of this xless; empty: it is. A pack of an Xcode this xless has no recipe for (versions.env
    /// maps it to no Swift toolchain) cannot be checked: that is said, and it is used as it is. A recipe input that cannot be read
    /// (a share that lacks a file or a versions.env entry) stops the run: whether a pack is current cannot be told then.
    /// `parts`: those a preparation makes again (all, for a pack of another format, build or architecture).
    private func staleness(_ pack: XcodePack) throws -> (reasons: [String], parts: [PackPart]) {
        let m = pack.manifest
        guard !(table["XCODE_SWIFT_\(m.build)"] ?? "").isEmpty else {
            run.host.say("==> note: the pack \(pack.name) in \(place(of: pack.name)) is of Xcode \(m.xcode) (\(m.build)), which this xless has no recipe for "
                + "(versions.env maps it to no Swift toolchain, XCODE_SWIFT_\(m.build)): it is used as it is, and whether it is current is not checked")
            return ([], [])
        }
        var expected: [String: String] = [:]
        do {
            for part in PackPart.allCases { expected[part.rawValue] = try PackRecipe.hash(part, build: m.build, arch: m.arch, table: table, share: share) }
        } catch let e as XlessError {
            throw RunStop.usage("cannot tell whether the pack \(pack.name) in \(place(of: pack.name)) is current: \(e.cause); \(e.fix)")
        }
        let check = SetupStep.PackCheck(volume: PackVolumes.name(xcode: m.xcode, build: m.build, arch: m.arch), pack: pack.name, arch: arch,
                                        image: image.name, build: m.build, expected: expected)
        let reasons = SetupPlan.staleness(m, check: check)
        guard reasons.isEmpty else {
            let whole = m.format != PackRecipe.format || m.build != check.build || m.arch != check.arch
            return (reasons, PackPart.allCases.filter { whole || m.parts[$0.rawValue] != expected[$0.rawValue] })
        }
        guard case .directory = store else { return ([], []) }
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        return (SetupPlan.lacking(pack.root, existing: exists),
                PackPart.allCases.filter { part in PackPlan.entries(of: part).contains { !exists(pack.root.appendingPathComponent($0)) } })
    }

    func choose() throws -> RunPack {
        if let mine = run.environment["XLESS_XCODE"], !mine.isEmpty {
            run.host.say("==> note: XLESS_XCODE (\(mine)) names a pack of this machine, which xless run --docker does not use: its containers take "
                + "the pack from \(place); unset XLESS_XCODE, or pin the Xcode with xcode:")
        }
        let here = try packs()
        let chosen = try? XcodeResolver.choose(here, pin: run.xcodePin, arch: arch, order: order)
        let why: String
        var parts = PackPart.allCases
        if let chosen {
            // A volume not read (a dry run) is said to be read when the run starts.
            guard reads || store != .volumes else { return RunPack(chosen.manifest, store: store) }
            let stale = try staleness(chosen)
            if stale.reasons.isEmpty { return RunPack(chosen.manifest, store: store) }
            why = "the pack \(chosen.name) in \(place(of: chosen.name)) is not current (\(stale.reasons.joined(separator: "; ")))"
            parts = stale.parts
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
        return try prepare(export.xcode, from: export.dir, cacheRoot: cacheRoot, why: why, parts: parts)
    }

    /// The steps of `xless setup --docker --sdk <export>` for this pack (`SetupPlan`: its volume when there is none, then the
    /// container of `PackSetup`, which prepares what is not current), each in the run's own way: shown by a dry run, else run with
    /// the run's label (a stopped run removes it) and nothing secret in docker's environment. Then the pack is read again.
    /// `parts`: what of it is not current, which the estimate names (the image's setup decides what it prepares).
    private func prepare(_ xcode: KnownXcode, from export: URL, cacheRoot: URL, why: String, parts: [PackPart]) throws -> RunPack {
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
        // Not under a running build that has it, of another run or a setup (this run's own containers start after): asked once,
        // before anything is said or done, for the pack the steps write.
        if !run.dryRun, let target = steps.lazy.compactMap({ step -> SetupStep.PackTarget? in
            if case let .packRun(job) = step.action { return job.writes } else { return nil }
        }).first {
            do { try target.refuseInUse(run.askDocker, excludingRun: run.runLabel.split(separator: "=", maxSplits: 1).last.map(String.init)) }
            catch let problem as ImageProblem { throw RunStop.usage("\(problem)") }
        }
        let what = (parts.isEmpty ? PackPart.allCases : parts).map { "its \($0.rawValue) part (\(PackPlan.estimate(of: $0)))" }.joined(separator: " and ")
        run.host.say("==> \(run.dryRun ? "would prepare" : "preparing") the pack \(name) of Xcode \(version) (\(xcode.build)) first (\(why)): "
            + "\(what), from the SDK export \(export.path)")
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
        let reasons = try staleness(pack).reasons
        guard reasons.isEmpty else {
            throw RunStop.usage("the pack \(name) is still not current after it was prepared (\(reasons.joined(separator: "; "))); xless setup --docker --sdk \(export.path) prepares it, and says why it cannot")
        }
        run.host.say("==> the pack \(name) is current")
        return RunPack(pack.manifest, store: store)
    }
}
