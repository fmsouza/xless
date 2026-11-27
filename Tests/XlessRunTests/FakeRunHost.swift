import Foundation
import XlessCore
import XlessImages
import XlessSDK
@testable import XlessRun

/// A host whose programs are a closure, and whose files are real ones.
final class FakeRunHost: RunHost, @unchecked Sendable {
    typealias Answer = (code: Int32, output: String)
    struct Process { var started = "Tue Nov 24 10:00:00 2026"; var command = "sleep"; var children: [Int32] = []; var stubborn = false; var mark = ""; var file = "/bin/sleep" }

    private let lock = NSLock()
    private let files = PosixRunHost()
    private var steps: [RunStep] = []
    private var said: [String] = [], shown: [String] = []
    private var stop: (@Sendable (Int32) -> Void)?
    private var processes: [Int32: Process] = [:]
    private var nextPID: Int32 = 5000
    private var ended: Int32?
    private let hasEnded = DispatchSemaphore(value: 0)

    let programs: Swift.Set<String>
    let isMac: Bool
    let isWSL: Bool
    let directory: String
    /// What a step does, and its answer.
    let answer: @Sendable (FakeRunHost, RunStep) -> Answer
    private(set) var became: [String]?
    private(set) var becameWith: [String: String] = [:]

    /// Instead of what the system says.
    var physical: (@Sendable (String) -> String?)?
    /// Paths of which the system says nothing, as of those below a directory that may not be searched.
    var unseen: Swift.Set<String> = []

    init(programs: Swift.Set<String> = ["docker", "xless"], isMac: Bool = false, isWSL: Bool = false, directory: String = "/", processes: [Int32: Process] = [:],
         answer: @escaping @Sendable (FakeRunHost, RunStep) -> Answer = { _, _ in (0, "") }) {
        self.programs = programs
        self.isMac = isMac
        self.isWSL = isWSL
        self.directory = directory
        self.processes = processes
        self.answer = answer
    }

    var allSteps: [RunStep] { lock.withLock { steps } }
    var lines: [String] { lock.withLock { said } }
    var output: [String] { lock.withLock { shown } }
    var killed: [Int32] { lock.withLock { terminated } }
    private var terminated: [Int32] = []
    private var stopped = false

    /// Asks the run to stop, as a signal does; to what it ends with.
    func askToStop(_ code: Int32) -> Int32? {
        let (stop, _) = lock.withLock { stopped = true; return (self.stop, ()) }
        Thread.detachNewThread { stop?(code) }
        return hasEnded.wait(timeout: .now() + 30) == .success ? lock.withLock { ended } : nil
    }

    /// What is in reach of a build in WSL; what it leaves running, and what of that cannot be ended.
    var windowsInReach = WindowsReach()
    var keepsOrphans = true, orphans: [String] = [], stayingOrphans: [String] = []
    func keepOrphans() -> Bool {
        lock.withLock { orphanLog.append("keep after \(steps.count)") }
        return keepsOrphans
    }
    func endOrphans(within seconds: Double) -> (ended: [String], left: [String]) {
        lock.withLock { orphanLog.append("end after \(steps.count)") }
        return (orphans, stayingOrphans)
    }
    private(set) var orphanLog: [String] = []

    var processID: Int32 { 4242 }
    var hostName: String { "here" }
    var machine = "this one", boot = "boot", namespace = "pid:[1]"
    var architecture: String { "arm64" }
    var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    var currentDirectory: String { directory }
    func show(_ line: String) { lock.withLock { shown.append(line) } }
    func say(_ line: String) { lock.withLock { said.append(line) } }
    func program(_ name: String, path: String?) -> String? { programs.contains(name) ? "/bin/\(name)" : nil }

    func start(_ step: RunStep) throws -> StartedStep {
        let pid = lock.withLock { () -> Int32 in
            steps.append(step)
            nextPID += 1
            processes[nextPID] = Process(command: step.words.joined(separator: " "))
            return nextPID
        }
        lock.withLock { running[pid] = step }
        return StartedStep(pid: pid, reading: nil, shows: false)
    }
    private var running: [Int32: RunStep] = [:]

    func finish(_ step: StartedStep) -> (code: Int32, output: String) {
        let what = lock.withLock { running[step.pid] }
        var result: Answer = (0, "")
        if let what {
            result = answer(self, what)
            if case .file(let path) = what.output { try? Data(result.output.utf8).write(to: URL(fileURLWithPath: path)) }
            if case .shown = what.output { result.output = "" }
        }
        lock.withLock { processes[step.pid] = nil }
        return result
    }

    /// An answer of this code: the step does not end.
    static let hangs: Int32 = -1
    func finish(_ step: StartedStep, within seconds: Double, unless stopped: () -> Bool) -> (code: Int32, output: String)? {
        let answer = finish(step)
        lock.withLock { limits.append(seconds) }
        return answer.code == Self.hangs || stopped() ? nil : answer
    }
    private(set) var limits: [Double] = []

    func become(_ words: [String], environment: [String: String]) -> String {
        became = words
        becameWith = environment
        return "this is a test"
    }

    func onStop(_ stop: @escaping @Sendable (Int32) -> Void) throws { lock.withLock { self.stop = stop } }
    var stopping: Bool { lock.withLock { stopped } }
    var stops: Int { lock.withLock { (stopped ? 1 : 0) + more } }
    /// More requests to stop.
    var more = 0
    func end(_ code: Int32) -> Never {
        lock.withLock { ended = code }
        hasEnded.signal()
        pthread_exit(nil)
    }

    func removeOnFault(_ path: String, isDirectory: Bool) { lock.withLock { onFault.append(path) } }
    private var onFault: [String] = []
    var removedOnFault: [String] { lock.withLock { onFault } }

    func isRunning(_ pid: Int32) -> Bool { lock.withLock { processes[pid] != nil } }
    func started(_ pid: Int32) -> String { lock.withLock { processes[pid]?.started ?? (pid == processID ? "Tue Nov 24 09:00:00 2026" : "") } }
    func commandLine(_ pid: Int32) -> String { lock.withLock { processes[pid]?.command ?? "" } }
    func mark(_ pid: Int32) -> String { lock.withLock { processes[pid]?.mark ?? "own mark" } }
    func programFile(_ pid: Int32) -> String { lock.withLock { processes[pid]?.file ?? (pid == processID ? "/own/xless" : "") } }
    func children() -> [Int32: [Int32]] { lock.withLock { processes.mapValues(\.children).filter { !$0.value.isEmpty } } }
    func terminate(_ pid: Int32) {
        lock.withLock {
            terminated.append(pid)
            if processes[pid]?.stubborn == false { processes[pid] = nil }
        }
    }
    func pause(_ seconds: Double) { if stopping, Thread.current.threadDictionary["run"] != nil { pthread_exit(nil) } }

    func realPath(_ path: String) -> String? { files.realPath(path) }
    func physicalPath(_ path: String) -> String? { physical.map { $0(path) } ?? files.physicalPath(path) }
    func isSame(_ a: String, _ b: String) -> Bool? { files.isSame(a, b) }
    func isThere(_ path: String, followed: Bool) -> Bool? { unseen.contains(path) ? nil : files.isThere(path, followed: followed) }
    func isReadable(_ path: String) -> Bool { files.isReadable(path) }
    func isFile(_ path: String) -> Bool { files.isFile(path) }
    func temporaryFile() throws -> String { try files.temporaryFile() }
    func link(_ file: String, _ path: String) -> Bool { files.link(file, path) }
    func rename(_ file: String, _ path: String) -> Bool { files.rename(file, path) }
    func makeDirectory(_ path: String) -> Bool { files.makeDirectory(path) }
    func removeFile(_ path: String) { files.removeFile(path) }
    func removeEmptyDirectory(_ path: String) { files.removeEmptyDirectory(path) }
    func removeTree(_ path: String) { if !keepsTrees && !kept.contains(path) { files.removeTree(path) } }
    var keepsTrees = false
    /// Trees that cannot be removed.
    var kept: Swift.Set<String> = []
    func isPrivateDirectory(_ path: String) -> Bool { files.isPrivateDirectory(path) }
    func ownFile(_ path: String) -> String? { files.ownFile(path) }
}

/// A home with a project, an overlay and its source, of one test.
final class RunHome: Sendable {
    let root: String
    var home: String { "\(root)/home" }
    var overlay: String { "\(root)/ov/app.yml" }
    var project: String { "\(root)/proj" }
    /// Where the fake `secrets materialize` writes.
    var secrets: String { "\(root)/run/xless/\(String(repeating: "0a", count: 16))" }
    var share: URL { URL(fileURLWithPath: "\(root)/share") }
    /// The images of this machine: this xless's, and the kits on it.
    let images: FakeImages
    /// The Xcode packs of this machine: by default a current one of Xcode 26.2 and one of 27.0, each in its volume.
    let packs: FakePacks
    /// Where a run finds the SDK exports (`SetupPlan.cacheRoot`).
    var exports: String { "\(home)/.cache/xless/sdk" }

    /// The two Xcodes of the share's table, as versions.env names them: their pack names, and their export directories.
    static let xcodes = [(xcode: "26.2", build: "17C52", swift: "6.2.3"), (xcode: "27.0", build: "27A266a", swift: "6.4.0")]

    /// `version`: the release this xless's share records (the images' tags name it). The recipe inputs of the packs are the same
    /// whatever it is.
    init(version: String = FakeImages.version) throws {
        let temporary = FileManager.default.temporaryDirectory.path
        root = "\(PosixRunHost().realPath(temporary) ?? temporary)/xless-run-\(UUID().uuidString)"
        images = FakeImages(version: version)
        packs = FakePacks(share: URL(fileURLWithPath: "\(root)/share"))
        for directory in ["home", "ov", "src", "proj", "run", "share/scripts", "share/docker/toolchain/target-os"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(directory)", withIntermediateDirectories: true)
        }
        try write("ov/app.yml", "type: tauri\nsource: ../src\nteamID: ABCDE12345\n")
        try write("proj/xless.yml", "name: App\n")
        var table = ["XLESS_VERSION=\(version)", "XCODE_VERSION=27.0", "SWIFT_VERSION=6.4.0", "SWIFT_IMAGE=swift:6.4.0-jammy@sha256:0123", "XTOOL_VERSION=1.21.0",
                     "SWB_TAG=swift-6.4.0-RELEASE", "XCODE_RELEASES=\(Self.xcodes.map(\.build).joined(separator: " "))"]
        for x in Self.xcodes {
            let toolchain = "SWIFT_TOOLCHAIN_\(x.swift.replacingOccurrences(of: ".", with: "_"))"
            table += ["XCODE_SHORT_\(x.build)=\(x.xcode)", "XCODE_APPLE_SWIFT_\(x.build)=\(x.swift)", "XCODE_BUILD_MACHINE_OS_\(x.build)=25A1", "XCODE_SWIFT_\(x.build)=\(x.swift)",
                      "\(toolchain)_URL_AARCH64=https://example.invalid/\(x.swift)", "\(toolchain)_SHA256_AARCH64=\(x.swift)"]
            try write("share/docker/toolchain/target-os/\(x.build).txt", "\(x.build)\n")
        }
        try write("share/versions.env", table.joined(separator: "\n") + "\n")
        for file in ["scripts/fit-toolchain.sh", "scripts/pack-swift-build.sh", "docker/toolchain/clang-driver", "docker/toolchain/target-os-check",
                     "docker/toolchain/record-flags.py", "docker/toolchain/target-os/derived.txt"] { try write("share/\(file)", "\(file)\n") }
        for kit in Kit.allCases {
            try FileManager.default.createDirectory(at: kit.directory(share: share), withIntermediateDirectories: true)
            try write("share/docker/\(kit.rawValue)/Dockerfile", "FROM \(kit.rawValue)\n")
        }
        images.add(xcode: "26.6", build: "17F113")
        for kit in Kit.allCases { try images.add(kit, xcode: "26.6", share: share) }
        for x in Self.xcodes { try packs.add(packs.current(x.xcode, x.build)) }
    }

    /// The SDK export of an Xcode in the cache, as a setup leaves it: `arm64/darwin.xtoolsdk` and its toolchain-meta.json.
    func export(_ xcode: String, _ build: String) throws {
        try FileManager.default.createDirectory(atPath: "\(exports)/xcode\(xcode)-\(build)/arm64/darwin.xtoolsdk", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(exports)/xcode\(xcode)-\(build)/toolchain-meta.json"))
    }
    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> String {
        try Data(text.utf8).write(to: URL(fileURLWithPath: "\(root)/\(path)"))
        return "\(root)/\(path)"
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The secrets of a run given as files and, the key, as a value too.
    func files() throws -> [String: String] {
        ["ASC_KEY_ID": "KEY1", "ASC_ISSUER_ID": "issuer-1", "ASC_KEY_P8_FILE": try write("asc.p8", "p8"), "XLESS_DIST_KEY_FILE": try write("dist.pem", "dist"),
         "XLESS_DIST_KEY": "DIST-VALUE", "XLESS_DEMO_PASSWORD": "DEMO-VALUE", "SOME_PASSWORD": "OWN-VALUE"]
    }

    func run(_ arguments: [String], docker: Bool, host: FakeRunHost, environment: [String: String] = [:], session: String? = nil, unlocked: Bool = false,
             prepareMac: (@Sendable (String?, Bool, Bool) throws -> Void)? = nil, overlayLacks: (@Sendable (Kit, [String: String]) -> [String])? = nil) throws -> Int32 {
        Thread.current.threadDictionary["run"] = true
        let environment = ["HOME": home, "PATH": "/bin", "XDG_RUNTIME_DIR": "\(root)/run"].merging(environment) { $1 }
            .merging(session.map { ["XLESS_SESSION": $0] } ?? [:]) { $1 } // as before `XlessSession` took it
        let context = RunContext(environment: environment, xless: "xless", again: ["/x/xless", "run"] + arguments, share: "\(root)/share",
                                 useDocker: docker ? "1" : "0", session: session, unlocked: unlocked, prepareMac: prepareMac,
                                 overlayLacks: overlayLacks)
        return try ProjectRun(arguments, context: context, host: host).run()
    }

    /// The programs of a run that goes well: a build number, the store's secrets, the images.
    func answer(_ other: @escaping @Sendable (RunStep) -> FakeRunHost.Answer? = { _ in nil }) -> @Sendable (FakeRunHost, RunStep) -> FakeRunHost.Answer {
        let secrets = secrets, images = images, packs = packs, share = share
        return { _, step in
            if let answer = other(step) { return answer }
            if let answer = packs.answer(step.words) { return answer }
            if let answer = images.answer(step.words, share: share) { return answer }
            if step.words.contains("next-build") { return (0, "noise\n42\n") }
            if step.words.contains("named-by") { return (0, "SOME_PASSWORD\n") }
            if step.words == ["xless", "auth", "status", "--json"] { return (0, #"{"session":{"state":"none"},"store":{"state":"locked"}}"# + "\n") }
            if step.words.contains("materialize"), !step.words.contains("--check") {
                for set in step.words where set.contains("=") {
                    let parts = set.split(separator: "=")
                    let directory = "\(secrets)/\(parts[0])"
                    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    for name in parts[1].split(separator: ",") { FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: Data("SECRET".utf8)) }
                }
                return (0, "\(secrets)\n")
            }
            return (0, "")
        }
    }
}

/// The images of a fake docker.
final class FakeImages: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: LocalImage] = [:]
    /// What a build of a kit leaves.
    var buildFails = false, buildIsElsewhere = false
    /// The release of the xless whose images these are.
    let version: String

    init(version: String = FakeImages.version) { self.version = version }

    func set(_ image: LocalImage) { lock.withLock { images[image.name] = image } }
    func remove(_ name: String) { lock.withLock { images[name] = nil } }
    func change(_ name: String, _ body: (inout LocalImage) -> Void) { lock.withLock { if var image = images[name] { body(&image); images[name] = image } } }
    func has(_ name: String) -> Bool { lock.withLock { images[name] != nil } }
    /// The name of the image with this ID, which is what a container must be of; else what was given.
    func name(_ id: String) -> String { lock.withLock { images.values.filter { $0.id == id }.map(\.name).min() } ?? "not an ID: \(id)" }

    /// The xless of the tests: its share directory records this release (`RunHome`).
    static let version = "0.14.0"
    var baseName: String { ImageName.base(version: version, arch: "arm64") }

    /// An image as `xless setup --docker` builds it. (It holds no Xcode: `xcode` only makes the IDs and layers of the fake's images
    /// differ.)
    func add(xcode: String, build: String, name: String? = nil, layers more: [String] = [], id: String? = nil) {
        set(LocalImage(name: name ?? baseName, id: id ?? "sha256:base\(xcode)", architecture: "arm64",
                       labels: [ImageLabel.image: "true", ImageLabel.arch: "arm64", ImageLabel.version: version, ImageLabel.id: "v\(version)-0123456789ab"],
                       layers: ["os", "xcode\(xcode)"] + more))
    }

    func add(_ kit: Kit, xcode: String, share: URL) throws {
        let name = baseName, base = lock.withLock { images[name] }!
        var image = base
        image.name = kit.image(on: base)
        image.id = "sha256:\(kit.rawValue)\(xcode)"
        image.layers.append(kit.rawValue)
        image.labels.merge([ImageLabel.kit: kit.rawValue, ImageLabel.kitBase: base.id, ImageLabel.kitRecipe: try kit.recipe(share: share)]) { $1 }
        set(image)
    }

    /// docker's answer to a question or a build of images; nil: it is another command.
    func answer(_ words: [String], share: URL) -> FakeRunHost.Answer? {
        guard words.first == "docker" else { return nil }
        if words.suffix(2) == ["context", "show"] { return (0, "here\n") }
        if words.contains("ls"), words.contains("image") { return (0, lock.withLock { images.keys.sorted().joined(separator: "\n") } + "\n") }
        if words.contains("inspect") {
            guard let image = lock.withLock({ images[words.last ?? ""] }) else { return (1, "\n") }
            let json: [String: Any] = ["Id": image.id, "Architecture": image.architecture, "Config": ["Labels": image.labels], "RootFS": ["Layers": image.layers]]
            return (0, String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n")
        }
        guard words.contains("build") && words.contains("--pull=false") else { return nil }
        if buildFails { return (1, "") }
        for kit in Kit.allCases where words.contains("\(ImageLabel.kit)=\(kit.rawValue)") {
            let tag = words[words.firstIndex(of: "-t")! + 1]
            try! add(kit, xcode: "26.6", share: share)
            if buildIsElsewhere { change(tag) { $0.layers = ["pulled"] } }
        }
        return (0, "")
    }
}

extension RunStep {
    var line: String { words.joined(separator: " ") }
    /// `docker <command>`, of the clean-up.
    func isCleanUp(_ command: String) -> Bool { words.contains(command) && line.contains("label=xless.run=") }
    /// `docker run …`, of a step (not one that reads or prepares a pack).
    var isContainer: Bool { words.contains("--rm") && words.contains("--init") }
    /// Any `docker run`: of a step, of the run's reading of the pack volumes, of a pack's preparation.
    var isDockerRun: Bool { words.first == "docker" && words.contains("run") && words.contains("--rm") }
    /// The container of a pack's preparation (`PackSetup`).
    var isPackSetup: Bool { isDockerRun && words.suffix(3).first == "setup" }
    /// The image a container is of: what its xless follows.
    var image: String { words.firstIndex(of: "xless").map { words[$0 - 1] } ?? "" }
}

/// Lines from several threads.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var noted: [String] = []
    func add(_ line: String) { lock.withLock { noted.append(line) } }
    var lines: [String] { lock.withLock { noted } }
}

/// The Xcode packs of a fake docker: its pack volumes, each with the pack.json it holds (nil: none yet), and what the containers of
/// their preparation did. A directory store (`XLESS_XCODES`) is real files instead.
final class FakePacks: @unchecked Sendable {
    private let lock = NSLock()
    private var volumes: [String: PackManifest?] = [:]
    private var setups: [String] = []
    let share: URL

    init(share: URL) { self.share = share }

    /// The pack of `xcode` that this xless's share makes: `parts`, each with its recipe hash.
    func current(_ xcode: String, _ build: String, parts: [PackPart] = PackPart.allCases) throws -> PackManifest {
        let table = KnownXcodes.parseEnv(try String(contentsOf: share.appendingPathComponent("versions.env"), encoding: .utf8))
        var hashes: [String: String] = [:]
        for part in parts { hashes[part.rawValue] = try PackRecipe.hash(part, build: build, arch: "arm64", table: table, share: share) }
        return PackManifest(format: PackRecipe.format, xcode: xcode, build: build, arch: "arm64", swift: "6.4.0", mode: .own, parts: hashes)
    }

    static func volume(_ m: PackManifest) -> String { PackVolumes.name(xcode: m.xcode, build: m.build, arch: m.arch) }

    func add(_ manifest: PackManifest) { lock.withLock { volumes[Self.volume(manifest)] = .some(manifest) } }
    func change(_ volume: String, _ body: (inout PackManifest) -> Void) {
        lock.withLock { if case var .some(.some(m)) = volumes[volume] { body(&m); volumes[volume] = .some(m) } }
    }
    func removeAll() { lock.withLock { volumes = [:] } }
    func manifest(_ volume: String) -> PackManifest? { lock.withLock { volumes[volume] ?? nil } }
    /// The stores the preparing containers wrote into.
    var prepared: [String] { lock.withLock { setups } }

    /// A running container of the machine: its name, image, `xless.run` label, and what it mounts (volume names, host directories).
    struct Running { var name: String; var image = "xless:0.14.0-arm64-tauri"; var run = ""; var volumes: [String] = []; var directories: [String] = [] }
    private var containers: [Running] = []
    var running: [Running] {
        get { lock.withLock { containers } }
        set { lock.withLock { containers = newValue } }
    }
    /// The `docker ps` and `docker inspect` that asked about them.
    private(set) var askedUsers: [[String]] = []

    /// A pack in a directory store, as a setup leaves it: its pack.json and the entries of its parts.
    func write(_ manifest: PackManifest, in store: String) throws {
        let root = URL(fileURLWithPath: store).appendingPathComponent(XcodePack.name(xcode: manifest.xcode, build: manifest.build, arch: manifest.arch))
        for part in PackPart.allCases where manifest.parts[part.rawValue] != nil {
            for entry in PackPlan.entries(of: part) { try FileManager.default.createDirectory(at: root.appendingPathComponent(entry), withIntermediateDirectories: true) }
        }
        try manifest.write(to: root.appendingPathComponent("pack.json"))
    }

    /// docker's answer about the packs; nil: another command.
    func answer(_ words: [String]) -> FakeRunHost.Answer? {
        guard words.first == "docker" else { return nil }
        if words.contains("volume"), words.contains("ls") {
            return (0, lock.withLock { volumes.keys.sorted().map { "\($0)\n" }.joined() })
        }
        if words.contains("volume"), words.contains("create"), let name = words.last {
            lock.withLock { if volumes[name] == nil { volumes[name] = .some(nil) } }
            return (0, "\(name)\n")
        }
        if words.contains("info") { return (0, "[\"name=seccomp,profile=builtin\"]\n") }
        // which running containers use a pack (PackUsers); the clean-up's `ps -aq --filter label=…` is not this
        if !words.contains("run"), let ps = words.firstIndex(of: "ps"), !words.contains("-aq") {
            lock.withLock { askedUsers.append(Array(words[ps...])) }
            if let filter = words.first(where: { $0.hasPrefix("volume=") }) {
                let volume = String(filter.dropFirst("volume=".count))
                return (0, running.filter { $0.volumes.contains(volume) }.map { "\($0.name)\t\($0.image)\t\($0.run)\n" }.joined())
            }
            if words.last == "-q" { return (0, running.indices.map { "id\($0)\n" }.joined()) }
        }
        if !words.contains("run"), let inspect = words.firstIndex(of: "inspect"), inspect + 2 < words.endIndex, words[inspect + 1] == "--format", words[inspect + 2].contains(".Mounts") {
            lock.withLock { askedUsers.append(Array(words[inspect...])) }
            let all = running
            return (0, words[(inspect + 3)...].compactMap { id -> String? in
                guard let i = Int(id.dropFirst(2)), all.indices.contains(i) else { return nil }
                let c = all[i]
                let mounts = c.volumes.map { ["Type": "volume", "Name": $0, "Source": "/var/lib/docker/volumes/\($0)/_data"] } + c.directories.map { ["Type": "bind", "Source": $0] }
                let json = String(decoding: try! JSONSerialization.data(withJSONObject: mounts), as: UTF8.self)
                return "/\(c.name)\t\(c.image)\t\(c.run.isEmpty ? "<no value>" : c.run)\t\(json)\n"
            }.joined())
        }
        guard words.contains("run") else { return nil }
        if words.contains(where: { $0.contains("--- xless pack") }) { // the reading container
            var at: [String: String] = [:]
            for w in words where w.hasPrefix("type=volume,") {
                let f = Dictionary(uniqueKeysWithValues: w.split(separator: ",").compactMap { kv -> (String, String)? in
                    let p = kv.split(separator: "=", maxSplits: 1); return p.count == 2 ? (String(p[0]), String(p[1])) : nil })
                at[f["dst"] ?? ""] = f["src"]
            }
            var out = ""
            for path in words where path.hasSuffix("/pack.json") {
                out += "\n--- xless pack \(path)\n"
                let dir = "/" + path.split(separator: "/").prefix(2).joined(separator: "/")
                if let volume = at[dir], let m = manifest(volume), let data = try? JSONEncoder().encode(m) { out += String(decoding: data, as: UTF8.self) + "\n" }
            }
            return (0, out)
        }
        if words.contains(where: { $0.contains("chown") }) { return (0, "") }
        guard let i = words.firstIndex(of: "setup"), words[i - 1] == "xless", let sdk = words.firstIndex(of: "--sdk") else { return nil }
        // the image's xless setup: the pack of the export, current
        let export = words[sdk + 1].split(separator: "/").last.map(String.init) ?? ""   // xcode<V>-<B>
        let parts = export.dropFirst("xcode".count).split(separator: "-").map(String.init)
        guard parts.count == 2, let m = try? current(parts[0], parts[1]) else { return (1, "") }
        let store = words.first { $0.hasSuffix(",dst=/xcodes") } ?? ""
        lock.withLock { setups.append(store) }
        if store.hasPrefix("type=volume,") { add(m) }
        else if let src = store.split(separator: ",").first(where: { $0.hasPrefix("src=") }) { try? write(m, in: String(src.dropFirst(4))) }
        return (0, "")
    }
}
