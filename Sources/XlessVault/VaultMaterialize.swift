import Foundation
import XlessCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One container's secrets for `xless secrets materialize` (scripts/testflight.sh): `sign=ASC_KEY_P8,XLESS_DIST_KEY`
/// becomes `<run dir>/sign/ASC_KEY_P8` and `<run dir>/sign/XLESS_DIST_KEY`, mounted into that container only.
public struct MaterializeSet: Sendable, Equatable {
    public let name: String
    public let secrets: [String]

    public init(name: String, secrets: [String]) {
        self.name = name
        self.secrets = secrets
    }

    /// `NAME=SECRET[,SECRET…]`: a lower-case set name, then secrets of `SecretEnvironment` (not their `_FILE` forms).
    public static func parse(_ text: String) throws -> MaterializeSet {
        let parts = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].wholeMatch(of: /[a-z0-9][a-z0-9-]{0,31}/) != nil else {
            throw XlessError(.config, "'\(text)' is not a set of secrets", fix: "write SET=NAME[,NAME…], e.g. sign=ASC_KEY_P8,XLESS_DIST_KEY")
        }
        let names = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw XlessError(.config, "the set \(parts[0]) names no secret", fix: "write \(parts[0])=NAME[,NAME…]") }
        let known = SecretEnvironment.entries.map(\.name)
        for name in names where !known.contains(name) {
            throw XlessError(.config, "\(name) is not a secret xless reads", fix: "use one of: \(known.joined(separator: ", "))")
        }
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        return MaterializeSet(name: parts[0], secrets: unique)
    }
}

extension MaterializeSet {
    /// Each set's name once (each is its own directory).
    public static func requireDistinct(_ sets: [MaterializeSet]) throws {
        var seen: Set<String> = []
        for set in sets where !seen.insert(set.name).inserted {
            throw XlessError(.config, "the set \(set.name) is given twice", fix: "name each set once, with all its secrets: \(set.name)=A,B")
        }
    }
}

/// Where a run's materialised secrets go: `$XDG_RUNTIME_DIR/xless` (a tmpfs on systemd hosts, never written to disk).
/// Anywhere else (no XDG_RUNTIME_DIR, or one on a disk) is refused unless the user allows disk secrets.
public enum SecretRunBase {
    public static func choose(env: [String: String] = ProcessInfo.processInfo.environment, allowDisk: Bool,
                              isMemory: (String) -> Bool = isMemoryFileSystem) throws -> URL {
        let allow = "or pass --allow-disk-secrets (xless run --allow-disk-secrets …) to accept them on disk for the run's length"
        if let runtime = env["XDG_RUNTIME_DIR"], runtime.hasPrefix("/"), isDirectory(runtime) {
            guard allowDisk || isMemory(runtime) else {
                throw XlessError(.config, "XDG_RUNTIME_DIR (\(runtime)) is not a memory file system (tmpfs): the run's secrets would be written to disk",
                                 fix: "point XDG_RUNTIME_DIR at a tmpfs (systemd's /run/user/<uid>), \(allow)")
            }
            return URL(fileURLWithPath: runtime, isDirectory: true).appendingPathComponent("xless", isDirectory: true)
        }
        guard allowDisk else {
            let why = env["XDG_RUNTIME_DIR"].map { $0.isEmpty ? "is empty" : $0.hasPrefix("/") ? "(\($0)) is not a directory" : "(\($0)) is not an absolute path" } ?? "is not set"
            throw XlessError(.config, "XDG_RUNTIME_DIR \(why): there is no memory file system (tmpfs) for the run's secrets",
                             fix: "run on a host that sets it (systemd: /run/user/<uid>), set *_FILE variables yourself, \(allow)")
        }
        // Under the home directory: the one place Colima and Docker Desktop share with their VM by default.
        let cache: URL
        if let xdg = env["XDG_CACHE_HOME"], xdg.hasPrefix("/") {
            cache = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            cache = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cache", isDirectory: true)
        }
        return cache.appendingPathComponent("xless/secrets", isDirectory: true)
    }

    /// tmpfs or ramfs (Linux `statfs`); false anywhere else, and on macOS (no tmpfs there by default).
    public static func isMemoryFileSystem(_ path: String) -> Bool {
        MemoryFileSystem.contains(path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Writes a run's secrets from the store into files for scripts/testflight.sh's containers: all of them at once (one
/// passphrase for the run), each set in its own 0700 directory of a fresh 0700 run directory, files 0600. Only the
/// store is read (the script handles the environment and `_FILE` variables); ASC_KEY_ID and ASC_ISSUER_ID are the
/// ASC_KEY_P8 entry's IDs. With a team, its entries are preferred (`VaultResolver.preferredCandidate`).
public struct VaultMaterializer {
    let store: any SecretStore
    let team: String?
    let resolver: any SecretFallback

    public init(secrets store: any SecretStore, team: String?) {
        self.store = store
        self.team = team
        let base = VaultResolver(secrets: store)
        resolver = team.map { base.preferring(team: $0) } ?? base
    }

    public init(store: VaultStore, team: String?, cache: (any VaultKeyCache)?, prompter: @escaping () -> (any PassphrasePrompter)?) {
        self.init(secrets: VaultSecretStore(store: store, cache: cache, prompter: prompter), team: team)
    }

    /// Every secret of `sets` has an entry (and the API key its IDs). Reads names and IDs only: no passphrase.
    public func check(_ sets: [MaterializeSet]) throws {
        let file: SecretCatalog?
        do { file = try store.catalog() } catch let e as VaultError { throw e.stageError(.config) }
        for name in Self.names(sets) {
            let entryName = VaultResolver.metadataField(name) == nil ? name : "ASC_KEY_P8"
            let entry: VaultEntry?
            do {
                entry = try file.flatMap { f in
                    try team.map { try VaultResolver.preferredCandidate(for: entryName, in: f, team: $0) } ?? VaultResolver.candidate(for: entryName, in: f, team: nil)
                }
            } catch let e as VaultError { throw e.stageError(.config) }
            guard let entry, VaultResolver.metadataField(name).map({ $0(entry.metadata) != nil }) ?? true else {
                let whose = team.map { " for team \($0)" } ?? ""
                let place = file == nil ? "there is no secret store (\(store.place))" : "\(store.place) has no \(name)\(whose)"
                throw XlessError(.config, "\(place), and neither \(name) nor \(name)_FILE is set", fix: Secrets.missingFix(name))
            }
        }
    }

    /// Checks, unlocks once and reads every secret, then creates `<base>/<random>/` and its sets. `announce` gets the
    /// run directory as soon as it exists (before any file is written), so a caller stopped half-way knows what to
    /// remove. On a failure after that, the run directory is removed.
    public func write(_ sets: [MaterializeSet], base: URL, announce: (URL) -> Void) throws -> URL {
        try MaterializeSet.requireDistinct(sets)
        try check(sets)
        var values: [String: SecretBytes] = [:]
        defer { values.values.forEach { $0.wipe() } }
        for name in Self.names(sets) {
            guard let value = try resolver.lookup(name, stage: .config) else { throw XlessError(.config, "missing secret \(name)", fix: Secrets.missingFix(name)) }
            values[name] = SecretBytes(utf8: value)
        }
        try Self.prepare(base)
        let run = base.appendingPathComponent(Self.randomName(), isDirectory: true)
        guard mkdir(run.path, 0o700) == 0 else {
            throw XlessError(.config, "cannot create \(run.path): \(String(cString: strerror(errno)))", fix: "check \(base.path)")
        }
        announce(run)
        do {
            for set in sets {
                let dir = run.appendingPathComponent(set.name, isDirectory: true)
                guard mkdir(dir.path, 0o700) == 0 else {
                    throw XlessError(.config, "cannot create \(dir.path): \(String(cString: strerror(errno)))", fix: "check \(run.path)")
                }
                for name in set.secrets { try Self.writeFile(dir.appendingPathComponent(name).path, values[name]!) }
            }
        } catch {
            try? FileManager.default.removeItem(at: run)
            throw error
        }
        return run
    }

    static func names(_ sets: [MaterializeSet]) -> [String] {
        var all: [String] = []
        for name in sets.flatMap(\.secrets) where !all.contains(name) { all.append(name) }
        return all
    }

    /// The base directory: created 0700 when missing; a symlink, another owner or group/world access is refused.
    static func prepare(_ base: URL) throws {
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(base.path, 0o700) != 0, errno != EEXIST {
            throw XlessError(.config, "cannot create \(base.path): \(String(cString: strerror(errno)))", fix: "check the parent directory's permissions")
        }
        var st = stat()
        guard lstat(base.path, &st) == 0 else {
            throw XlessError(.config, "cannot inspect \(base.path): \(String(cString: strerror(errno)))", fix: "check the path")
        }
        do { try VaultLocation.check(st, path: base.path, directory: true) } catch let e as VaultError { throw e.stageError(.config) }
    }

    static func randomName() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    static func writeFile(_ path: String, _ bytes: SecretBytes) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw XlessError(.config, "cannot create \(path): \(String(cString: strerror(errno)))", fix: "check the run directory") }
        defer { close(fd) }
        let count = bytes.count
        var off = 0
        while off < count {
            let n = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + off, count - off) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw XlessError(.config, "cannot write \(path): \(String(cString: strerror(errno)))", fix: "check free space in the run directory") }
            off += n
        }
    }
}
