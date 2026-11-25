import Testing
import Foundation
@testable import XlessCore

@Test func withStagePassesXlessErrorThrough() async {
    do { _ = try await withStage(.sign) { throw XlessError(.config, "bad", fix: "fix it") }; Issue.record("expected throw") }
    catch let e as XlessError { #expect(e == XlessError(.config, "bad", fix: "fix it")) }
    catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageMapsCocoaErrorToStage() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())/out")
    do {
        _ = try await withStage(.upload) { try FileManager.default.contentsOfDirectory(at: missing, includingPropertiesForKeys: nil) }
        Issue.record("expected throw")
    } catch let e as XlessError {
        #expect(e.stage == .upload)
        #expect(e.stage.exitCode == 17)
        #expect(e.description.hasPrefix("[upload] "))
        #if !os(Windows) // Foundation there does not say of which directory
        #expect(e.cause.contains(missing.path))
        #endif
        #expect(!e.fix.isEmpty)
    } catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageMapsUnknownErrorWithItsText() async {
    struct Boom: Error, CustomStringConvertible { var description: String { "kaboom 42" } }
    do { _ = try await withStage(.finalize) { throw Boom() }; Issue.record("expected throw") }
    catch let e as XlessError {
        #expect(e.stage == .finalize)
        #expect(e.cause.contains("kaboom 42"))
        #expect(e.description.contains(" — "))
    } catch { Issue.record("not an XlessError: \(error)") }
}

@Test func withStageReturnsValue() async throws {
    #expect(try await withStage(.build) { 7 } == 7)
}

@Test func checkSDKReportsTheCallersStage() {
    do { try Requirements.checkSDK(sdkInfo("18.5"), platform: .ios, stage: .sdk); Issue.record("expected throw") }
    catch let e as XlessError { #expect(e.stage == .sdk) }
    catch { Issue.record("\(error)") }
}

@Test func prepareIsExit19BetweenSDKAndBuild() {
    #expect(Stage.prepare.exitCode == 19)
    #expect(Stage.sdk < .prepare && Stage.prepare < .build)
}

@Test func accountIsExit20AndOutsideThePipeline() {
    #expect(Stage.account.exitCode == 20)
    #expect(Stage(rawValue: "account") == .account)
    #expect(!StagePolicy.pipeline.contains(.account))
    #expect(XlessError(.account, "x", fix: "y").description == "[account] x — y")
}

@Test func onlyPipelineStagesSuggestShipFrom() {
    #expect(!XlessError.rerun(.account).contains("ship --from"))
    #expect(!XlessError.rerun(.ib).contains("ship --from"))
    #expect(XlessError.rerun(.sign).contains("ship --from sign"))
}
