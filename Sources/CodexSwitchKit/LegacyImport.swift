import Foundation

/// One-time pickup of accounts managed by the menu-bar tool this CLI replaced.
/// Credentials are copied, never moved, so the old directory keeps working as a
/// backup until the user deletes it.
public enum LegacyImport {
    public static func defaultSource(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/Codex Manager", isDirectory: true)
    }

    public struct Result {
        public var imported: [StoredAccount] = []
        public var skipped: Int = 0
    }

    public static func isAvailable(at source: URL) -> Bool {
        FileManager.default.fileExists(atPath: source.appendingPathComponent("profiles.json").path)
    }

    public static func run(
        from source: URL,
        into manager: AccountManager
    ) throws -> Result {
        let file = source.appendingPathComponent("profiles.json")
        guard
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["profiles"] as? [[String: Any]]
        else {
            return Result()
        }

        let formatter = ISO8601DateFormatter()
        var result = Result()

        for entry in entries {
            guard
                let legacyID = entry["id"] as? String,
                let legacyHome = entry["codexHomePath"] as? String
            else {
                continue
            }
            let legacyHomeURL = URL(fileURLWithPath: legacyHome, isDirectory: true)
            let credentials = manager.credentials
            guard let fingerprint = (try? credentials.fingerprint(in: legacyHomeURL)) ?? nil else {
                result.skipped += 1
                continue
            }
            guard manager.store.account(fingerprint: fingerprint) == nil else {
                result.skipped += 1
                continue
            }

            let home = manager.environment.accountHome(legacyID)
            try Privacy.makeDirectory(home)
            try credentials.copy(from: legacyHomeURL, to: home)

            var account = StoredAccount(
                id: legacyID,
                label: entry["displayName"] as? String ?? "Unnamed account",
                email: entry["email"] as? String,
                plan: entry["planType"] as? String,
                fingerprint: fingerprint,
                homePath: home.path,
                addedAt: (entry["createdAt"] as? String).flatMap(formatter.date(from:)) ?? Date(),
                checkedAt: (entry["lastRefreshedAt"] as? String).flatMap(formatter.date(from:)),
                quota: quota(from: entry["lastUsageSnapshot"] as? [String: Any])
            )
            if let identity = credentials.identity(in: home) {
                account.apply(identity: identity)
            }

            try manager.store.save(account)
            result.imported.append(account)
        }

        if let activeID = root["activeProfileID"] as? String, manager.store.account(id: activeID) != nil {
            try? manager.store.markActive(activeID)
        }
        return result
    }

    private static func quota(from snapshot: [String: Any]?) -> QuotaReport? {
        guard let snapshot else { return nil }
        return QuotaReport.parse(["rateLimits": snapshot])
    }
}
