import Foundation

/// The free plan allows 100 calls per day and 5 per second, and failed calls
/// count too. This keeps a local tally so the UI can show what is left before
/// the quota is hit.
///
/// Incremented from the URLSession layer (which runs off the main actor) and
/// read by the UI on the main actor, so every access is serialised behind one
/// lock — a read-modify-write that races would silently under-count a quota
/// that cannot be overspent safely.
final class CallBudget: @unchecked Sendable {
    static let dailyLimit = 100

    private enum Key {
        static let count = "budget.count"
        static let day = "budget.day"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static var today: String {
        dayFormatter.string(from: Date())
    }

    /// Built once: `today` is checked on every tally read and write, and a
    /// fresh DateFormatter per call (it configures locale, time zone and a
    /// format) is needless work at that frequency.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Callers must hold `lock`.
    private func rollOverIfNeededLocked() {
        if defaults.string(forKey: Key.day) != Self.today {
            defaults.set(Self.today, forKey: Key.day)
            defaults.set(0, forKey: Key.count)
        }
    }

    /// Calls already spent today (UTC, matching the quota reset).
    var usedToday: Int {
        lock.lock()
        defer { lock.unlock() }
        rollOverIfNeededLocked()
        return defaults.integer(forKey: Key.count)
    }

    /// One attempt actually put on the wire: retries and transport failures
    /// count, exactly like the server counts them.
    func record() {
        lock.lock()
        defer { lock.unlock() }
        rollOverIfNeededLocked()
        defaults.set(defaults.integer(forKey: Key.count) + 1, forKey: Key.count)
    }
}
