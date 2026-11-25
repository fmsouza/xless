import Foundation
import XlessImages
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
    let directory: String
    /// What a step does, and its answer.
    let answer: @Sendable (FakeRunHost, RunStep) -> Answer
    private(set) var became: [String]?
    private(set) var becameWith: [String: String] = [:]

    /// Instead of what the system says.
    var physical: (@Sendable (String) -> String?)?
    /// Paths of which the system says nothing, as of those below a directory that may not be searched.
    var unseen: Swift.Set<String> = []

    init(programs: Swift.Set<String> = ["docker", "xless"], isMac: Bool = false, directory: String = "/", processes: [Int32: Process] = [:],
         answer: @escaping @Sendable (FakeRunHost, RunStep) -> Answer = { _, _ in (0, "") }) {
        self.programs = programs
        self.isMac = isMac
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
    /// The images of this machine: one Xcode's, and the kits on it.
    let images = FakeImages()

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        root = "\(PosixRunHost().realPath(temporary) ?? temporary)/xless-run-\(UUID().uuidString)"
        for directory in ["home", "ov", "src", "proj", "run", "share"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(directory)", withIntermediateDirectories: true)
        }
        try write("ov/app.yml", "type: tauri\nsource: ../src\nteamID: ABCDE12345\n")
        try write("proj/xless.yml", "name: App\n")
        try write("share/versions.env", "XCODE_VERSION=27.0\n")
        for kit in Kit.allCases {
            try FileManager.default.createDirectory(at: kit.directory(share: share), withIntermediateDirectories: true)
            try write("share/docker/\(kit.rawValue)/Dockerfile", "FROM \(kit.rawValue)\n")
        }
        images.add(xcode: "26.6", build: "17F113")
        for kit in Kit.allCases { try images.add(kit, xcode: "26.6", share: share) }
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

    func run(_ arguments: [String], docker: Bool, host: FakeRunHost, environment: [String: String] = [:], session: String? = nil, unlocked: Bool = false) throws -> Int32 {
        Thread.current.threadDictionary["run"] = true
        let environment = ["HOME": home, "PATH": "/bin", "XDG_RUNTIME_DIR": "\(root)/run"].merging(environment) { $1 }
            .merging(session.map { ["XLESS_SESSION": $0] } ?? [:]) { $1 } // as before `XlessSession` took it
        let context = RunContext(environment: environment, xless: "xless", again: ["/x/xless", "run"] + arguments, share: "\(root)/share",
                                 useDocker: docker ? "1" : "0", session: session, unlocked: unlocked)
        return try ProjectRun(arguments, context: context, host: host).run()
    }

    /// The programs of a run that goes well: a build number, the store's secrets, the images.
    func answer(_ other: @escaping @Sendable (RunStep) -> FakeRunHost.Answer? = { _ in nil }) -> @Sendable (FakeRunHost, RunStep) -> FakeRunHost.Answer {
        let secrets = secrets, images = images, share = share
        return { _, step in
            if let answer = other(step) { return answer }
            if let answer = images.answer(step.words, share: share) { return answer }
            if step.words.contains("next-build") { return (0, "noise\n42\n") }
            if step.words.contains("named-by") { return (0, "SOME_PASSWORD\n") }
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

    func set(_ image: LocalImage) { lock.withLock { images[image.name] = image } }
    func remove(_ name: String) { lock.withLock { images[name] = nil } }
    func change(_ name: String, _ body: (inout LocalImage) -> Void) { lock.withLock { if var image = images[name] { body(&image); images[name] = image } } }
    func has(_ name: String) -> Bool { lock.withLock { images[name] != nil } }
    /// The name of the image with this ID, which is what a container must be of; else what was given.
    func name(_ id: String) -> String { lock.withLock { images.values.filter { $0.id == id }.map(\.name).min() } ?? "not an ID: \(id)" }

    /// An image as `xless setup --docker` builds it.
    func add(xcode: String, build: String, name: String? = nil, layers more: [String] = [], id: String? = nil) {
        set(LocalImage(name: name ?? ImageName.base(arch: "arm64", xcode: xcode), id: id ?? "sha256:base\(xcode)", architecture: "arm64",
                       labels: [ImageLabel.image: "true", ImageLabel.sdk: build, ImageLabel.xcode: xcode, ImageLabel.arch: "arm64", ImageLabel.version: "0.0.0-dev"],
                       layers: ["os", "xcode\(xcode)"] + more))
    }

    func add(_ kit: Kit, xcode: String, share: URL) throws {
        let name = ImageName.base(arch: "arm64", xcode: xcode), base = lock.withLock { images[name] }!
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
            try! add(kit, xcode: String(tag.dropFirst("xless:local-arm64-xcode".count).dropLast("-\(kit.rawValue)".count)), share: share)
            if buildIsElsewhere { change(tag) { $0.layers = ["pulled"] } }
        }
        return (0, "")
    }
}

extension RunStep {
    var line: String { words.joined(separator: " ") }
    /// `docker <command>`, of the clean-up.
    func isCleanUp(_ command: String) -> Bool { words.contains(command) && line.contains("label=xless.run=") }
    /// `docker run …`, of a step.
    var isContainer: Bool { words.contains("--rm") && !words.contains("--entrypoint") }
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
