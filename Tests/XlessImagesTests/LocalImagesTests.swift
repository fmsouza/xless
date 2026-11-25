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

    /// An image as `xless setup` builds it.
    func addBase(_ xcode: String, sdk: String = "17F113", arch: String = "arm64", name: String? = nil, id: String = "sha256:base", version: String = "0.10.0",
                 layers: [String] = ["a", "b"]) {
        add(name ?? ImageName.base(arch: arch, xcode: xcode), id: id, arch: arch,
            labels: ["org.xless.image": "true", "dev.xless.sdk": sdk, "dev.xless.xcode": xcode, "dev.xless.arch": arch, "dev.xless.version": version], layers: layers)
    }

    func answer(_ words: [String]) -> (code: Int32, output: String) {
        asked.append(words)
        guard answers else { return (1, "") }
        if words.starts(with: ["image", "ls"]) { return (0, images.keys.sorted().joined(separator: "\n") + "\n") }
        guard words.starts(with: ["image", "inspect"]), let image = images[words.last ?? ""] else { return (1, "\n") }
        let json: [String: Any] = ["Id": image.id, "Architecture": image.architecture, "Config": ["Labels": image.labels], "RootFS": ["Type": "layers", "Layers": image.layers]]
        return (0, String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n")
    }

    /// The SDK exports in the cache.
    var exports: [SDKExport] = []

    var local: LocalImages { LocalImages(exports: { _ in self.exports }) { self.answer($0) } }
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
    @Test func aBaseImagesTagNamesItsArchitectureAndXcode() {
        #expect(ImageName.base(arch: "arm64", xcode: "26.6") == "xless:local-arm64-xcode26.6")
        #expect(ImageName.xcode(ofBase: "xless:local-arm64-xcode26.6", arch: "arm64") == "26.6")
        #expect(ImageName.xcode(ofBase: "xless:local-arm64-xcode26.0.1", arch: "arm64") == "26.0.1")
        for other in ["xless:local-arm64", "xless:local-amd64-xcode26.6", "xless:local-arm64-xcode26.6-17F113", "xless:local-arm64-xcode26.6-tauri",
                      "xless-base:local-arm64-xcode26.6", "registry.example.com/xless:local-arm64-xcode26.6", "xless:local-arm64-setup"] {
            #expect(ImageName.xcode(ofBase: other, arch: "arm64") == nil, "\(other)")
        }
    }

    /// What a person writes goes into docker's arguments: never an option of it.
    @Test func aReferenceIsNoOption() {
        for good in ["my-app", "my-app:dev", "registry.example.com:5000/team/app_x:1.2", "app@sha256:\(String(repeating: "a", count: 64))"] {
            #expect(ImageName.isReference(good), "\(good)")
        }
        for bad in ["", "-v", "--privileged", "a b", "a\nb", "a;b", "$(x)", "a\"b", ":x", "/x"] { #expect(!ImageName.isReference(bad), "\(bad)") }
    }
}

@Suite struct LocalImagesTests {
    let docker = FakeDocker()

    @Test func anImageIsWhatDockerSaysOfIt() throws {
        docker.addBase("26.6")
        let image = try #require(docker.local.image("xless:local-arm64-xcode26.6"))
        #expect(image == docker.images["xless:local-arm64-xcode26.6"])
        #expect(image.sdk == "17F113" && image.xcode == "26.6" && image.version == "0.10.0")
        #expect(docker.local.image("xless:local-arm64-xcode1.0") == nil)
        // docker prints no labels as null
        let bare = LocalImage.parse(#"{"Id":"sha256:1","Architecture":"amd64","Config":{"Labels":null},"RootFS":{"Layers":null}}"#, name: "x")
        #expect(bare == LocalImage(name: "x", id: "sha256:1", architecture: "amd64", labels: [:], layers: []))
        #expect(LocalImage.parse("", name: "x") == nil && LocalImage.parse("[]", name: "x") == nil)
    }

    @Test func thePinChoosesTheImage() throws {
        docker.addBase("26.6")
        docker.addBase("27.0", sdk: "27A266a")
        #expect(try docker.local.base(arch: "arm64", pin: "26.6").image.name == "xless:local-arm64-xcode26.6")
        let missing = problem { try docker.local.base(arch: "arm64", pin: "26.2") }
        #expect(missing == "the image xless:local-arm64-xcode26.2 is missing; build it from Xcode 26.2: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64")
    }

    @Test func withoutAPinTheNewestXcodeIsChosen() throws {
        for xcode in ["26.2", "26.10", "26.9.1", "9.9"] { docker.addBase(xcode) }
        docker.addBase("27.0", arch: "amd64")
        docker.add("xless:local-arm64-xcode99.0") // of an older xless: no labels
        docker.addBase("98.0", name: "xless:local-arm64-xcode98.0-98A1")
        docker.addBase("97.0", name: "someone/xless:local-arm64-xcode97.0")
        let choice = try docker.local.base(arch: "arm64", pin: nil)
        #expect(choice.image.name == "xless:local-arm64-xcode26.10" && choice.notice == nil)
        let none = problem { try FakeDocker().local.base(arch: "arm64", pin: nil) }
        #expect(none == "there is no xless image on this machine (xless images are never pulled from a registry); build it with: xless setup --docker --xcode <Xcode.xip> --arch arm64")
    }

    @Test func anImageOfAnOlderXlessIsNamedAsOne() {
        docker.add("xless:local-arm64-xcode26.2", labels: ["org.xless.image": "true"])
        let pinned = problem { try docker.local.base(arch: "arm64", pin: "26.2") }
        #expect(pinned == "xless:local-arm64-xcode26.2 is not an image of this xless (it has no dev.xless.sdk label: an older xless built it); build it again: xless setup --docker --arch arm64 (from the SDK export in the cache; when that is gone: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64)")
        let any = problem { try docker.local.base(arch: "arm64", pin: nil) }
        #expect(any == "there is no xless image on this machine (xless images are never pulled from a registry); build it with: xless setup --docker --arch arm64 (from the SDK export in the cache; when that is gone: xless setup --docker --xcode <Xcode.xip> --arch arm64; those of an older xless, as xless:local-arm64-xcode26.2, are not used: xless clean --old removes them)")
        // the pinned Xcode's is missing, and an older xless's without an Xcode in its tag is there
        docker.images = [:]
        docker.add("xless:local-arm64")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.contains("build it: xless setup --docker --arch arm64 (from the SDK export in the cache; when that is gone: xless setup --docker --xcode <path to Xcode 26.6's .app or .xip> --arch arm64)"))
    }

    /// The export of an earlier setup is all that a new image needs: the Xcode need not be there any more.
    @Test func theExportInTheCacheIsNamedBeforeTheXcode() {
        let again = "xless setup --docker --arch arm64 (from the SDK export in the cache; when that is gone: xless setup --docker --xcode"
        docker.exports = [SDKExport(xcode: "26.6", directory: "/c/sdk/xcode26.6-17F113")]
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") } == "the image xless:local-arm64-xcode26.6 is missing; build it: \(again) <path to Xcode 26.6's .app or .xip> --arch arm64)")
        #expect(problem { try docker.local.base(arch: "arm64", pin: nil) }.hasSuffix("build it with: \(again) <Xcode.xip> --arch arm64)"))
        // another Xcode's export is of no use
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.2") }.hasSuffix("build it from Xcode 26.2: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64"))
        docker.add("xless:local-arm64-xcode26.2")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.2") }.hasSuffix("build it again from Xcode 26.2: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64"))
        // one of several is named
        docker.exports.append(SDKExport(xcode: "27.0", directory: "/c/sdk x/xcode27.0-27A266a"))
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.contains("build it: xless setup --docker --sdk /c/sdk/xcode26.6-17F113 --arch arm64 (from the SDK export in the cache; when that is gone: "))
        #expect(problem { try docker.local.base(arch: "arm64", pin: "27.0") }.contains("build it: xless setup --docker --sdk '/c/sdk x/xcode27.0-27A266a' --arch arm64 ("))
        #expect(problem { try docker.local.base(arch: "arm64", pin: nil) }.contains("xless setup --docker --sdk '/c/sdk x/xcode27.0-27A266a' --arch arm64 ("))
        // quoted by its bytes: a mark after a quote makes them one Character
        docker.exports[1].directory = "/c/a'\u{301}; b"
        #expect(problem { try docker.local.base(arch: "arm64", pin: "27.0") }.contains(" --sdk '/c/a'\\''\u{301}; b' --arch arm64 ("))
    }

    @Test func theExportsAreWhatTheCacheHolds() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("exports-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        #expect(SDKExport.all(in: cache, arch: "arm64").isEmpty)
        for path in ["xcode26.6-17F113/arm64/darwin.xtoolsdk", "xcode26.10-18A1/arm64/darwin.xtoolsdk", "xcode27.0-27A266a/amd64/darwin.xtoolsdk", "xcode28.0-28A1/arm64/darwin.xtoolsdk.partial", "mine/arm64/darwin.xtoolsdk"] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent("sdk/\(path)"), withIntermediateDirectories: true)
        }
        #expect(SDKExport.all(in: cache, arch: "arm64") == [SDKExport(xcode: "26.6", directory: "\(cache.path)/sdk/xcode26.6-17F113"), SDKExport(xcode: "26.10", directory: "\(cache.path)/sdk/xcode26.10-18A1")])
        #expect(SDKExport.all(in: cache, arch: "amd64").map(\.xcode) == ["27.0"])
    }

    /// For one release more: the tag `xless:local-<arch>`, on an image that has the labels.
    @Test func thePlainTagStillWorksWhereItHasTheLabels() throws {
        docker.addBase("26.6", name: "xless:local-arm64")
        for pin in [nil, "26.6"] {
            let choice = try docker.local.base(arch: "arm64", pin: pin)
            #expect(choice.image.name == "xless:local-arm64")
            #expect(choice.notice == "note: xless:local-arm64 is used for Xcode 26.6; the tag without an Xcode goes away in a later release (xless setup --docker makes xless:local-arm64-xcode26.6)")
        }
        #expect(problem { try docker.local.base(arch: "arm64", pin: "27.0") }.contains("xless:local-arm64-xcode27.0 is missing"))
        docker.addBase("26.2")
        #expect(try docker.local.base(arch: "arm64", pin: nil).image.name == "xless:local-arm64-xcode26.2")
        docker.images["xless:local-arm64"]?.labels = [:]
        docker.images["xless:local-arm64-xcode26.2"] = nil
        #expect(problem { try docker.local.base(arch: "arm64", pin: nil) }.contains("as xless:local-arm64, are not used"))
    }

    @Test func aTagThatIsNotWhatItSaysIsRefused() {
        docker.addBase("27.0", sdk: "27A266a", name: "xless:local-arm64-xcode26.6")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.hasPrefix("xless:local-arm64-xcode26.6 holds the SDK of Xcode 27.0 (27A266a), not Xcode 26.6's; build it again"))
        docker.addBase("26.6", arch: "amd64", name: "xless:local-arm64-xcode26.6")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.hasPrefix("xless:local-arm64-xcode26.6 is for amd64, not arm64; build it again"))
        // the label, and what docker says
        docker.images["xless:local-arm64-xcode26.6"]?.labels["dev.xless.arch"] = "arm64"
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.contains("is for amd64, not arm64"))
        docker.addBase("26.6", version: "0.1.2")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.hasPrefix("xless:local-arm64-xcode26.6 holds xless 0.1.2, and this xless needs \(ImageLabel.minimumVersion) or later there; build it again"))
        for good in ["0.0.0-dev", ImageLabel.minimumVersion, "12.0.0", "1.0.0-rc.1"] {
            docker.addBase("26.6", version: good)
            #expect((try? docker.local.base(arch: "arm64", pin: "26.6")) != nil, "\(good)")
        }
        docker.addBase("26.6", version: "")
        #expect(problem { try docker.local.base(arch: "arm64", pin: "26.6") }.contains("holds an unknown xless"))
    }

    @Test func aDockerThatDoesNotAnswerIsNamed() {
        docker.answers = false
        #expect(problem { try docker.local.base(arch: "arm64", pin: nil) }.hasPrefix("docker does not list its images (docker image ls failed); is it running?"))
    }
}

@Suite struct CustomImageTests {
    let docker = FakeDocker()
    init() {
        docker.addBase("26.6")
        docker.addBase("27.0", sdk: "27A266a", id: "sha256:27", layers: ["x", "y"])
        mine()
    }

    private func mine(sdk: String = "17F113", xcode: String = "26.6", layers: [String] = ["a", "b", "c"], arch: String = "arm64", version: String = "0.10.0") {
        docker.addBase(xcode, sdk: sdk, arch: arch, name: "mine:1", id: "sha256:mine", version: version, layers: layers)
    }

    private func custom(pin: String? = nil, _ name: String = "mine:1") throws -> LocalImages.Custom {
        try docker.local.custom(name, named: "XLESS_IMAGE", arch: "arm64", pin: pin)
    }

    @Test func itIsUsedWithTheLocalImageItIsBuiltOn() throws {
        for pin in [nil, "26.6"] {
            let custom = try custom(pin: pin)
            #expect(custom.image.name == "mine:1" && custom.base.name == "xless:local-arm64-xcode26.6" && !custom.isBase)
        }
        #expect(try custom("xless:local-arm64-xcode27.0").isBase)
    }

    @Test func anotherXcodesIsRefused() {
        #expect(problem { try custom(pin: "27.0") } == "XLESS_IMAGE names mine:1, which holds the SDK of Xcode 26.6 (17F113), not Xcode 27.0's; build it on the image of Xcode 27.0: docker build --pull=false --build-arg XLESS_IMAGE=xless:local-arm64-xcode27.0 -t mine:1 <its folder>")
        docker.images["xless:local-arm64-xcode26.6"] = nil
        #expect(problem { try custom() } == "XLESS_IMAGE names mine:1, which is built for Xcode 26.6 (17F113), and the image xless:local-arm64-xcode26.6 is missing, which the steps with the secrets run in; build it from Xcode 26.6: xless setup --docker --xcode <path to Xcode 26.6's .app or .xip> --arch arm64")
    }

    @Test func anotherArchitecturesOrAnOlderXlesssIsRefused() {
        mine(arch: "amd64")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which is for amd64, not arm64; "))
        mine(version: "0.2.0")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which holds xless 0.2.0, and this xless needs"))
        docker.add("mine:1")
        #expect(problem { try custom() }.hasPrefix("XLESS_IMAGE names mine:1, which is not built on an image of this xless (it has no dev.xless.sdk label); build it on xless:local-arm64-xcode<version>: "))
        #expect(problem { try custom("none:1") } == "XLESS_IMAGE names none:1, which is not on this machine (images are never pulled from a registry); build it first: docker build -t none:1 <its folder>")
        #expect(problem { try custom("--privileged") } == "XLESS_IMAGE names '--privileged', which is not an image name; name a local image")
    }

    /// The labels are inherited, and anybody can write them: what is inside is compared too.
    @Test func theLabelsAloneDoNotMakeIt() {
        for layers in [["a"], ["a", "x", "c"], [], ["x", "a", "b"]] {
            mine(layers: layers)
            #expect(problem { try custom() } == "XLESS_IMAGE names mine:1, which is not built on xless:local-arm64-xcode26.6 as it is now (xless setup has built that again since, or the labels are copied); build it again: docker build --pull=false --build-arg XLESS_IMAGE=xless:local-arm64-xcode26.6 -t mine:1 <its folder>", "\(layers)")
        }
    }

    /// The steps with the secrets run in it.
    @Test func theImageItIsBuiltOnIsCheckedToo() {
        docker.images["xless:local-arm64-xcode26.6"]?.labels["dev.xless.version"] = "0.1.0"
        #expect(problem { try custom() }.hasPrefix("xless:local-arm64-xcode26.6 holds xless 0.1.0, and this xless needs"))
        docker.addBase("26.6", arch: "amd64", name: "xless:local-arm64-xcode26.6")
        #expect(problem { try custom() }.hasPrefix("xless:local-arm64-xcode26.6 is for amd64, not arm64"))
    }

    @Test func theImageOfAnotherBuildOfThatXcodeIsFound() throws {
        docker.addBase("26.6", sdk: "17F200")
        #expect(problem { try custom() }.contains("the image xless:local-arm64-xcode26.6-17F113 is missing"))
        docker.addBase("26.6", name: "xless:local-arm64-xcode26.6-17F113")
        #expect(try custom().base.name == "xless:local-arm64-xcode26.6-17F113")
    }
}
