public enum Platform: String, Sendable, CaseIterable, Codable {
    case ios, macos

    /// `iOS`, `macOS`.
    public var display: String { self == .ios ? "iOS" : "macOS" }
    /// Key used in toolchain-meta.json and DTPlatformName.
    public var sdkKey: String { self == .ios ? "iphoneos" : "macosx" }
    /// CFBundleSupportedPlatforms value.
    public var supportedPlatformName: String { self == .ios ? "iPhoneOS" : "MacOSX" }
    /// LC_BUILD_VERSION platform (PLATFORM_MACOS = 1, PLATFORM_IOS = 2).
    public var machOPlatform: UInt32 { self == .ios ? 2 : 1 }
    /// App Store Connect platform enum.
    public var ascPlatform: String { self == .ios ? "IOS" : "MAC_OS" }
}

public enum Distribution: String, Sendable, Codable {
    case appStore = "app-store"
    case developerID = "developer-id"
}
