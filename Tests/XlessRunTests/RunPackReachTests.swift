import Foundation
import Testing
import XlessCore
import XlessImages
@testable import XlessRun

/// No container of a run can write the pack through another of its mounts: a writable mount that is a pack volume, or that holds a
/// directory store or is in it (as files: a link does not hide it), stops the run before any container starts or any secret is written.
@Suite struct RunPackReachTests {
    let home: RunHome
    init() throws { home = try RunHome() }

    /// The packs of both Xcodes in a directory store at `store`, and no volume.
    private func directoryStore(_ store: String) throws {
        for x in RunHome.xcodes { try home.packs.write(home.packs.current(x.xcode, x.build), in: store) }
        home.packs.removeAll()
    }

    private func run(_ arguments: [String], _ environment: [String: String]) throws -> (host: FakeRunHost, code: Int32) {
        let host = FakeRunHost(answer: home.answer())
        let code = try home.run(arguments, docker: true, host: host, environment: home.files().merging(environment) { $1 })
        return (host, code)
    }

    /// Refused: the usage code, the last line, and nothing started or written.
    private func refused(_ arguments: [String], _ environment: [String: String]) throws -> String {
        let (host, code) = try run(arguments, environment)
        #expect(code == 2, "\(host.lines)")
        #expect(!host.allSteps.contains { $0.isContainer || $0.isPackSetup }, "\(host.allSteps.map(\.line))")
        #expect(!home.exists(home.secrets))
        return host.lines.last ?? ""
    }

    @Test func writableMountsInEveryForm() {
        let words = ["--mount", "type=bind,src=/a,dst=/w", "--mount", "type=bind,src=/b,dst=/r,readonly", "--mount", "type=volume,src=v1,dst=/v",
                     "--mount", "src=v2,dst=/d", "--mount", "type=bind,\"src=/c,d\"\"e\",dst=/q", "--mount", "type=bind,src=/e,dst=/e,readonly=false",
                     "--mount", "type=bind,src=/f,dst=/f,ro=true", "-v", "/g:/g", "-v", "/h:/h:ro", "-v", "vol:/x:rw", "--volume=/i:/i", "-v", "/anon",
                     "--mount=type=bind,source=/j,target=/j", "--mount", "type=tmpfs,dst=/t", "-e", "X=1", "--volume", "/k:/k:z,ro"]
        #expect(RunPack.writableMounts(words) == [
            WritableMount(kind: .bind, source: "/a", target: "/w"), WritableMount(kind: .volume, source: "v1", target: "/v"),
            WritableMount(kind: .volume, source: "v2", target: "/d"), WritableMount(kind: .bind, source: "/c,d\"e", target: "/q"),
            WritableMount(kind: .bind, source: "/e", target: "/e"), WritableMount(kind: .bind, source: "/g", target: "/g"),
            WritableMount(kind: .volume, source: "vol", target: "/x"), WritableMount(kind: .bind, source: "/i", target: "/i"),
            WritableMount(kind: .bind, source: "/j", target: "/j"),
        ])
    }

    @Test func aStoreInTheProjectIsRefused() throws {
        let store = "\(home.project)/xcodes"
        try directoryStore(store)
        let last = try refused([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(last == "testflight: XLESS_XCODES (\(store)), the store of the Xcode packs, and \(home.project), which a container of this run would mount writable at /work, "
            + "overlap (the store is in \(home.project)): the build could change the pack that the steps after it read. Keep the store and \(home.project) apart: "
            + "set XLESS_XCODES to a directory outside it, beside it for one", "\(last)")
    }

    @Test func aProjectInTheStoreIsRefused() throws {
        let store = "\(home.root)/xcodes"
        try directoryStore(store)
        try FileManager.default.createDirectory(atPath: "\(store)/proj", withIntermediateDirectories: true)
        try home.write("xcodes/proj/xless.yml", "name: App\n")
        let last = try refused(["\(store)/proj", "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(last.contains("and \(store)/proj, which a container of this run would mount writable at /work, overlap (\(store)/proj is in the store)"), "\(last)")
    }

    /// An overlay's build mounts ~/.cache/xless/{work,downloads} writable (and inputs, for Cargo): the store in one, or one in the store.
    @Test(arguments: [("tauri", ".cache/xless/work/xcodes", "/cache/work"), ("tauri", ".cache/xless/downloads/xcodes", "/cache/downloads"),
                      ("cargo", ".cache/xless/inputs/xcodes", "/cache/inputs"), ("tauri", ".cache", "/cache/work")])
    func anOverlayCacheThatOverlapsTheStoreIsRefused(type: String, store: String, target: String) throws {
        let store = "\(home.home)/\(store)"
        try directoryStore(store)
        try home.write("ov/app.yml", "type: \(type)\nsource: ../src\nteamID: ABCDE12345\n")
        let last = try refused(["--config", home.overlay], ["XLESS_XCODES": store])
        #expect(last.hasPrefix("testflight: XLESS_XCODES (\(store)), the store of the Xcode packs, and \(home.home)/.cache/xless/"), "\(last)")
        #expect(last.contains("which a container of this run would mount writable at \(target), overlap ("), "\(last)")
    }

    @Test func aPackVolumeAsTheWorkVolumeIsRefused() throws {
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\nteamID: ABCDE12345\n")
        let last = try refused(["--config", home.overlay], ["XLESS_RN_WORK_VOLUME": "xless-xcode-26.2-17C52-arm64"])
        #expect(last == "testflight: the volume xless-xcode-26.2-17C52-arm64, which a container of this run would mount writable at /cache/work, is a pack volume "
            + "(its name starts with xless-xcode-), and no container of a run may write a pack: the build could change what the steps after it read; "
            + "set XLESS_RN_WORK_VOLUME to a name that does not start with xless-xcode-", "\(last)")
        // any pack volume, not only the pinned Xcode's
        let other = try refused(["--config", home.overlay], ["XLESS_RN_WORK_VOLUME": "xless-xcode-99.0-99Z99-arm64"])
        #expect(other.contains("the volume xless-xcode-99.0-99Z99-arm64, which"), "\(other)")
    }

    /// Refused before anything is prepared: a stale pack is not prepared again (nor a kit built) for a run that cannot start.
    @Test func theReachIsRefusedBeforeAStalePackIsPrepared() throws {
        home.packs.change("xless-xcode-27.0-27A266a-arm64") { $0.parts["swift-build"] = String(repeating: "0", count: 64) }
        try home.export("27.0", "27A266a")
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\nteamID: ABCDE12345\nxcode: \"27.0\"\n")
        let last = try refused(["--config", home.overlay], ["XLESS_RN_WORK_VOLUME": "xless-xcode-26.2-17C52-arm64"])
        #expect(last.contains("the volume xless-xcode-26.2-17C52-arm64, which"), "\(last)")
        #expect(home.packs.prepared.isEmpty)
    }

    /// The store named through a link to the project: compared as files, it is in the project all the same.
    @Test func aLinkDoesNotHideTheOverlap() throws {
        try directoryStore("\(home.project)/xcodes")
        try FileManager.default.createSymbolicLink(atPath: "\(home.root)/alias", withDestinationPath: home.project)
        let store = "\(home.root)/alias/xcodes"
        let last = try refused([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(last.contains("XLESS_XCODES (\(store)), the store of the Xcode packs, and \(home.project), which") && last.contains("overlap (the store is in \(home.project))"), "\(last)")
    }

    @Test func aStoreBesideTheProjectIsAccepted() throws {
        let store = "\(home.root)/xcodes"
        try directoryStore(store)
        try home.write("proj/xless.yml", "name: App\nxcode: \"26.2\"\n")
        let (project, projectCode) = try run([home.project, "--to", "finalize"], ["XLESS_XCODES": store])
        #expect(projectCode == 0, "\(project.lines)")
        let (overlay, overlayCode) = try run(["--config", home.overlay], ["XLESS_XCODES": store])
        #expect(overlayCode == 0, "\(overlay.lines)")
        // and a work volume of its own
        try home.write("ov/app.yml", "type: react-native\nsource: ../src\nteamID: ABCDE12345\n")
        let (rn, rnCode) = try run(["--config", home.overlay, "--to", "finalize"], ["XLESS_XCODES": store, "XLESS_RN_WORK_VOLUME": "my-work"])
        #expect(rnCode == 0, "\(rn.lines)")
    }
}
