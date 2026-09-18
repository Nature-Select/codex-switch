import Foundation

public struct LocalActivity: Equatable {
    public var tokens: Int64
    public var threads: Int

    public static let none = LocalActivity(tokens: 0, threads: 0)
}

/// Codex keeps thread history in a SQLite file inside the live home. Summing it
/// over the stretches an account was active gives a rough "how much did this
/// Mac use" number — it is not the billed figure and never claims to be.
public struct LocalActivityReader {
    private let environment: CodexEnvironment

    public init(environment: CodexEnvironment) {
        self.environment = environment
    }

    public func measure(sessions: [SwitchRecord]) -> LocalActivity {
        let database = environment.liveHome.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return .none }

        guard !sessions.isEmpty else {
            return query(database, filter: nil)
        }

        return sessions.reduce(into: LocalActivity.none) { total, session in
            let from = Int64(session.startedAt.timeIntervalSince1970)
            let to = Int64((session.endedAt ?? Date()).timeIntervalSince1970)
            let slice = query(database, filter: "updated_at >= \(from) AND updated_at <= \(to)")
            total.tokens += slice.tokens
            total.threads += slice.threads
        }
    }

    private func query(_ database: URL, filter: String?) -> LocalActivity {
        let clause = filter.map { " WHERE \($0)" } ?? ""
        let sql = "SELECT COALESCE(SUM(tokens_used), 0), COUNT(*) FROM threads\(clause);"
        guard
            let output = Shell.capture("/usr/bin/sqlite3", [database.path, sql])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return .none
        }

        let columns = output.split(separator: "|")
        guard columns.count == 2 else { return .none }
        return LocalActivity(tokens: Int64(columns[0]) ?? 0, threads: Int(columns[1]) ?? 0)
    }
}
