import XlessCore
import XlessVault

/// What a command says when Apple already revoked or deleted something (a key, a webhook) and the secret-store entries
/// that held its secret could not be removed. A store a newer xless wrote refuses every change this xless would make,
/// `xless secrets rm` included, so the way out is to upgrade first.
enum StoreCleanup {
    /// Whether `error` is the refusal of a store a newer xless wrote (`VaultFile.requireWritable`).
    static func isNewerStore(_ error: Error) -> Bool { (error as? VaultError)?.kind == .newerFormat }

    /// The fix for entries `names` (or `fallback` when the names are not known) left in the store after `done` (what
    /// Apple already did, e.g. "the key is revoked at Apple").
    static func fix(after error: Error, names: [String], fallback: String, done: String) -> String {
        let what = names.isEmpty ? fallback : names.joined(separator: ", ")
        if isNewerStore(error) {
            return "\(done) already; a newer xless wrote the secret store and this one may not change it (`xless secrets rm` is refused too): upgrade xless (run the install line again: README.md#install), then remove \(what) with `xless secrets rm <name>`"
        }
        return "remove \(what) with `xless secrets rm <name>`; \(done)"
    }

    /// The line `certs revoke` prints for a key it leaves in the store: with a store this xless may not change, upgrade
    /// first.
    static func leftEntry(_ name: String, writable: Bool) -> String {
        writable ? "the secret store still holds its private key as \(name): remove it with `xless secrets rm \(name)`"
            : "the secret store still holds its private key as \(name); a newer xless wrote the store and this one may not change it: upgrade xless (run the install line again: README.md#install), then remove it with `xless secrets rm \(name)`"
    }
}
