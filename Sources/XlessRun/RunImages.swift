import Foundation
import XlessCore
import XlessImages

/// The images that the steps of a run in containers are in.
struct RunImages {
    struct Image {
        /// As a person knows it.
        var name: String
        /// What a container is started of: the ID of the image that was checked, which no tag moves meanwhile (in a dry run, which
        /// shows what would run, its name).
        var reference: String
    }

    /// Of the step that builds: code of the app and of others, with no secret in reach.
    var build: Image
    /// Of the steps with the secrets: xless's own image, with no toolchain of another language in it.
    var secrets: Image
    /// The Xcode's pack, which every container of the run has, read-only.
    var pack: RunPack?
    /// The app is built in an image other than xless's own.
    var areTwo: Bool { build.reference != secrets.reference }

    static let none = RunImages(build: Image(name: "", reference: ""), secrets: Image(name: "", reference: ""))
}

extension ProjectRun {
    /// docker, asked (with the run's context): not a step.
    var askDocker: LocalImages.Docker { { [self] in ask(dockerCLI + $0, quiet: true) } }
    private var localImages: LocalImages {
        LocalImages(askDocker)
    }
    private func started(_ image: LocalImage) -> RunImages.Image { RunImages.Image(name: image.name, reference: dryRun ? image.name : image.id) }
    var shareDirectory: URL { URL(fileURLWithPath: context.share) }

    /// Chooses them, and the pack: the project's pinned Xcode, else the newest one there is a pack of, decides the pack
    /// (`choosePack`); the images are this xless's. A person never names one, unless the app needs one of their own (`image:`,
    /// XLESS_IMAGE), which is for the build step alone. Every container of the run gets the pack (`dockerRun`).
    ///
    /// - Parameters:
    ///   - kit: what the app's build needs besides xless's own image.
    ///   - builds: the run has the build step. Only that one needs the kit, which is built here when it is missing or stale.
    ///   - other: it has others.
    func chooseImages(_ top: RunTop, kit: Kit? = nil, builds: Bool, other: Bool) throws -> RunImages {
        do { return try choose(top, kit: kit, builds: builds, other: other) } catch let problem as ImageProblem {
            throw RunStop.usage("\(problem)")
        }
    }

    private func choose(_ top: RunTop, kit: Kit?, builds: Bool, other: Bool) throws -> RunImages {
        guard !top.isNotOneValue("image") else { throw RunStop.usage("image: in \(pinFile) is not the name of an image") }
        let own = setting("XLESS_IMAGE").map { (name: $0, variable: "XLESS_IMAGE") } ?? top["image"].map { (name: $0, variable: "image: in \(pinFile)") }
        var images: RunImages
        let base: LocalImage
        if let own, try isHere(own.name, own.variable) {
            let custom = try localImages.custom(own.name, named: own.variable, version: context.version, arch: architecture)
            base = custom.base
            images = RunImages(build: started(custom.isBase ? base : custom.image), secrets: started(base))
        } else {
            base = try baseImage()
            images = RunImages(build: started(base), secrets: started(base))
            if let name = own?.name ?? kit?.image(on: base) { images.build = RunImages.Image(name: name, reference: name) }
        }
        let pack = try choosePack(image: base)
        images.pack = pack
        dockerRun += pack.arguments
        sayImages(images, own: own?.variable, builds: builds, other: other)
        if builds, own == nil, let kit, let built = try prepare(kit, on: base) { images.build = started(built) }
        return images
    }

    /// A dry run shows what a run would do: an image that is not on this machine stops only the run.
    private func isHere(_ name: String, _ variable: String) throws -> Bool {
        guard dryRun, ImageName.isReference(name), localImages.image(name) == nil else { return true }
        host.say("==> note: \(variable) names \(name), which is not on this machine: a run would stop here")
        return false
    }

    /// The image of this xless. A run never builds it (`xless setup --docker` does): a missing one stops the run, with that command.
    private func baseImage() throws -> LocalImage {
        do {
            return try localImages.base(version: context.version, arch: architecture)
        } catch let problem as ImageProblem {
            guard dryRun else { throw problem }
            host.say("==> note: \(problem)")
            // (empty ID: there is none to read the pack volumes with)
            return LocalImage(name: ImageName.base(version: (try? context.version) ?? "<version>", arch: architecture), id: "", architecture: architecture, labels: [:], layers: [])
        }
    }

    private func sayImages(_ images: RunImages, own: String?, builds: Bool, other: Bool) {
        let what = builds && other && images.areTwo ? "build \(images.build.name), signing and upload \(images.secrets.name)" : builds ? images.build.name : images.secrets.name
        let why = xcodePin.map { "xcode: \"\($0)\" (pinned)" } ?? own ?? "no xcode: is pinned, so the newest Xcode there is a pack of"
        let xcode = images.pack.map { "Xcode \($0.manifest.xcode) (\($0.manifest.build)), " } ?? ""
        host.say("==> \(why): \(xcode)\(what)")
    }

    /// The kit's image as this xless builds it: from the Dockerfile shipped with it, on the image of this xless. nil: a dry run, and
    /// there is none.
    private func prepare(_ kit: Kit, on base: LocalImage) throws -> LocalImage? {
        let name = kit.image(on: base), why: String
        switch try localImages.state(of: kit, on: base, share: shareDirectory) {
        case .current(let image): return image
        case .missing: why = "there is none yet"
        case .stale(let reason): why = reason
        }
        host.say("==> \(dryRun ? "would build" : "building") the image \(name)\(dryRun ? " first" : "") (\(why)): \(kit.holds), for \(kit.apps); \(kit.estimate), once")
        let build = try kit.build(on: base, share: shareDirectory, builder: localImages.builder)
        let code = step(dockerCLI + build, .nothing, without: LocalImages.builderVariables).code
        guard !dryRun else { return nil }
        guard code == 0 else {
            throw RunStop.usage("\(name) was not built (docker build exited with code \(code)); its output is above: it needs buildx (docker buildx version), the network and room on Docker's disk")
        }
        if case .current(let image) = try localImages.state(of: kit, on: base, share: shareDirectory) { return image }
        throw RunStop.usage("\(name) is not on \(base.name): docker build ended, and left another image than it was asked for; xless setup --docker --with \(kit.rawValue) builds it again")
    }
}
