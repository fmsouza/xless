/// Names of environment variables. Windows has one variable for `PATH`, `Path` and `path`; the other systems have three.
public enum EnvironmentNames {
    #if os(Windows)
    public static let ignoreCase = true
    #else
    public static let ignoreCase = false
    #endif

    /// What two names of one variable have in common. Only ASCII letters are folded: no name that matters here has others.
    static func folded(_ name: String, ignoreCase: Bool = ignoreCase) -> String {
        guard ignoreCase else { return name }
        return String(String.UnicodeScalarView(name.unicodeScalars.map { ("a"..."z").contains($0) ? Unicode.Scalar($0.value - 32)! : $0 }))
    }
}

extension [String: String] {
    /// The value of the variable `name`, whichever case it has here on a system that takes no notice of it.
    public func variable(_ name: String) -> String? { variable(name, ignoreCase: EnvironmentNames.ignoreCase) }

    func variable(_ name: String, ignoreCase: Bool) -> String? {
        if let value = self[name] { return value }
        guard ignoreCase else { return nil }
        let wanted = EnvironmentNames.folded(name, ignoreCase: true)
        // Sorted: should a process have two of them all the same, it is always the same one.
        return filter { EnvironmentNames.folded($0.key, ignoreCase: true) == wanted }.min { $0.key < $1.key }?.value
    }
}
