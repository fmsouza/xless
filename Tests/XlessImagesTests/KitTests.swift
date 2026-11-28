import Foundation
import Testing
@testable import XlessImages

@Suite struct KitTests {
    let docker = FakeDocker()
    let share: URL
    let base: LocalImage

    init() throws {
        share = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID())")
        for kit in Kit.allCases {
            let directory = kit.directory(share: share)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("FROM \(kit.rawValue)\n".utf8).write(to: directory.appendingPathComponent("Dockerfile"))
        }
        docker.addBase()
        base = docker.images["xless:0.14.0-arm64"]!
    }

    private func add(_ kit: Kit, base id: String? = nil, recipe: String? = nil, layers: [String] = ["a", "b", "c"], arch: String = "arm64") throws {
        docker.addBase(arch: arch, name: kit.image(on: base), id: "sha256:kit", layers: layers)
        let recipe = try recipe ?? kit.recipe(share: share)
        docker.images[kit.image(on: base)]?.labels.merge(["dev.xless.kit": kit.rawValue, "dev.xless.kit.base": id ?? base.id, "dev.xless.kit.recipe": recipe]) { $1 }
    }

    @Test func theKitsHaveTheNamesPeopleUse() {
        #expect(Kit(named: "tauri") == .tauri && Kit(named: "cargo") == .tauri && Kit(named: "react-native") == .reactNative && Kit(named: "expo") == .reactNative)
        #expect(Kit(named: "Tauri") == nil && Kit(named: "") == nil)
        #expect(Kit(overlayType: "react-native") == .reactNative && Kit(overlayType: "cargo") == .tauri && Kit(overlayType: "tauri") == .tauri)
    }

    @Test func kitImageIsNamedAfterTheBase() {
        #expect(Kit.tauri.image(on: base) == "xless:0.14.0-arm64-tauri" && Kit.reactNative.image(on: base) == "xless:0.14.0-arm64-react-native")
        var checkout = base
        checkout.name = "xless:0123456789ab-dirty-arm64"
        #expect(Kit.tauri.image(on: checkout) == "xless:0123456789ab-dirty-arm64-tauri")
    }

    @Test func itIsBuiltFromTheShippedFolderAlone() throws {
        let words = try Kit.reactNative.build(on: base, share: share)
        let recipe = try Kit.reactNative.recipe(share: share)
        #expect(words == ["build", "--platform", "linux/arm64", "--pull=false", "--provenance=false", "--build-arg", "XLESS_IMAGE=xless:0.14.0-arm64",
                          "--label", "dev.xless.kit=react-native", "--label", "dev.xless.kit.base=sha256:base", "--label", "dev.xless.kit.recipe=\(recipe)",
                          "-t", "xless:0.14.0-arm64-react-native", "\(share.path)/docker/react-native"])
        try FileManager.default.removeItem(at: Kit.tauri.directory(share: share))
        #expect(problem { try Kit.tauri.build(on: base, share: share) }.contains("xless's Dockerfile for Tauri and Cargo apps is missing: \(share.path)/docker/tauri/Dockerfile"))
    }

    @Test func theRecipeIsWhatTheFolderHolds() throws {
        let before = try Kit.tauri.recipe(share: share)
        let other = try Kit.reactNative.recipe(share: share)
        #expect(before.count == 64 && before != other)
        let file = Kit.tauri.directory(share: share).appendingPathComponent("more")
        try Data("x".utf8).write(to: file)
        let more = try Kit.tauri.recipe(share: share)
        #expect(more != before)
        try FileManager.default.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("other"))
        let renamed = try Kit.tauri.recipe(share: share)
        #expect(renamed != more)
    }

    /// An installed share directory can be links (Homebrew's, stow's): the files are what counts.
    @Test func theRecipeOfAFolderBehindALinkIsTheFiles() throws {
        let linked = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: linked) }
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("docker"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("docker/tauri"), withDestinationURL: Kit.tauri.directory(share: share))
        let before = try Kit.tauri.recipe(share: linked)
        let files = try Kit.tauri.recipe(share: share)
        #expect(before == files)
        try Data("FROM newer\n".utf8).write(to: Kit.tauri.directory(share: share).appendingPathComponent("Dockerfile"))
        let after = try Kit.tauri.recipe(share: linked)
        #expect(after != before)
    }

    /// The builder is docker's own, which sees the local images: named after the context.
    @Test func dockersOwnBuilderBuildsIt() throws {
        let words = try Kit.tauri.build(on: base, share: share, builder: "colima")
        #expect(words.starts(with: ["build", "--builder", "colima", "--platform", "linux/arm64", "--pull=false"]))
        func builder(_ code: Int32, _ output: String) -> String? { LocalImages { words in words == ["context", "show"] ? (code, output) : (1, "") }.builder }
        #expect(builder(0, "colima\n") == "colima" && builder(0, "default\n") == "default")
        for (code, output) in [(1, "colima\n"), (0, ""), (0, "--x\n"), (0, "a b\n")] as [(Int32, String)] { #expect(builder(code, output) == nil, "\(output)") }
    }

    @Test func kitStateIsStaleWhenTheBaseChanged() throws {
        func state() throws -> Kit.State { try docker.local.state(of: .tauri, on: base, share: share) }
        #expect(try state() == .missing)
        try add(.tauri)
        #expect(try state() == .current(docker.images["xless:0.14.0-arm64-tauri"]!))
        try add(.tauri, base: "sha256:older")
        #expect(try state() == .stale("it is not built on xless:0.14.0-arm64 as it is now"))
        try add(.tauri, layers: ["a", "c"]) // whatever its labels say
        #expect(try state() == .stale("it is not built on xless:0.14.0-arm64 as it is now"))
        try add(.tauri, recipe: "old")
        #expect(try state() == .stale("xless's Dockerfile for it has changed"))
        try add(.tauri, arch: "amd64")
        #expect(try state() == .stale("it is for amd64"))
        docker.addBase(name: "xless:0.14.0-arm64-tauri", layers: ["a", "b"]) // no kit's labels
        #expect(try state() == .stale("xless did not build it"))
    }
}
