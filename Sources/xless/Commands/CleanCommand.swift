import ArgumentParser
import Foundation
import XlessCore
import XlessSDK

/// `xless clean`: frees the disk space `xless setup` and `xless run` use. It removes only what xless made: the native
/// install (`NativeLayout`, with the SDK and metadata it installed), the four images' local tags (and the older builds of
/// them setup left untagged), xless's Docker volumes, and the cache directory.
/// BuildKit's build cache is shared with every other Docker project, so it is only pointed at, never pruned.
struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove the xless images, Docker volumes and cache, to free disk space.",
        discussion: """
        With no option it lists what there is and removes nothing. --images removes every local tag of xless-base, xless, \
        xless-tauri and xless-rn, then the older builds of them that a later xless setup left untagged (label \
        \(CleanPlan.imageLabel)); --old removes only those older builds, which is what an upgrade leaves behind. --volumes removes the volumes xless docker creates (\(CleanPlan.volumes.joined(separator: ", ")) \
        and \(CleanPlan.volumePrefix)*). --cache removes $XDG_CACHE_HOME/xless (default ~/.cache/xless): the exported SDKs, \
        Tauri work copies and downloads. --native removes the native install: $XLESS_NATIVE_HOME (default \
        ~/.local/share/xless-native: the Swift toolchain, xtool, rcodesign), the installed Darwin SDK and its \
        toolchain-meta.json. --all does the four. The xless install itself (~/.local/bin/xless and \
        ~/.local/share/xless) and Docker's build cache, which other projects share (docker builder prune), are left alone.
        """)

    @Flag(help: "Remove the xless images (every tag, and older untagged builds).") var images = false
    @Flag(help: "Remove only the older builds of the images that a later xless setup left untagged (after an upgrade).") var old = false
    @Flag(help: "Remove the Docker volumes xless docker creates.") var volumes = false
    @Flag(help: "Remove the cache directory ($XDG_CACHE_HOME/xless, default ~/.cache/xless).") var cache = false
    @Flag(help: "Remove the native install (toolchain, tools, the installed SDK and its metadata).") var native = false
    @Flag(help: "--images, --volumes, --cache and --native.") var all = false
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
        let removing = !listOnly && !dryRun

        var imageRefs: [String] = [], volumeNames: [String] = []
        if listOnly || doImages || doVolumes {
            do {
                if listOnly || doImages {
                    imageRefs = CleanPlan.images(fromListing: try Shell.run("docker", ["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"], stage: .sdk).stdout)
                }
                if listOnly || doVolumes {
                    volumeNames = CleanPlan.volumes(fromListing: try Shell.run("docker", ["volume", "ls", "--format", "{{.Name}}"], stage: .sdk).stdout)
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

        let verb = removing ? "removing" : (dryRun ? "would remove" : "found")
        if listOnly || doImages {
            say("\(verb) \(imageRefs.count) image tag\(imageRefs.count == 1 ? "" : "s")" + (imageRefs.isEmpty ? "" : ":"))
            for r in imageRefs { say("  \(r)") }
        }
        if doOld {
            say("\(doImages ? (removing ? "then removing" : "and") : verb) the untagged older builds (docker image prune --filter label=\(CleanPlan.imageLabel))")
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
        guard removing else { return }

        var failures: [String] = []
        if !volumeNames.isEmpty {
            do { try Shell.run("docker", ["volume", "rm"] + volumeNames, stage: .sdk, passthrough: true) } catch {
                failures.append("some volumes were not removed (one in use by a container? docker ps -a)")
            }
        }
        if doImages && !imageRefs.isEmpty {
            do { try Shell.run("docker", ["image", "rm"] + imageRefs, stage: .sdk, passthrough: true) } catch {
                failures.append("some images were not removed (one in use by a container? docker ps -a)")
            }
        }
        if doOld {
            do { try Shell.run("docker", ["image", "prune", "--force", "--filter", "label=\(CleanPlan.imageLabel)"], stage: .sdk, passthrough: true) } catch {
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
