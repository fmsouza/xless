import Foundation
import XlessCore

/// The versions whose iOS build xless reproduces: the ones docs/research/react-native-ios-contract.md was measured
/// with (gates G1–G4). Another React Native minor, Expo SDK, CocoaPods or Bundler may generate a different workspace or
/// need different fixes, so it is refused until the contract is re-measured.
public enum ReactNativeContract {
    /// major.minor of `react-native`.
    public static let reactNative = "0.86"
    /// The Expo SDK: the major version of the `expo` package.
    public static let expoSDK = "57"
    /// Exact versions from the app's `Gemfile.lock` (`cocoapods` spec, `BUNDLED WITH`); the image's Bundler is this one.
    public static let cocoaPods = "1.15.2"
    public static let bundler = "2.7.2"

    /// The detected versions; nil where they cannot be read.
    public struct Detected: Equatable, Sendable {
        public var reactNative: String?
        public var expo: String?
        public var cocoaPods: String?
        public var bundler: String?
        public init(reactNative: String? = nil, expo: String? = nil, cocoaPods: String? = nil, bundler: String? = nil) {
            self.reactNative = reactNative; self.expo = expo; self.cocoaPods = cocoaPods; self.bundler = bundler
        }
        public var inContract: Bool {
            reactNative.map(majorMinor) == ReactNativeContract.reactNative && expo.map(major) == expoSDK
                && cocoaPods == ReactNativeContract.cocoaPods && bundler == ReactNativeContract.bundler
        }
    }

    // MARK: Ruby (before the work copy: from the source)

    /// The `Gemfile.lock` Bundler uses for `pod install` in `<appDir>/ios`: the nearest one from there up to `root`.
    static func gemfileLock(appDir: URL, root: URL) -> URL? {
        walkUp(from: appDir.appendingPathComponent("ios"), to: root) { d in
            let f = d.appendingPathComponent("Gemfile.lock")
            return FileManager.default.fileExists(atPath: f.path) ? f : nil
        }
    }

    /// `cocoapods (x.y.z)` in the specs, and `BUNDLED WITH`.
    static func rubyVersions(gemfileLock text: String) -> (cocoaPods: String?, bundler: String?) {
        let pods = text.firstMatch(of: /(?m)^    cocoapods \(([0-9][^)]*)\)$/).map { String($0.1) }
        let bundler = text.firstMatch(of: /(?m)^BUNDLED WITH\r?\n\s+([0-9][^\s]*)/).map { String($0.1) }
        return (pods, bundler)
    }

    /// Refuses a missing `Gemfile.lock` or CocoaPods/Bundler versions outside the contract. `appDir` and `root` are in
    /// the source tree.
    public static func checkRuby(appDir: URL, root: URL) throws {
        guard let lock = gemfileLock(appDir: appDir, root: root), let text = try? String(contentsOf: lock, encoding: .utf8) else {
            throw XlessError(.prepare, "no Gemfile.lock for \(appDir.lastPathComponent)/ios (looked from there up to the source root)",
                             fix: "commit a Gemfile with gem \"cocoapods\", \"~> \(cocoaPods)\" and its Gemfile.lock (bundle lock), as React Native templates do")
        }
        let (pods, bundler) = rubyVersions(gemfileLock: text)
        guard let pods else {
            throw XlessError(.prepare, "\(lock.path) does not lock the cocoapods gem", fix: "add gem \"cocoapods\", \"~> \(cocoaPods)\" to the Gemfile and run bundle lock")
        }
        guard pods == cocoaPods else {
            throw XlessError(.prepare, "CocoaPods \(pods) (Gemfile.lock) is outside the contract xless supports (\(cocoaPods))",
                             fix: "lock cocoapods \(cocoaPods), or re-measure docs/research/react-native-ios-contract.md (gate G1) and update ReactNativeContract")
        }
        guard bundler == ReactNativeContract.bundler else {
            throw XlessError(.prepare, "Gemfile.lock is BUNDLED WITH \(bundler ?? "(none)"); xless's React Native image has Bundler \(ReactNativeContract.bundler)",
                             fix: "run `bundle _\(ReactNativeContract.bundler)_ lock` in the app and commit Gemfile.lock")
        }
    }

    // MARK: JavaScript (after the JS install: what Node resolves from the app)

    /// The installed `version` of `package`, resolved as Node does from `appDir` (`node_modules/<package>` in it or a
    /// parent, up to `root`).
    static func installedVersion(_ package: String, appDir: URL, root: URL) -> String? {
        walkUp(from: appDir, to: root) { d in
            (try? Data(contentsOf: d.appendingPathComponent("node_modules/\(package)/package.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String
        }
    }

    /// Reads every version without judging it: Ruby from the source's Gemfile.lock, JavaScript from what is installed
    /// in the work copy (nil before the JS install).
    public static func detect(appDir: String, source: URL, work: URL) -> Detected {
        let lock = gemfileLock(appDir: source.appendingPathComponent(appDir), root: source).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let ruby: (cocoaPods: String?, bundler: String?) = lock.map(rubyVersions) ?? (nil, nil)
        let app = work.appendingPathComponent(appDir)
        return Detected(reactNative: installedVersion("react-native", appDir: app, root: work), expo: installedVersion("expo", appDir: app, root: work),
                        cocoaPods: ruby.cocoaPods, bundler: ruby.bundler)
    }

    /// Refuses `react-native` or `expo` outside the contract, as installed in the work copy.
    public static func checkJavaScript(appDir: URL, root: URL) throws {
        guard let rn = installedVersion("react-native", appDir: appDir, root: root) else {
            throw XlessError(.prepare, "react-native is not installed for \(appDir.path)", fix: "add react-native to the app's package.json dependencies (and its lockfile)")
        }
        guard majorMinor(rn) == reactNative else {
            throw XlessError(.prepare, "React Native \(rn) is outside the contract xless supports (\(reactNative).x)",
                             fix: "use react-native \(reactNative).x, or re-measure docs/research/react-native-ios-contract.md and update ReactNativeContract")
        }
        guard let expo = installedVersion("expo", appDir: appDir, root: root) else {
            throw XlessError(.prepare, "expo is not installed for \(appDir.path); xless builds Expo (CNG) apps",
                             fix: "add expo \(expoSDK).x to the app's dependencies")
        }
        guard major(expo) == expoSDK else {
            throw XlessError(.prepare, "Expo SDK \(major(expo)) (expo \(expo)) is outside the contract xless supports (SDK \(expoSDK))",
                             fix: "use expo \(expoSDK).x, or re-measure docs/research/react-native-ios-contract.md and update ReactNativeContract")
        }
    }

    static func majorMinor(_ v: String) -> String { v.split(separator: ".").prefix(2).joined(separator: ".") }
    static func major(_ v: String) -> String { v.split(separator: ".").first.map(String.init) ?? v }
}
