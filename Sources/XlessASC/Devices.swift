import Foundation
import XlessCore

// Registered devices (`/v1/devices`), for `xless devices` (docs/apple-account.md#xless-devices). Apple lets a team
// list, register (POST), rename and enable or disable (PATCH) devices; there is no DELETE.

/// A device platform as the App Store Connect API spells it (`IOS` also covers iPadOS, tvOS, watchOS and visionOS).
public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case ios = "IOS"
    case macOS = "MAC_OS"

    /// `ios`, `macos` or `mac` (Apple's device file says `mac`), in any case.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "ios": self = .ios
        case "macos", "mac": self = .macOS
        default: return nil
        }
    }

    /// How the command line names it.
    public var argument: String { self == .ios ? "ios" : "macos" }

    /// The command-line name of an API value (`IOS` → `ios`); other values (`UNIVERSAL`) as they are.
    public static func display(_ value: String?) -> String {
        guard let value else { return "" }
        return DevicePlatform(rawValue: value)?.argument ?? value
    }
}

public enum DeviceStatus: String, Codable, Sendable, CaseIterable {
    case enabled = "ENABLED"
    case disabled = "DISABLED"

    public init?(argument: String) { self.init(rawValue: argument.uppercased()) }
    public var argument: String { rawValue.lowercased() }
}

/// What was wrong with a UDID or a device file; never sent to Apple. One message per problem.
public struct DeviceInputError: Error, CustomStringConvertible, Sendable, Equatable {
    public var messages: [String]
    public init(_ messages: [String]) { self.messages = messages }
    public var description: String { messages.joined(separator: "\n") }
}

/// The shapes of a device identifier, checked before anything is sent to Apple.
public enum DeviceUDID {
    public enum Kind: Sendable, Equatable {
        /// 40 hex digits: iPhones and iPads before the iPhone XS.
        case legacy40
        /// 8 and 16 hex digits joined by a dash (`00008030-001A35E80C42802E`): newer iPhones, iPads and Apple-silicon Macs.
        case modern25
        /// A Mac's hardware UUID (8-4-4-4-12 hex digits).
        case macUUID
    }

    public static func kind(_ udid: String) -> Kind? {
        func hex(_ s: Substring) -> Bool { s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) } }
        let parts = udid.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.allSatisfy(hex) else { return nil }
        switch parts.map(\.count) {
        case [40]: return .legacy40
        case [8, 16]: return .modern25
        case [8, 4, 4, 4, 12]: return .macUUID
        default: return nil
        }
    }

    /// The UDID (trimmed) and its platform: `platform` when given and consistent with the UDID's shape, else the one the
    /// shape implies (a hardware UUID is a Mac's; 40 hex digits an iOS device's; the 8-16 form is taken as iOS, since
    /// Apple-silicon Macs, which share it, are registered with `--platform macos`).
    public static func validate(_ raw: String, platform: DevicePlatform?) throws -> (udid: String, platform: DevicePlatform) {
        let udid = raw.trimmingCharacters(in: .whitespaces)
        guard let kind = kind(udid) else {
            throw DeviceInputError(["\(udid.isEmpty ? "an empty UDID" : udid) is not a device UDID: an iPhone or iPad has 40 hex digits, or 8 and 16 hex digits joined by a dash (00008030-001A35E80C42802E); a Mac its hardware UUID (8-4-4-4-12 hex digits) or, on Apple silicon, the 8-16 form"])
        }
        switch (kind, platform) {
        case (.macUUID, .ios?):
            throw DeviceInputError(["\(udid) is a Mac hardware UUID, not an iOS device's UDID: register it with platform macos"])
        case (.legacy40, .macOS?):
            throw DeviceInputError(["\(udid) is an iOS device's UDID (40 hex digits), not a Mac's: register it with platform ios"])
        case (_, let p?): return (udid, p)
        case (.macUUID, nil): return (udid, .macOS)
        case (_, nil): return (udid, .ios)
        }
    }
}

/// One device of a device file.
public struct DeviceFileEntry: Sendable, Equatable {
    public var line: Int
    public var udid: String
    public var name: String
    public var platform: DevicePlatform
}

/// Apple's device file, as the developer portal imports and exports it: tab-separated `Device ID`, `Device Name` and an
/// optional `Device Platform` (`ios` or `mac`), with an optional header line. Blank lines and `#` comments are skipped;
/// a byte order mark and CRLF line ends are accepted.
public enum DeviceFile {
    /// Every device of the file; every bad line (and every UDID that appears twice) is reported at once.
    public static func parse(_ text: String) throws -> [DeviceFileEntry] {
        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }
        var entries: [DeviceFileEntry] = []
        var problems: [String] = []
        var seen: [String: Int] = [:]
        var first = true
        for (index, raw) in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let number = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            defer { first = false }
            if first, columns[0].lowercased() == "device id" { continue }
            guard columns.count >= 2, !columns[1].isEmpty, columns.dropFirst(3).allSatisfy(\.isEmpty) else {
                problems.append("line \(number): expected <UDID><tab><name>[<tab><platform>], separated by tabs")
                continue
            }
            var platform: DevicePlatform?
            if columns.count > 2, !columns[2].isEmpty {
                guard let p = DevicePlatform(argument: columns[2]) else {
                    problems.append("line \(number): unknown platform \"\(columns[2])\" (ios or mac)")
                    continue
                }
                platform = p
            }
            do {
                let (udid, p) = try DeviceUDID.validate(columns[0], platform: platform)
                if let earlier = seen[udid.lowercased()] {
                    problems.append("line \(number): \(udid) is already on line \(earlier)")
                    continue
                }
                seen[udid.lowercased()] = number
                entries.append(DeviceFileEntry(line: number, udid: udid, name: columns[1], platform: p))
            } catch let e as DeviceInputError {
                problems += e.messages.map { "line \(number): \($0)" }
            }
        }
        if !problems.isEmpty { throw DeviceInputError(problems) }
        if entries.isEmpty { throw DeviceInputError(["the file lists no device"]) }
        return entries
    }
}

/// A device's attributes, as far as xless reads them.
public struct ASCDeviceAttributes: Codable, Sendable, Equatable {
    public var name: String?
    public var platform: String?
    public var udid: String?
    public var deviceClass: String?
    public var model: String?
    public var status: String?
    public var addedDate: String?

    public init(name: String? = nil, platform: String? = nil, udid: String? = nil, deviceClass: String? = nil,
                model: String? = nil, status: String? = nil, addedDate: String? = nil) {
        self.name = name; self.platform = platform; self.udid = udid; self.deviceClass = deviceClass
        self.model = model; self.status = status; self.addedDate = addedDate
    }
}

/// A registered device: App Store Connect's resource as received (what `--json` prints, so fields Apple adds survive)
/// and its attributes, typed.
public struct ASCDevice: Codable, Sendable {
    public var resource: ASCAnyResource
    public var attributes: ASCDeviceAttributes

    public init(resource: ASCAnyResource) {
        self.resource = resource
        let json = (try? JSONEncoder().encode(resource.attributes ?? [:])) ?? Data("{}".utf8)
        attributes = (try? JSONDecoder().decode(ASCDeviceAttributes.self, from: json)) ?? ASCDeviceAttributes()
    }

    public init(from decoder: Decoder) throws { self.init(resource: try ASCAnyResource(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try resource.encode(to: encoder) }

    public var id: String { resource.id }
    public var name: String { attributes.name ?? "" }
    public var udid: String { attributes.udid ?? "" }
    public var status: DeviceStatus? { attributes.status.flatMap(DeviceStatus.init(rawValue:)) }
}

/// The device operations, on the App Store Connect API key.
public struct ASCDevices: Sendable {
    public static let path = "/v1/devices"
    public let resources: ASCResources

    public init(resources: ASCResources) { self.resources = resources }

    public enum Registration: Sendable {
        case registered(ASCDevice)
        /// The UDID was already registered: nothing was created.
        case existing(ASCDevice)

        public var device: ASCDevice {
            switch self { case .registered(let d), .existing(let d): return d }
        }
    }

    /// Every registered device (every page), filtered by platform and status, sorted by name then ID.
    public func list(platform: DevicePlatform? = nil, status: DeviceStatus? = nil) async throws -> [ASCDevice] {
        var filters: [(String, String)] = []
        if let platform { filters.append(("platform", platform.rawValue)) }
        if let status { filters.append(("status", status.rawValue)) }
        let listing = try await resources.list(Self.path, query: ASCQuery(filters: filters), as: ASCDevice.self)
        return listing.items.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    public func get(id: String) async throws -> ASCDevice {
        guard Self.isDeviceID(id) else { throw XlessError(.account, "\(id) is not a device ID", fix: "use an ID or a UDID from `xless devices list`") }
        let single: ASCSingle<ASCDevice> = try await resources.get("\(Self.path)/\(id)", as: ASCDevice.self)
        return single.data
    }

    /// App Store Connect's resource IDs are letters and digits.
    public static func isDeviceID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    /// The device with this UDID, compared without regard to case.
    public static func find(udid: String, in devices: [ASCDevice]) -> ASCDevice? {
        devices.first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
    }

    /// The device a command names: a UDID (looked up in the listing), else a device ID.
    public func resolve(_ text: String) async throws -> ASCDevice {
        guard DeviceUDID.kind(text) != nil else { return try await get(id: text) }
        guard let device = Self.find(udid: text, in: try await list()) else {
            throw XlessError(.account, "no device with UDID \(text) is registered on this team",
                             fix: "check the UDID with `xless devices list`, or register it with `xless devices register <name> \(text)`")
        }
        return device
    }

    /// Registers a device, unless its UDID already is (in `existing`, the team's devices, or as App Store Connect says
    /// when it refuses a duplicate): then that device is returned and nothing is created. The POST is sent once.
    public func register(name: String, udid: String, platform: DevicePlatform, existing: [ASCDevice]) async throws -> Registration {
        if let device = Self.find(udid: udid, in: existing) { return .existing(device) }
        struct Attributes: Encodable, Sendable { var name: String; var udid: String; var platform: String }
        do {
            let created: ASCSingle<ASCDevice> = try await resources.create(Self.path, type: "devices",
                                                                          attributes: Attributes(name: name, udid: udid, platform: platform.rawValue))
            return .registered(created.data)
        } catch let e as ASCError where e.status == 409 && DeviceLimit.isLimitError(e) {
            throw DeviceLimit.error(from: e)
        } catch let e as ASCError where e.status == 409 && Self.text(of: e).contains("already exist") {
            if let device = Self.find(udid: udid, in: try await list()) { return .existing(device) }
            throw e
        }
    }

    /// Renames the device and/or sets its status (PATCH); returns it as App Store Connect now has it.
    public func update(_ device: ASCDevice, name: String? = nil, status: DeviceStatus? = nil) async throws -> ASCDevice {
        struct Attributes: Encodable, Sendable { var name: String?; var status: String? }
        do {
            let updated: ASCSingle<ASCDevice> = try await resources.update("\(Self.path)/\(device.id)", type: "devices", id: device.id,
                                                                          attributes: Attributes(name: name, status: status?.rawValue))
            return updated.data
        } catch let e as ASCError where e.status == 409 && DeviceLimit.isLimitError(e) {
            throw DeviceLimit.error(from: e)
        }
    }

    static func text(of error: ASCError) -> String {
        error.items.map { [$0.code, $0.title, $0.detail].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ").lowercased()
    }
}

/// Apple's yearly device limit: 100 devices of each product family per membership year. Disabled devices keep their
/// slot until the membership renews, when the Account Holder can remove devices and reset the count.
public enum DeviceLimit {
    public static let perFamily = 100
    /// A family with this many devices registered gets a warning.
    public static let warnAt = 90

    static let families: [(deviceClass: String, name: String)] = [
        ("IPHONE", "iPhone"), ("IPAD", "iPad"), ("IPOD", "iPod touch"), ("APPLE_WATCH", "Apple Watch"),
        ("APPLE_TV", "Apple TV"), ("APPLE_VISION_PRO", "Apple Vision Pro"), ("MAC", "Mac"),
    ]

    public static let resetRule = "Apple allows \(perFamily) devices of each kind (iPhone, iPad, iPod touch, Apple Watch, Apple TV, Apple Vision Pro, Mac) per membership year, and a disabled device keeps its slot; when the membership renews, the Account Holder can remove devices at https://developer.apple.com/account/resources/devices/list to reset the count"

    /// The devices of each family (enabled and disabled alike: both use a slot), in the order of `families`; families
    /// with none are left out.
    public static func counts(_ devices: [ASCDevice]) -> [(family: String, count: Int)] {
        families.compactMap { family in
            let n = devices.filter { $0.attributes.deviceClass == family.deviceClass }.count
            return n == 0 ? nil : (family.name, n)
        }
    }

    /// One warning per family at or over `warnAt`.
    public static func warnings(_ devices: [ASCDevice]) -> [String] {
        counts(devices).filter { $0.count >= warnAt }.map { family in
            let left = max(perFamily - family.count, 0)
            return "warning: \(family.count) \(family.family) devices are registered this membership year; \(left) of Apple's \(perFamily) left (disabled devices still count until the list is reset when the membership renews)"
        }
    }

    /// Whether Apple refused the request because a family's limit is reached.
    public static func isLimitError(_ error: ASCError) -> Bool {
        let text = ASCDevices.text(of: error)
        return text.contains("device") && (text.contains("limit") || text.contains("maximum number"))
    }

    public static func error(from error: ASCError) -> XlessError {
        let request = [error.method, error.path].compactMap { $0 }.joined(separator: " ")
        return XlessError(.account, (request.isEmpty ? "" : "\(request): ") + "the device limit is reached — \(error.description)", fix: resetRule)
    }
}

/// `xless devices import`: what a device file adds, and the registration of the new ones.
public struct DeviceImport: Sendable {
    public struct Report: Encodable, Sendable {
        public var registered: [ASCDevice] = []
        /// Devices of the file that were already registered (as App Store Connect has them).
        public var existing: [ASCDevice] = []
        public init() {}
    }

    /// The file's devices split into those to register and those already registered.
    public static func plan(_ entries: [DeviceFileEntry], existing: [ASCDevice]) -> (new: [DeviceFileEntry], existing: [ASCDevice]) {
        var new: [DeviceFileEntry] = []
        var known: [ASCDevice] = []
        for entry in entries {
            if let device = ASCDevices.find(udid: entry.udid, in: existing) { known.append(device) } else { new.append(entry) }
        }
        return (new, known)
    }

    /// Registers `entries` one by one. A failure stops the import and says which devices were registered before it.
    public static func run(_ entries: [DeviceFileEntry], existing: [ASCDevice], devices: ASCDevices,
                           registered: (ASCDevice) -> Void = { _ in }) async throws -> Report {
        var report = Report()
        let (new, known) = plan(entries, existing: existing)
        report.existing = known
        for entry in new {
            do {
                switch try await devices.register(name: entry.name, udid: entry.udid, platform: entry.platform, existing: existing) {
                case .registered(let d): report.registered.append(d); registered(d)
                case .existing(let d): report.existing.append(d)
                }
            } catch {
                let e = XlessError.wrapping(error, stage: .account)
                let done = report.registered.isEmpty ? "none of the file's new devices was registered"
                    : "\(report.registered.count) of \(new.count) new devices were registered before it (\(report.registered.map(\.name).joined(separator: ", ")))"
                throw XlessError(.account, "registering \(entry.name) (\(entry.udid), line \(entry.line)) failed: \(e.cause); \(done)",
                                 fix: "\(e.fix); then re-run the import: devices already registered are skipped")
            }
        }
        return report
    }
}
