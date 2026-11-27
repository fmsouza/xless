import ArgumentParser
import Foundation
import XlessCore
import XlessImages
import XlessSDK

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
        and \(CleanPlan.volumePrefix)*) and the Xcode packs (\(PackVolumes.prefix)<version>-<build>-<arch>): preparing a pack again takes minutes \
        and needs its SDK export or the Xcode, so it lists the packs and asks (--yes answers); a pack that a running container uses is left. \
        --cache removes $XDG_CACHE_HOME/xless (default ~/.cache/xless): the exported SDKs that packs are prepared from (your only \
        copy without the .xip), Tauri work copies and downloads. --native removes the native install: $XLESS_NATIVE_HOME (default \
        ~/.local/share/xless-native: the Xcode packs in its xcodes directory, xtool, rcodesign), those of $XLESS_XCODES too, and an older \
        install's SDK and toolchain-meta.json. --all does the four. The xless install itself (~/.local/bin/xless and \
        ~/.local/share/xless) and Docker's build cache, which other projects share (docker builder prune), are left alone.
        """)

    @Flag(help: "Remove the xless images (every tag of every version, and older untagged builds).") var images = false
    @Flag(help: "Remove only what older layouts left: legacy images, images of another xless version, an older native install. Never a pack.") var old = false
    @Flag(help: "Remove the Docker volumes xless docker creates, and the Xcode packs.") var volumes = false
    @Flag(help: "Remove the cache directory ($XDG_CACHE_HOME/xless, default ~/.cache/xless), with the SDK exports in it.") var cache = false
    @Flag(help: "Remove the native install (toolchain, tools, the Xcode packs of its store, an older install's SDK and metadata).") var native = false
    @Flag(help: "--images, --volumes, --cache and --native.") var all = false
    @Flag(help: "Do not ask (when removing packs, or with --old).") var yes = false
    @Flag(help: "Print what would be removed, and remove nothing.") var dryRun = false

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let cacheRoot = SetupPlan.cacheRoot(env: env, home: home)
        let doImages = images || all, doVolumes = volumes || all, doCache = cache || all, doOld = old || doImages, doNative = native || all
        let listOnly = !(doOld || doVolumes || doCache || doNative)
        let layout = NativeLayout(env: env)
        // What an older xless installed natively, as setup's note sees it: read before anything goes (the record is in the native home).
        let olderInstall = layout.olderInstall(env: env)
        // The native install: its home (which holds the store of packs), and the SDK and metadata an older xless's setup installed.
        let store = XcodeStore(env: env)
        let storeInHome = store.root.standardizedFileURL.path.hasPrefix(layout.root.standardizedFileURL.path + "/")
        let storePacks = store.packs()
        var removing = !listOnly && !dryRun

        let tag = (try? XlessShare.locate(env: env, executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])))
            .flatMap { try? ImageName.cachedTag(ofShare: $0) }

        // --old alone: what each tag is now, for the check right before it goes.
        let asks = old && !doImages
        var imageRefs: [String] = [], workVolumes: [String] = [], packVolumes: [CleanPlan.PackVolume] = [], oldIDs: [String: String] = [:]
        var dockerAnswered = true
        if listOnly || doOld || doVolumes {
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
                if listOnly || doVolumes {
                    let listing = try Shell.docker(["volume", "ls", "--format", "{{.Name}}"], stage: .sdk).stdout
                    workVolumes = CleanPlan.volumes(fromListing: listing)
                    packVolumes = CleanPlan.packs(fromListing: listing)
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
            say("note: this xless's image tag is not known (no share directory with a release), so only the legacy images are listed, not those of other versions")
        }

        // The packs that running containers use stay. A volume: the containers that mount it; a directory store (XLESS_XCODES): those that mount it.
        var left: [(pack: String, users: [String])] = []
        func usersOf(_ store: PackStore, _ pack: (xcode: String, build: String, arch: String)) -> [String] {
            do { return try PackUsers(LocalImages.hereDocker).of(store, xcode: pack.xcode, build: pack.build, arch: pack.arch) } catch {
                return ["docker did not say which containers run (\(Self.firstLine(error)))"]
            }
        }
        var removablePackVolumes: [CleanPlan.PackVolume] = []
        for p in packVolumes {
            let users = usersOf(.volumes, (p.xcode, p.build, p.arch))
            if users.isEmpty { removablePackVolumes.append(p) } else { left.append((p.name, users)) }
        }
        var removableStorePacks: [XcodePack] = []
        var homeBlocked = false
        if doNative || listOnly {
            let dockerStore = PackStore(env: env)
            for p in storePacks {
                var users: [String] = []
                if case .directory = dockerStore { users = usersOf(dockerStore, (p.manifest.xcode, p.manifest.build, p.manifest.arch)) }
                if users.isEmpty { removableStorePacks.append(p) } else { left.append((p.root.path, users)); if storeInHome { homeBlocked = true } }
            }
        }
        // The native home goes whole unless a pack in it is in use; a store of its own (XLESS_XCODES) loses its packs, not the directory.
        var nativePaths = (homeBlocked ? [] : [layout.root]) + olderInstall.filter { !$0.path.hasPrefix(layout.root.path + "/") }.filter { path in
            path == DarwinSDKLocator.bundle(env: env) || path == ToolchainMeta.defaultLocation(env: env)
        }
        nativePaths = nativePaths.filter { fm.fileExists(atPath: $0.path) }
        let storeRoots = storeInHome ? [] : removableStorePacks.map(\.root)
        let oldNative = old ? olderInstall : []
        let cacheExists = fm.fileExists(atPath: cacheRoot.path)
        let exports = (try? fm.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent("sdk").path))?.filter { !$0.hasPrefix(".") } ?? []

        let questions: [String] = [
            asks && !imageRefs.isEmpty ? (imageRefs.count == 1 ? "this image tag" : "these \(imageRefs.count) image tags") : nil,
            asks && !imageRefs.isEmpty ? "the untagged older builds" : nil,
            !removablePackVolumes.isEmpty ? "\(removablePackVolumes.count) Xcode pack volume\(removablePackVolumes.count == 1 ? "" : "s")" : nil,
            doNative && !removableStorePacks.isEmpty ? "\(removableStorePacks.count) Xcode pack\(removableStorePacks.count == 1 ? "" : "s") of the native store" : nil,
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
            if dockerAnswered || doVolumes {
                say("\(verb) \(removablePackVolumes.count) Xcode pack volume\(removablePackVolumes.count == 1 ? "" : "s")" + (removablePackVolumes.isEmpty ? "" : ":"))
                for p in removablePackVolumes { say("  \(p.name)  \(p.summary)") }
                if !removablePackVolumes.isEmpty {
                    say("  preparing a pack again takes minutes and needs its SDK export (xless setup --sdk <export>) or the Xcode (xless setup --docker --xcode <Xcode.app or .xip>)")
                }
            }
        }
        for (pack, users) in left { say("\(removing ? "leaving" : "would leave") the pack \(pack): in use by \(users.joined(separator: ", "))") }
        if listOnly || doCache {
            say(cacheExists ? "\(verb) the cache \(cacheRoot.path) (\(Self.size(of: cacheRoot)))" : "no cache at \(cacheRoot.path)")
            if cacheExists && !exports.isEmpty {
                say("  it holds \(exports.count) SDK export\(exports.count == 1 ? "" : "s") (\(exports.sorted().joined(separator: ", "))): packs are prepared from them, and without the .xip they are your only copy; only --cache and --all remove them")
            }
        }
        if listOnly || doNative {
            if nativePaths.isEmpty && storeRoots.isEmpty { say("no native install") }
            for p in nativePaths { say("\(verb) the native install's \(p.path) (\(Self.size(of: p)))") }
            for p in removableStorePacks { say("\(verb) the Xcode pack \(p.name) of the store \(store.root.path): Xcode \(p.manifest.xcode) (\(p.manifest.build), \(p.manifest.arch))") }
            if !removableStorePacks.isEmpty { say("  preparing a pack again takes minutes and needs its SDK export (xless setup --sdk <export>) or the Xcode (xless setup --xcode <Xcode.app or .xip>)") }
        }
        if listOnly {
            say("nothing removed: pass --images, --old, --volumes, --cache, --native or --all (--dry-run to see what they would remove)")
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
        if doNative {
            for p in nativePaths + storeRoots {
                guard fm.fileExists(atPath: p.path) else { continue }
                do { try fm.removeItem(at: p) } catch { failures.append("\(p.path) was not fully removed (\(Self.firstLine(error)))") }
            }
        }
        for p in oldNative where fm.fileExists(atPath: p.path) {
            do { try fm.removeItem(at: p) } catch { failures.append("\(p.path) was not fully removed (\(Self.firstLine(error)))") }
        }
        for (pack, users) in left {
            let names = users.map { String($0.prefix { $0 != " " }) }
            failures.append("the pack \(pack) was left: \(users.count == 1 ? "a running container uses" : "running containers use") it (\(users.joined(separator: ", ")))"
                            + "; stop \(users.count == 1 ? "it" : "them") (docker stop \(names.joined(separator: " ")))")
        }
        if !failures.isEmpty {
            throw XlessError(.sdk, failures.joined(separator: "; "), fix: "see above, then run xless clean again")
        }
        say("done. Docker's build cache is shared with other projects and was left alone; docker builder prune frees it")
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
