import Foundation

/// A downloaded .xip's SHA-256, recorded next to it as `<name>.sha256` (sha256sum's format, so `sha256sum -c` checks it)
/// so that a re-run that keeps the file does not read gigabytes again. The record is trusted only while it is at least as
/// new as the .xip.
public enum XipDigest {
    public static func sha256(of xip: URL, compute: (URL) throws -> String) throws -> String {
        let record = xip.appendingPathExtension("sha256")
        if let sum = recorded(record, for: xip) { return sum }
        let sum = try compute(xip)
        try? Data("\(sum)  \(xip.lastPathComponent)\n".utf8).write(to: record, options: .atomic)
        return sum
    }

    private static func recorded(_ record: URL, for xip: URL) -> String? {
        let fm = FileManager.default
        guard let recordDate = (try? fm.attributesOfItem(atPath: record.path))?[.modificationDate] as? Date,
              let xipDate = (try? fm.attributesOfItem(atPath: xip.path))?[.modificationDate] as? Date,
              recordDate >= xipDate,
              let text = try? String(contentsOf: record, encoding: .utf8),
              let sum = text.split(separator: " ").first.map(String.init),
              sum.count == 64, sum.allSatisfy(\.isHexDigit) else { return nil }
        return sum.lowercased()
    }
}
