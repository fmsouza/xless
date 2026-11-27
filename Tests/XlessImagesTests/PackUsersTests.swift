import Foundation
import Testing
@testable import XlessImages

/// Which running containers use a pack, before it is prepared (`PackUsers`).
@Suite struct PackUsersTests {
    /// A docker that answers `ps` and `inspect` from `rows`, and records what it was asked.
    private final class Fake: @unchecked Sendable {
        var asked: [[String]] = []
        var code: Int32 = 0
        var ps = "", ids = "", inspect = ""
        func answer(_ words: [String]) -> (code: Int32, output: String) {
            asked.append(words)
            if words.first == "inspect" { return (code, inspect) }
            return (code, words.contains("-q") ? ids : ps)
        }
        var users: PackUsers { PackUsers { self.answer($0) } }
    }

    @Test func aVolumeIsAskedByItsName() throws {
        let fake = Fake()
        fake.ps = "busy\txless:0.14.0-arm64-tauri\t77.1700000000\nmine\txless:0.14.0-arm64\t42.1700000000\nsetup\txless:0.14.0-arm64\t\n"
        let users = try fake.users.of(.volumes, xcode: "26.2", build: "17C52", arch: "arm64", excludingRun: "42.1700000000")
        #expect(users == ["busy (xless:0.14.0-arm64-tauri)", "setup (xless:0.14.0-arm64)"], "the run's own containers do not count")
        #expect(fake.asked == [["ps", "--filter", "volume=xless-xcode-26.2-17C52-arm64", "--format", "{{.Names}}\t{{.Image}}\t{{.Label \"xless.run\"}}"]])
        fake.ps = ""
        #expect(try fake.users.of(.volumes, xcode: "26.2", build: "17C52", arch: "arm64").isEmpty)
    }

    @Test func aDirectoryStoreIsAskedByTheContainersMounts() throws {
        let fake = Fake()
        let store = PackStore.directory(URL(fileURLWithPath: "/data/xcodes"))
        // nothing runs: no inspect
        #expect(try fake.users.of(store, xcode: "26.2", build: "17C52", arch: "arm64").isEmpty)
        #expect(fake.asked == [["ps", "-q"]])
        fake.asked = []
        fake.ids = "a1\nb2\nc3\nd4\ne5\n"
        func mounts(_ sources: String...) -> String { "[" + sources.map { "{\"Type\":\"bind\",\"Source\":\"\($0)\"}" }.joined(separator: ",") + "]" }
        fake.inspect = [
            "/pack\timg\t<no value>\t\(mounts("/data/xcodes/26.2-17C52-arm64"))",
            "/inside\timg\t<no value>\t\(mounts("/elsewhere", "/data/xcodes/26.2-17C52-arm64/toolchain"))",
            "/holder\timg\t<no value>\t\(mounts("/data"))",
            "/otherpack\timg\t<no value>\t\(mounts("/data/xcodes/27.0-27A266a-arm64", "/data/xcodes-old"))",
            "/own\timg\t42.1\t\(mounts("/data/xcodes"))",
        ].joined(separator: "\n") + "\n"
        let users = try fake.users.of(store, xcode: "26.2", build: "17C52", arch: "arm64", excludingRun: "42.1")
        #expect(users == ["pack (img)", "inside (img)", "holder (img)"])
        #expect(fake.asked.count == 2 && fake.asked[1].prefix(2) == ["inspect", "--format"] && fake.asked[1].suffix(5) == ["a1", "b2", "c3", "d4", "e5"])
    }

    /// Compared as files: a store named through a link is the directory a container mounts by its real path, and the other
    /// way round.
    @Test func aDirectoryStoreIsComparedByRealPaths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("pack-users-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let real = base.appendingPathComponent("data/xcodes"), link = base.appendingPathComponent("link")
        try fm.createDirectory(at: real.appendingPathComponent("26.2-17C52-arm64/toolchain"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("data"))
        let realPath = try #require(realpath(real.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let fake = Fake()
        fake.ids = "a1\nb2\n"
        func mounts(_ sources: String...) -> String { "[" + sources.map { "{\"Type\":\"bind\",\"Source\":\"\($0)\"}" }.joined(separator: ",") + "]" }
        fake.inspect = [
            "/byreal\timg\t<no value>\t\(mounts(realPath + "/26.2-17C52-arm64"))",
            "/bylink\timg\t<no value>\t\(mounts(link.path + "/xcodes/26.2-17C52-arm64/toolchain"))",
        ].joined(separator: "\n") + "\n"
        // the store named through the link: both count
        #expect(try fake.users.of(.directory(link.appendingPathComponent("xcodes")), xcode: "26.2", build: "17C52", arch: "arm64") == ["byreal (img)", "bylink (img)"])
        // the store by its real path: both count
        #expect(try fake.users.of(.directory(real), xcode: "26.2", build: "17C52", arch: "arm64") == ["byreal (img)", "bylink (img)"])
    }

    @Test func aDockerThatCannotSayIsAProblem() {
        let fake = Fake()
        fake.code = 1
        #expect(throws: ImageProblem.self) { try fake.users.of(.volumes, xcode: "26.2", build: "17C52", arch: "arm64") }
        #expect(throws: ImageProblem.self) { try fake.users.of(.directory(URL(fileURLWithPath: "/d")), xcode: "26.2", build: "17C52", arch: "arm64") }
    }

    @Test func theRefusalNamesThemAndWhatToDo() {
        let one = PackUsers.refusal(pack: "26.2-17C52-arm64", place: "the volume xless-xcode-26.2-17C52-arm64", users: ["busy (img)"])
        #expect(one.description == "the pack 26.2-17C52-arm64 in the volume xless-xcode-26.2-17C52-arm64 is used by a running container: busy (img); "
            + "preparing it now would replace it under it; wait for that run to end, or stop it (docker stop busy), then run this again")
        let two = PackUsers.refusal(pack: "p", place: "q", users: ["a (i)", "b (j)"])
        #expect(two.description.contains("is used by running containers: a (i), b (j); preparing it now would replace it under them; wait for those runs to end, or stop them (docker stop a b)"))
    }
}
