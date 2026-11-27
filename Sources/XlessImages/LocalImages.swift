import Foundation

/// The images on this machine, and which of them a build runs in. Nothing here pulls one.
public struct LocalImages {
    /// Runs docker with these arguments: its exit code, and what it printed.
    public typealias Docker = (_ arguments: [String]) -> (code: Int32, output: String)
    private let docker: Docker

    public init(_ docker: @escaping Docker) { self.docker = docker }

    public func image(_ name: String) -> LocalImage? {
        let answer = docker(["image", "inspect", "--format", "{{json .}}", name])
        return answer.code == 0 ? LocalImage.parse(answer.output, name: name) : nil
    }

    private func names() throws -> [String] {
        let answer = docker(["image", "ls", "--format", "{{.Repository}}:{{.Tag}}"])
        guard answer.code == 0 else { throw ImageProblem("docker does not list its images (docker image ls failed)", fix: "is it running?") }
        return answer.output.split(whereSeparator: \.isNewline).map(String.init)
    }

    // MARK: - The base image

    /// The command that makes the image of this xless: it needs no Xcode.
    private static func setUp(arch: String) -> String { "xless setup --docker --arch \(arch) (it needs no Xcode to build the image)" }

    /// The local image of the xless named `version` (the part of its tag that names it: `ImageName.tag(ofShare:)`), for `arch`.
    public func base(version: String, arch: String) throws -> LocalImage {
        let name = ImageName.base(version: version, arch: arch)
        if let found = image(name) {
            if let mismatch = found.mismatch(arch: arch, version: version) { throw ImageProblem("\(found.name) \(mismatch)", fix: "build it again: \(Self.setUp(arch: arch))") }
            return found
        }
        let all = try names()
        let others = all.filter { $0.hasPrefix("\(ImageName.repository):") && $0.hasSuffix("-\(arch)") && !ImageName.isLegacy($0) }
        let fix = "build it: \(Self.setUp(arch: arch))"
        if let other = others.first {
            throw ImageProblem("the image \(name) is missing (\(other) is another version's; xless images are never pulled from a registry)", fix: fix)
        }
        if let legacy = all.first(where: ImageName.isLegacy) {
            throw ImageProblem("there is no xless image on this machine (xless images are never pulled from a registry), and \(legacy) is an older xless's, which is not used",
                               fix: "\(fix), and xless clean --old removes the older xless's images")
        }
        throw ImageProblem("the image \(name) is missing (xless images are never pulled from a registry)", fix: fix)
    }

    // MARK: - An image of the project's own

    /// An image that a person built on xless's, and that one.
    public struct Custom {
        public var image: LocalImage
        public var base: LocalImage
        /// It is xless's image itself.
        public var isBase: Bool { image.id == base.id }
    }

    /// `name`, as `variable` (a variable, or `image:` of a file) names it. It is refused unless it is for this architecture and
    /// xless, and all of the local image of that xless is in it: not only its labels say so, its layers do.
    public func custom(_ name: String, named variable: String, version: String, arch: String) throws -> Custom {
        guard ImageName.isReference(name) else { throw ImageProblem("\(variable) names '\(name)', which is not an image name", fix: "name a local image") }
        let what = "\(variable) names \(name), which"
        let baseName = ImageName.base(version: version, arch: arch)
        func build() -> String { "docker build --pull=false --build-arg XLESS_IMAGE=\(baseName) -t \(name) <its folder>" }
        guard let image = image(name) else {
            throw ImageProblem("\(what) is not on this machine (images are never pulled from a registry)", fix: "build it first: docker build -t \(name) <its folder>")
        }
        guard image.imageID != nil else {
            throw ImageProblem("\(what) is not built on an image of this xless (it has no \(ImageLabel.id) label)", fix: "build it on \(baseName): \(build())")
        }
        if let mismatch = image.mismatch(arch: arch, version: version) { throw ImageProblem("\(what) \(mismatch)", fix: "build it on \(baseName): \(build())") }
        guard let base = self.image(baseName) else {
            throw ImageProblem("\(what) is built on an image of xless \(version), and \(baseName) is missing, which the steps with the secrets run in", fix: "build it: \(Self.setUp(arch: arch))")
        }
        if let mismatch = base.mismatch(arch: arch, version: version) { throw ImageProblem("\(base.name) \(mismatch)", fix: "build it again: \(Self.setUp(arch: arch))") }
        guard image.isBuilt(on: base) else {
            throw ImageProblem("\(what) is not built on \(base.name) as it is now (xless setup has built that again since, or the labels are copied)", fix: "build it again: \(build())")
        }
        return Custom(image: image, base: base)
    }

    // MARK: - The kits

    /// docker's own builder, which is named after the context: the others (a builder container) do not see the local images, and
    /// would look for them in a registry. nil: docker is too old to say.
    public var builder: String? {
        let answer = docker(["context", "show"])
        let name = answer.output.hasSuffix("\n") ? String(answer.output.dropLast()) : answer.output
        return answer.code == 0 && name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.+-]*/) != nil ? name : nil
    }

    /// What of the environment chooses another builder.
    public static let builderVariables = ["BUILDX_BUILDER", "DOCKER_BUILDKIT"]

    /// Whether the image of `kit` on `base` is the one this xless would build.
    public func state(of kit: Kit, on base: LocalImage, share: URL) throws -> Kit.State {
        guard let image = image(kit.image(on: base)) else { return .missing }
        if image.architecture != base.architecture { return .stale("it is for \(image.architecture)") }
        guard image.labels[ImageLabel.kit] == kit.rawValue else { return .stale("xless did not build it") }
        guard image.labels[ImageLabel.kitBase] == base.id, image.isBuilt(on: base) else { return .stale("it is not built on \(base.name) as it is now") }
        guard image.labels[ImageLabel.kitRecipe] == (try kit.recipe(share: share)) else { return .stale("xless's Dockerfile for it has changed") }
        return .current(image)
    }
}
