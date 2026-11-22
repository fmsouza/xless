/// The narrowest App Store Connect role an API key needs for a path, for the 403 fix of the account commands. Best effort,
/// from Apple's role descriptions (developer.apple.com/help/app-store-connect/reference/role-permissions): users and
/// provisioning need Admin, finance and sales reports their own roles, and the app's own resources App Manager.
public enum ASCRoles {
    static let byResource: [(prefix: String, role: String)] = [
        ("users", "Admin"), ("userInvitations", "Admin"),
        ("certificates", "Admin"), ("profiles", "Admin"), ("bundleIds", "Admin"), ("bundleIdCapabilities", "Admin"),
        ("devices", "Admin"), ("merchantIds", "Admin"), ("passTypeIds", "Admin"),
        ("financeReports", "Finance"), ("salesReports", "Sales"),
    ]

    public static func needed(path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return "App Manager" }
        let resource = String(parts[1])
        return byResource.first { $0.prefix == resource }?.role ?? "App Manager"
    }
}
