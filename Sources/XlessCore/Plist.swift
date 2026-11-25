import Foundation

public enum Plist {
    public static func read(_ url: URL, stage: Stage) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XlessError(stage, "cannot read \(url.path)", fix: "check the previous stage produced it")
        }
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw XlessError(stage, "\(url.path) is not a dictionary plist", fix: "check the file contents")
        }
        return dict
    }

    public static func write(_ dict: [String: Any], to url: URL,
                             format: PropertyListSerialization.PropertyListFormat = .binary, stage: Stage) throws {
        do { try data(dict, format: format, named: url.path, stage: stage).write(to: url) } catch let e as XlessError { throw e } catch {
            throw cannotWrite(url.path, error, stage)
        }
    }

    /// `dict` as a property list, to be written to the file `name`, which only the error says.
    public static func data(_ dict: [String: Any], format: PropertyListSerialization.PropertyListFormat, named name: String, stage: Stage) throws -> Data {
        do { return try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0) } catch { throw cannotWrite(name, error, stage) }
    }

    private static func cannotWrite(_ name: String, _ error: any Error, _ stage: Stage) -> XlessError {
        XlessError(stage, "cannot write plist \(name): \(error)", fix: "check disk space and permissions")
    }
}
