import Foundation
import XlessCore
import XlessImages

/// The images that the steps of a run in containers are in.
struct RunImages {
    /// Of the step that builds: code of the app and of others, with no secret in reach.
    var build: String
    /// Of the steps with the secrets: xless's own image of the same Xcode, with no toolchain of another language in it.
    var secrets: String
    /// The app is built in an image other than xless's own.
    var areTwo: Bool { build != secrets }
}

extension ProjectRun {
    private var localImages: LocalImages { LocalImages { [self] in ask(dockerCLI + $0, quiet: true) } }
    private var shareDirectory: URL { URL(fileURLWithPath: context.share) }

    /// Chooses them: the project's pinned Xcode, else the newest one there is an image of, decides. A person never names one,
    /// unless the app needs one of their own (`image:`, XLESS_IMAGE), which is for the build step alone.
    ///
    /// - Parameters:
    ///   - kit: what the app's build needs besides xless's own image.
    ///   - builds: the run has the build step. Only that one needs the kit, which is built here when it is missing or stale.
    ///   - other: it has others.
    ///   - signImage: XLESS_SIGN_IMAGE counts.
    func chooseImages(_ top: RunTop, kit: Kit? = nil, builds: Bool, other: Bool, signImage: Bool = false) throws -> RunImages {
        do { return try choose(top, kit: kit, builds: builds, other: other, signImage: signImage) } catch let problem as ImageProblem {
            throw RunStop.usage("\(problem)")
        }
    }

    private func choose(_ top: RunTop, kit: Kit?, builds: Bool, other: Bool, signImage: Bool) throws -> RunImages {
        guard !top.isNotOneValue("image") else { throw RunStop.usage("image: in \(pinFile) is not the name of an image") }
        let own = setting("XLESS_IMAGE").map { (name: $0, variable: "XLESS_IMAGE") } ?? top["image"].map { (name: $0, variable: "image: in \(pinFile)") }
        var images: RunImages
        let base: LocalImage
        if let own, try isHere(own.name, own.variable) {
            let custom = try localImages.custom(own.name, named: own.variable, arch: architecture, pin: xcodeTag)
            base = custom.base
            images = RunImages(build: custom.isBase ? base.name : own.name, secrets: base.name)
        } else {
            base = try baseImage()
            images = RunImages(build: own?.name ?? kit.map { $0.image(on: base) } ?? base.name, secrets: base.name)
        }
        if signImage, let name = setting("XLESS_SIGN_IMAGE") {
            host.say("note: XLESS_SIGN_IMAGE still works, but nothing needs it any more: without it the steps with the secrets run in xless's own image of the same Xcode")
            if try isHere(name, "XLESS_SIGN_IMAGE") {
                let custom = try localImages.custom(name, named: "XLESS_SIGN_IMAGE", arch: architecture, pin: base.xcode)
                guard custom.base.id == base.id else {
                    throw ImageProblem("XLESS_SIGN_IMAGE names \(name), which is built on \(custom.base.name), and the build's image on \(base.name)", fix: "build both on the same image, or unset XLESS_SIGN_IMAGE")
                }
            }
            images.secrets = name
        }
        sayImages(images, own: own?.variable, builds: builds, other: other)
        if builds, own == nil, let kit { try prepare(kit, on: base) }
        return images
    }

    /// A dry run shows what a run would do: an image that is not on this machine stops only the run.
    private func isHere(_ name: String, _ variable: String) throws -> Bool {
        guard dryRun, ImageName.isReference(name), localImages.image(name) == nil else { return true }
        host.say("==> note: \(variable) names \(name), which is not on this machine: a run would stop here")
        return false
    }

    private func baseImage() throws -> LocalImage {
        do {
            let base = try localImages.base(arch: architecture, pin: xcodeTag)
            if let notice = base.notice { host.say(notice) }
            return base.image
        } catch let problem as ImageProblem {
            if let pin = xcodePin { throw RunStop.usage("\(pinFile) pins xcode: \"\(pin)\", but \(problem)") }
            guard dryRun else { throw problem }
            host.say("==> note: \(problem)")
            let versions = (try? String(contentsOfFile: "\(context.share)/versions.env", encoding: .utf8)) ?? ""
            let xcode = RunText.lines(versions).lazy.compactMap { RunText.value(of: "XCODE_VERSION=", in: $0) }.first.flatMap(RunText.xcodeTag) ?? "<version>"
            return LocalImage(name: ImageName.base(arch: architecture, xcode: xcode), id: "", architecture: architecture, labels: [ImageLabel.xcode: xcode], layers: [])
        }
    }

    private func sayImages(_ images: RunImages, own: String?, builds: Bool, other: Bool) {
        let what = builds && other && images.areTwo ? "build \(images.build), signing and upload \(images.secrets)" : builds ? images.build : images.secrets
        let why = xcodePin.map { "xcode: \"\($0)\" (pinned)" } ?? own ?? "no xcode: is pinned, so the newest Xcode there is an image of"
        host.say("==> \(why): \(what)")
    }

    /// The kit's image as this xless builds it: from the Dockerfile shipped with it, on the local image of the project's Xcode.
    private func prepare(_ kit: Kit, on base: LocalImage) throws {
        let name = kit.image(on: base), why: String
        switch try localImages.state(of: kit, on: base, share: shareDirectory) {
        case .current: return
        case .missing: why = "there is none yet"
        case .stale(let reason): why = reason
        }
        host.say("==> \(dryRun ? "would build" : "building") the image \(name)\(dryRun ? " first" : "") (\(why)): \(kit.holds), for \(kit.apps); \(kit.estimate), once")
        // docker's own builder: the others cannot see the local image, and would look for it in a registry
        let code = step(dockerCLI + (try kit.build(on: base, share: shareDirectory)), .nothing, without: ["BUILDX_BUILDER"]).code
        guard !dryRun else { return }
        guard code == 0 else { throw RunStop.usage("\(name) was not built (docker build exited with code \(code))") }
        if case .current = try localImages.state(of: kit, on: base, share: shareDirectory) { return }
        throw RunStop.usage("\(name) is not on \(base.name): docker build ended, and left another image than it was asked for; xless setup --docker --with \(kit.rawValue) builds it again")
    }
}
