import ArgumentParser
import Foundation
import XlessCore
import XlessImages
import XlessSDK

/// `xless clean`: frees the disk space `xless setup` and `xless run` use. It removes only what xless made: the native
/// install (`NativeLayout`, with the SDK and metadata it installed), the local tags of its images (those of older ones too, and
/// the older builds that setup left untagged), xless's Docker volumes, and the cache directory.
/// BuildKit's build cache is shared with every other Docker project, so it is only pointed at, never pruned.
struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove the xless images, Docker volumes and cache, to free disk space.",
        discussion: """
        With no option it lists what there is and removes nothing. --images removes every local tag of xless's images \
        (xless:local-…, and xless-base, xless-tauri and xless-rn of xless 0.10 and older), then the older builds that a later \
        xless setup left untagged (label \(CleanPlan.imageLabel)); --old removes only what an upgrade leaves behind: the tags of \
        xless 0.10 and older, which it lists and asks about (--yes answers), and those older builds. --volumes removes the volumes xless docker creates (\(CleanPlan.volumes.joined(separator: ", ")) \
        and \(CleanPlan.volumePrefix)*). --cache removes $XDG_CACHE_HOME/xless (default ~/.cache/xless): the exported SDKs, \
        Tauri work copies and downloads. --native removes the native install: $XLESS_NATIVE_HOME (default \
        ~/.local/share/xless-native: the Swift toolchain, xtool, rcodesign), the installed Darwin SDK and its \
        toolchain-meta.json. --all does the four. The xless install itself (~/.local/bin/xless and \
        ~/.local/share/xless) and Docker's build cache, which other projects share (docker builder prune), are left alone.
        """)

    @Flag(help: "Remove the xless images (every tag, and older untagged builds).") var images = false
    @Flag(help: "Remove only what an upgrade leaves: the images of xless 0.10 and older, and the older builds that a later xless setup left untagged.") var old = false
    @Flag(help: "Remove the Docker volumes xless docker creates.") var volumes = false
    @Flag(help: "Remove the cache directory ($XDG_CACHE_HOME/xless, default ~/.cache/xless).") var cache = false
    @Flag(help: "Remove the native install (toolchain, tools, the installed SDK and its metadata).") var native = false
    @Flag(help: "--images, --volumes, --cache and --native.") var all = false
    @Flag(help: "With --old: do not ask.") var yes = false
    @Flag(help: "Print what would be removed, and remove nothing.") var dryRun = false

    func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let home = env["HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
        let cacheRoot = SetupPlan.cacheRoot(env: env, home: home)
        let doImages = images || all, doVolumes = volumes || all, doCache = cache || all, doOld = old || doImages, doNative = native || all
        let listOnly = !(doOld || doVolumes || doCache || doNative)
        // The native install: its home, and, when it has a toolchain record, the SDK and metadata its setup installed
        // (never an image's; an SDK put there by `xless sdk install` alone stays).
        let layout = NativeLayout(env: env)
        let nativePaths = ([layout.root] + (fm.fileExists(atPath: layout.record.path) ? [DarwinSDKLocator.bundle(env: env), ToolchainMeta.defaultLocation(env: env)] : []))
            .filter { !$0.path.hasPrefix("/opt/xless/") && fm.fileExists(atPath: $0.path) }
        var removing = !listOnly && !dryRun

        // --old alone: what each tag is now, for the check right before it goes.
        let asks = old && !doImages
        var imageRefs: [String] = [], volumeNames: [String] = [], oldIDs: [String: String] = [:]
        if listOnly || doOld || doVolumes {
            do {
                let ls = ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"]
                if listOnly || doOld {
                    let all = try Shell.docker(ls, stage: .sdk).stdout
                    if asks {
                        for ref in CleanPlan.old(fromListing: all, labelled: try Shell.docker(ls + ["--filter", "label=\(ImageLabel.sdk)"], stage: .sdk).stdout) {
                            guard let image = LocalImages.here.image(ref), CleanPlan.isStillOld(ref, id: image.id, now: image) else { continue }
                            imageRefs.append(ref)
                            oldIDs[ref] = image.id
                        }
                    } else { imageRefs = CleanPlan.images(fromListing: all) }
                }
                if listOnly || doVolumes {
                    volumeNames = CleanPlan.volumes(fromListing: try Shell.docker(["volume", "ls", "--format", "{{.Name}}"], stage: .sdk).stdout)
                }
            } catch {
                guard listOnly else {
                    throw XlessError(.sdk, "docker does not answer, so the images and volumes cannot be listed: \(Self.firstLine(error))",
                                     fix: "start Docker (and check that you can run docker without sudo), then run xless clean again; --cache alone needs no Docker")
                }
                say("docker does not answer: images and volumes not listed")
            }
        }
        let cacheExists = fm.fileExists(atPath: cacheRoot.path)

        let mustAsk = removing && asks && !imageRefs.isEmpty && !yes
        let verb = removing && !mustAsk ? "removing" : (dryRun || mustAsk ? "would remove" : "found")
        if listOnly || doOld {
            say("\(verb) \(imageRefs.count) image tag\(imageRefs.count == 1 ? "" : "s")" + (imageRefs.isEmpty ? "" : ":"))
            for r in imageRefs { say("  \(r)") }
        }
        if doOld {
            say("\(removing && !mustAsk ? "then removing" : "and") the untagged older builds (docker image prune --filter label=\(CleanPlan.imageLabel))")
        }
        if listOnly || doVolumes {
            say("\(verb) \(volumeNames.count) volume\(volumeNames.count == 1 ? "" : "s")" + (volumeNames.isEmpty ? "" : ":"))
            for v in volumeNames { say("  \(v)") }
        }
        if listOnly || doCache {
            say(cacheExists ? "\(verb) the cache \(cacheRoot.path) (\(Self.size(of: cacheRoot)))" : "no cache at \(cacheRoot.path)")
        }
        if listOnly || doNative {
            if nativePaths.isEmpty { say("no native install") }
            for p in nativePaths { say("\(verb) the native install's \(p.path) (\(Self.size(of: p)))") }
        }
        if listOnly {
            say("nothing removed: pass --images, --old, --volumes, --cache, --native or --all (--dry-run to see what they would remove)")
            return
        }
        if mustAsk {
            removing = try AccountConfirm.confirm("Remove \(imageRefs.count == 1 ? "this image tag" : "these \(imageRefs.count) image tags"), and the untagged older builds?",
                                                  action: "removing the images of an older xless", yes: yes, stage: .sdk)
            if !removing { say("cancelled; nothing was removed") }
        }
        guard removing else { return }

        var failures: [String] = []
        if !volumeNames.isEmpty {
            do { try Shell.docker(["volume", "rm"] + volumeNames, stage: .sdk, passthrough: true) } catch {
                failures.append("some volumes were not removed (one in use by a container? docker ps -a)")
            }
        }
        if asks {
            for ref in imageRefs {
                guard CleanPlan.isStillOld(ref, id: oldIDs[ref] ?? "", now: LocalImages.here.image(ref)) else {
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
            for p in nativePaths {
                do { try fm.removeItem(at: p) } catch { failures.append("\(p.path) was not fully removed (\(Self.firstLine(error)))") }
            }
        }
        if !failures.isEmpty {
            throw XlessError(.sdk, failures.joined(separator: "; "), fix: "see above, then run xless clean again")
        }
        say("done. Docker's build cache is shared with other projects and was left alone; docker builder prune frees it")
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
