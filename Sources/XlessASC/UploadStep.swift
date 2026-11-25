import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XlessCore

/// The app record an upload, or its TestFlight delivery, goes to.
func uploadApp(bundleID: String, resources: ASCResources, fix: String, suffix: String = "") async throws -> ASCApp {
    let found = try await uploadStep("looking up the app record", fix: fix, suffix: suffix) { try await ASCApps(resources: resources).find(bundleID: bundleID) }
    guard let found else {
        throw XlessError(.upload, "no app record for \(bundleID)", fix: "create it with `xless apps create --bundle-id \(bundleID) --name <name> --sku <sku> --locale <locale>` (Apple ID sign-in: the API cannot create app records), or in App Store Connect (Apps → +)")
    }
    return found
}

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
