import Foundation
import XlessCore
import XlessImages

/// The three steps of a run of an overlay: a Tauri v2 app (`type: tauri`, docs/tauri.md), a plain Cargo app (`type: cargo`,
/// docs/cargo.md) or a React Native or Expo app (`type: react-native`, docs/react-native.md).
///
/// In docker (bind mounts as --mount, so any path works): the source, read-only at /source (the top of the git checkout it is
/// inside of: xless lists the tracked files with git), and the overlay's folder, read-only at /config (the whole folder, so a
/// relative `privacyManifest:` or `assets:` resolves). Neither may hold the env file or a secret's file, nor be /, the home
/// directory or a directory above it. Natively on a Mac, where the build's xless reads the same of this machine and no more
/// (docs/security.md), the same holds.
extension ProjectRun {
    private struct Overlay {
        let path: String
        let isReactNative: Bool
        let isCargo: Bool
        var isSimulator = false
        var source = ""
        /// What docker mounts at /source, and where the source is below that.
        var mounted = "", below = ""
        var span = RunSpan(from: .build, to: .upload)

        var directory: String { RunFiles.parent(path) }
        var stem: String { RunFiles.stem(path) }
    }

    /// How the steps run: the images, the caches and the arguments that every one has.
    private struct Steps {
        var images = RunImages.none
        var mounts: [String] = []
        var buildCaches: [String] = [], signCaches: [String] = []
        /// `--config`, and `--source`.
        var arguments: [String] = []
        var workVolume = ""
        var cache = ""
    }

    func run(overlay path: String, top: RunTop) throws -> Int32 {
        let macos = request.platform == .macos
        var overlay = Overlay(path: path, isReactNative: top["type"] == "react-native", isCargo: top["type"] == "cargo", isSimulator: request.simulator)
        if overlay.isReactNative, macos { throw RunStop.usage("React Native overlays build iOS apps only (drop --platform macos)") }
        if overlay.isSimulator, !overlay.isReactNative { throw RunStop.usage("--destination simulator builds React Native overlays only") }
        guard let given = setting("XLESS_SOURCE") ?? top["source"] else { throw RunStop.usage("\(path) has no source: (set it, or set XLESS_SOURCE)") }
        overlay.source = files.expanded(given)
        if !RunText.isAbsolute(overlay.source) { overlay.source = "\(overlay.directory)/\(overlay.source)" }
        guard files.isDirectory(overlay.source) else { throw RunStop.usage("the app source \(overlay.source) does not exist") }
        overlay.source = files.absolute(overlay.source)
        let span = try RunSpan.overlay(request)
        overlay.span = span
        try chooseDocker()

        // Step 1 only for a run that starts with `build: dated` (the default): later stages read the number recorded in the work
        // copy, and a fixed build needs no App Store Connect query.
        let dated = (top["build"] ?? "dated") == "dated"
        let next = !macos && !overlay.isSimulator && setting("XLESS_BUILD_NUMBER") == nil && !span.buildNumberGiven && span.from <= .build && dated
        let signs = span.to >= .sign
        let lane = macos && span.to >= .upload
        try findSecrets(.init(next: next, signs: signs, uploads: span.to >= .upload && !overlay.isSimulator, lane: lane), top: top)
        var inputs: [(name: String, path: String)] = []
        if docker || host.isMac {
            findMount(&overlay)
            inputs = try checkMounts(overlay)
        }
        if docker {
            try prepareDocker()
            try mountFiles(platform: request.platform)
        } else {
            if host.isMac, !dryRun { try context.prepareMac?(xcodePin, span.from <= .finalize, signs) }
            try unlockStore()
        }

        let steps = try docker ? dockerSteps(overlay, inputs, top, next: next) : nativeSteps(overlay)
        try holdWorkCopy(workCopy(overlay, steps))
        if docker {
            // The store's secrets for steps 1 and 3, now that nothing else can stop the run before step 1.
            buildMounts = try [overlay.directory, overlay.mounted].map(files.real) + inputs.map(\.path)
            if !overlay.isReactNative { buildMounts += ["work", "downloads", "inputs"].map { "\(steps.cache)/\($0)" } }
            try materialize()
        }
        if next { try nextBuild(overlay, steps) }
        sayBuildNumber(overlay)
        if span.from <= .finalize, let end = build(overlay, steps) { return end }
        if signs { return macos ? try shipMac(overlay, steps) : ship(overlay, steps) }
        return stoppedEarly(span)
    }

    private func stoppedEarly(_ span: RunSpan) -> Int32 {
        host.say("==> TestFlight: stopped after \(span.to.name) (--to), nothing delivered")
        return 0
    }

    // MARK: - Mounts

    private func findMount(_ overlay: inout Overlay) {
        overlay.mounted = overlay.source
        let answer = ask(["git", "-C", overlay.source, "rev-parse", "--show-toplevel"], quiet: true)
        let top = answer.output.utf8.last == UInt8(ascii: "\n") ? String(decoding: answer.output.utf8.dropLast(), as: UTF8.self) : answer.output
        guard answer.code == 0, !top.isEmpty, let source = host.realPath(overlay.source), let checkout = host.realPath(top),
              let below = RunText.value(of: "\(checkout)/", in: source) else { return }
        overlay.mounted = checkout
        overlay.below = "/\(below)"
    }

    /// The overlay's directory, the source and the path inputs are mounted into the container that runs the app's build code, or
    /// readable in its sandbox: no secret may live below them.
    private func checkMounts(_ overlay: Overlay) throws -> [(name: String, path: String)] {
        let opened = docker ? "mounted into the build container" : "readable to the app's build code"
        let config = try files.real(overlay.directory), source = try files.real(overlay.mounted)
        // Both are opened whole: never the file system root, the home directory or a directory above it.
        for directory in [config, source] where try files.isBroad(directory) {
            throw RunStop.usage("\(directory) would be \(opened), and it is / or holds your home directory; keep the overlay in its own directory and point source: at the app's checkout")
        }
        let secretFiles = secretFiles()
        for (name, path) in secretFiles {
            if try files.file(path, isIn: config) {
                throw RunStop.usage("\(name) (\(path)) is inside the overlay's directory \(config), which is \(opened); keep the overlay in its own directory, away from secrets")
            }
            if try files.file(path, isIn: source) {
                throw RunStop.usage("\(name) (\(path)) is inside the app source \(source), which is \(opened); keep secrets out of the source")
            }
        }
        // A cargo overlay's path inputs are mounted into step 2, the container that runs the app's build code: the same rules.
        // (Only when step 2 runs; the host's xless lists them.)
        guard overlay.isCargo, overlay.span.from <= .finalize else { return [] }
        let answer = ask([xself, "cargo", "inputs", "--config", overlay.path, "--source", overlay.source])
        guard answer.code == 0 else { throw RunStop.usage("cannot list the path inputs of \(overlay.path) (\"\(xself)\" cargo inputs failed)") }
        var inputs: [(name: String, path: String)] = []
        for line in RunText.lines(answer.output) {
            let parts = RunText.cut(line, at: "\t", max: 1, keepingEmpty: true)
            let name = parts[0], path = parts.count > 1 ? parts[1] : ""
            if name.isEmpty { continue }
            guard name.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil, name != ".", name != ".." else {
                throw RunStop.usage("the path input '\(name)' has a name that cannot be a mount point")
            }
            guard RunText.isAbsolute(path), FileManager.default.fileExists(atPath: path) else { throw RunStop.usage("the path input '\(name)' (\(path)) does not exist") }
            guard try !files.isBroad(path) else {
                throw RunStop.usage("the path input '\(name)' (\(path)) would be \(opened), and it is / or holds your home directory; point it at the folder the build needs")
            }
            for (variable, file) in secretFiles where try files.file(file, isOrIsIn: path) {
                throw RunStop.usage("\(variable) (\(file)) is inside the path input '\(name)' (\(path)), which is \(opened); keep secrets out of the path inputs")
            }
            inputs.append((name, path))
        }
        return inputs
    }

    // MARK: - The steps' images, caches and arguments

    private func nativeSteps(_ overlay: Overlay) -> Steps {
        // --source only when XLESS_SOURCE overrides the overlay's own `source:`
        Steps(arguments: ["--config", overlay.path] + (setting("XLESS_SOURCE") == nil ? [] : ["--source", overlay.source]))
    }

    private func dockerSteps(_ overlay: Overlay, _ inputs: [(name: String, path: String)], _ top: RunTop, next: Bool) throws -> Steps {
        var steps = Steps()
        steps.mounts = ["--mount", RunText.bind(overlay.mounted, "/source", readOnly: true), "--mount", RunText.bind(overlay.directory, "/config", readOnly: true)]
        steps.arguments = ["--config", "/config/\(RunFiles.name(overlay.path))", "--source", "/source\(overlay.below)"]
        if overlay.isReactNative {
            // One work volume per overlay file: its name, and a hash of its path (two overlays never share a work copy). A volume,
            // not a host folder: the build needs a case-sensitive file system.
            let volume = setting("XLESS_RN_WORK_VOLUME") ?? "xless-rn-work-\(volumeName(overlay.stem))-\(RunText.sha256(overlay.path).prefix(8))"
            steps.workVolume = volume
            steps.buildCaches = ["-v", "\(volume):/cache/work", "-v", "xless-corepack:/cache/corepack", "-v", "xless-bundle:/cache/bundle",
                                 "-v", "xless-cocoapods-home:/root/.cocoapods", "-v", "xless-cocoapods-cache:/root/Library/Caches/CocoaPods",
                                 "-e", "XLESS_WORK_VOLUME=\(volume)"] + (setting("XLESS_RN_CLEAN") == nil ? [] : ["-e", "XLESS_RN_CLEAN"])
            // xless's own image sets no work root: the work copy is where step 2 left it
            steps.signCaches = ["-v", "\(volume):/cache/work", "-e", "XLESS_WORK_ROOT=/cache/work", "-e", "XLESS_WORK_VOLUME=\(volume)"]
            host.say("==> React Native: work volume \(volume)")
        } else {
            let cache = "\(files.home)/.cache/xless"
            steps.cache = cache
            if !dryRun {
                for name in ["work", "downloads"] + (overlay.isCargo ? ["inputs"] : []) {
                    try FileManager.default.createDirectory(atPath: "\(cache)/\(name)", withIntermediateDirectories: true)
                }
            }
            steps.buildCaches = ["--mount", RunText.bind("\(cache)/work", "/cache/work"), "--mount", RunText.bind("\(cache)/downloads", "/cache/downloads"),
                                 "-e", "XLESS_CACHE=/cache", "-v", "xless-rustup:/cache/rustup", "-v", "xless-cargo:/cache/cargo"]
            if overlay.isCargo { // the checkouts of git inputs, and the overlay's path inputs
                steps.buildCaches += ["--mount", RunText.bind("\(cache)/inputs", "/cache/inputs")]
                for input in inputs { steps.buildCaches += ["--mount", RunText.bind(input.path, "/inputs/\(input.name)", readOnly: true)] }
                steps.buildCaches += ["-e", "XLESS_INPUTS_MOUNTED=1"]
            }
            steps.signCaches = ["--mount", RunText.bind("\(cache)/work", "/cache/work")]
        }
        steps.signCaches += origin(overlay.path)
        // A simulator build is step 2 only.
        steps.images = try chooseImages(top, kit: Kit(overlayType: top["type"]), builds: overlay.span.from <= .finalize, other: next || overlay.span.to >= .sign,
                                        signImage: overlay.isReactNative && !overlay.isSimulator)
        return steps
    }

    /// The name as a volume's may be spelled. (By characters on macOS, by bytes elsewhere, as tr does it: a name that moved would
    /// lose the work copy.)
    private func volumeName(_ name: String) -> String {
        func keeps(_ c: Unicode.Scalar) -> Bool { c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || "_.-".unicodeScalars.contains(c)) }
        let units = host.isMac ? Array(name.unicodeScalars) : name.utf8.map { Unicode.Scalar($0) }
        return String(String.UnicodeScalarView(units.map { keeps($0) ? $0 : "-" }))
    }

    /// The work copy all three steps share: the overlay's name under xless's work root (the cache's, in docker), or the React
    /// Native build's work volume.
    private func workCopy(_ overlay: Overlay, _ steps: Steps) throws -> String {
        if docker, overlay.isReactNative { return "docker volume \(steps.workVolume)" }
        let root = docker ? "\(steps.cache)/work" : files.expanded(setting("XLESS_WORK_ROOT") ?? "\(files.home)/.cache/xless/work")
        if !dryRun {
            do { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true) } catch { throw RunStop.usage("cannot create the work root \(root)") }
        }
        let copy = "\(host.realPath(root) ?? root)/\(overlay.stem)" // created as xless would, its links resolved: one spelling only
        guard host.isMac, let there = host.realPath(copy) else { return copy }
        return there // also where the name is written in another case than the directory's
    }

    // MARK: - The steps

    private var buildNumberWords: [String] { setting("XLESS_BUILD_NUMBER") == nil ? [] : ["-e", "XLESS_BUILD_NUMBER"] }

    /// Step 1: the build number (App Store Connect, read-only).
    private func nextBuild(_ overlay: Overlay, _ steps: Steps) throws {
        let command = overlay.isReactNative || overlay.isCargo ? ["next-build"] : ["tauri", "next-build"]
        host.say("==> TestFlight: step 1/3, next build number (App Store Connect, read-only)")
        let words = docker ? dockerRun + steps.mounts + secrets.api + storeMounts("next") + [steps.images.secrets.reference, "xless"] + command + steps.arguments
            : [xself] + command + steps.arguments
        let result = step(words, docker ? .identifiers : .everything, told: !docker, output: .captured)
        if dryRun {
            environment["XLESS_BUILD_NUMBER"] = "<next-build>"
            return
        }
        cleanup.dropSecrets("next") // step 1's copy of the key: done with
        if result.code != 0 { throw RunStop(code: finished(result.code)) }
        let number = RunText.lines(result.output).last ?? ""
        guard number.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil else { throw RunStop.usage("xless \(command.joined(separator: " ")) printed '\(number)', not a build number") }
        environment["XLESS_BUILD_NUMBER"] = number
    }

    private func sayBuildNumber(_ overlay: Overlay) {
        if let number = setting("XLESS_BUILD_NUMBER") { host.say("==> TestFlight: build number \(number)") }
        else if overlay.span.buildNumberGiven { host.say("==> TestFlight: build number from --build-number") }
        else if request.platform == .macos { host.say("==> DMG: build number chosen from the clock when the run starts") }
        else if overlay.isSimulator { host.say("==> Simulator: build number chosen from the clock when the run starts") }
        else { host.say("==> TestFlight: build number recorded in the work copy") }
    }

    private func shipWords(_ steps: Steps, _ more: [String], from: RunStage, to: RunStage, _ span: RunSpan) -> [String] {
        ["ship", "--platform", request.platform == .macos ? "macos" : "ios"] + steps.arguments + more + ["--from", from.name, "--to", to.name] + span.extra
    }

    /// Step 2: the build, with no secret in reach. The exit code of a run that ends with it.
    private func build(_ overlay: Overlay, _ steps: Steps) -> Int32? {
        let span = overlay.span, to = min(span.to, .finalize), simulator = overlay.isSimulator
        host.say(simulator ? "==> Simulator: \(span.from.name) to \(to.name) (no secrets)" : "==> TestFlight: step 2/3, \(span.from.name) to \(to.name) (no secrets)")
        let ship = shipWords(steps, simulator ? ["--destination", "simulator"] : [], from: span.from, to: to, span)
        let output: RunStep.Output = simulator ? .both : .shown
        let result: (code: Int32, output: String)
        if docker {
            result = step(dockerRun + steps.mounts + steps.buildCaches + ["-e", "XLESS_SOURCE_ORIGIN=\(overlay.source)"] + buildNumberWords + [steps.images.build.reference, "xless"] + ship, .nothing, output: output)
        } else {
            // without the secret variables (xless also scrubs them from its tools; the files stay on disk), without what a session
            // holds, and with the secret store closed to it
            let names = SecretEnvironment.names + secrets.demoNames.flatMap { [$0, "\($0)_FILE"] } + [ChildProcess.session]
            let command = [xself] + ship
            result = step(command, .nothing, output: output, shown: ["env"] + names.flatMap { ["-u", $0] } + ["XLESS_NO_SECRET_STORE=1"] + command, adding: ["XLESS_NO_SECRET_STORE": "1"])
        }
        if result.code != 0 { return finished(result.code) }
        guard simulator else { return nil }
        if span.to == .build, !dryRun {
            var app = TerminalText.escaped(last(of: result.output, ".app")) // what the build called it
            if docker { app = "volume:\(steps.workVolume):\(app)" }
            host.say("==> Simulator app: \(app)")
            if host.isMac { host.say("==> launch it on this Mac: scripts/sim-launch.sh \(RunText.quoted(app))") }
        }
        host.say("==> Simulator build finished (nothing signed for distribution or uploaded)")
        return 0
    }

    private func last(of output: String, _ suffix: String) -> String { RunText.lines(output).last { $0.hasSuffix(suffix) } ?? "" }

    /// Step 3: sign, package, upload with the secrets; no build code runs here.
    private func saySigning(_ span: RunSpan) -> RunStage {
        let from = max(span.from, .sign)
        host.say("==> TestFlight: step 3/3, \(from.name) to \(span.to.name)")
        return from
    }

    private func signStep(_ steps: Steps, _ ship: [String], _ keys: [String], output: RunStep.Output = .shown) -> (code: Int32, output: String) {
        docker ? step(dockerRun + steps.mounts + steps.signCaches + secrets.api + keys + buildNumberWords + [steps.images.secrets.reference, "xless"] + ship, .identifiers, output: output)
            : step([xself] + ship, .everything, told: true, output: output)
    }

    private func ship(_ overlay: Overlay, _ steps: Steps) -> Int32 {
        let from = saySigning(overlay.span)
        return finished(signStep(steps, shipWords(steps, [], from: from, to: overlay.span.to, overlay.span), secrets.sign + storeMounts("sign")).code)
    }

    /// Macs ship two channels in one run, each signing its own copy of the built app: sign to package is the Developer ID DMG; sign
    /// to upload under --distribution app-store is the flat package that App Store Connect receives and TestFlight delivers. A
    /// failure in either stops the run with that one's code.
    private func shipMac(_ overlay: Overlay, _ steps: Steps) throws -> Int32 {
        let span = overlay.span, uploads = span.to >= .upload
        let from = saySigning(span)
        func show(_ kind: String, _ path: String) {
            let shown = docker ? RunText.value(of: "/cache/work", in: path).map { "\(steps.cache)/work\($0)" } ?? path : path
            host.say("==> \(kind): \(shown)")
        }
        let first = signStep(steps, shipWords(steps, [], from: from, to: min(span.to, .package), span), secrets.sign + storeMounts("sign"), output: .both)
        if !dryRun {
            try require(first.code)
            cleanup.dropSecrets("sign")
            show("DMG", last(of: first.output, ".dmg"))
            if !docker { host.say("==> DMG build finished") }
        }
        if uploads {
            let second = signStep(steps, ["ship", "--platform", "macos"] + steps.arguments + ["--distribution", "app-store", "--from", "sign", "--to", "upload"] + span.extra,
                                  secrets.appStore + storeMounts("appstore"), output: .both)
            if !dryRun {
                try require(second.code, " (the TestFlight upload)")
                show("PKG", last(of: second.output, ".pkg"))
            }
        }
        if dryRun { return stoppedEarly(span) }
        if docker { host.say("==> DMG build finished") }
        return 0
    }
}
