import Foundation
import XlessCore

/// Where each secret of a run comes from: NAME_FILE (of the environment or the env file), as does NAME itself natively; else the
/// encrypted secret store (`xless secrets`): natively xless reads it itself, and in docker the host's xless writes what each
/// container needs to a tmpfs first.
struct RunSecrets {
    /// The steps that need some.
    struct Needs {
        /// Step 1 asks App Store Connect for a build number.
        var next: Bool
        /// Step 3 runs (or the project's one ship, past finalize).
        var signs: Bool
        /// The run reaches upload.
        var uploads: Bool
        /// The macOS App Store lane.
        var lane = false
    }

    var needs = Needs(next: false, signs: false, uploads: false)
    /// The App Store Connect key and its IDs come from the store. (They come from one place.)
    var storeHasAPI = false
    /// The signing keys the store gives.
    var storeKeys: [String] = []
    /// The TestFlight demo account's password, under the name the configuration has for it: only the upload reads it.
    var demoNames: [String] = []
    var demoFiles: [String] = []
    var demoStore: [String] = []
    /// What the store gives, per container: `next` (step 1), `sign` (step 3, the project's one container, or the DMG ship) and
    /// `appstore` (the macOS App Store ship). `?NAME`: only when the store has it.
    var sets: [Set] = []
    var team: [String] = []

    struct Set: Equatable {
        let name: String
        var names: [String]
        var text: String { "\(name)=\(names.joined(separator: ","))" }
    }

    // In docker: the words that give a container the files.
    var api: [String] = []
    var sign: [String] = []
    var appStore: [String] = []
    /// Where the store's secrets were written.
    var directory = ""
}

extension ProjectRun {
    /// Every secret the run needs has its place, or the run stops here, before anything runs.
    func findSecrets(_ needs: RunSecrets.Needs, top: RunTop) throws {
        secrets.needs = needs
        let macos = request.platform == .macos
        // The first ship's key (Apple Distribution on iOS, Developer ID for the DMG), and those of the macOS App Store lane: the
        // app's signature, and the flat package's. Only a run that uploads needs them in reach.
        let signKeys = needs.signs ? [macos ? "XLESS_DEVID_KEY" : "XLESS_DIST_KEY"] : []
        let laneKeys = needs.lane ? ["XLESS_DIST_KEY", "XLESS_INSTALLER_KEY"] : []
        if needs.next || needs.signs { try findAPIKey() }
        for key in signKeys + laneKeys {
            if setting("\(key)_FILE") != nil { try makeAbsolute("\(key)_FILE") }
            else if docker || setting(key) == nil { secrets.storeKeys.append(key) }
        }
        // In docker a secret's value itself (NAME, not NAME_FILE) is never passed into a container: the store's is used.
        if docker {
            for name in (secrets.storeHasAPI ? ["ASC_KEY_P8"] : []) + secrets.storeKeys where setting(name) != nil {
                host.say("==> note: \(name) is set, but docker builds take only \(name)_FILE (a file to mount); using the secret store's \(name)")
            }
        }
        if needs.uploads { findDemoPassword() }
        try sortDemoPasswords()

        // The store prefers the project's team (its top-level teamID:).
        func add(_ set: String, _ keys: [String]) {
            let names = (secrets.storeHasAPI ? ["ASC_KEY_P8", "ASC_KEY_ID", "ASC_ISSUER_ID"] : []) + keys.filter { $0.hasPrefix("?") || secrets.storeKeys.contains($0) }
            if !names.isEmpty { secrets.sets.append(.init(name: set, names: names)) }
        }
        if needs.next { add("next", []) }
        if needs.signs { add("sign", signKeys + (macos ? [] : secrets.demoStore)) } // the demo password goes to the container that uploads
        if needs.lane { add("appstore", laneKeys + secrets.demoStore) }
        if let team = top["teamID"], team.wholeMatch(of: /[A-Z0-9]{10}/) != nil { secrets.team = ["--team", team] }
        if !secrets.sets.isEmpty, !has(xself), !dryRun {
            throw RunStop.usage("the secrets not set in the environment or \(environmentFile) come from the secret store, which xless on this host reads, and \"\(xself)\" is not on PATH: install xless (or set XLESS_SELF), or set the *_FILE variables (\(setTexts.joined(separator: " ")))")
        }
    }

    private var setTexts: [String] { secrets.sets.map(\.text) }

    private func findAPIKey() throws {
        if setting("ASC_KEY_P8_FILE") != nil || (!docker && setting("ASC_KEY_P8") != nil) {
            guard setting("ASC_KEY_ID") != nil else { throw RunStop.usage("set ASC_KEY_ID in the environment or \(environmentFile)") }
            guard setting("ASC_ISSUER_ID_FILE") != nil || setting("ASC_ISSUER_ID") != nil else {
                throw RunStop.usage("set ASC_ISSUER_ID_FILE (or ASC_ISSUER_ID) in the environment or \(environmentFile)")
            }
            for name in ["ASC_KEY_P8_FILE", "ASC_ISSUER_ID_FILE"] where setting(name) != nil { try makeAbsolute(name) }
        } else if ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_ISSUER_ID_FILE"].contains(where: { setting($0) != nil }) {
            throw RunStop.usage("ASC_KEY_ID or ASC_ISSUER_ID is set, but not ASC_KEY_P8_FILE: set ASC_KEY_P8_FILE in the environment or \(environmentFile), or unset the IDs to use the App Store Connect key of the secret store (xless secrets), which carries its IDs")
        } else { secrets.storeHasAPI = true }
    }

    /// A secret's file: readable, and its path in full (docker needs that).
    private func makeAbsolute(_ name: String) throws {
        let path = environment[name] ?? ""
        guard host.isReadable(path) else { throw RunStop.usage("\(name) points to a file that does not exist or is unreadable") }
        if !path.hasPrefix("/") { environment[name] = files.absolute(path) }
    }

    /// Which secret holds the TestFlight demo account's password: the host's xless reads the configuration (nothing when the
    /// account never needs its password sent).
    private func findDemoPassword() {
        guard has(xself) else {
            if setting("XLESS_DEMO_PASSWORD_FILE") != nil { secrets.demoNames = ["XLESS_DEMO_PASSWORD"] } // the default name, set as a file
            return
        }
        let what: [String] = switch request.target {
        case .overlay: ["--config", pinFile, "--platform", request.platform == .macos ? "macos" : "ios"]
        case .project: ["--project", RunFiles.parent(pinFile)]
        }
        let answer = ask([xself, "secrets", "named-by"] + what, quiet: true)
        // (an answer that is not names, as from an xless too old to know the command, counts as none)
        let names = answer.output.split(separator: "\n").map(String.init)
        if answer.code == 0, names.allSatisfy({ $0.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*(@[A-Z0-9]{10})?/) != nil }) {
            secrets.demoNames = names
        } else {
            let end = docker ? "it is given to no container" : "xless reads it itself when it uploads"
            host.say("==> note: \"\(xself)\" secrets named-by could not tell which secret holds the TestFlight demo account's password: \(end) (xless says what is wrong when it reads the configuration)")
        }
    }

    /// From NAME_FILE when set, else, in docker, from the store as an optional secret: Apple never gives the password back, so it
    /// is sent only when the demo account is new, renamed or newly required, and a store without it stops nothing up front.
    /// Natively xless reads it itself; the build step runs without NAME and NAME_FILE.
    private func sortDemoPasswords() throws {
        for name in secrets.demoNames {
            // (from the environment only for upper-case names: never one of the system's or of a tool's)
            let isVariable = name.wholeMatch(of: /[A-Z][A-Z0-9_]*/) != nil && name != "ENV"
            if isVariable, setting("\(name)_FILE") != nil {
                try makeAbsolute("\(name)_FILE")
                secrets.demoFiles.append(name)
            } else if docker {
                if isVariable, setting(name) != nil {
                    host.say("==> note: \(name) is set, but docker builds take only \(name)_FILE (a file to mount); using the secret store's \(name)")
                }
                secrets.demoStore.append("?\(name)")
            }
        }
    }

    /// The files of secrets, as variables name them: none may be in what a build container mounts.
    func secretFiles() -> [(variable: String, path: String)] {
        let variables = ["ASC_KEY_P8_FILE", "XLESS_DIST_KEY_FILE", "XLESS_DEVID_KEY_FILE", "XLESS_INSTALLER_KEY_FILE", "ASC_ISSUER_ID_FILE"] + secrets.demoFiles.map { "\($0)_FILE" }
        return ([("ENV_FILE", environmentFile)] + variables.compactMap { name in setting(name).map { (name, $0) } })
            .filter { FileManager.default.fileExists(atPath: $0.1) }
    }

    /// Docker: the mounts of the secret files. By path or by name: values never appear on a command line.
    func mountFiles(platform: Platform) throws {
        func file(_ variable: String, _ destination: String) -> [String] {
            setting(variable).map { ["--mount", RunText.bind($0, destination, readOnly: true), "-e", "\(variable)=\(destination)"] } ?? []
        }
        if secrets.needs.next || secrets.needs.signs, !secrets.storeHasAPI {
            secrets.api = ["--mount", RunText.bind(environment["ASC_KEY_P8_FILE"] ?? "", "/secrets/asc.p8", readOnly: true), "-e", "ASC_KEY_ID", "-e", "ASC_KEY_P8_FILE=/secrets/asc.p8"]
            let issuer = file("ASC_ISSUER_ID_FILE", "/secrets/asc-issuer-id")
            secrets.api += issuer.isEmpty ? ["-e", "ASC_ISSUER_ID"] : issuer // by name: the value never appears in the process list
        }
        let demo = secrets.demoFiles.flatMap { file("\($0)_FILE", "/secrets/passwords/\($0)") }
        if platform == .macos {
            if secrets.needs.signs { secrets.sign = file("XLESS_DEVID_KEY_FILE", "/secrets/devid-key.pem") }
            // The App Store lane's keys: only the second ship takes them, and only a run that reaches it has them.
            if secrets.needs.lane {
                secrets.appStore = file("XLESS_DIST_KEY_FILE", "/secrets/dist-key.pem") + file("XLESS_INSTALLER_KEY_FILE", "/secrets/installer-key.pem")
            }
            secrets.appStore += demo
        } else {
            if secrets.needs.signs { secrets.sign = file("XLESS_DIST_KEY_FILE", "/secrets/dist-key.pem") }
            secrets.sign += demo
        }
    }

    // MARK: - The store

    /// Natively each step's xless reads the store itself. Checked now, without the passphrase: that it holds them all, not after
    /// the build. Then the passphrase is asked, once, for all of them: the run starts again inside `xless session`, which drops
    /// the unlock when it ends. The build (step 2, and the tools of every step) is outside: its xless does not look for an
    /// unlock, and its tools are in POSIX sessions of their own, which the session's agent refuses.
    func unlockStore() throws {
        guard !secrets.sets.isEmpty else { return }
        let code = step([xself, "secrets", "materialize", "--check"] + secrets.team + setTexts, .nothing).code
        guard code == 0 else { throw RunStop(code: code) }
        var needed: [String] = []
        for name in secrets.sets.flatMap(\.names) where !name.hasPrefix("?") && !needed.contains(name) { needed.append(name) }
        guard !context.unlocked, context.session == nil, !needed.isEmpty, !dryRun else { return }
        cleanup.finish()
        let words = [xself, "session", "--if-possible", "--purpose", "xless run", "--reason", "reading \(needed.joined(separator: ", "))", "--"] + context.again
        let why = host.become(words, environment: context.environment.merging(["XLESS_RUN_UNLOCKED": "1"]) { $1 })
        throw RunStop(code: 127, message: "testflight: cannot run \(xself): \(why)")
    }

    /// Docker: the store's secrets, written once for the whole run (one passphrase) by the host's xless into a fresh
    /// $XDG_RUNTIME_DIR/xless/<random>/ (a tmpfs; anywhere else only with --allow-disk-secrets), one directory per container, each
    /// mounted read-only at /secrets/store into its container only and removed when that container ends; whatever is left goes
    /// when the run ends, on an error and when it is stopped. After every check that could still stop the run.
    func materialize() throws {
        guard !secrets.sets.isEmpty else { return }
        if !dryRun {
            try dropMissingOptional()
            guard !secrets.sets.isEmpty else { return }
        }
        let words = [xself, "secrets", "materialize"] + secrets.team + (request.allowDisk ? ["--allow-disk"] : []) + setTexts
        if dryRun {
            step(words, .nothing)
            secrets.directory = "$XDG_RUNTIME_DIR/xless/<run>"
            return
        }
        // Where xless will put them (SecretRunBase): refused before anything is written when a build mount holds it.
        let base: String
        if let runtime = setting("XDG_RUNTIME_DIR"), runtime.hasPrefix("/"), files.isDirectory(runtime) { base = "\(runtime)/xless" }
        else if let cache = setting("XDG_CACHE_HOME"), cache.hasPrefix("/") { base = "\(cache)/xless/secrets" }
        else { base = "\(files.home)/.cache/xless/secrets" }
        try refuseInBuildMounts(base)
        host.say("==> secrets from the secret store: \(setTexts.joined(separator: " "))")
        let file = try temporaryFile()
        cleanup.change { $0.secretsFile = file }
        // Recorded in the work copy's lock first: a run that takes the lock over after a SIGKILL removes what this wrote.
        lock?.note("secrets_out=\(file)")
        let code = step(words, .nothing, told: true, output: .file(file)).code
        let directory = RunCleanup.firstLine(file) ?? ""
        cleanup.change { $0.secrets = directory }
        try require(code, " (the secret store)")
        guard RunText.isSecretsDirectory(directory), files.isDirectory(directory) else {
            throw RunStop.usage("\"\(xself)\" secrets materialize printed '\(directory)', not a run directory")
        }
        try refuseInBuildMounts(directory)
        secrets.directory = directory
    }

    func temporaryFile() throws -> String {
        try cleanup.change { state in
            let file = try host.temporaryFile()
            state.temporary.append(file)
            return file
        }
    }

    private func sayMissing(_ name: String) {
        host.say("==> note: the secret store has no \(name): a run that must send the TestFlight demo account's password stops at upload (store it with: xless secrets import \(name) --file <file> --kind password, or set \(name)_FILE)")
    }

    /// The optional secrets (the demo password) that the store does not have leave the sets, asked by name first (`materialize
    /// --check` prints those it has; no passphrase). A run whose other secrets are all files then opens the store, and needs a
    /// tmpfs, only when the store has the password.
    private func dropMissingOptional() throws {
        let all = secrets.sets.flatMap(\.names)
        guard all.contains(where: { $0.hasPrefix("?") }) else { return }
        let answer = ask([xself, "secrets", "materialize", "--check"] + secrets.team + setTexts)
        if !all.allSatisfy({ $0.hasPrefix("?") }) { try require(answer.code, " (the secret store)") }
        // (only optional ones: a store that cannot be read gives none of them)
        let found = answer.code == 0 ? answer.output.split(separator: "\n").map(String.init) : []
        secrets.sets = secrets.sets.compactMap { set in
            var kept = set
            kept.names.removeAll { name in
                guard name.hasPrefix("?"), !found.contains(String(name.dropFirst())) else { return false }
                sayMissing(String(name.dropFirst()))
                return true
            }
            return kept.names.isEmpty ? nil : kept
        }
    }

    /// The words that give a container its set: the read-only mount, and NAME_FILE=/secrets/store/NAME for each secret in it.
    func storeMounts(_ name: String) -> [String] {
        guard !secrets.directory.isEmpty, let set = secrets.sets.first(where: { $0.name == name }) else { return [] }
        var words = ["--mount", RunText.bind("\(secrets.directory)/\(name)", "/secrets/store", readOnly: true)]
        for var secret in set.names {
            if secret.hasPrefix("?") { // optional: passed only when the store had it
                secret.removeFirst()
                if !dryRun, !files.isFile("\(secrets.directory)/\(name)/\(secret)") {
                    sayMissing(secret)
                    continue
                }
            }
            words += ["-e", "\(secret)_FILE=/secrets/store/\(secret)"]
        }
        return words
    }

    /// Neither `path` (or, while it does not exist, its nearest parent) nor a parent of it is mounted into the build.
    private func refuseInBuildMounts(_ path: String) throws {
        var here = path
        while !FileManager.default.fileExists(atPath: here), here != "/" { here = RunFiles.parent(here) }
        for mount in buildMounts where FileManager.default.fileExists(atPath: mount) && files.directory(here, isIn: mount) {
            throw RunStop.usage("the secret store's files (\(path)) would be inside \(mount), which is mounted into the build container; point XDG_RUNTIME_DIR elsewhere")
        }
    }
}
