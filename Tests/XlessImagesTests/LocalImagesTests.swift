import Foundation
import Testing
@testable import XlessImages

/// A Docker whose images are a dictionary.
final class FakeDocker: @unchecked Sendable {
    var images: [String: LocalImage] = [:]
    var answers = true
    private(set) var asked: [[String]] = []

    func add(_ name: String, id: String = "sha256:base", arch: String = "arm64", labels: [String: String] = [:], layers: [String] = ["a", "b"]) {
        images[name] = LocalImage(name: name, id: id, architecture: arch, labels: labels, layers: layers)
    }

    /// An image as scripts/docker-images.sh builds it for `version`: a release's, so its `dev.xless.image` is `v<version>-<12 hex>`.
    func addBase(_ version: String = "0.14.0", arch: String = "arm64", name: String? = nil, id: String = "sha256:base", imageID: String? = nil,
                 layers: [String] = ["a", "b"]) {
        add(name ?? ImageName.base(version: version, arch: arch), id: id, arch: arch,
            labels: ["org.xless.image": "true", "dev.xless.arch": arch, "dev.xless.version": version, "dev.xless.image": imageID ?? "v\(version)-0123456789ab"], layers: layers)
    }

    func answer(_ words: [String]) -> (code: Int32, output: String) {
        asked.append(words)
        guard answers else { return (1, "") }
        if words.starts(with: ["image", "ls"]) { return (0, images.keys.sorted().joined(separator: "\n") + "\n") }
        guard words.starts(with: ["image", "inspect"]), let image = images[words.last ?? ""] else { return (1, "\n") }
        let json: [String: Any] = ["Id": image.id, "Architecture": image.architecture, "Config": ["Labels": image.labels], "RootFS": ["Type": "layers", "Layers": image.layers]]
        return (0, String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n")
    }

    var local: LocalImages { LocalImages { self.answer($0) } }
}

/// The message of the `ImageProblem` that `body` throws.
func problem(_ body: () throws -> some Any) -> String {
    do {
        _ = try body()
        Issue.record("nothing thrown")
        return ""
    } catch { return "\(error)" }
}

@Suite struct ImageNameTests {
    @Test func aBaseImagesTagNamesItsVersionAndArchitecture() {
        #expect(ImageName.base(version: "0.14.0", arch: "arm64") == "xless:0.14.0-arm64")
        #expect(ImageName.base(version: "0123456789ab-dirty", arch: "amd64") == "xless:0123456789ab-dirty-amd64")
    }

    @Test func everyTagOfTheOldLayoutsIsLegacy() {
        for old in ["xless:local", "xless:local-arm64", "xless:local-arm64-xcode26.6", "xless:local-arm64-xcode26.6-17F113", "xless:local-arm64-xcode26.6-tauri", "xless:local-arm64-setup",
                    "xless-base:0.9.0", "xless-tauri:local-arm64", "xless-rn:anything"] {
            #expect(ImageName.isLegacy(old), "\(old)")
        }
        for current in ["xless:0.14.0-arm64", "xless:0123456789ab-dirty-arm64", "xless:0.14.0-arm64-tauri", "someone/xless:local-arm64", "mine:local", "xless:locale-arm64", "xless:localx"] {
            #expect(!ImageName.isLegacy(current), "\(current)")
        }
        #expect("local".wholeMatch(of: ImageName.legacyTag) != nil && "local-arm64-xcode26.6".wholeMatch(of: ImageName.legacyTag) != nil && "0.14.0-arm64".wholeMatch(of: ImageName.legacyTag) == nil)
    }

    /// What a person writes goes into docker's arguments: never an option of it.
    @Test func aReferenceIsNoOption() {
        for good in ["my-app", "my-app:dev", "registry.example.com:5000/team/app_x:1.2", "app@sha256:\(String(repeating: "a", count: 64))"] {
            #expect(ImageName.isReference(good), "\(good)")
        }
        for bad in ["", "-v", "--privileged", "a b", "a\nb", "a;b", "$(x)", "a\"b", ":x", "/x"] { #expect(!ImageName.isReference(bad), "\(bad)") }
    }
}

/// The tag part that names this xless: the way scripts/docker-images.sh decides it.
@Suite struct ThisXlessTests {
    private func share(files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
        return directory
    }
    /// No git checkout is there.
    private let noGit: ImageName.Git = { _, _ in (128, "") }

    @Test func aReleaseIsNamedByItsVersionFile() throws {
        let release = try share(files: ["VERSION": "0.14.0\n", "versions.env": "XLESS_VERSION=0.0.0-dev\n"])
        defer { try? FileManager.default.removeItem(at: release) }
        #expect(try ImageName.tag(ofShare: release, git: noGit) == "0.14.0")
        // even where git is there, but the share is not its checkout's top
        #expect(try ImageName.tag(ofShare: release) == "0.14.0")
    }

    @Test func withoutAVersionFileItIsVersionsEnvs() throws {
        let source = try share(files: ["versions.env": "XLESS_VERSION=0.0.0-dev\n"])
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try ImageName.tag(ofShare: source, git: noGit) == "0.0.0-dev")
        let none = try share(files: [:])
        defer { try? FileManager.default.removeItem(at: none) }
        #expect(problem { try ImageName.tag(ofShare: none, git: noGit) }.hasPrefix("xless's share directory \(none.path) records no release"))
    }

    /// A checkout with no commit yet is no checkout, as scripts/docker-images.sh has it.
    @Test func aCheckoutWithNoCommitIsNamedByItsRelease() throws {
        let share = try share(files: ["versions.env": "XLESS_VERSION=0.0.0-dev\n"])
        defer { try? FileManager.default.removeItem(at: share) }
        let git: ImageName.Git = { words, _ in
            switch words {
            case ["rev-parse", "--show-toplevel"]: return (0, share.resolvingSymlinksInPath().path + "\n")
            default: return (128, "")
            }
        }
        #expect(try ImageName.tag(ofShare: share, git: git) == "0.0.0-dev")
    }

    /// `xless clean --old` trusts a tag that names the release or the commit; one that a checkout fell back to (git failed there) is not that.
    @Test func aCheckoutWhoseGitFailedHasFallenBack() throws {
        let checkout = try share(files: ["versions.env": "XLESS_VERSION=0.0.0-dev\n"])
        defer { try? FileManager.default.removeItem(at: checkout) }
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let top = checkout.resolvingSymlinksInPath().path + "\n"
        let broken: ImageName.Git = { words, _ in words == ["rev-parse", "--show-toplevel"] ? (0, top) : (128, "") }
        let fell = try ImageName.resolution(ofShare: checkout, git: broken)
        #expect(fell.tag == "0.0.0-dev" && fell.fellBack)
        let working: ImageName.Git = { words, _ in
            switch words {
            case ["rev-parse", "--show-toplevel"]: return (0, top)
            case ["rev-parse", "--short=12", "HEAD"]: return (0, "0123456789ab\n")
            default: return (0, "")
            }
        }
        let fine = try ImageName.resolution(ofShare: checkout, git: working)
        #expect(fine.tag == "0123456789ab" && !fine.fellBack)
        let release = try share(files: ["VERSION": "0.14.0\n"])
        defer { try? FileManager.default.removeItem(at: release) }
        let plain = try ImageName.resolution(ofShare: release, git: noGit)
        #expect(plain.tag == "0.14.0" && !plain.fellBack, "a release has no .git: its tag is trusted")
    }

    #if !os(Windows)
    private static let checkoutRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// bash, the script and git are here (a skip is recorded otherwise, not passed in silence).
    private static var scriptRuns: Bool {
        FileManager.default.isExecutableFile(atPath: "/bin/bash") && FileManager.default.fileExists(atPath: checkoutRoot.appendingPathComponent("scripts/docker-images.sh").path)
            && ImageName.runGit(["--version"], in: checkoutRoot).code == 0
    }

    /// The script and Swift name this very checkout's image the same way.
    @Test(.enabled(if: scriptRuns, "needs bash, scripts/docker-images.sh and git"))
    func theScriptAndXlessAgreeOnTheTag() throws {
        let root = Self.checkoutRoot
        let script = root.appendingPathComponent("scripts/docker-images.sh")
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "tag", "--arch", "arm64"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 && !said.isEmpty)
        #expect(try ImageName.tag(ofShare: root) == said)
    }
    #endif

    @Test func aCheckoutIsNamedByItsCommit() throws {
        #expect(ImageName.checkoutTag(commit: "0123456789ab", dirty: false) == "0123456789ab")
        #expect(ImageName.checkoutTag(commit: "0123456789ab", dirty: true) == "0123456789ab-dirty")
        let checkout = try share(files: ["versions.env": "XLESS_VERSION=0.0.0-dev\n"])
        defer { try? FileManager.default.removeItem(at: checkout) }
        let top = checkout.resolvingSymlinksInPath().path
        func git(dirty: Bool, top: String? = nil) -> ImageName.Git {
            { words, _ in
                switch words {
                case ["rev-parse", "--show-toplevel"]: return (0, (top ?? "\(checkout.resolvingSymlinksInPath().path)") + "\n")
                case ["rev-parse", "--short=12", "HEAD"]: return (0, "0123456789ab\n")
                case ["diff", "--quiet", "HEAD"]: return (dirty ? 1 : 0, "")
                default: return (1, "")
                }
            }
        }
        #expect(try ImageName.tag(ofShare: checkout, git: git(dirty: false)) == "0123456789ab")
        #expect(try ImageName.tag(ofShare: checkout, git: git(dirty: true)) == "0123456789ab-dirty")
        _ = top
        // a share inside somebody else's checkout is not a checkout of its own
        #expect(try ImageName.tag(ofShare: checkout, git: git(dirty: true, top: "/somewhere/else")) == "0.0.0-dev")
    }
}

@Suite struct LocalImagesTests {
    let docker = FakeDocker()

    @Test func anImageIsWhatDockerSaysOfIt() throws {
        docker.addBase()
        let image = try #require(docker.local.image("xless:0.14.0-arm64"))
        #expect(image == docker.images["xless:0.14.0-arm64"])
        #expect(image.version == "0.14.0" && image.imageID == "v0.14.0-0123456789ab")
        #expect(docker.local.image("xless:1.0.0-arm64") == nil)
        // docker prints no labels as null
        let bare = LocalImage.parse(#"{"Id":"sha256:1","Architecture":"amd64","Config":{"Labels":null},"RootFS":{"Layers":null}}"#, name: "x")
        #expect(bare == LocalImage(name: "x", id: "sha256:1", architecture: "amd64", labels: [:], layers: []))
        #expect(LocalImage.parse("", name: "x") == nil && LocalImage.parse("[]", name: "x") == nil)
    }

    @Test func baseIsTheImageOfThisVersion() throws {
        docker.addBase("0.14.0")
        docker.addBase("0.13.0")
        docker.addBase("0.14.0", arch: "amd64")
        #expect(try docker.local.base(version: "0.14.0", arch: "arm64").name == "xless:0.14.0-arm64")
        #expect(try docker.local.base(version: "0.14.0", arch: "amd64").name == "xless:0.14.0-amd64")
        // a checkout's image: the tag is the commit, and so is the start of its ID
        docker.addBase("0.0.0-dev", name: "xless:0123456789ab-dirty-arm64", imageID: "0123456789ab-dirty-fedcba987654")
        #expect(try docker.local.base(version: "0123456789ab-dirty", arch: "arm64").name == "xless:0123456789ab-dirty-arm64")
        // missing: the one of another version is named, and is no use
        let missing = problem { try docker.local.base(version: "0.15.0", arch: "arm64") }
        #expect(missing == "the image xless:0.15.0-arm64 is missing (xless:0.13.0-arm64 is another version's; xless images are never pulled from a registry); build it: xless setup --docker --arch arm64 (it needs no Xcode to build the image)")
        #expect(problem { try FakeDocker().local.base(version: "0.15.0", arch: "arm64") }
            == "the image xless:0.15.0-arm64 is missing (xless images are never pulled from a registry); build it: xless setup --docker --arch arm64 (it needs no Xcode to build the image)")
        #expect(problem { try FakeDocker().local.base(version: "0.14.0", arch: "arm64") }.hasPrefix("the image xless:0.14.0-arm64 is missing"))
    }

    @Test func anotherVersionIsRefusedWithSetup() {
        let fix = "build it again: xless setup --docker --arch arm64 (it needs no Xcode to build the image)"
        // the tag is not what the image is
        docker.addBase("0.13.0", name: "xless:0.14.0-arm64")
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") } == "xless:0.14.0-arm64 is the image of xless v0.13.0-0123456789ab, not of 0.14.0; \(fix)")
        // an image that does not say (an older xless's tag with the new name)
        docker.add("xless:0.14.0-arm64", labels: ["dev.xless.arch": "arm64"])
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") } == "xless:0.14.0-arm64 holds an unknown xless (it has no dev.xless.image label); \(fix)")
        // another version's image is named where the one wanted is missing
        docker.images = [:]
        docker.addBase("0.13.0")
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") }.contains("the image xless:0.14.0-arm64 is missing (xless:0.13.0-arm64 is another version's;"))
    }

    @Test func onlyLegacyImagesAreNamedAsOld() {
        for old in ["xless:local-arm64-xcode26.6", "xless:local-arm64", "xless-base:local-arm64-xcode26.6", "xless-tauri:local-arm64", "xless-rn:local-arm64"] {
            let docker = FakeDocker()
            docker.add(old, labels: ["org.xless.image": "true", "dev.xless.sdk": "17F113"])
            #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") }
                == "there is no xless image on this machine (xless images are never pulled from a registry), and \(old) is an older xless's, which is not used; build it: xless setup --docker --arch arm64 (it needs no Xcode to build the image), and xless clean --old removes the older xless's images", "\(old)")
        }
        // another image is not
        docker.add("mine:local")
        docker.add("someone/xless:local-arm64")
        #expect(!problem { try docker.local.base(version: "0.14.0", arch: "arm64") }.contains("older xless's"))
    }

    @Test func aBaseOfAnotherArchitectureIsRefused() {
        docker.addBase("0.14.0", arch: "amd64", name: "xless:0.14.0-arm64")
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") }.hasPrefix("xless:0.14.0-arm64 is for amd64, not arm64; build it again: xless setup --docker"))
        // the label, and what docker says
        docker.addBase("0.14.0")
        docker.images["xless:0.14.0-arm64"]?.labels["dev.xless.arch"] = "amd64"
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") }.contains("is for amd64, not arm64"))
    }

    @Test func aDockerThatDoesNotAnswerIsNamed() {
        docker.answers = false
        #expect(problem { try docker.local.base(version: "0.14.0", arch: "arm64") }.hasPrefix("docker does not list its images (docker image ls failed); is it running?"))
    }
}

@Suite struct CustomImageTests {
    let docker = FakeDocker()
    init() {
        docker.addBase("0.14.0")
        mine()
    }

    /// A person's image, built on the base: the labels are inherited, and its layers are the base's and one more.
    private func mine(layers: [String] = ["a", "b", "c"], arch: String = "arm64", version: String = "0.14.0") {
        docker.addBase(version, arch: arch, name: "mine:1", id: "sha256:mine", layers: layers)
    }

    private func custom(_ name: String = "mine:1") throws -> LocalImages.Custom {
        try docker.local.custom(name, named: "XLESS_IMAGE", version: "0.14.0", arch: "arm64")
    }

    @Test func itIsUsedWithTheLocalImageItIsBuiltOn() throws {
        let custom = try custom()
        #expect(custom.image.name == "mine:1" && custom.base.name == "xless:0.14.0-arm64" && !custom.isBase)
        #expect(try self.custom("xless:0.14.0-arm64").isBase)
    }

    @Test func customMustBeBuiltOnTheBase() {
        // the labels are inherited, and anybody can write them: what is inside is compared too
        for layers in [["a"], ["a", "x", "c"], [], ["x", "a", "b"]] {
            mine(layers: layers)
            #expect(problem { try custom() } == "XLESS_IMAGE names mine:1, which is not built on xless:0.14.0-arm64 as it is now (xless setup has built that again since, or the labels are copied); build it again: docker build --pull=false --build-arg XLESS_IMAGE=xless:0.14.0-arm64 -t mine:1 <its folder>", "\(layers)")
        }
        docker.images["xless:0.14.0-arm64"] = nil
        mine()
        #expect(problem { try custom() } == "XLESS_IMAGE names mine:1, which is built on an image of xless 0.14.0, and xless:0.14.0-arm64 is missing, which the steps with the secrets run in; build it: xless setup --docker --arch arm64 (it needs no Xcode to build the image)")
        docker.add("mine:1")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which is not built on an image of this xless (it has no dev.xless.image label); build it on xless:0.14.0-arm64: docker build"))
    }

    @Test func customOfAnotherArchIsRefused() {
        mine(arch: "amd64")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which is for amd64, not arm64; "))
    }

    @Test func customOfAnotherVersionIsRefused() {
        mine(version: "0.13.0")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which is the image of xless v0.13.0-0123456789ab, not of 0.14.0; build it on xless:0.14.0-arm64: docker build"))
        #expect(problem { try custom("none:1") } == "XLESS_IMAGE names none:1, which is not on this machine (images are never pulled from a registry); build it first: docker build -t none:1 <its folder>")
        #expect(problem { try custom("--privileged") } == "XLESS_IMAGE names '--privileged', which is not an image name; name a local image")
    }

    /// The steps with the secrets run in it.
    @Test func theImageItIsBuiltOnIsCheckedToo() {
        docker.images["xless:0.14.0-arm64"]?.labels["dev.xless.image"] = "v0.1.0-0123456789ab"
        #expect(problem { try custom() }.hasPrefix("xless:0.14.0-arm64 is the image of xless v0.1.0-0123456789ab, not of 0.14.0"))
        docker.addBase("0.14.0", arch: "amd64", name: "xless:0.14.0-arm64")
        #expect(problem { try custom() }.hasPrefix("xless:0.14.0-arm64 is for amd64, not arm64"))
    }
}
