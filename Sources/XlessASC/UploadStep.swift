import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// Runs one upload step, rethrowing every failure (ASC, transport, decoding, cancellation) as an error of `stage`
/// (`[upload]` by default). `suffix` is appended to whatever fix applies (auth hint, known issue or `fix`).
func uploadStep<T>(_ what: String, stage: Stage = .upload, fix: String, suffix: String = "", _ op: () async throws -> T) async throws -> T {
    func withSuffix(_ f: String) -> String { suffix.isEmpty ? f : "\(f); \(suffix)" }
    do { return try await op() }
    catch let e as ASCError {
        let auth = e.status == 401 || e.status == 403 ? e.stageError(stage).fix : nil
        throw XlessError(stage, "\(what): \(e.description)", fix: withSuffix(auth ?? KnownIssues.explain(e.description) ?? fix))
    }
    catch let e as URLError { throw XlessError(stage, "\(what): \(e.localizedDescription) (\(e.code.rawValue))", fix: withSuffix(fix)) }
    catch let e as XlessError { throw e }
    catch { throw XlessError(stage, "\(what): \(error)", fix: withSuffix(fix)) }
}
