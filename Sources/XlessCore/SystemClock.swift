import CXlessProcess

/// The system's own clock: it counts while the system sleeps and nobody sets it.
public enum SystemClock {
    /// Whole seconds since some moment before the system started.
    public static var seconds: Int { Int(xless_clock_continuous_ms() / 1000) }
}
