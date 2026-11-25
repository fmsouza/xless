import Foundation
import Testing
import XlessCore
@testable import XlessRun

private func stop(_ body: () throws -> Void) -> RunStop? {
    do { try body(); return nil } catch { return error as? RunStop }
}

@Test func theRunsOwnOptionsAreTakenWhereverTheyAre() throws {
    let r = try RunRequest.parse(["--platform=macos", "--config", "o.yml", "--verbose", "--dry-run", "--allow-disk-secrets", "--from", "sign"])
    #expect(r.target == .overlay("o.yml") && r.platform == .macos && r.dryRun && r.allowDisk && !r.simulator)
    #expect(r.rest == ["--verbose", "--from", "sign"])
    let p = try RunRequest.parse(["MyApp", "--platform", "ios", "--build-number", "1"])
    #expect(p.target == .project("MyApp") && p.rest == ["--build-number", "1"] && !p.dryRun)
}

/// ship takes no operands, so a `--` passed on would make it fail.
@Test func theDashesThatIntroduceShipsArgumentsAreNotPassedOn() throws {
    #expect(try RunRequest.parse(["MyApp", "--to", "finalize", "--", "--verbose"]).rest == ["--to", "finalize", "--verbose"])
}

@Test func argumentsThatMeanNothingAreUsageErrors() {
    for bad in [[], ["--dry-run"], ["--config"], ["--config", "o.yml", "proj"], ["proj", "--config", "o.yml"], ["proj", "--config=o.yml"],
                ["--platform"], ["--platform", "tvos", "p"], ["--destination", "tv", "p"], ["p", "--platform", "macos"]] {
        let e = stop { _ = try RunRequest.parse(bad) }
        #expect(e?.code == 2 && e?.message?.hasPrefix("testflight: ") == true, "\(bad)")
    }
}

@Test func theStagesOfAnOverlayRun() throws {
    func span(_ words: String...) throws -> RunSpan { try .overlay(RunRequest.parse(["--config", "o"] + words)) }
    #expect(try span() == RunSpan(from: .build, to: .upload))
    #expect(try span("--platform", "macos").to == .package)
    #expect(try span("--destination", "simulator").to == .build)
    #expect(try span("--to", "prepare").from == .prepare)
    #expect(try span("--from=assets", "--to=package", "--verbose") == RunSpan(from: .assets, to: .package, extra: ["--verbose"]))
    #expect(try span("--build-number=7").buildNumberGiven)
    for bad in [["--from", "upload", "--to", "build"], ["--from", "build", "--to", "prepare"], ["--from", "ib"], ["--to"],
                ["--destination", "simulator", "--to", "finalize"], ["--destination", "simulator", "--from", "sign"]] {
        #expect(stop { _ = try RunSpan.overlay(RunRequest.parse(["--config", "o"] + bad)) }?.code == 2, "\(bad)")
    }
}

@Test func aProjectsRunIsReadOnlyForWhereItStops() throws {
    #expect(try RunSpan.project(RunRequest.parse(["p", "--to", "finalize"])).to == .finalize)
    let s = try RunSpan.project(RunRequest.parse(["p", "--from", "upload", "--build-number", "3"]))
    #expect(s.to == .upload && s.buildNumberGiven && s.extra == ["--from", "upload", "--build-number", "3"])
    #expect(stop { _ = try RunSpan.project(RunRequest.parse(["p", "--to", "nowhere"])) }?.message?.contains("unknown stage") == true)
}
