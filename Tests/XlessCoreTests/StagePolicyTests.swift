import Foundation
import Testing
@testable import XlessCore

// MARK: simulator builds stop at build (StagePolicy, what the CLI asks)

@Test(arguments: [Stage.assets, .finalize, .sign, .package, .upload])
func everyStageAfterBuildRefusesASimulatorBuildWithItsOwnExitCode(stage: Stage) throws {
    let app = URL(fileURLWithPath: "/w/.xless/build/ios-simulator/app")
    let e = #expect(throws: XlessError.self) { try StagePolicy.requireDevice(stage, simulator: true, appDir: app) }
    #expect(e?.stage == stage)
    #expect(e?.cause.contains("--destination simulator builds stop at build") == true)
    #expect(e?.fix.contains("/w/.xless/build/ios-simulator/app/<App>.app") == true)
    // A device build passes.
    try StagePolicy.requireDevice(stage, simulator: false, appDir: app)
}

@Test func aSimulatorShipDefaultsToBuildAndRefusesAnyLaterStage() {
    #expect(StagePolicy.lastStage(to: nil, simulator: true) == .build)
    #expect(StagePolicy.lastStage(to: nil, simulator: false) == .upload)
    #expect(StagePolicy.lastStage(to: .finalize, simulator: true) == .finalize)
    #expect(StagePolicy.shipRangeProblem(from: .build, last: .build, simulator: true) == nil)
    #expect(StagePolicy.shipRangeProblem(from: .prepare, last: .prepare, simulator: true) == nil)
    for last in [Stage.assets, .finalize, .sign, .package, .upload] {
        #expect(StagePolicy.shipRangeProblem(from: .build, last: last, simulator: true)
                == "--to \(last.rawValue): --destination simulator builds stop at build (prepare, build)")
        #expect(StagePolicy.shipRangeProblem(from: .build, last: last, simulator: false) == nil)
    }
    // --from past build implies --to past build: refused too.
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: StagePolicy.lastStage(to: nil, simulator: true), simulator: true)
            == "--to build comes before --from sign")
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: .sign, simulator: true) != nil)
}

@Test func shipRefusesStagesOutsideThePipeline() {
    for stage in [Stage.config, .sdk, .ib] {
        #expect(StagePolicy.shipRangeProblem(from: stage, last: .upload, simulator: false)
                == "--from \(stage.rawValue): `\(stage.rawValue)` is not a ship pipeline stage; use one of: prepare, build, assets, finalize, sign, package, upload")
        #expect(StagePolicy.shipRangeProblem(from: .build, last: stage, simulator: false)?.hasPrefix("--to \(stage.rawValue): ") == true)
    }
    #expect(StagePolicy.shipRangeProblem(from: .sign, last: .finalize, simulator: false) == "--to finalize comes before --from sign")
}

/// `ship` uploads a Mac app only when the command line says so and it is built for the App Store.
@Test func shipUploadsAMacAppOnlyWhenAskedAndBuiltForTheAppStore() {
    func stages(to: Stage?, platform: Platform = .macos, distribution: Distribution, from: Stage = .sign, prepare: Bool = false) -> [Stage] {
        StagePolicy.shipStages(from: from, to: to, simulator: false, hasPrepare: prepare, platform: platform, distribution: distribution)
    }
    #expect(stages(to: .upload, distribution: .appStore) == [.sign, .package, .upload])
    #expect(stages(to: .upload, distribution: .appStore, from: .upload) == [.upload])
    #expect(stages(to: nil, distribution: .appStore) == [.sign, .package])
    #expect(stages(to: .package, distribution: .appStore) == [.sign, .package])
    #expect(stages(to: .upload, distribution: .developerID) == [.sign, .package])
    #expect(stages(to: nil, distribution: .developerID) == [.sign, .package])
    #expect(stages(to: nil, platform: .ios, distribution: .appStore) == [.sign, .package, .upload])
    #expect(stages(to: .upload, platform: .ios, distribution: .appStore, from: .build) == [.build, .assets, .finalize, .sign, .package, .upload])
    // An overlay build without a freshly synced work copy is never right: starting at build includes prepare.
    #expect(stages(to: .build, platform: .ios, distribution: .appStore, from: .build, prepare: true) == [.prepare, .build])
    #expect(stages(to: .build, platform: .ios, distribution: .appStore, from: .prepare) == [.build])
    #expect(stages(to: .finalize, platform: .ios, distribution: .appStore, from: .assets, prepare: true) == [.assets, .finalize])
    #expect(StagePolicy.shipStages(from: .build, to: nil, simulator: true, hasPrepare: true, platform: .ios, distribution: .appStore) == [.prepare, .build])
}

@Test func theSimulatorIsRefusedForTauriAndXlessYMLProjects() throws {
    let e = #expect(throws: XlessError.self) { try StagePolicy.requireReactNativeForSimulator(simulator: true, isReactNative: false) }
    #expect(e?.stage == .config && e?.stage.exitCode == 10)
    #expect(e?.description == "[config] --destination simulator builds React Native overlays only — drop --destination, or build a type: react-native overlay")
    try StagePolicy.requireReactNativeForSimulator(simulator: true, isReactNative: true)
    try StagePolicy.requireReactNativeForSimulator(simulator: false, isReactNative: false)
}
