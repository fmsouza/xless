import Foundation

/// Paths inside the installed Darwin Swift SDK bundle (`xtool sdk install`; layout of darwin.xtoolsdk).
public struct DarwinSDK: Sendable {
    public let bundle: URL
    public init(bundle: URL = DarwinSDKLocator.bundle()) { self.bundle = bundle }

    static let platformDir = ["iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator", "macosx": "MacOSX"]

    public func sdkPath(_ name: String) throws -> URL {
        guard let p = Self.platformDir[name] else { throw XlessError(.sdk, "unknown SDK '\(name)'", fix: "use iphoneos, iphonesimulator or macosx") }
        let dir = bundle.appendingPathComponent("Developer/Platforms/\(p).platform/Developer/SDKs")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // Prefer the versioned directory (iPhoneOS27.0.sdk); the unversioned one may be a symlink.
        guard let pick = items.filter({ $0.hasPrefix(p) && $0.hasSuffix(".sdk") }).sorted(by: { $0.count > $1.count }).first else {
            throw XlessError(.sdk, "no \(p) SDK in \(dir.path)", fix: "install the Darwin SDK (`xless sdk install` / use the xless image)")
        }
        return dir.appendingPathComponent(pick)
    }

    public func sdkVersion(_ name: String) throws -> String {
        let settings = try sdkPath(name).appendingPathComponent("SDKSettings.json")
        struct S: Decodable { var Version: String }
        guard let d = try? Data(contentsOf: settings), let s = try? JSONDecoder().decode(S.self, from: d) else {
            throw XlessError(.sdk, "cannot read \(settings.path)", fix: "reinstall the Darwin SDK")
        }
        return s.Version
    }

    public var toolchain: URL { bundle.appendingPathComponent("Developer/Toolchains/XcodeDefault.xctoolchain") }
    public var ld64: URL { bundle.appendingPathComponent("toolset/bin/ld64.lld") }
    /// xtool's toolset (darwin-tools-linux-llvm, the LLVM of `ld64.lld`) ships dsymutil next to the linker; Swift Build
    /// finds it there through PATH.
    public var dsymutil: URL { bundle.appendingPathComponent("toolset/bin/dsymutil") }

    /// `libclang_rt.<platform>.a` from the toolchain's clang resource dir (platform "ios" → libclang_rt.ios.a).
    public func clangRuntime(platform: String) throws -> URL {
        let base = toolchain.appendingPathComponent("usr/lib/clang")
        for v in ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).sorted().reversed() {
            let f = base.appendingPathComponent("\(v)/lib/darwin/libclang_rt.\(platform).a")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        throw XlessError(.build, "libclang_rt.\(platform).a not found under \(base.path)", fix: "reinstall the Darwin SDK")
    }
}
