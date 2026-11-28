import Foundation
import Testing
import XlessCore
@testable import XlessImages

/// A docker whose pack volumes are a list, and whose one reading container prints what `packs` holds for each mounted volume.
private final class FakeVolumes: @unchecked Sendable {
    var volumes: [String] = []
    /// Volumes without xless's label (made by hand: `docker volume create <name>`); a listing filtered by the label leaves them out.
    var unlabelled: Set<String> = []
    /// The pack.json a volume holds (by volume name); a volume missing here has none, so its `cat` fails.
    var packs: [String: String] = [:]
    var runFails = false
    private(set) var asked: [[String]] = []

    func answer(_ words: [String]) -> (code: Int32, output: String) {
        asked.append(words)
        if words.starts(with: ["volume", "ls"]) {
            let byLabel = words.contains("label=\(PackVolumes.label)")
            return (0, volumes.filter { !byLabel || !unlabelled.contains($0) }.map { $0 + "\n" }.joined())
        }
        guard words.first == "run", !runFails else { return (1, "") }
        // The volumes the container mounts, in order: /v/<i>.
        var mounted: [Int: String] = [:]
        for w in words where w.hasPrefix("type=volume,") {
            let fields = Dictionary(uniqueKeysWithValues: w.split(separator: ",").compactMap { f -> (String, String)? in
                let kv = f.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            })
            if let dst = fields["dst"], let src = fields["src"], let i = Int(dst.dropFirst("/v/".count)) { mounted[i] = src }
        }
        var out = ""
        for path in words.drop(while: { $0 != "sh" }).dropFirst(4) {
            out += "\n\(PackVolumes.marker) \(path)\n"
            let i = Int(path.split(separator: "/")[1])!
            if let volume = mounted[i], let json = packs[volume] { out += json }
        }
        return (0, out)
    }

    var local: PackVolumes { PackVolumes { self.answer($0) } }
}

private func manifest(_ xcode: String, _ build: String, _ arch: String) -> PackManifest {
    PackManifest(format: 1, xcode: xcode, build: build, arch: arch, swift: "6.2.3", mode: .separate, parts: ["sdk": "s", "swift-build": "w"])
}

private func json(_ m: PackManifest) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try! enc.encode(m), as: UTF8.self) + "\n"
}

@Suite struct PackVolumesTests {
    @Test func nameAndMountPath() {
        #expect(PackVolumes.name(xcode: "26.2", build: "17C52", arch: "arm64") == "xless-xcode-26.2-17C52-arm64")
        #expect(PackVolumes.name(xcode: "26.2", build: "17C52", arch: "arm64").hasPrefix(PackVolumes.prefix))
        // The volume is the store: mounted at /xcodes, the pack is the directory of its name in it.
        #expect(PackVolumes.mountPath("26.2-17C52-arm64") == "/xcodes/26.2-17C52-arm64")
        #expect(PackStore.root == "/xcodes")
    }

    @Test func theStoreIsVolumesUnlessXcodesNamesADirectory() {
        #expect(PackStore(env: [:]) == .volumes)
        #expect(PackStore(env: ["XLESS_XCODES": ""]) == .volumes)
        #expect(PackStore(env: ["XLESS_XCODES": "/data/xcodes"]) == .directory(URL(fileURLWithPath: "/data/xcodes")))
    }

    @Test func aVolumeIsMountedAsTheStoreReadOnlyUnlessWritable() {
        #expect(PackStore.volumes.mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: true)
                == ["--mount", "type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/xcodes"])
        #expect(PackStore.volumes.mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: false)
                == ["--mount", "type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/xcodes,readonly"])
        let dir = PackStore.directory(URL(fileURLWithPath: "/data/xcodes"))
        #expect(dir.mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: true) == ["--mount", "type=bind,src=/data/xcodes,dst=/xcodes"])
        // read-only, of a directory that may hold several packs: that pack's directory alone, where a volume puts it
        #expect(dir.mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: false)
                == ["--mount", "type=bind,src=/data/xcodes/26.2-17C52-arm64,dst=/xcodes/26.2-17C52-arm64,readonly"])
        // docker reads --mount as CSV: a comma or a quote in a path is quoted.
        #expect(PackStore.directory(URL(fileURLWithPath: "/data/a,b\"c")).mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: true)
                == ["--mount", "type=bind,\"src=/data/a,b\"\"c\",dst=/xcodes"])
        #expect(PackStore.directory(URL(fileURLWithPath: "/data/a,b\"c")).mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: false)
                == ["--mount", "type=bind,\"src=/data/a,b\"\"c/26.2-17C52-arm64\",dst=/xcodes/26.2-17C52-arm64,readonly"])
        // and a line break: docker reads the first CSV record alone, which would end the field there
        #expect(PackStore.directory(URL(fileURLWithPath: "/data/a\nb")).mount(xcode: "26.2", build: "17C52", arch: "arm64", writable: true)
                == ["--mount", "type=bind,\"src=/data/a\nb\",dst=/xcodes"])
        #expect(PackStore.mountOption(["type": "bind", "src": "/a\rb", "dst": "/x"], readonly: false) == "type=bind,\"src=/a\rb\",dst=/x")
    }

    @Test func manifestsSkipVolumesWithoutAPack() throws {
        let fake = FakeVolumes()
        fake.volumes = ["xless-xcode-26.2-17C52-arm64", "xless-xcode-27.0-27A266a-arm64"]
        fake.packs = ["xless-xcode-26.2-17C52-arm64": json(manifest("26.2", "17C52", "arm64"))]
        let found = try fake.local.manifests(arch: "arm64", image: "xless:0.14.0-arm64")
        #expect(found == [manifest("26.2", "17C52", "arm64")])
        // One container of the image reads them all, each volume read-only, with no network.
        let runs = fake.asked.filter { $0.first == "run" }
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.starts(with: ["run", "--rm", "--pull=never", "--platform", "linux/arm64", "--network", "none"]))
        #expect(run.contains("type=volume,src=xless-xcode-26.2-17C52-arm64,dst=/v/0,readonly"))
        #expect(run.contains("type=volume,src=xless-xcode-27.0-27A266a-arm64,dst=/v/1,readonly"))
        #expect(run.contains("xless:0.14.0-arm64"))
        #expect(Array(run.suffix(2)) == ["/v/0/26.2-17C52-arm64/pack.json", "/v/1/27.0-27A266a-arm64/pack.json"])
        #expect(!run.contains("--user") && !run.contains { $0.hasPrefix("type=bind") })
    }

    @Test func aPackJSONThatIsNotThatVolumesPackIsSkipped() throws {
        let fake = FakeVolumes()
        fake.volumes = ["xless-xcode-26.2-17C52-arm64", "xless-xcode-27.0-27A266a-arm64"]
        // the 27.0 volume holds a pack.json that says 26.2; the 26.2 one holds no JSON at all
        fake.packs = ["xless-xcode-27.0-27A266a-arm64": json(manifest("26.2", "17C52", "arm64")), "xless-xcode-26.2-17C52-arm64": "not json\n"]
        #expect(try fake.local.manifests(arch: "arm64", image: "i").isEmpty)
    }

    @Test func manifestsOnlyListThisArchitecture() throws {
        let fake = FakeVolumes()
        fake.volumes = ["xless-xcode-26.2-17C52-amd64", "xless-xcode-26.2-17C52-arm64", "carryon_db", "xless-xcode-junk"]
        fake.packs = ["xless-xcode-26.2-17C52-amd64": json(manifest("26.2", "17C52", "amd64")), "xless-xcode-26.2-17C52-arm64": json(manifest("26.2", "17C52", "arm64"))]
        #expect(try fake.local.names(arch: "arm64") == ["xless-xcode-26.2-17C52-arm64"])
        #expect(try fake.local.manifests(arch: "arm64", image: "i") == [manifest("26.2", "17C52", "arm64")])
        let run = try #require(fake.asked.first { $0.first == "run" })
        #expect(!run.joined(separator: " ").contains("amd64"))
        // The listing asks for every volume, and takes those whose name has a pack's shape.
        #expect(fake.asked.first == ["volume", "ls", "--format", "{{.Name}}"])
        // None of this architecture: no container is started.
        let none = FakeVolumes()
        none.volumes = ["xless-xcode-26.2-17C52-amd64"]
        #expect(try none.local.manifests(arch: "arm64", image: "i").isEmpty)
        #expect(!none.asked.contains { $0.first == "run" })
    }

    /// A volume made by hand (`docker volume create xless-xcode-26.2-17C52-arm64`, then a setup into it) has no label: it is a
    /// pack volume by its name, as `xless clean --packs` takes it. A name that only starts like one is not.
    @Test func aVolumeMadeByHandIsAPackVolumeByItsName() throws {
        let fake = FakeVolumes()
        fake.volumes = ["xless-xcode-26.2-17C52-arm64", "xless-xcode-26.2-17C52-arm64-old", "xless-xcode-backup", "xless-xcode-26.2-17C52-x86"]
        fake.unlabelled = ["xless-xcode-26.2-17C52-arm64"]
        fake.packs = ["xless-xcode-26.2-17C52-arm64": json(manifest("26.2", "17C52", "arm64"))]
        #expect(try fake.local.names(arch: "arm64") == ["xless-xcode-26.2-17C52-arm64"])
        #expect(try fake.local.manifests(arch: "arm64", image: "i") == [manifest("26.2", "17C52", "arm64")])
        #expect(PackVolumes.parse("xless-xcode-26.2-17C52-arm64").map { [$0.xcode, $0.build, $0.arch] } == ["26.2", "17C52", "arm64"])
        #expect(PackVolumes.parse("xless-xcode-26.2-17C52-arm64-old") == nil)
        #expect(PackVolumes.parse("xless-xcode-backup") == nil)
    }

    @Test func aContainerThatCannotReadIsAProblem() {
        let fake = FakeVolumes()
        fake.volumes = ["xless-xcode-26.2-17C52-arm64"]
        fake.runFails = true
        #expect(problem { try fake.local.manifests(arch: "arm64", image: "xless:0.14.0-arm64") }.contains("xless:0.14.0-arm64"))
        let unlisted = PackVolumes { _ in (1, "") }
        #expect(problem { try unlisted.names(arch: "arm64") }.contains("docker volume ls"))
    }

    @Test func aVolumeIsCreatedWithItsLabel() {
        #expect(PackVolumes.create("xless-xcode-26.2-17C52-arm64") == ["docker", "volume", "create", "--label", "org.xless.pack=true", "xless-xcode-26.2-17C52-arm64"])
    }
}
