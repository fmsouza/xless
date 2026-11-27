import Foundation
import XlessCore

/// The Docker volumes that hold Xcode packs (`XcodePack`): one per pack, `xless-xcode-<version>-<build>-<arch>`. xless labels
/// the volumes it creates `org.xless.pack=true`, but a volume is a pack volume by its name alone (one made by hand,
/// `docker volume create <name>`, has no label), everywhere: setup, run and clean. A volume is a store of one pack: mounted at `/xcodes` (the image's `XLESS_XCODES`), it holds the
/// pack's directory, `/xcodes/<version>-<build>-<arch>`, and while a setup prepares it, that directory's `.partial`, `.old`
/// and `.lock` siblings (a pack is prepared beside its place and renamed into it, which cannot happen at a volume's root).
public struct PackVolumes {
    public static let prefix = "xless-xcode-"
    /// The label of the pack volumes xless creates (a volume made by hand has none: the listing goes by name).
    public static let label = "org.xless.pack"
    /// The line the reading container prints before each pack.json.
    static let marker = "--- xless pack"

    private let docker: LocalImages.Docker

    public init(_ docker: @escaping LocalImages.Docker) { self.docker = docker }

    /// "xless-xcode-26.2-17C52-arm64".
    public static func name(xcode: String, build: String, arch: String) -> String { prefix + XcodePack.name(xcode: xcode, build: build, arch: arch) }

    /// Where the pack named `packName` ("26.2-17C52-arm64") is in a container that mounts its store: "/xcodes/26.2-17C52-arm64".
    public static func mountPath(_ packName: String) -> String { "\(PackStore.root)/\(packName)" }

    /// The command that creates the volume `name`, labelled as a pack volume.
    public static func create(_ name: String) -> [String] { ["docker", "volume", "create", "--label", "\(label)=true", name] }

    /// The Xcode version, build and architecture of the pack volume `name`: `prefix`, then `<version>-<build>-<arch>` in the
    /// shape xless creates; nil for any other name (`xless-xcode-backup`, `xless-xcode-26.2-17C52-arm64-old`).
    public static func parse(_ name: String) -> (xcode: String, build: String, arch: String)? {
        guard name.hasPrefix(prefix),
              let m = String(name.dropFirst(prefix.count)).wholeMatch(of: /([0-9]+(?:\.[0-9]+)*)-([A-Za-z0-9]+)-(arm64|amd64)/) else { return nil }
        return (String(m.1), String(m.2), String(m.3))
    }

    /// The pack volumes of `arch` (`parse`), by name, labelled or not.
    public func names(arch: String) throws -> [String] {
        let answer = docker(["volume", "ls", "--format", "{{.Name}}"])
        guard answer.code == 0 else { throw ImageProblem("docker does not list its volumes (docker volume ls failed)", fix: "is it running?") }
        return Set(answer.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Self.parse($0)?.arch == arch }).sorted()
    }

    /// The manifests of the pack volumes of `arch`, read with one container of `image` (`cat /v/<i>/<pack name>/pack.json` per
    /// volume, each mounted read-only, no network). A volume without a pack.json, or whose pack.json is not that volume's pack,
    /// is absent from the result. No volume of `arch`: no container.
    public func manifests(arch: String, image: String) throws -> [PackManifest] {
        let volumes = try names(arch: arch)
        guard !volumes.isEmpty else { return [] }
        let packs = volumes.map { String($0.dropFirst(Self.prefix.count)) }
        var argv = ["run", "--rm", "--pull=never", "--platform", "linux/\(arch)", "--network", "none"]
        for (i, volume) in volumes.enumerated() { argv += ["--mount", "type=volume,src=\(volume),dst=/v/\(i),readonly"] }
        argv += [image, "sh", "-c", "for p in \"$@\"; do printf '\\n%s %s\\n' '\(Self.marker)' \"$p\"; cat \"$p\" 2>/dev/null; done; exit 0", "sh"]
        argv += packs.enumerated().map { "/v/\($0.offset)/\($0.element)/pack.json" }
        let answer = docker(argv)
        guard answer.code == 0 else {
            throw ImageProblem("the pack volumes (\(volumes.joined(separator: ", "))) cannot be read with a container of \(image)",
                               fix: "check that `docker run --rm \(image) true` works, then run xless setup again")
        }
        var found: [PackManifest] = [], pack: String?, text = ""
        func close() {
            defer { text = "" }
            guard let pack, let m = try? JSONDecoder().decode(PackManifest.self, from: Data(text.utf8)),
                  XcodePack.name(xcode: m.xcode, build: m.build, arch: m.arch) == pack else { return }
            found.append(m)
        }
        for line in answer.output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(Self.marker + " ") {
                close()
                let path = line.dropFirst(Self.marker.count + 1).split(separator: "/")
                pack = path.count >= 2 ? String(path[path.count - 2]) : nil
            } else { text += line + "\n" }
        }
        close()
        return found
    }
}

/// Where a --docker store of Xcode packs is.
public enum PackStore: Equatable, Sendable {
    /// One Docker volume per pack (`PackVolumes`).
    case volumes
    /// A directory of the host (`XLESS_XCODES`), which may hold several packs.
    case directory(URL)

    /// Where the store is in a container: the image's `XLESS_XCODES`.
    public static let root = "/xcodes"

    /// `XLESS_XCODES`, when set, names a directory of the host; else the packs are volumes.
    public init(env: [String: String]) {
        if let dir = env["XLESS_XCODES"], !dir.isEmpty { self = .directory(URL(fileURLWithPath: dir)) } else { self = .volumes }
    }

    /// docker's mount arguments for one pack. Writable (the setup container alone): its store at `/xcodes`, where a pack is
    /// prepared beside its place; a directory is mounted whole. Read-only (every container of a run): the pack is at
    /// `/xcodes/<name>` and is the only one there, in both kinds of store: a volume holds that pack alone and is mounted as
    /// the store, and of a directory, which may hold several, the pack's own directory alone is mounted there.
    public func mount(xcode: String, build: String, arch: String, writable: Bool) -> [String] {
        switch self {
        case .volumes:
            return ["--mount", Self.mountOption(["type": "volume", "src": PackVolumes.name(xcode: xcode, build: build, arch: arch), "dst": Self.root], readonly: !writable)]
        case let .directory(dir) where writable:
            return ["--mount", Self.mountOption(["type": "bind", "src": dir.path, "dst": Self.root], readonly: false)]
        case let .directory(dir):
            let name = XcodePack.name(xcode: xcode, build: build, arch: arch)
            return ["--mount", Self.mountOption(["type": "bind", "src": dir.appendingPathComponent(name).path, "dst": PackVolumes.mountPath(name)], readonly: true)]
        }
    }

    /// docker's `--mount` value: `type`, `src`, `dst` in that order, then `readonly`. docker reads it as CSV, so a field with a
    /// comma or a quote is quoted (its quotes doubled).
    public static func mountOption(_ fields: [String: String], readonly: Bool) -> String {
        var out = ["type", "src", "dst"].compactMap { key in
            fields[key].map { value -> String in
                let field = "\(key)=\(value)"
                return field.contains(",") || field.contains("\"") ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }
        }
        if readonly { out.append("readonly") }
        return out.joined(separator: ",")
    }
}

/// The container that prepares one pack: the image's own `xless setup` (a native setup there: xtool, rcodesign and the shims are
/// in the image, so it prepares both parts, `sdk` and `swift-build`), with the store mounted read-write and nothing of a
/// project, no secret and no variable of the host but the disk figures.
public enum PackSetup {
    /// The host's variables that go into the container: the disk figures its setup checks (an override on the host holds there).
    public static let passed = ["XLESS_SETUP_CACHE_GB", "XLESS_SETUP_NATIVE_GB"]

    /// Where the SDK export of the Xcode is in the container: where a setup with `XDG_CACHE_HOME=/cache` keeps it.
    public static func exportPath(xcode: String, build: String) -> String { "/cache/xless/sdk/xcode\(xcode)-\(build)" }

    /// What the pack is prepared from.
    public enum Source: Equatable, Sendable {
        /// An Xcode .xip or Xcode.app, mounted read-only at `/xcode/<name>`, whose SDK is exported into `export` (the host
        /// cache's directory of that Xcode, mounted read-write).
        case xcode(URL, name: String, export: URL)
        /// An SDK export, mounted read-only.
        case export(URL)
    }

    /// `docker run` of the image's `xless setup` for the pack of `xcode` (canonical version) and `build` on `arch`. `user`: the
    /// calling user's `uid:gid` (nil with rootless Docker, whose root is the calling user already). `environment`: the host's;
    /// only `passed` is read from it.
    public static func argv(image: String, arch: String, xcode: String, build: String, store: PackStore, source: Source, reexport: Bool,
                            user: String?, environment: [String: String]) -> [String] {
        var argv = ["docker", "run", "--rm", "--pull=never", "--platform", "linux/\(arch)"]
        if let user { argv += ["--user", user] }
        argv += ["-e", "HOME=/tmp"]
        let export = exportPath(xcode: xcode, build: build)
        let command: [String]
        switch source {
        case let .xcode(url, name, dir):
            argv += ["--mount", PackStore.mountOption(["type": "bind", "src": url.path, "dst": "/xcode/\(name)"], readonly: true)]
            argv += ["--mount", PackStore.mountOption(["type": "bind", "src": dir.path, "dst": export], readonly: false)]
            command = ["--xcode", "/xcode/\(name)"] + (reexport ? ["--reexport"] : [])
        case let .export(dir):
            argv += ["--mount", PackStore.mountOption(["type": "bind", "src": dir.path, "dst": export], readonly: true)]
            command = ["--sdk", export]
        }
        argv += ["-e", "XDG_CACHE_HOME=/cache"]
        for key in passed { if let v = environment[key], !v.isEmpty { argv += ["-e", "\(key)=\(v)"] } }
        argv += store.mount(xcode: xcode, build: build, arch: arch, writable: true)
        return argv + [image, "xless", "setup"] + command
    }
}

/// The running containers that use a pack, asked before it is prepared: preparing replaces it, and a build that has it mounted
/// would go on with a mix of the old pack and the new one (a volume's new files under the same paths), or with its directory
/// emptied under it (a directory store). Both `xless setup --docker` and a run that prepares a pack ask, and stop when any runs.
public struct PackUsers {
    private let docker: LocalImages.Docker

    public init(_ docker: @escaping LocalImages.Docker) { self.docker = docker }

    /// The label every container of a run carries (`xless.run=<pid>.<time>`).
    public static let runLabel = "xless.run"

    /// "<name> (<image>)" of each running container that has the pack of `xcode` (canonical version), `build` and `arch` mounted,
    /// but for those of the run `excludingRun` (its `xless.run` label's value). A volume: `docker ps --filter volume=<name>`. A
    /// directory store: `docker ps -q`, then one `docker inspect` of those containers' mounts; one that mounts the pack's
    /// directory, the store, something in the pack or a directory that holds the store counts.
    public func of(_ store: PackStore, xcode: String, build: String, arch: String, excludingRun: String? = nil) throws -> [String] {
        let row = "{{.Names}}\t{{.Image}}\t{{.Label \"\(Self.runLabel)\"}}"
        switch store {
        case .volumes:
            let volume = PackVolumes.name(xcode: xcode, build: build, arch: arch)
            let listed = docker(["ps", "--filter", "volume=\(volume)", "--format", row])
            guard listed.code == 0 else { throw problem("docker ps --filter volume=\(volume)") }
            return rows(listed.output, excludingRun: excludingRun) { _ in true }
        case let .directory(dir):
            let ids = docker(["ps", "-q"])
            guard ids.code == 0 else { throw problem("docker ps -q") }
            let running = ids.output.split(whereSeparator: \.isWhitespace).map(String.init)
            if running.isEmpty { return [] }
            let format = "{{.Name}}\t{{.Config.Image}}\t{{index .Config.Labels \"\(Self.runLabel)\"}}\t{{json .Mounts}}"
            let inspected = docker(["inspect", "--format", format] + running)
            guard inspected.code == 0 else { throw problem("docker inspect") }
            let root = dir.standardizedFileURL.path
            let pack = dir.appendingPathComponent(XcodePack.name(xcode: xcode, build: build, arch: arch)).standardizedFileURL.path
            return rows(inspected.output, excludingRun: excludingRun) { fields in
                guard fields.count > 3, let data = fields[3].data(using: .utf8),
                      let mounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
                return mounts.contains { mount in
                    guard let source = (mount["Source"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return false }
                    // the pack, in it, the store, or what holds the store
                    return source == pack || source.hasPrefix(pack + "/") || source == root || root.hasPrefix(source == "/" ? "/" : source + "/")
                }
            }
        }
    }

    private func rows(_ output: String, excludingRun: String?, _ uses: ([String]) -> Bool) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, uses(fields) else { return nil }
            if let excludingRun, fields[2] == excludingRun { return nil }
            let name = fields[0].hasPrefix("/") ? String(fields[0].dropFirst()) : fields[0]
            return "\(name) (\(fields[1]))"
        }
    }

    private func problem(_ command: String) -> ImageProblem {
        ImageProblem("docker cannot tell which containers are running (\(command) failed), so whether one uses the pack before it is replaced",
                      fix: "check that docker runs (docker ps), then run this again")
    }

    /// Why the pack is not prepared now, and what to do, when `users` run.
    public static func refusal(pack: String, place: String, users: [String]) -> ImageProblem {
        let names = users.map { String($0.prefix { $0 != " " }) }
        return ImageProblem("the pack \(pack) in \(place) is used by \(users.count == 1 ? "a running container" : "running containers"): \(users.joined(separator: ", ")); "
                                + "preparing it now would replace it under \(users.count == 1 ? "it" : "them")",
                            fix: "wait for \(users.count == 1 ? "that run" : "those runs") to end, or stop \(users.count == 1 ? "it" : "them") (docker stop \(names.joined(separator: " "))), then run this again")
    }
}
