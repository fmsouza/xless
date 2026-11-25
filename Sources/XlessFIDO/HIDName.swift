import Foundation

/// What a device says it is called, which is printed beside the question for a PIN.
enum HIDName {
    static let longest = 64

    /// `said` without the spaces around it, cut to `longest` scalars; nil when it is empty, or holds anything that is not shown as
    /// itself (a control character, a change of direction, a line separator, a scalar that means nothing to the system).
    static func printable(_ said: String) -> String? {
        let trimmed = said.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        for scalar in trimmed.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: return nil
            case .spaceSeparator where scalar != " ": return nil
            default: continue
            }
        }
        guard !trimmed.isEmpty else { return nil }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(longest)))
    }
}
