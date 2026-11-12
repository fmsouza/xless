import Testing
import Foundation
@testable import XlessIB
@testable import XlessCore

/// Cases outside the supported subset that ibtool compiles: the compiler refuses them on purpose (ruling R9: one
/// golden is not enough to generalise from), so they are not compared with their goldens; `refusesUnsupportedCases`
/// asserts the refusal instead.
let unsupportedCases: [String: String] = [
    // ibtool maps an unknown content mode to scaleToFill; Xcode never writes one.
    "image-mode-unknown": #"unsupported contentMode="bogusMode" on <imageView>"#,
    // ibtool turns a referenced CR (&#13;) into LF next to other characters, but keeps "&#xD;" alone.
    "label-text-carriage-return": "unsupported label text with a carriage return",
    // ibtool rewrites left/right paired with leading/trailing (to leading here); UIKit rejects the pairing at run time.
    "cons-mixed-horizontal": #"unsupported constraint pairing firstAttribute="leading" with secondAttribute="left""#,
]

/// Cases that exhibit an open question of docs/research/nib-encoding.md: the compiler refuses them (R9), so they are
/// not compared with their goldens; `refusesOpenQuestionCases` asserts the refusal instead.
/// Open question 2: ibtool converts these color spaces to extended sRGB / gray with results that differ from the
/// published formulas by ±1 float ulp (task-6 report), so the compiler refuses them.
let refusedCases: [String: String] = [
    "color-calibrated-rgb": "unsupported: calibratedRGB color",
    "color-calibrated-rgb-grid": "unsupported: calibratedRGB color",
    "color-calibrated-white": "unsupported: calibratedWhite color",
    "color-calibrated-white-grid": "unsupported: calibratedWhite color",
    "color-p3": "unsupported: displayP3 color",
    "color-p3-grid": "unsupported: displayP3 color",
    // Open question 3: these fonts ship with macOS and iOS, so ibtool resolves them and encodes their own traits.
    "label-custom-font": #"unsupported: font "Helvetica-Bold" ships with macOS or iOS"#,
    "label-custom-font-avenir": #"unsupported: font "AvenirNext-Regular" ships with macOS or iOS"#,
    // Open question 1: constraints that differ only in their second items (step 7 of the constraint order).
    "order-cons-second-item": #"unsupported: constraints "v04-cn-aaa" and "w03-cn-aaa" differ only in their second items"#,
    "order-cons-second-item-mixed": #"unsupported: constraints "K01-tb-001" and "K02-tb-002" differ only in their second items"#,
    "order-cons-second-item-safe": #"unsupported: constraints "K01-tb-001" and "K02-tb-002" differ only in their second items"#,
    // Open question 13: mirrored constraints (one written from the owning view) that tie through step 6. With the
    // same attribute on both sides the root view's goldens happen to follow the ids, subview owners' do not.
    "order-cons-mirrored-tie": #"unsupported: constraints "K01-tb-001" and "K02-tb-002" tie but are written in opposite directions"#,
    "order-cons-mirrored-same": #"unsupported: constraints "K07-tb-007" and "K08-tb-008" tie but are written in opposite directions"#,
    "order-cons-mirrored-nested": #"unsupported: constraints "gNn-790-CRz" and "twf-789-anu" tie but are written in opposite directions"#,
    // Open question 14: ibtool snaps a gray this close to 0 or 1 to black or white (tolerance not pinned down).
    "color-white-near-black": #"unsupported: gray color white="1.1000000000000001e-07" within 1e-06 of 0 or 1"#,
    "color-white-near-white": #"unsupported: gray color white="0.99999998999999995" within 1e-06 of 0 or 1"#,
]

/// The Xcode builds whose ibtool outputs are committed (`golden/<build>/`), one per `XcodeToolsProfile`.
let goldenBuilds = ["17C52", "27A266a", "27A9275", "27B52"]

struct GoldenCase: CustomStringConvertible, Sendable {
    let name: String
    let flagset: String
    var build = "27A266a"
    var description: String { "\(build)/\(name)/\(flagset)" }
    var profile: XcodeToolsProfile { XcodeToolsProfile.all[build]! }
}

func allGoldenCases() throws -> [GoldenCase] {
    let flags = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusRoot.appendingPathComponent("flagsets.json"))) as! [String: Any]
    let overrides = flags["cases"] as? [String: [String]] ?? [:]
    let defaults = flags["default"] as! [String]
    let names = try FileManager.default.contentsOfDirectory(atPath: corpusRoot.path).filter { $0.hasSuffix(".storyboard") }.map { String($0.dropLast(11)) }.sorted()
    return names.flatMap { n in (overrides[n] ?? defaults).map { GoldenCase(name: n, flagset: $0) } }
}

/// Every corpus case is compared with its goldens, except the refused ones (`refusedCases`, `unsupportedCases`).
func enabledGoldenCases() throws -> [GoldenCase] {
    try allGoldenCases().filter { c in refusedCases[c.name] == nil && unsupportedCases[c.name] == nil }
}

/// `enabledGoldenCases` once per golden build: each is compiled with that build's profile and compared with its goldens.
func enabledGoldenCasesPerBuild() throws -> [GoldenCase] {
    try goldenBuilds.flatMap { b in try enabledGoldenCases().map { GoldenCase(name: $0.name, flagset: $0.flagset, build: b) } }
}

/// A corpus case: its storyboard and its compiled goldens.
struct CorpusCase {
    let name: String
    var storyboard: URL { corpusRoot.appendingPathComponent("\(name).storyboard") }
    func goldenDir(flagset: String, build: String = "27A266a") -> URL {
        corpusRoot.appendingPathComponent("golden/\(build)/\(name)/\(flagset).storyboardc")
    }
    /// The golden `.storyboardc` files by relative path (skips `warnings.txt`).
    func goldenFiles(flagset: String, build: String = "27A266a") throws -> [String: Data] {
        let dir = goldenDir(flagset: flagset, build: build)
        var out: [String: Data] = [:]
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) where f != "warnings.txt" {
            out[f] = try Data(contentsOf: dir.appendingPathComponent(f))
        }
        return out
    }
    /// The ibtool warnings recorded for this case, if any.
    func goldenWarnings(flagset: String, build: String = "27A266a") throws -> [String]? {
        let url = goldenDir(flagset: flagset, build: build).deletingLastPathComponent().appendingPathComponent("warnings.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

@Test(arguments: goldenBuilds)
func goldensAreFromTheirIbtool(_ build: String) throws {
    let v = try String(contentsOf: corpusRoot.appendingPathComponent("golden/\(build)/IBTOOL_VERSION"), encoding: .utf8)
    let p = try #require(XcodeToolsProfile.all[build])
    #expect(v.contains(build))
    #expect(v.contains("ibtool \(p.ibtoolShortVersion) (\(p.ibtoolBundleVersion))"))
}

@Test func everyProfileHasGoldens() {
    #expect(goldenBuilds == XcodeToolsProfile.all.keys.sorted())
}

@Test func filterListsNameRealCases() throws {
    let names = Set(try allGoldenCases().map(\.name))
    for n in Array(refusedCases.keys) + Array(unsupportedCases.keys) { #expect(names.contains(n), "\(n) is not a corpus case") }
    #expect(Set(refusedCases.keys).isDisjoint(with: unsupportedCases.keys))
    #expect(try enabledGoldenCases().count > 230)
}

@Test(arguments: try enabledGoldenCasesPerBuild())
func compilesByteIdentical(_ c: GoldenCase) throws {
    let cc = CorpusCase(name: c.name)
    let doc = try StoryboardParser.parse(url: cc.storyboard)
    let result = try StoryboardCompiler.compile(doc, options: .flagset(named: c.flagset, root: corpusRoot), profile: c.profile)
    let produced = result.files
    let golden = try cc.goldenFiles(flagset: c.flagset, build: c.build)
    let expected = golden.keys.sorted()
    #expect(produced.keys.sorted() == expected)
    #expect(result.warnings == (try cc.goldenWarnings(flagset: c.flagset, build: c.build) ?? []))
    for f in expected {
        let want = golden[f]!
        let got = try #require(produced[f])
        if got != want, f.hasSuffix(".nib") {
            let w = NIBDump.render(try NIBArchiveReader.read(want)).split(separator: "\n")
            let g = NIBDump.render(try NIBArchiveReader.read(got)).split(separator: "\n")
            let diff = zip(w, g).first { $0 != $1 }.map { "golden: \($0)\nxless:  \($1)" }
                ?? (w.count == g.count ? "dumps equal (key or class table order differs)" : "lengths differ")
            Issue.record("\(c)/\(f) differs — first differing dump line:\n\(diff)")
        } else {
            #expect(got == want, "\(c)/\(f)")
        }
    }
}

@Test(arguments: goldenBuilds, refusedCases.keys.sorted())
func refusesOpenQuestionCases(_ build: String, _ name: String) throws {
    let doc = try StoryboardParser.parse(url: CorpusCase(name: name).storyboard)
    let error = try #require(throws: XlessError.self) {
        try StoryboardCompiler.compile(doc, options: .flagset(named: "universal-16", root: corpusRoot), profile: XcodeToolsProfile.all[build]!)
    }
    #expect(error.stage == .ib)
    #expect(error.cause.hasPrefix(refusedCases[name]!), "\(error)")
    #expect(error.cause.hasSuffix("(see docs/research/nib-encoding.md#open-questions)"), "\(error)")
}

@Test(arguments: goldenBuilds, unsupportedCases.keys.sorted())
func refusesUnsupportedCases(_ build: String, _ name: String) throws {
    let doc = try StoryboardParser.parse(url: CorpusCase(name: name).storyboard)
    let error = try #require(throws: XlessError.self) {
        try StoryboardCompiler.compile(doc, options: .flagset(named: "universal-16", root: corpusRoot), profile: XcodeToolsProfile.all[build]!)
    }
    #expect(error.stage == .ib)
    #expect(error.cause.hasPrefix(unsupportedCases[name]!), "\(error)")
}
