import Foundation

/// App Store Connect's screenshot display types (the `screenshots/<type>/` directory names) and the pixel sizes each
/// accepts, portrait and landscape. Source: developer.apple.com/help/app-store-connect/reference/screenshot-specifications
/// (read 2026-11-23). Where Apple's page groups several sizes under one display, each type accepts every size of its group.
public enum ScreenshotDisplayType {
    typealias Size = (width: Int, height: Int)

    static let iphone69: [Size] = [(1260, 2736), (1290, 2796), (1320, 2868)]
    static let iphone65: [Size] = [(1284, 2778), (1242, 2688)]
    static let iphone61: [Size] = [(1179, 2556), (1206, 2622), (1170, 2532), (1125, 2436), (1080, 2340)]
    static let iphone55: [Size] = [(1242, 2208)]
    static let iphone47: [Size] = [(750, 1334)]
    static let iphone40: [Size] = [(640, 1096), (640, 1136), (600, 1136)]
    static let iphone35: [Size] = [(640, 920), (640, 960), (600, 960)]
    static let ipad13: [Size] = [(2064, 2752), (2048, 2732)]
    static let ipad129: [Size] = [(2048, 2732)]
    static let ipad11: [Size] = [(1488, 2266), (1512, 2316), (1668, 2420), (1668, 2388), (1640, 2360)]
    static let ipad105: [Size] = [(1668, 2224)]
    static let ipad97: [Size] = [(1536, 2008), (1536, 2048), (768, 1004), (768, 1024), (1496, 2048), (748, 1024)]

    /// Display type → sizes (each also accepted rotated).
    static let table: [String: [Size]] = {
        var t: [String: [Size]] = [
            "APP_IPHONE_67": iphone69, "APP_IPHONE_65": iphone65, "APP_IPHONE_61": iphone61, "APP_IPHONE_58": iphone61,
            "APP_IPHONE_55": iphone55, "APP_IPHONE_47": iphone47, "APP_IPHONE_40": iphone40, "APP_IPHONE_35": iphone35,
            "APP_IPAD_PRO_3GEN_129": ipad13, "APP_IPAD_PRO_129": ipad129, "APP_IPAD_PRO_3GEN_11": ipad11,
            "APP_IPAD_105": ipad105, "APP_IPAD_97": ipad97,
            "APP_DESKTOP": [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)],
            "APP_APPLE_TV": [(1920, 1080), (3840, 2160)],
            "APP_APPLE_VISION_PRO": [(3840, 2160)],
            "APP_WATCH_ULTRA": [(422, 514), (410, 502)],
            "APP_WATCH_SERIES_10": [(416, 496)],
            "APP_WATCH_SERIES_7": [(396, 484)],
            "APP_WATCH_SERIES_4": [(368, 448)],
            "APP_WATCH_SERIES_3": [(312, 390)],
        ]
        for (type, sizes) in t where type.hasPrefix("APP_IPHONE") || type.hasPrefix("APP_IPAD") {
            t["IMESSAGE_" + type] = sizes
        }
        return t
    }()

    /// Every display type xless knows.
    public static var known: [String] { table.keys.sorted() }

    public static func isKnown(_ type: String) -> Bool { table[type] != nil }

    /// Whether `type` takes a `width`×`height` screenshot; nil when xless does not know the type.
    public static func accepts(_ type: String, width: Int, height: Int) -> Bool? {
        guard let sizes = table[type] else { return nil }
        return sizes.contains { ($0.width == width && $0.height == height) || ($0.width == height && $0.height == width) }
    }

    /// The sizes `type` accepts, for an error message: `1320x2868, 2868x1320, …`.
    public static func sizes(_ type: String) -> [String] {
        (table[type] ?? []).flatMap { s in s.width == s.height ? ["\(s.width)x\(s.height)"] : ["\(s.width)x\(s.height)", "\(s.height)x\(s.width)"] }
    }

    /// A set the App Store needs for a first submission on `platform` (any one of them).
    public static func required(for platform: String?) -> [String] {
        switch platform {
        case "MAC_OS": ["APP_DESKTOP"]
        case "TV_OS": ["APP_APPLE_TV"]
        case "VISION_OS": ["APP_APPLE_VISION_PRO"]
        default: ["APP_IPHONE_67", "APP_IPHONE_65", "APP_IPAD_PRO_3GEN_129", "APP_IPAD_PRO_129"]
        }
    }

    /// Screenshot file extensions App Store Connect takes.
    public static let extensions: Set<String> = ["png", "jpg", "jpeg"]
    public static let maxPerSet = 10
}

/// App preview types (the `previews/<type>/` directory names).
public enum PreviewType {
    public static let known: Set<String> = [
        "IPHONE_67", "IPHONE_65", "IPHONE_61", "IPHONE_58", "IPHONE_55", "IPHONE_47", "IPHONE_40", "IPHONE_35",
        "IPAD_PRO_3GEN_129", "IPAD_PRO_3GEN_11", "IPAD_PRO_129", "IPAD_105", "IPAD_97", "DESKTOP", "APPLE_TV", "APPLE_VISION_PRO",
    ]
    public static let extensions: Set<String> = ["mov", "m4v", "mp4"]
    public static let maxPerSet = 3
    /// 500 MB (Apple's app preview specifications).
    public static let maxBytes = 500 * 1024 * 1024
}
