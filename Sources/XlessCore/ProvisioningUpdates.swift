import Yams

/// `provisioningUpdates: false` (xless.yml or an overlay): `sign` changes nothing on the account
/// (docs/signing-and-testflight.md#what-sign-changes-on-the-account).
public enum ProvisioningUpdates {
    public static let key = "provisioningUpdates"

    /// Refuses a top-level key that reads like `provisioningUpdates` and is not it: where unknown keys are ignored, the
    /// restriction would be dropped without a word.
    public static func refuseMisspelt(yaml: String, file: String) throws {
        guard let top = try? Yams.load(yaml: yaml) as? [String: Any] else { return }
        for found in top.keys.sorted() where found != key && found.lowercased().contains("provisioning") {
            throw XlessError(.config, "\(file): unknown key '\(found)'", fix: "write it as \(key): false")
        }
    }
}
