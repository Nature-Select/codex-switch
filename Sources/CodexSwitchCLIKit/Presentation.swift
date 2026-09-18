import CodexSwitchKit
import Foundation

enum Present {
    static let labelColumn = 20
    private static let rightAligned: Set<String> = ["#", "5H", "WEEKLY", "LEFT", "RESETS IN"]

    static func field(_ label: String, _ value: String) -> String {
        Layout.padRight(label, labelColumn) + value
    }

    static func tint(_ remaining: Int) -> (String) -> String {
        switch remaining {
        case 50...: return Style.green
        case 30..<50: return Style.blue
        case 10..<30: return Style.yellow
        default: return Style.red
        }
    }

    static func percent(_ remaining: Int) -> String {
        tint(remaining)("\(remaining)%")
    }

    static func gauge(_ remaining: Int, width: Int = 10) -> String {
        let clamped = max(0, min(100, remaining))
        let filled = Int((Double(clamped) / 100 * Double(width)).rounded())
        return tint(clamped)(String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled))
    }

    static func remainingCell(_ window: QuotaWindow?) -> String {
        guard let window else { return Style.faint("–") }
        return percent(window.remainingPercent)
    }

    static func windowName(_ window: QuotaWindow) -> String {
        switch window.durationMinutes {
        case QuotaReport.fiveHourMinutes: return "5h window"
        case QuotaReport.weeklyMinutes: return "Weekly window"
        case let minutes? where minutes < 60: return "\(minutes)m window"
        case let minutes? where minutes < 1_440: return "\(minutes / 60)h window"
        case let minutes?: return "\(minutes / 1_440)d window"
        case nil: return "Quota"
        }
    }

    static func quotaLines(_ quota: QuotaReport?) -> [String] {
        guard let quota, !quota.windows.isEmpty || quota.credits != nil else {
            return [field("Quota", Style.faint("unknown — run `codex-switch refresh`"))]
        }

        var lines = quota.windows.map { window -> String in
            let remaining = window.remainingPercent
            var line = Layout.padRight(windowName(window), labelColumn)
                + Layout.padRight(percent(remaining) + " left", 12)
                + gauge(remaining)
            if let stamp = Clock.stamp(window.resetsAt), let until = Clock.until(window.resetsAt) {
                line += Style.faint("  resets \(stamp)  ·  in \(until)")
            }
            return line
        }

        if let credits = quota.credits {
            let value = credits.unlimited ? "unlimited" : (credits.balance ?? (credits.hasCredits ? "available" : "0"))
            lines.append(field("Credits", value))
        }
        return lines
    }

    static func table(_ headers: [String], _ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }

        var columns = headers.map(Layout.width)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columns.count {
                columns[index] = max(columns[index], Layout.width(cell))
            }
        }

        func render(_ cells: [String]) -> String {
            cells.enumerated()
                .map { index, cell -> String in
                    guard index < cells.count - 1 else { return cell }
                    return rightAligned.contains(headers[index])
                        ? Layout.padLeft(cell, columns[index])
                        : Layout.padRight(cell, columns[index])
                }
                .joined(separator: "  ")
                .trimmedTrailing()
        }

        return ([Style.faint(render(headers))] + rows.map(render)).joined(separator: "\n")
    }

    static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}

extension String {
    func trimmedTrailing() -> String {
        var copy = self
        while copy.hasSuffix(" ") { copy.removeLast() }
        return copy
    }
}

struct AccountPayload: Encodable {
    var id: String
    var label: String
    var email: String?
    var plan: String?
    var isActive: Bool
    var home: String
    var addedAt: Date
    var checkedAt: Date?
    var remainingPercent: Int?
    var fiveHourRemainingPercent: Int?
    var weeklyRemainingPercent: Int?
    var resetsAt: Date?
    var lastError: String?

    init(_ account: StoredAccount, isActive: Bool) {
        self.id = account.id
        self.label = account.label
        self.email = account.email
        self.plan = account.plan
        self.isActive = isActive
        self.home = account.homePath
        self.addedAt = account.addedAt
        self.checkedAt = account.checkedAt
        self.remainingPercent = account.quota?.remainingPercent
        self.fiveHourRemainingPercent = account.quota?.fiveHour?.remainingPercent
        self.weeklyRemainingPercent = account.quota?.weekly?.remainingPercent
        self.resetsAt = account.quota?.nextReset
        self.lastError = account.lastError
    }
}

public enum Lookup {
    /// Accounts can be named by list position, label, email, or id prefix —
    /// whatever the user has in front of them.
    public static func find(_ reference: String, in accounts: [StoredAccount]) throws -> StoredAccount {
        let needle = reference.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            throw CLIError("Name an account: a list number, label, email, or id.", code: 2)
        }

        if let position = Int(needle), position >= 1, position <= accounts.count {
            return accounts[position - 1]
        }
        if let exact = accounts.first(where: { $0.id == needle }) {
            return exact
        }

        let equal = accounts.filter {
            $0.email?.compare(needle, options: .caseInsensitive) == .orderedSame
                || $0.label.compare(needle, options: .caseInsensitive) == .orderedSame
        }
        if equal.count == 1 { return equal[0] }

        let partial = accounts.filter {
            $0.id.hasPrefix(needle)
                || $0.email?.range(of: needle, options: .caseInsensitive) != nil
                || $0.label.range(of: needle, options: .caseInsensitive) != nil
        }
        switch partial.count {
        case 1:
            return partial[0]
        case 0:
            let hint = Int(needle) == nil
                ? "Run `codex-switch list` to see them."
                : "There \(accounts.count == 1 ? "is 1 account" : "are \(accounts.count) accounts")."
            throw CLIError("No account matches \"\(needle)\". \(hint)")
        default:
            throw CLIError("\"\(needle)\" matches \(partial.map(\.label).joined(separator: ", ")). Use a number or id.", code: 2)
        }
    }
}
