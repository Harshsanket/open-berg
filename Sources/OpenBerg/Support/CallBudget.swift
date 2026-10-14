import Foundation

/// The free plan allows 100 calls per day and 5 per second, and failed calls
/// count too. This keeps a local tally so the UI can show what is left before
/// the quota is hit.
/// Not `Sendable`: it wraps `UserDefaults` and is only touched from the main
/// actor, where the model already lives.
struct CallBudget {
    static let dailyLimit = 100

    private enum Key {
        static let count = "budget.count"
        static let day = "budget.day"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func rollOverIfNeeded() {
        if defaults.string(forKey: Key.day) != Self.today {
            defaults.set(Self.today, forKey: Key.day)
            defaults.set(0, forKey: Key.count)
        }
    }

    /// Calls already spent today (UTC, matching the quota reset).
    var usedToday: Int {
        rollOverIfNeeded()
        return defaults.integer(forKey: Key.count)
    }

    var remainingToday: Int { max(0, Self.dailyLimit - usedToday) }

    func record() {
        rollOverIfNeeded()
        defaults.set(defaults.integer(forKey: Key.count) + 1, forKey: Key.count)
    }

    /// Rough cost of polling at `interval` seconds, shown next to the setting so
    /// the trade-off is visible before it is chosen.
    static func dailyCost(forInterval seconds: Int) -> Int {
        guard seconds > 0 else { return 0 }
        return Int((86_400.0 / Double(seconds)).rounded())
    }
}
