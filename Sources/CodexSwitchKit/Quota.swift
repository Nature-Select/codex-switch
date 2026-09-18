import Foundation

/// Codex reports quota as one or more rolling windows. Which windows exist
/// depends on the plan, so windows are kept as a list and looked up by length
/// rather than by position.
public struct QuotaWindow: Codable, Equatable {
    public var usedPercent: Int
    public var durationMinutes: Int?
    public var resetsAt: Date?

    public init(usedPercent: Int, durationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct QuotaCredits: Codable, Equatable {
    public var balance: String?
    public var hasCredits: Bool
    public var unlimited: Bool

    public init(balance: String?, hasCredits: Bool, unlimited: Bool) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }
}

public struct QuotaReport: Codable, Equatable {
    public var windows: [QuotaWindow]
    public var credits: QuotaCredits?
    public var plan: String?

    public init(windows: [QuotaWindow], credits: QuotaCredits? = nil, plan: String? = nil) {
        self.windows = windows
        self.credits = credits
        self.plan = plan
    }

    public static let fiveHourMinutes = 300
    public static let weeklyMinutes = 10_080

    public func window(ofMinutes minutes: Int) -> QuotaWindow? {
        windows.first { $0.durationMinutes == minutes }
    }

    public var fiveHour: QuotaWindow? { window(ofMinutes: Self.fiveHourMinutes) }
    public var weekly: QuotaWindow? { window(ofMinutes: Self.weeklyMinutes) }

    /// What actually gates the account right now: the window with the least left.
    public var tightest: QuotaWindow? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    public var remainingPercent: Int? {
        tightest?.remainingPercent
    }

    public var nextReset: Date? {
        windows.compactMap(\.resetsAt).filter { $0 > Date() }.min()
    }

    /// Parses `account/rateLimits/read`. The reply carries a default bucket plus
    /// per-limit buckets; the `codex` bucket is the one that governs Codex usage.
    public static func parse(_ reply: [String: Any]) -> QuotaReport? {
        let byLimit = reply["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (byLimit?["codex"] as? [String: Any]) ?? (reply["rateLimits"] as? [String: Any])
        guard let bucket else { return nil }

        let windows = ["primary", "secondary"].compactMap { key -> QuotaWindow? in
            guard let raw = bucket[key] as? [String: Any], let used = raw["usedPercent"] as? Int else {
                return nil
            }
            let resets = (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(
                usedPercent: used,
                durationMinutes: (raw["windowDurationMins"] as? NSNumber)?.intValue,
                resetsAt: resets
            )
        }

        var credits: QuotaCredits?
        if let raw = bucket["credits"] as? [String: Any] {
            credits = QuotaCredits(
                balance: raw["balance"] as? String,
                hasCredits: raw["hasCredits"] as? Bool ?? false,
                unlimited: raw["unlimited"] as? Bool ?? false
            )
        }

        guard !windows.isEmpty || credits != nil else { return nil }
        return QuotaReport(windows: windows, credits: credits, plan: bucket["planType"] as? String)
    }
}
