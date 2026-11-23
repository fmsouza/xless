import Foundation
import SwiftASN1
import XlessCore

/// A provisioning profile file: a CMS (PKCS #7) SignedData envelope, BER or DER, whose encapsulated content is an XML
/// property list. `xless profiles download` parses it and checks it belongs to the team and the bundle ID before writing
/// it. The signature is not verified: the file comes from App Store Connect over TLS, and devices check it themselves.
public struct ProvisioningProfile: Sendable, Equatable {
    public var name: String?
    public var uuid: String?
    public var teamIdentifiers: [String]
    public var teamName: String?
    /// The entitlements' `application-identifier` (iOS, tvOS) or `com.apple.application-identifier` (macOS).
    public var applicationIdentifier: String?
    public var expirationDate: Date?
    public var provisionedDevices: [String]
    public var provisionsAllDevices: Bool

    static let signedDataOID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 2]
    static let dataOID: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
    static let contextZero = ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)

    /// The encapsulated content of a CMS SignedData envelope (`ContentInfo` → `SignedData` → `encapContentInfo` →
    /// `eContent`), in BER (indefinite lengths, chunked OCTET STRINGs) or DER.
    public static func content(ofCMS data: Data, stage: Stage = .account) throws -> Data {
        let notCMS = { (why: String) in
            XlessError(stage, "the profile is not a CMS envelope (\(why))",
                       fix: "re-run; if it persists, check the profile with `xless profiles list --json` and renew it")
        }
        do {
            let root = try BER.parse(Array(data))
            let bytes: [UInt8] = try BER.sequence(root, identifier: .sequence) { nodes in
                guard let type = nodes.next() else { throw notCMS("empty ContentInfo") }
                guard try ASN1ObjectIdentifier(berEncoded: type) == signedDataOID else { throw notCMS("its content type is not signedData") }
                guard let wrapped = nodes.next() else { throw notCMS("no content") }
                return try BER.explicitlyTagged(wrapped, tagNumber: 0, tagClass: .contextSpecific) { signed in
                    try BER.sequence(signed, identifier: .sequence) { fields in
                        _ = fields.next() // version
                        _ = fields.next() // digestAlgorithms
                        guard let encap = fields.next() else { throw notCMS("no encapsulated content") }
                        let content: [UInt8] = try BER.sequence(encap, identifier: .sequence) { parts in
                            guard let eType = parts.next(), try ASN1ObjectIdentifier(berEncoded: eType) == dataOID else {
                                throw notCMS("the encapsulated content is not data")
                            }
                            guard let eContent = parts.next() else { throw notCMS("the encapsulated content is detached") }
                            return try BER.explicitlyTagged(eContent, tagNumber: 0, tagClass: .contextSpecific) {
                                Array(try ASN1OctetString(berEncoded: $0).bytes)
                            }
                        }
                        while fields.next() != nil {} // certificates, crls, signerInfos
                        return content
                    }
                }
            }
            return Data(bytes)
        } catch let e as XlessError {
            throw e
        } catch {
            throw notCMS("\(error)")
        }
    }

    /// Parses the profile file: the envelope, then the property list inside.
    public static func parse(_ data: Data, stage: Stage = .account) throws -> ProvisioningProfile {
        let xml = try content(ofCMS: data, stage: stage)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any] else {
            throw XlessError(stage, "the profile's envelope holds no property list", fix: "renew the profile with `xless profiles renew <id>`")
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfile(
            name: plist["Name"] as? String, uuid: plist["UUID"] as? String,
            teamIdentifiers: plist["TeamIdentifier"] as? [String] ?? [], teamName: plist["TeamName"] as? String,
            applicationIdentifier: (entitlements["application-identifier"] as? String) ?? (entitlements["com.apple.application-identifier"] as? String),
            expirationDate: plist["ExpirationDate"] as? Date,
            provisionedDevices: plist["ProvisionedDevices"] as? [String] ?? [],
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false)
    }

    /// Checks the profile is the one App Store Connect described: issued to `team`, for `<appIDPrefix>.<bundleIdentifier>`
    /// (a wildcard identifier such as `com.example.*` as it is), and, when `uuid` is given, with that UUID.
    public func verify(team: String, appIDPrefix: String, bundleIdentifier: String, uuid expected: String? = nil, stage: Stage = .account) throws {
        let fix = "do not use this file; check the team (--team) and the profile with `xless profiles list --json`"
        guard teamIdentifiers.contains(team) else {
            throw XlessError(stage, "the profile's TeamIdentifier is \(teamIdentifiers.isEmpty ? "missing" : teamIdentifiers.joined(separator: ", ")), not team \(team)", fix: fix)
        }
        let appID = "\(appIDPrefix).\(bundleIdentifier)"
        guard applicationIdentifier == appID else {
            throw XlessError(stage, "the profile's application-identifier is \(applicationIdentifier ?? "missing"), not \(appID)", fix: fix)
        }
        if let expected, uuid?.lowercased() != expected.lowercased() {
            throw XlessError(stage, "the profile's UUID is \(uuid ?? "missing"), not \(expected) as App Store Connect says", fix: fix)
        }
    }
}
