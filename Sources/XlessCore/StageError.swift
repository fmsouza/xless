import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error from a lower layer (e.g. the App Store Connect client) that can describe itself in the
/// `[stage] cause — fix` form for whichever stage it surfaced in.
public protocol StageReportableError: Error {
    func stageError(_ stage: Stage) -> XlessError
}

extension XlessError {
    /// Maps any error onto the stage error contract (`[stage] cause — fix`, per-stage exit codes). `XlessError` passes through unchanged.
    public static func wrapping(_ error: any Error, stage: Stage) -> XlessError {
        switch error {
        case let e as XlessError:
            return e
        case let e as any StageReportableError:
            return e.stageError(stage)
        case let e as URLError:
            // localizedDescription, not description: the latter can embed request URLs (e.g. presigned upload URLs).
            return XlessError(stage, "network error talking to Apple: \(e.localizedDescription) (\(e.code.rawValue))",
                              fix: "check network access to api.appstoreconnect.apple.com (already retried), then re-run")
        case is CancellationError:
            return XlessError(stage, "cancelled", fix: rerun(stage))
        case let e as CocoaError:
            let path = e.filePath ?? e.url?.path
            let text = e.localizedDescription
            let cause = "file operation failed: \(text)" + (path.map { text.contains($0) ? "" : " (\($0))" } ?? "")
            return XlessError(stage, cause, fix: "check that the path exists and is writable; if it is this stage's input, run the previous stage first (or `xless ship`)")
        default:
            return XlessError(stage, "\(error)", fix: rerun(stage))
        }
    }

    static func rerun(_ stage: Stage) -> String {
        stage >= .build && StagePolicy.pipeline.contains(stage) ? "fix the cause above, then re-run (`xless ship --from \(stage.rawValue)` resumes here)" : "fix the cause above, then re-run"
    }
}

/// Runs one stage's work; any failure leaves as an `XlessError` for `stage`, so it prints `[stage] cause — fix`
/// and exits with the stage's exit code.
public func withStage<T>(_ stage: Stage, _ op: () async throws -> T) async throws -> T {
    do { return try await op() } catch { throw XlessError.wrapping(error, stage: stage) }
}
