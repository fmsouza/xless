import ArgumentParser
import Foundation
import XlessCore
import XlessImages
import XlessSDK
import XlessVault

/// `xless clean`: frees the disk space `xless setup` and `xless run` use. It removes only what xless made: the images of every xless
/// version and the kits (the local tags, and the older builds that setup left untagged), those of the older layouts too, the Docker
/// volumes `xless run --docker` creates, the Xcode packs (a Docker volume each, `xless-xcode-<version>-<build>-<arch>`, and the native
/// store), the cache directory, and the native install. `--old` removes only what older layouts left, never a pack.
/// BuildKit's build cache is shared with every other Docker project, so it is only pointed at, never pruned.
struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove the xless images, Docker volumes, Xcode packs and cache, to free disk space.",
        discussion: """
        With no option it lists what there is and removes nothing. --images removes every local tag of xless's images (xless:<version>-<arch> \
        and its kits, of every xless version; xless:local-… and xless-base, xless-tauri and xless-rn of the older layouts), then the older builds \
        that a later xless setup left untagged (label \(CleanPlan.imageLabel)); --old removes only what older layouts left: the legacy tags, \
        the images of another xless version than this one's (never this one's, nor its kits), and an older native install (the SDK \
        darwin.artifactbundle that xless installed, its toolchain-meta.json, the Swift toolchains and the record: not a pack). It lists them and \
        asks (--yes answers). --volumes removes the volumes xless docker creates (\(CleanPlan.volumes.joined(separator: ", ")) \
        and \(CleanPlan.volumePrefix)*), and nothing else. --packs removes the Xcode packs (the volumes \(PackVolumes.prefix)<version>-<build>-<arch>, and \
        the packs of a store of your own, XLESS_XCODES): preparing a pack again takes minutes and needs its SDK export or the Xcode, so it \
        lists the packs and asks (--yes answers); a pack that a running container uses is left. \
        --cache removes $XDG_CACHE_HOME/xless (default ~/.cache/xless): the exported SDKs that packs are prepared from (your only \
        copy without the .xip), Tauri work copies and downloads. --native removes the native install: $XLESS_NATIVE_HOME (default \
        ~/.local/share/xless-native: xtool, rcodesign and its xcodes directory, where the native packs are) and an older \
        install's SDK and toolchain-meta.json. --all does the five. The xless install itself (~/.local/bin/xless and \
        ~/.local/share/xless) and Docker's build cache, which other projects share (docker builder prune), are left alone.
        """)

    @Flag(help: "Remove the xless images (every tag of every version, and older untagged builds).") var images = false
    @Flag(help: "Remove only what older layouts left: legacy images, images of another xless version, an older native install. Never a pack.") var old = false
    @Flag(help: "Remove the Docker volumes xless docker creates (Rust toolchains, React Native work copies and caches), not the Xcode packs.") var volumes = false
    @Flag(help: "Remove the Xcode packs: the pack volumes (xless-xcode-<version>-<build>-<arch>) and the packs of a store of your own (XLESS_XCODES). Asks first.") var packs = false
    @Flag(help: "Remove the cache directory ($XDG_CACHE_HOME/xless, default ~/.cache/xless), with the SDK exports in it.") var cache = false
    @Flag(help: "Remove the native install: its home with the tools and the Xcode packs of its store (xcodes), and an older install's SDK and metadata.") var native = false
    @Flag(help: "--images, --volumes, --packs, --cache and --native.") var all = false
    @Flag(help: "Do not ask (when removing packs, or with --old).") var yes = false
    @Flag(help: "Print what would be removed, and remove nothing.") var dryRun = false

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let cacheRoot = SetupPlan.cacheRoot(env: env, home: home)
        let doImages = images || all, doVolumes = volumes || all, doCache = cache || all, doOld = old || doImages, doNative = native || all
        let doPacks = packs || all
        let listOnly = !(doOld || doVolumes || doCache || doNative || doPacks)
        let layout = NativeLayout(env: env)
        // What an older xless installed natively, as setup's note sees it: read before anything goes (the record is in the native home).
        // Not what lies in a pack store or the cache, or leads there by a link (`XDG_CONFIG_HOME` of a build is `<cache>/xless/xtool-config/<pack>`,
        // whose swift-sdks is a link into the pack): those are packs and exports, not an older install.
        let real = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path }
        let guarded = [XcodeStore(env: env).root, layout.root.appendingPathComponent("xcodes"), cacheRoot].map(real)
        var skipped: [String] = []
        let olderInstall = layout.olderInstall(env: env).filter { path in
            let r = real(path)
            guard let inside = guarded.first(where: { r == $0 || r.hasPrefix($0 + "/") }) else { return true }
            skipped.append("leaving \(path.path): it is, or leads to, \(r == path.standardizedFileURL.path ? "" : r + ", ")inside \(inside) (a pack store or the cache), not an older install's")
            return false
        }
        for line in skipped { say(line) }
        // --native removes its root whole: only one that is a native home and holds nothing else (see `rootProblem`).
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let shareURL = try? XlessShare.locate(env: env, executable: executable)
        func xdg(_ key: String, _ fallback: String) -> URL {
            if let v = env[key], v.hasPrefix("/") { return URL(fileURLWithPath: v) }
            return home.appendingPathComponent(fallback)
        }
        let holds: [(what: String, url: URL)] = [
            ("your home directory", home), ("the cache", cacheRoot),
            ("xless's share directory", shareURL ?? home), ("the directory of the xless binary", executable.deletingLastPathComponent()),
            ("xless's install prefix", executable.deletingLastPathComponent().deletingLastPathComponent()),
            ("xless's data directory (with the secrets vault)", xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("xless")),
            ("the secrets vault", VaultLocation.standard(env: env).directory),
            ("xless's configuration directory", xdg("XDG_CONFIG_HOME", ".config").appendingPathComponent("xless")),
        ]
        let rootProblem = Self.rootProblem(layout.root, env: env, holds: holds)
        let rootEmpty = ((try? fm.contentsOfDirectory(atPath: layout.root.path)) ?? ["-"]).isEmpty
        if let rootProblem {
            guard !doNative else { throw XlessError(.sdk, rootProblem.cause, fix: rootProblem.fix) }
            if listOnly || old { say("\(old ? "leaving the older native install" : "not listing the native home"): \(rootProblem.cause)") }
        }
        var removing = !listOnly && !dryRun

        // This xless's tag; unknown when there is no share, or a checkout's git did not give its commit (the tag would be the release's, not the one of its images).
        let resolved = (try? XlessShare.locate(env: env, executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])))
            .flatMap { try? ImageName.resolution(ofShare: $0) }
        let tag = resolved.flatMap { $0.fellBack ? nil : $0.tag }

        // --old alone: what each tag is now, for the check right before it goes.
        let asks = old && !doImages
        var imageRefs: [String] = [], workVolumes: [String] = [], packVolumes: [CleanPlan.PackVolume] = [], oldIDs: [String: String] = [:]
        var dockerAnswered = true
        if listOnly || doOld || doVolumes || doPacks {
            do {
                let ls = ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]
                if listOnly || doOld {
                    let all = try Shell.docker(ls, stage: .sdk).stdout
                    if asks {
                        for ref in tag.map({ CleanPlan.old(fromListing: all, version: $0) }) ?? CleanPlan.legacy(fromListing: all) {
                            guard let image = LocalImages.here.image(ref), CleanPlan.isStillOld(ref, id: image.id, now: image, version: tag) else { continue }
                            imageRefs.append(ref)
                            oldIDs[ref] = image.id
                        }
                    } else { imageRefs = CleanPlan.images(fromListing: all) }
                }
                if listOnly || doVolumes || doPacks {
                    let listing = try Shell.docker(["volume", "ls", "--format", "{{.Name}}"], stage: .sdk).stdout
                    if listOnly || doVolumes { workVolumes = CleanPlan.volumes(fromListing: listing) }
                    if listOnly || doPacks { packVolumes = CleanPlan.packs(fromListing: listing) }
                }
            } catch {
                guard listOnly else {
                    throw XlessError(.sdk, "docker does not answer, so the images and volumes cannot be listed: \(Self.firstLine(error))",
                                     fix: "start Docker (and check that you can run docker without sudo), then run xless clean again; --cache alone needs no Docker")
                }
                dockerAnswered = false
                say("docker does not answer: images and volumes not listed")
            }
        }
        if old && tag == nil && !listOnly {
            say("note: this xless's image tag is not known (\(resolved?.fellBack == true ? "git did not give the commit of its checkout" : "no share directory with a release")), so only the legacy images are listed, not those of other versions")
        }

        // The packs that running containers use stay. A volume: the containers that mount it; a directory store (XLESS_XCODES): those that mount it.
        var left: [(pack: String, use: Use)] = []
        func useOf(volume p: CleanPlan.PackVolume) -> Use { Self.use(.volumes, xcode: p.xcode, build: p.build, arch: p.arch) }
        var removablePackVolumes: [CleanPlan.PackVolume] = []
        for p in packVolumes {
            let u = useOf(volume: p)
            if case .free = u { removablePackVolumes.append(p) } else { left.append((p.name, u)) }
        }
        // The packs of a native install: those in <native home>/xcodes go with --native (the home goes whole), and so do those of an XLESS_XCODES
        // inside the home; those of a store of its own (XLESS_XCODES elsewhere) go with --packs. Real paths are compared, and a directory is a pack
        // only when its name is its manifest's.
        let homeReal = real(layout.root), homeStore = layout.root.appendingPathComponent("xcodes")
        let givenStore = (env["XLESS_XCODES"] ?? "").isEmpty ? nil : URL(fileURLWithPath: env["XLESS_XCODES"] ?? "")
        // If <home>/xcodes is a link, removing the home removes the link and not the packs behind it: they are not this install's to list as removed.
        let homeLink = try? fm.destinationOfSymbolicLink(atPath: homeStore.path)
        var nativeStores = homeLink == nil ? [homeStore] : [], ownStore: URL?
        if let given = givenStore, homeLink != nil || real(given) != real(homeStore) {
            if real(given) == homeReal || real(given).hasPrefix(homeReal + "/") { nativeStores.append(given) } else { ownStore = given }
        }
        func packsOf(_ dir: URL) -> [XcodePack] { XcodeStore(root: dir).packs().filter { $0.root.lastPathComponent == $0.name } }
        let nativePacks = (rootProblem == nil && (doNative || listOnly)) ? nativeStores.flatMap(packsOf) : []
        let ownPacks = (doPacks || listOnly) ? ownStore.map(packsOf) ?? [] : []
        let dockerDirectory: URL? = { if case let .directory(d) = PackStore(env: env) { return d } else { return nil } }()
        // Only the packs of the directory that docker mounts can be in use.
        func useOf(pack p: XcodePack) -> Use {
            guard let d = dockerDirectory, real(p.root.deletingLastPathComponent()) == real(d) else { return .free }
            return Self.use(.directory(d), xcode: p.manifest.xcode, build: p.manifest.build, arch: p.manifest.arch)
        }
        var removableOwn: [XcodePack] = []
        for p in ownPacks {
            let u = useOf(pack: p)
            if case .free = u { removableOwn.append(p) } else { left.append((p.root.path, u)) }
        }
        var blockers: [(pack: String, use: Use)] = []
        for p in nativePacks {
            let u = useOf(pack: p)
            if case .free = u { continue }
            blockers.append((p.root.path, u))
        }
        left += blockers
        let homeBlocked = !blockers.isEmpty
        // The native home goes whole, unless a pack in it is in use.
        var nativePaths = ((homeBlocked || rootProblem != nil) ? [] : [layout.root]) + olderInstall.filter { !$0.path.hasPrefix(layout.root.path + "/") }.filter { path in
            path == DarwinSDKLocator.bundle(env: env) || path == ToolchainMeta.olderLocation(env: env)
        }
        nativePaths = nativePaths.filter { fm.fileExists(atPath: $0.path) }
        let oldNative = old && rootProblem == nil ? olderInstall : []
        let cacheExists = fm.fileExists(atPath: cacheRoot.path)
        let exports = (try? fm.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent("sdk").path))?.filter { !$0.hasPrefix(".") } ?? []

        let questions: [String] = [
            asks && !imageRefs.isEmpty ? (imageRefs.count == 1 ? "this image tag" : "these \(imageRefs.count) image tags") : nil,
            asks && !imageRefs.isEmpty ? "the untagged older builds" : nil,
            !removablePackVolumes.isEmpty ? "\(removablePackVolumes.count) Xcode pack volume\(removablePackVolumes.count == 1 ? "" : "s")" : nil,
            doNative && nativePaths.contains(layout.root) && !rootEmpty ? "the native install \(real(layout.root))" : nil,
            doNative && !homeBlocked && !nativePacks.isEmpty ? "\(nativePacks.count) Xcode pack\(nativePacks.count == 1 ? "" : "s") of the native install" : nil,
            doPacks && !removableOwn.isEmpty ? "\(removableOwn.count) Xcode pack\(removableOwn.count == 1 ? "" : "s") of \(ownStore?.path ?? "your store")" : nil,
            !oldNative.isEmpty ? "what an older xless installed natively" : nil,
        ].compactMap { $0 }
        let mustAsk = removing && !questions.isEmpty && !yes
        let verb = removing && !mustAsk ? "removing" : (dryRun || mustAsk ? "would remove" : "found")
        if listOnly || doOld {
            say("\(verb) \(imageRefs.count) image tag\(imageRefs.count == 1 ? "" : "s")" + (imageRefs.isEmpty ? "" : ":"))
            for r in imageRefs { say("  \(r)") }
        }
        if doOld {
            say("\(removing && !mustAsk ? "then removing" : "and") the untagged older builds (docker image prune --filter label=\(CleanPlan.imageLabel))")
        }
        if old {
            if oldNative.isEmpty { say("no older native install") }
            for p in oldNative { say("\(verb) the older native install's \(p.path) (\(Self.size(of: p)))") }
        }
        if listOnly || doVolumes {
            say("\(verb) \(workVolumes.count) volume\(workVolumes.count == 1 ? "" : "s")" + (workVolumes.isEmpty ? "" : ":"))
            for v in workVolumes { say("  \(v)") }
        }
        if listOnly || doPacks {
            if dockerAnswered || doPacks {
                say("\(verb) \(removablePackVolumes.count) Xcode pack volume\(removablePackVolumes.count == 1 ? "" : "s")" + (removablePackVolumes.isEmpty ? "" : ":"))
                for p in removablePackVolumes { say("  \(p.name)  \(p.summary)") }
                if !removablePackVolumes.isEmpty {
                    say("  preparing a pack again takes minutes and needs its SDK export (xless setup --sdk <export>) or the Xcode (xless setup --docker --xcode <Xcode.app or .xip>)")
                }
            }
        }
        let leave = removing ? "leaving" : "would leave"
        for (pack, use) in left { say("\(leave) the pack \(pack): \(Self.reason(use).listing)") }
        if listOnly || doCache {
            say(cacheExists ? "\(verb) the cache \(cacheRoot.path) (\(Self.size(of: cacheRoot)))" : "no cache at \(cacheRoot.path)")
            if cacheExists && !exports.isEmpty {
                say("  it holds \(exports.count) SDK export\(exports.count == 1 ? "" : "s") (\(exports.sorted().joined(separator: ", "))): packs are prepared from them, and without the .xip they are your only copy; only --cache and --all remove them")
            }
        }
        let again = "  preparing a pack again takes minutes and needs its SDK export (xless setup --sdk <export>) or the Xcode (xless setup --xcode <Xcode.app or .xip>)"
        if listOnly || doNative {
            if nativePaths.isEmpty && !homeBlocked { say("no native install") }
            if homeBlocked { say("\(leave) the native install's \(layout.root.path): a pack in it is in use") }
            for p in nativePaths { say("\(verb) the native install's \(p.path) (\(Self.size(of: p)))") }
            if let homeLink, doNative || listOnly {
                say("\(verb) the link \(homeStore.path) (to \(homeLink)): the packs behind it are not removed")
            }
            for p in nativePacks where !homeBlocked {
                say("\(verb) the Xcode pack \(p.root.path): Xcode \(p.manifest.xcode) (\(p.manifest.build), \(p.manifest.arch))")
            }
            for p in nativePacks where homeBlocked && !blockers.contains(where: { $0.pack == p.root.path }) {
                say("\(leave) the Xcode pack \(p.root.path): the native install is kept whole while another pack in it is in use")
            }
            if !nativePacks.isEmpty && !homeBlocked { say(again) }
        }
        if listOnly || doPacks {
            for p in removableOwn { say("\(verb) the Xcode pack \(p.root.path): Xcode \(p.manifest.xcode) (\(p.manifest.build), \(p.manifest.arch))") }
            if !removableOwn.isEmpty { say(again) }
        }
        if listOnly {
            say("nothing removed: pass --images, --old, --volumes, --packs, --cache, --native or --all (--dry-run to see what they would remove)")
            return
        }
        if mustAsk {
            removing = try AccountConfirm.confirm("Remove \(Self.joined(questions))?", action: "removing images, packs or an older install", yes: yes, stage: .sdk)
            if !removing { say("cancelled; nothing was removed") }
        }
        guard removing else { return }

        var failures: [String] = []
        if !workVolumes.isEmpty {
            do { try Shell.docker(["volume", "rm"] + workVolumes, stage: .sdk, passthrough: true) } catch {
                failures.append("some volumes were not removed (one in use by a container? docker ps -a)")
            }
        }
        if !removablePackVolumes.isEmpty {
            do { try Shell.docker(["volume", "rm"] + removablePackVolumes.map(\.name), stage: .sdk, passthrough: true) } catch {
                failures.append("some pack volumes were not removed (one in use by a container? docker ps -a)")
            }
        }
        if asks {
            for ref in imageRefs {
                guard CleanPlan.isStillOld(ref, id: oldIDs[ref] ?? "", now: LocalImages.here.image(ref), version: tag) else {
                    say("kept \(ref): it is another image now")
                    continue
                }
                do { try Shell.docker(["image", "rm", ref], stage: .sdk, passthrough: true) } catch {
                    failures.append("\(ref) was not removed (in use by a container? docker ps -a)")
                }
            }
        } else if !imageRefs.isEmpty {
            do { try Shell.docker(["image", "rm"] + imageRefs, stage: .sdk, passthrough: true) } catch {
                failures.append("some images were not removed (one in use by a container? docker ps -a)")
            }
        }
        if doOld {
            do { try Shell.docker(["image", "prune", "--force", "--filter", "label=\(CleanPlan.imageLabel)"], stage: .sdk, passthrough: true) } catch {
                failures.append("the untagged older builds were not pruned")
            }
        }
        if doCache && cacheExists {
            do { try fm.removeItem(at: cacheRoot) } catch {
                // Work copies built in a container as root belong to root.
                failures.append("\(cacheRoot.path) was not fully removed (\(Self.firstLine(error))); files a container wrote as root need: sudo rm -rf '\(cacheRoot.path)'")
            }
        }
        // The packs of a store of its own: each is looked at again right before it goes (a run may have started since the question).
        if doPacks {
            for p in removableOwn {
                let now = useOf(pack: p)
                guard case .free = now else { left.append((p.root.path, now)); continue }
                do { try fm.removeItem(at: p.root) } catch { failures.append("\(p.root.path) was not fully removed (\(Self.firstLine(error)))") }
            }
        }
        if doNative {
            // The native home goes whole, so every pack in it is looked at again first: if one is in use now, the home stays.
            var homeKept = false
            for p in nativePacks where !homeBlocked {
                let now = useOf(pack: p)
                if case .free = now { continue }
                left.append((p.root.path, now)); homeKept = true
            }
            for p in nativePaths {
                guard !(homeKept && p == layout.root), fm.fileExists(atPath: p.path) else { continue }
                do { try fm.removeItem(at: p) } catch { failures.append("\(p.path) was not fully removed (\(Self.firstLine(error)))") }
            }
        }
        for p in oldNative where fm.fileExists(atPath: p.path) {
            do { try fm.removeItem(at: p) } catch { failures.append("\(p.path) was not fully removed (\(Self.firstLine(error)))") }
        }
        for (pack, use) in left { failures.append("the pack \(pack) was left: \(Self.reason(use).failure)") }
        if !failures.isEmpty {
            throw XlessError(.sdk, failures.joined(separator: "; "), fix: "see above, then run xless clean again")
        }
        say("done. Docker's build cache is shared with other projects and was left alone; docker builder prune frees it")
    }

    /// Whether a running container uses a pack.
    private enum Use {
        case free
        case users([String])
        /// docker could not be asked: the pack is left all the same.
        case unknown(String)
    }

    private static func use(_ store: PackStore, xcode: String, build: String, arch: String) -> Use {
        do {
            let users = try PackUsers(LocalImages.hereDocker).of(store, xcode: xcode, build: build, arch: arch)
            return users.isEmpty ? .free : .users(users)
        } catch { return .unknown(firstLine(error)) }
    }

    /// What the listing says, and the cause and fix at the end, of a pack that is left.
    private static func reason(_ use: Use) -> (listing: String, failure: String) {
        switch use {
        case .free: return ("", "")
        case let .users(users):
            let names = users.map { String($0.prefix { $0 != " " }) }
            return ("in use by \(users.joined(separator: ", "))",
                    "\(users.count == 1 ? "a running container uses" : "running containers use") it (\(users.joined(separator: ", "))); stop \(users.count == 1 ? "it" : "them") (docker stop \(names.joined(separator: " ")))")
        case let .unknown(why):
            return ("docker could not be asked whether a container uses it (\(why))",
                    "docker could not be asked whether a container uses it (\(why)); check that it runs (docker ps), then run xless clean again")
        }
    }

    /// The names a native home has at its top level: what `xless setup` makes (`NativeLayout`: bin, tools, toolchains and the older record; the
    /// store xcodes), with the `.partial`, `.old`, `.lock` and `.download` that setup leaves beside them (PackLock, PackPlan, NativeSetupPlan)
    /// and the macOS signer's `rcodesign.lock`.
    private static func isNativeHomeEntry(_ name: String) -> Bool {
        let bases = ["bin", "tools", "toolchains", "xcodes", "swift-toolchain.json"]
        if name == "rcodesign.lock" { return true }
        return bases.contains { base in name == base || [".partial", ".old", ".lock", ".download"].contains { name == base + $0 } }
    }

    /// Whether `root` has what only xless's setup makes: a link `bin/xtool` or `bin/rcodesign`, a `tools/xtool-*` or `tools/rcodesign-*`, a pack
    /// (`xcodes/*/pack.json`) or an older install's record. A bare `bin/` or `tools/` proves nothing.
    private static func hasNativeMark(_ root: URL) -> Bool {
        let fm = FileManager.default
        func exists(_ u: URL) -> Bool { (try? fm.attributesOfItem(atPath: u.path)) != nil }   // a link too, broken or not
        func names(_ dir: String) -> [String] { (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? [] }
        if exists(root.appendingPathComponent("bin/xtool")) || exists(root.appendingPathComponent("bin/rcodesign")) || exists(root.appendingPathComponent("swift-toolchain.json")) { return true }
        if names("tools").contains(where: { $0.hasPrefix("xtool-") || $0.hasPrefix("rcodesign-") }) { return true }
        return names("xcodes").contains { exists(root.appendingPathComponent("xcodes/\($0)/pack.json")) }
    }

    /// Why `root` is not a native home that `--native` may remove whole, or nil. It must be absolute; not `/`; and not hold (on real paths) anything
    /// in `holds` (the home directory, the share, the binary, the cache, the vault, the configuration: a native home is a leaf). When it exists and
    /// is not empty it must have nothing at its top level but the names of a native home (the first strangers are named) and a mark of xless's setup.
    private static func rootProblem(_ root: URL, env: [String: String], holds: [(what: String, url: URL)]) -> (cause: String, fix: String)? {
        let given = [env["XLESS_NATIVE_HOME"], env["XDG_DATA_HOME"]].compactMap { $0 }.first { !$0.isEmpty }
        let fix = given != nil
            ? "set XLESS_NATIVE_HOME to the native home (an absolute path of a directory that only xless setup filled), or unset it"
            : "move what is in \(root.path) away, or remove it yourself: xless removes only a directory that holds nothing but what its setup makes"
        if let given, !given.hasPrefix("/") { return ("the native home \(given) is a relative path, which would name another directory from every other one", fix) }
        let real = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path }
        let path = real(root)
        if path == "/" { return ("the native home is /", fix) }
        for (what, url) in holds {
            let r = real(url)
            if r == path || r.hasPrefix(path + "/") { return ("the native home \(path) is, or holds, \(what) (\(r)), which a native home must not", fix) }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path), let entries = try? fm.contentsOfDirectory(atPath: root.path), !entries.isEmpty else { return nil }
        let strangers = entries.filter { !isNativeHomeEntry($0) }.sorted()
        if !strangers.isEmpty {
            return ("the native home \(path) holds what xless did not put there (\(strangers.prefix(5).joined(separator: ", "))\(strangers.count > 5 ? ", and \(strangers.count - 5) more" : "")), so it is not removed",
                    fix)
        }
        if !hasNativeMark(root) { return ("the native home \(path) holds none of what xless's setup makes (a bin/xtool or bin/rcodesign link, tools/xtool-*, a pack, the older record), so it is not removed", fix) }
        return nil
    }

    /// "a", "a and b", "a, b and c".
    private static func joined(_ parts: [String]) -> String {
        parts.count < 2 ? (parts.first ?? "") : parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
    }

    private static func firstLine(_ error: Error) -> String {
        let text = (error as? XlessError).map { $0.cause } ?? "\(error)"
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    /// The space the files under `url` take (allocated size), as decimal GB or MB.
    private static func size(of url: URL) -> String {
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}

private func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
