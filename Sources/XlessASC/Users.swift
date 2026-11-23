import Foundation
import XlessCore

// The team's App Store Connect users (`/v1/users`) and pending invitations (`/v1/userInvitations`), for `xless users`
// (docs/apple-account.md#xless-users). Every endpoint needs an API key with the Admin role. Internal TestFlight testers
// must be users of the team, which is why `invite` exists.

/// A user's role, as the App Store Connect API spells it.
public enum UserRole: String, Codable, Sendable, CaseIterable {
    case admin = "ADMIN"
    case finance = "FINANCE"
    case accountHolder = "ACCOUNT_HOLDER"
    case sales = "SALES"
    case marketing = "MARKETING"
    case appManager = "APP_MANAGER"
    case developer = "DEVELOPER"
    case accessToReports = "ACCESS_TO_REPORTS"
    case customerSupport = "CUSTOMER_SUPPORT"
    case createApps = "CREATE_APPS"
    case cloudManagedDeveloperID = "CLOUD_MANAGED_DEVELOPER_ID"
    case cloudManagedAppDistribution = "CLOUD_MANAGED_APP_DISTRIBUTION"
    case generateIndividualKeys = "GENERATE_INDIVIDUAL_KEYS"

    /// `app-manager`, `App Manager`, `APP_MANAGER`: any case, dashes or spaces for underscores.
    public init?(argument: String) {
        let text = argument.trimmingCharacters(in: .whitespaces).uppercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        self.init(rawValue: text)
    }

    /// The roles a command can give: every one but the Account Holder, which only Apple assigns.
    public static let assignable = allCases.filter { $0 != .accountHolder }

    /// `--role` values, each repeatable and comma-separated, in the order given, without repeats. Unknown roles, and
    /// the Account Holder unless `allowAccountHolder` (a filter), are refused.
    public static func parse(_ texts: [String], allowAccountHolder: Bool = false) throws -> [UserRole] {
        var roles: [UserRole] = []
        for text in texts.flatMap({ $0.split(separator: ",").map(String.init) }) {
            guard let role = UserRole(argument: text) else {
                throw IdentifierInputError("--role \(text.trimmingCharacters(in: .whitespaces)) is not an App Store Connect role: use \((allowAccountHolder ? allCases : assignable).map(\.rawValue).joined(separator: ", "))")
            }
            if role == .accountHolder, !allowAccountHolder {
                throw IdentifierInputError("--role ACCOUNT_HOLDER cannot be given: Apple assigns it to the person who enrolled, and only a transfer on developer.apple.com moves it")
            }
            if !roles.contains(role) { roles.append(role) }
        }
        return roles
    }

    /// `ADMIN, DEVELOPER`; `-` for none.
    public static func display(_ roles: [String]) -> String { roles.isEmpty ? "-" : roles.joined(separator: ", ") }
}

/// An email address, as App Store Connect names users (their Apple ID) and invitations. Checked loosely before anything
/// is sent; Apple decides the rest. Compared without regard to case.
public enum UserEmail {
    public static func validate(_ raw: String) throws -> String {
        let email = raw.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        let domain = parts.count == 2 ? parts[1] : ""
        guard parts.count == 2, !parts[0].isEmpty, email.count <= 254,
              domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              email.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) && $0 != "/" }) else {
            throw IdentifierInputError("\(email.isEmpty ? "an empty email address" : email) is not an email address (name@example.com)")
        }
        return email
    }

    public static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

    /// Whether a command's argument names someone by email (rather than by ID).
    public static func isEmail(_ text: String) -> Bool { text.contains("@") }
}

/// The attributes users and invitations share.
public protocol ASCPersonAttributes: ASCAttributes {
    /// A user's Apple ID (`username`), an invitation's `email`.
    var address: String? { get }
    var firstName: String? { get }
    var lastName: String? { get }
    var roles: [String]? { get }
    var allAppsVisible: Bool? { get }
    var provisioningAllowed: Bool? { get }
}

public struct ASCUserAttributes: ASCPersonAttributes, Equatable {
    public var username: String?
    public var firstName: String?
    public var lastName: String?
    public var roles: [String]?
    public var allAppsVisible: Bool?
    public var provisioningAllowed: Bool?
    public init() {}
    public var address: String? { username }
}

public struct ASCUserInvitationAttributes: ASCPersonAttributes, Equatable {
    public var email: String?
    public var firstName: String?
    public var lastName: String?
    public var expirationDate: String?
    public var roles: [String]?
    public var allAppsVisible: Bool?
    public var provisioningAllowed: Bool?
    public init() {}
    public var address: String? { email }
}

/// A user of the team: App Store Connect's resource as received, and its attributes, typed.
public typealias ASCUser = ASCKeptResource<ASCUserAttributes>
/// A pending invitation.
public typealias ASCUserInvitation = ASCKeptResource<ASCUserInvitationAttributes>

extension ASCAnyResource {
    /// The IDs a to-many relationship's linkage points at, when the answer carried the linkage.
    public func relatedIDs(_ name: String) -> [String]? {
        guard case .array(let items)? = relationships?[name]?["data"] else { return nil }
        return items.compactMap { $0["id"]?.string }
    }
}

extension ASCKeptResource where A: ASCPersonAttributes {
    public var email: String { attributes.address ?? "" }
    public var fullName: String { [attributes.firstName, attributes.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
    public var roles: [String] { attributes.roles ?? [] }
    public var allAppsVisible: Bool { attributes.allAppsVisible ?? false }
    public var provisioningAllowed: Bool { attributes.provisioningAllowed ?? false }
    /// The IDs of the apps the person sees, when the answer carried the linkage (at most 50 per person in a listing).
    public var visibleAppIDs: [String]? { resource.relatedIDs("visibleApps") }
    public var isAccountHolder: Bool { roles.contains(UserRole.accountHolder.rawValue) }
}

/// An invitation to send: who, with which roles, which apps and whether they may manage certificates, identifiers and
/// profiles.
public struct UserInvitationRequest: Sendable, Equatable {
    public var email: String
    public var firstName: String
    public var lastName: String
    public var roles: [UserRole]
    /// True: every app, present and future. False: only `appIDs`.
    public var allAppsVisible: Bool
    public var appIDs: [String]
    public var provisioningAllowed: Bool

    public init(email: String, firstName: String, lastName: String, roles: [UserRole], allAppsVisible: Bool, appIDs: [String] = [],
                provisioningAllowed: Bool = false) {
        self.email = email; self.firstName = firstName; self.lastName = lastName; self.roles = roles
        self.allAppsVisible = allAppsVisible; self.appIDs = appIDs; self.provisioningAllowed = provisioningAllowed
    }
}

/// The user and invitation operations, on the App Store Connect API key (Admin role).
public struct ASCUsers: Sendable {
    public static let usersPath = "/v1/users"
    public static let invitationsPath = "/v1/userInvitations"
    /// The most apps a listing includes per person (Apple's maximum for `limit[visibleApps]`).
    public static let includedAppsLimit = 50
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    public enum Invitation: Sendable {
        case invited(ASCUserInvitation)
        /// The address is already a user of the team: nothing was sent.
        case existingUser(ASCUser)
        /// The address already has a pending invitation: nothing was sent.
        case existingInvitation(ASCUserInvitation)
    }

    /// App Store Connect's user and invitation IDs: letters, digits and dashes (UUIDs).
    public static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    static func listQuery(roles: [UserRole]) -> ASCQuery {
        ASCQuery(filters: roles.isEmpty ? [] : [("roles", roles.map(\.rawValue).joined(separator: ","))],
                 fields: [("apps", ["bundleId", "name"])], include: ["visibleApps"],
                 extra: [("limit[visibleApps]", String(includedAppsLimit))])
    }

    // MARK: Users

    /// Every user (every page) with the apps each sees (`included`), optionally only those with one of `roles`;
    /// sorted by email, then ID.
    public func list(roles: [UserRole] = []) async throws -> ASCListing<ASCUser> {
        var listing = try await resources.list(Self.usersPath, query: Self.listQuery(roles: roles), as: ASCUser.self)
        listing.items.sort { ($0.email.lowercased(), $0.id) < ($1.email.lowercased(), $1.id) }
        return listing
    }

    public func get(id: String) async throws -> ASCUser {
        guard Self.isID(id) else { throw XlessError(.account, "\(id) is not a user ID", fix: "use an email address or an ID from `xless users list`") }
        return try await resources.get("\(Self.usersPath)/\(id)", as: ASCUser.self).data
    }

    /// The user with this email address (Apple ID), compared without regard to case.
    public func find(email: String) async throws -> ASCUser? {
        try await list().items.first { UserEmail.same($0.email, email) }
    }

    /// The user a command names: an email address, else a user ID. An address that only has a pending invitation is an
    /// error saying so.
    public func resolve(_ text: String) async throws -> ASCUser {
        guard UserEmail.isEmail(text) else { return try await get(id: text) }
        if let user = try await find(email: text) { return user }
        if let invitation = try await findInvitation(email: text) {
            throw XlessError(.account, "\(text) has not accepted the invitation yet (invitation \(invitation.id)), so it is not a user of this team",
                             fix: "see it with `xless users invitations list`; cancel it with `xless users invitations cancel \(text)`")
        }
        throw XlessError(.account, "no user of this team has the email address \(text)",
                         fix: "check `xless users list` (and --team), or invite them with `xless users invite \(text) --first-name <name> --last-name <name> --role <role> --all-apps`")
    }

    /// Every app the user (or invitation, with `invitationsPath`) sees, when it does not see all of them.
    public func visibleApps(of id: String, in path: String = usersPath) async throws -> [ASCApp] {
        try await resources.list("\(path)/\(id)/visibleApps", query: ASCQuery(fields: [("apps", ["bundleId", "name"])]), as: ASCApp.self).items
    }

    /// Changes what differs from the user's current settings in one PATCH; nil when nothing differs and nothing was sent.
    /// - Parameters:
    ///   - roles: the complete new set of roles, or nil to keep them.
    ///   - allApps: true to show every app; ignored when `appIDs` is given.
    ///   - appIDs: the apps the user sees from now on (and no others), or nil to keep them.
    ///   - currentAppIDs: the apps the user sees now, when they do not see all of them (read when needed and not given).
    public func update(_ user: ASCUser, roles: [UserRole]? = nil, allApps: Bool = false, appIDs: [String]? = nil,
                       provisioning: Bool? = nil, currentAppIDs: [String]? = nil) async throws -> ASCUser? {
        struct Attributes: Encodable, Sendable { var roles: [String]?; var allAppsVisible: Bool?; var provisioningAllowed: Bool? }
        struct Relationships: Encodable, Sendable { var visibleApps: ASCToMany }
        struct Inner: Encodable, Sendable { var type = "users"; var id: String; var attributes: Attributes; var relationships: Relationships? }
        struct Body: Encodable, Sendable { var data: Inner }

        var attributes = Attributes()
        var relationships: Relationships?
        if let roles, Set(roles.map(\.rawValue)) != Set(user.roles) { attributes.roles = roles.map(\.rawValue) }
        if let appIDs {
            if user.allAppsVisible { attributes.allAppsVisible = false }
            var current = currentAppIDs ?? []
            if !user.allAppsVisible, currentAppIDs == nil {
                current = try await resources.relationship("\(Self.usersPath)/\(user.id)", "visibleApps").map(\.id)
            }
            if user.allAppsVisible || Set(current) != Set(appIDs) {
                relationships = Relationships(visibleApps: ASCToMany(appIDs.map { ASCRef(type: "apps", id: $0) }))
            }
        } else if allApps, !user.allAppsVisible {
            attributes.allAppsVisible = true
        }
        if let provisioning, provisioning != user.provisioningAllowed { attributes.provisioningAllowed = provisioning }
        guard attributes.roles != nil || attributes.allAppsVisible != nil || attributes.provisioningAllowed != nil || relationships != nil else { return nil }
        let updated: ASCSingle<ASCUser> = try await resources.client.patch(
            "\(Self.usersPath)/\(user.id)", body: Body(data: Inner(id: user.id, attributes: attributes, relationships: relationships)))
        return updated.data
    }

    /// Removes the user from the team (DELETE /v1/users/{id}).
    public func remove(_ user: ASCUser) async throws {
        try await resources.delete("\(Self.usersPath)/\(user.id)")
    }

    // MARK: Invitations

    /// Every pending invitation (every page), optionally only those with one of `roles`; sorted by email, then ID.
    public func invitations(roles: [UserRole] = []) async throws -> ASCListing<ASCUserInvitation> {
        var listing = try await resources.list(Self.invitationsPath, query: Self.listQuery(roles: roles), as: ASCUserInvitation.self)
        listing.items.sort { ($0.email.lowercased(), $0.id) < ($1.email.lowercased(), $1.id) }
        return listing
    }

    public func invitation(id: String) async throws -> ASCUserInvitation {
        guard Self.isID(id) else {
            throw XlessError(.account, "\(id) is not an invitation ID", fix: "use an email address or an ID from `xless users invitations list`")
        }
        return try await resources.get("\(Self.invitationsPath)/\(id)", as: ASCUserInvitation.self).data
    }

    public func findInvitation(email: String) async throws -> ASCUserInvitation? {
        try await invitations().items.first { UserEmail.same($0.email, email) }
    }

    /// The invitation a command names: an email address, else an invitation ID. An address that is already a user is an
    /// error saying so.
    public func resolveInvitation(_ text: String) async throws -> ASCUserInvitation {
        guard UserEmail.isEmail(text) else { return try await invitation(id: text) }
        if let invitation = try await findInvitation(email: text) { return invitation }
        if let user = try await find(email: text) {
            throw XlessError(.account, "\(text) has no pending invitation: it is already a user of this team (user \(user.id))",
                             fix: "remove the user with `xless users remove \(text)` if that is what you meant")
        }
        throw XlessError(.account, "no pending invitation for \(text) on this team", fix: "check `xless users invitations list` (and --team)")
    }

    /// Invites someone, unless the address is already a user of the team or already invited: then that one is returned and
    /// nothing is sent. The POST is sent once; when Apple refuses it as a conflict and the address now shows up as a
    /// user or an invitation, that one is returned.
    public func invite(_ request: UserInvitationRequest) async throws -> Invitation {
        if let user = try await find(email: request.email) { return .existingUser(user) }
        if let invitation = try await findInvitation(email: request.email) { return .existingInvitation(invitation) }
        struct Attributes: Encodable, Sendable {
            var email: String; var firstName: String; var lastName: String; var roles: [String]; var allAppsVisible: Bool; var provisioningAllowed: Bool
        }
        struct Relationships: Encodable, Sendable { var visibleApps: ASCToMany }
        let attributes = Attributes(email: request.email, firstName: request.firstName, lastName: request.lastName,
                                    roles: request.roles.map(\.rawValue), allAppsVisible: request.allAppsVisible,
                                    provisioningAllowed: request.provisioningAllowed)
        let relationships = request.allAppsVisible || request.appIDs.isEmpty ? nil
            : Relationships(visibleApps: ASCToMany(request.appIDs.map { ASCRef(type: "apps", id: $0) }))
        do {
            let created: ASCSingle<ASCUserInvitation> = try await resources.create(Self.invitationsPath, type: "userInvitations",
                                                                                   attributes: attributes, relationships: relationships)
            return .invited(created.data)
        } catch let e as ASCError where e.status == 409 {
            if let user = try await find(email: request.email) { return .existingUser(user) }
            if let invitation = try await findInvitation(email: request.email) { return .existingInvitation(invitation) }
            throw e
        }
    }

    /// Cancels a pending invitation (DELETE /v1/userInvitations/{id}): the link Apple emailed stops working.
    public func cancel(_ invitation: ASCUserInvitation) async throws {
        try await resources.delete("\(Self.invitationsPath)/\(invitation.id)")
    }
}
