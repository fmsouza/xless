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

    /// The image with the Xcode's SDK, and what to tell the person about it.
    public struct Base {
        public var image: LocalImage
        public var notice: String?
    }

    public static func setUp(xcode: String? = nil, arch: String) -> String {
        "xless setup --docker --xcode \(xcode.map { "<path to Xcode \($0)'s .app or .xip>" } ?? "<Xcode.xip>") --arch \(arch)"
    }

    private func build(again xcode: String, arch: String) -> String { "build it again from Xcode \(xcode): \(Self.setUp(xcode: xcode, arch: arch))" }

    private func missing(_ name: String, xcode: String, arch: String, why: String = "") -> ImageProblem {
        ImageProblem("the image \(name) is missing\(why)", fix: "build it from Xcode \(xcode): \(Self.setUp(xcode: xcode, arch: arch))")
    }

    /// The image of the pinned Xcode; without a pin, that of the newest Xcode there is one of.
    public func base(arch: String, pin: String?) throws -> Base {
        let plain = image(ImageName.plain(arch: arch))
        func old(_ image: LocalImage) -> Base {
            let xcode = image.xcode ?? "", name = ImageName.base(arch: arch, xcode: xcode)
            return Base(image: image, notice: "note: \(image.name) is used for Xcode \(xcode); the tag without an Xcode goes away in a later release (xless setup --docker makes \(name))")
        }
        if let pin {
            let name = ImageName.base(arch: arch, xcode: pin)
            if let found = image(name) { return Base(image: try checked(found, arch: arch, xcode: pin)) }
            if let plain, plain.sdk != nil, plain.xcode == pin { return old(try checked(plain, arch: arch, xcode: pin)) }
            throw missing(name, xcode: pin, arch: arch)
        }
        let found = try names().compactMap { name in ImageName.xcode(ofBase: name, arch: arch).map { (name: name, xcode: $0) } }
            .sorted { ImageName.isOlder($1.xcode, than: $0.xcode) }
        var older: [String] = []
        for (name, xcode) in found {
            guard let image = image(name) else { continue }
            if image.sdk != nil { return Base(image: try checked(image, arch: arch, xcode: xcode)) }
            older.append(name)
        }
        if let plain {
            if let xcode = plain.xcode, plain.sdk != nil { return old(try checked(plain, arch: arch, xcode: xcode)) }
            older.append(plain.name)
        }
        throw ImageProblem("there is no xless image on this machine (xless images are never pulled from a registry)",
                           fix: "build it with: \(Self.setUp(arch: arch))" + (older.isEmpty ? "" : " (those of an older xless, as \(older[0]), are not used; xless clean --old removes them)"))
    }

    private func checked(_ image: LocalImage, arch: String, xcode: String) throws -> LocalImage {
        guard image.sdk != nil else {
            throw ImageProblem("\(image.name) is not an image of this xless (it has no \(ImageLabel.sdk) label: an older xless built it)", fix: build(again: xcode, arch: arch))
        }
        if let mismatch = image.mismatch(arch: arch, xcode: xcode) { throw ImageProblem("\(image.name) \(mismatch)", fix: build(again: xcode, arch: arch)) }
        return image
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
    /// Xcode, and all of the local image of that Xcode is in it: not only its labels say so, its layers do.
    public func custom(_ name: String, named variable: String, arch: String, pin: String?) throws -> Custom {
        guard ImageName.isReference(name) else { throw ImageProblem("\(variable) names '\(name)', which is not an image name", fix: "name a local image") }
        let what = "\(variable) names \(name), which"
        func build(_ base: String) -> String { "docker build --pull=false --build-arg XLESS_IMAGE=\(base) -t \(name) <its folder>" }
        guard let image = image(name) else {
            throw ImageProblem("\(what) is not on this machine (images are never pulled from a registry)", fix: "build it first: docker build -t \(name) <its folder>")
        }
        guard let sdk = image.sdk, let xcode = image.xcode else {
            throw ImageProblem("\(what) is not built on an image of this xless (it has no \(ImageLabel.sdk) label)",
                               fix: "build it on \(ImageName.base(arch: arch, xcode: pin ?? "<version>")): \(build(ImageName.base(arch: arch, xcode: pin ?? "<version>")))")
        }
        if let mismatch = image.mismatch(arch: arch, xcode: pin) {
            let wanted = pin ?? xcode
            throw ImageProblem("\(what) \(mismatch)", fix: "build it on the image of Xcode \(wanted): \(build(ImageName.base(arch: arch, xcode: wanted)))")
        }
        let name = ImageName.base(arch: arch, xcode: xcode), ofBuild = ImageName.base(arch: arch, xcode: xcode, build: sdk)
        var base = self.image(name)
        if base?.sdk != sdk { base = self.image(ofBuild) ?? (base?.sdk == nil ? nil : base) }
        guard let base, base.sdk == sdk else {
            throw ImageProblem("\(what) is built for Xcode \(xcode) (\(sdk)), and the image \(base == nil ? name : ofBuild) is missing, which the steps with the secrets run in",
                               fix: "build it from Xcode \(xcode): \(Self.setUp(xcode: xcode, arch: arch))")
        }
        _ = try checked(base, arch: arch, xcode: xcode)
        guard image.isBuilt(on: base) else {
            throw ImageProblem("\(what) is not built on \(base.name) as it is now (xless setup has built that again since, or the labels are copied)", fix: "build it again: \(build(base.name))")
        }
        return Custom(image: image, base: base)
    }

    // MARK: - The kits

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
