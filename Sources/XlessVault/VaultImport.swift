import Crypto
import _CryptoExtras
import Foundation
import XlessCore

/// What `xless secrets import` infers and checks before a file's content goes into the store.
public enum VaultImport {
    /// The kind a well-known name implies: `ASC_KEY_P8` an App Store Connect API key, `XLESS_*_KEY` a signing key, `XLESS_DEMO_PASSWORD` a password.
    public static func inferredKind(for name: String) -> VaultEntry.Kind {
        let base = name.split(separator: "@", maxSplits: 1).first.map(String.init) ?? name
        switch base {
        case "ASC_KEY_P8": return .ascAPIKey
        case "XLESS_DIST_KEY", "XLESS_DEVID_KEY", "XLESS_INSTALLER_KEY": return .signingKey
        case "XLESS_DEMO_PASSWORD": return .password
        default: return .generic
        }
    }

    /// `AuthKey_ABC123DEFG.p8` (as Apple names API and auth key downloads) → `ABC123DEFG`.
    public static func keyID(fromFileName fileName: String) -> String? {
        guard fileName.hasPrefix("AuthKey_"), fileName.hasSuffix(".p8") else { return nil }
        let id = fileName.dropFirst("AuthKey_".count).dropLast(".p8".count)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return String(id)
    }

    /// Refuses content that is not what `kind` says: an API or auth key must be a P-256 private key PEM (`.p8`), a
    /// signing key an RSA private key PEM; any secret must be non-empty. The error never quotes the content.
    public static func validate(_ secret: SecretBytes, kind: VaultEntry.Kind) throws {
        guard !secret.isEmpty else { throw VaultError(.invalidSecret, "the file is empty", fix: "check the path given to --file") }
        switch kind {
        case .ascAPIKey, .authKey:
            guard (try? P256.Signing.PrivateKey(pemRepresentation: PEM.normalize(secret.utf8String()))) != nil else {
                throw VaultError(.invalidSecret, "the file is not a .p8 private key (\(kind.rawValue) expects one)",
                                 fix: "import the AuthKey_<KEY_ID>.p8 file Apple gave you, or pass the right --kind")
            }
        case .signingKey:
            guard (try? _RSA.Signing.PrivateKey(pemRepresentation: PEM.normalize(secret.utf8String()))) != nil else {
                throw VaultError(.invalidSecret, "the file is not an RSA private key PEM (signing-key expects one)",
                                 fix: "import the key written by `xless sign bootstrap`, or pass the right --kind")
            }
        case .password, .generic:
            break
        }
    }
}
