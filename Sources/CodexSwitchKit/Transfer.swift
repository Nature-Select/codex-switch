import Foundation

/// Moving a set of accounts to another Mac.
///
/// The bundle is one JSON file holding each account's `auth.json` verbatim plus
/// the registry fields worth keeping (label, plan, last known quota). It stores
/// no absolute paths on purpose: the receiving machine puts every account in its
/// own state directory, so a different user name or a different `CODEX_SWITCH_HOME`
/// changes nothing. Accounts are matched by fingerprint on the way in, so
/// importing the same bundle twice adds nothing the second time.
public enum AccountTransfer {
    public static let format = "codex-switch.accounts"
    public static let currentVersion = 1

    public struct Entry: Codable, Equatable {
        public var id: String
        public var label: String
        public var email: String?
        public var plan: String?
        public var fingerprint: String?
        public var addedAt: Date
        public var checkedAt: Date?
        public var quota: QuotaReport?
        public var needsSignIn: Bool?
        /// The account's `auth.json`, byte for byte. Re-encoding it would be
        /// lossless for us and a gamble against whatever Codex writes next.
        public var auth: String
    }

    public struct Bundle: Codable, Equatable {
        public var format: String
        public var version: Int
        public var exportedAt: Date
        public var accounts: [Entry]

        public init(accounts: [Entry], exportedAt: Date = Date()) {
            self.format = AccountTransfer.format
            self.version = AccountTransfer.currentVersion
            self.exportedAt = exportedAt
            self.accounts = accounts
        }
    }

    public struct ExportOutcome {
        public var bundle: Bundle
        public var skipped: [(account: StoredAccount, reason: String)] = []
    }

    public struct ImportOutcome {
        public var added: [StoredAccount] = []
        public var replaced: [StoredAccount] = []
        public var skipped: [(label: String, reason: String)] = []
    }

    // MARK: - Export

    /// Collects credentials for the given accounts. The account that owns
    /// `~/.codex` is read from there rather than from its parked copy: Codex
    /// renews tokens in the live home, so the copy can be a refresh behind.
    public static func export(_ accounts: [StoredAccount], from manager: AccountManager) -> ExportOutcome {
        let liveOwnerID = manager.accountOwningLiveHome()?.id
        var outcome = ExportOutcome(bundle: Bundle(accounts: []))

        for account in accounts {
            let home = account.id == liveOwnerID ? manager.environment.liveHome : account.home
            let file = CodexEnvironment.credentialFile(in: home)
            guard let data = try? Data(contentsOf: file), let auth = String(data: data, encoding: .utf8) else {
                outcome.skipped.append((account, "no readable credentials at \(file.path)"))
                continue
            }

            outcome.bundle.accounts.append(Entry(
                id: account.id,
                label: account.label,
                email: account.email,
                plan: account.plan,
                fingerprint: account.fingerprint ?? (try? manager.credentials.fingerprint(in: home)) ?? nil,
                addedAt: account.addedAt,
                checkedAt: account.checkedAt,
                quota: account.quota,
                needsSignIn: account.needsSignIn,
                auth: auth
            ))
        }

        return outcome
    }

    public static func encode(_ bundle: Bundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Writes the bundle owner-only and atomically: it holds live tokens, and a
    /// half-written one would look importable.
    public static func write(_ bundle: Bundle, to url: URL) throws {
        let data = try encode(bundle)
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: scratch, options: [.atomic])
        Privacy.lockDown(scratch)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        } else {
            try FileManager.default.moveItem(at: scratch, to: url)
        }
        Privacy.lockDown(url)
    }

    // MARK: - Import

    public static func decode(_ data: Data) throws -> Bundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(Bundle.self, from: data), bundle.format == format else {
            throw CodexSwitchError.bundleUnreadable("That file is not a codex-switch export.")
        }
        guard bundle.version <= currentVersion else {
            throw CodexSwitchError.bundleUnreadable(
                "That export was written by a newer codex-switch (format \(bundle.version)). Update this one first."
            )
        }
        return bundle
    }

    public static func read(_ url: URL) throws -> Bundle {
        guard let data = try? Data(contentsOf: url) else {
            throw CodexSwitchError.bundleUnreadable("Cannot read \(url.path).")
        }
        return try decode(data)
    }

    /// Restores a bundle into this machine's state directory. Known accounts are
    /// left alone unless `replacingKnown` is set, so a repeated import is a
    /// no-op rather than a way to push stale tokens over fresh ones.
    @discardableResult
    public static func restore(
        _ bundle: Bundle,
        into manager: AccountManager,
        replacingKnown: Bool
    ) throws -> ImportOutcome {
        var outcome = ImportOutcome()
        let credentials = manager.credentials

        for entry in bundle.accounts {
            let ticket = UUID().uuidString
            let staged = manager.environment.stagingHome(ticket)
            defer { credentials.discard(staged.deletingLastPathComponent()) }

            try Privacy.makeDirectory(staged)
            let stagedFile = CodexEnvironment.credentialFile(in: staged)
            try Data(entry.auth.utf8).write(to: stagedFile, options: [.atomic])
            Privacy.lockDown(stagedFile)

            guard let fingerprint = (try? credentials.fingerprint(in: staged)) ?? nil else {
                outcome.skipped.append((entry.label, "its credentials name no account"))
                continue
            }
            // A fingerprint that disagrees with the entry means the file was
            // edited or truncated somewhere along the way; importing it would
            // file one account's tokens under another's name.
            if let claimed = entry.fingerprint, claimed != fingerprint {
                outcome.skipped.append((entry.label, "its credentials do not match the entry"))
                continue
            }

            if let existing = manager.store.account(fingerprint: fingerprint) {
                guard replacingKnown else {
                    outcome.skipped.append((entry.label, "already saved as \"\(existing.label)\""))
                    continue
                }
                try credentials.copy(from: staged, to: existing.home)

                var updated = existing
                updated.email = entry.email ?? updated.email
                updated.plan = entry.plan ?? updated.plan
                updated.quota = entry.quota ?? updated.quota
                updated.checkedAt = entry.checkedAt ?? updated.checkedAt
                updated.needsSignIn = entry.needsSignIn
                updated.lastError = nil
                if let identity = credentials.identity(in: existing.home) {
                    updated.apply(identity: identity)
                }
                try manager.store.save(updated)
                outcome.replaced.append(updated)
                continue
            }

            let id = claim(entry.id, in: manager)
            let home = manager.environment.accountHome(id)
            try credentials.adopt(stagedHome: staged, as: home)

            var account = StoredAccount(
                id: id,
                label: entry.label,
                email: entry.email,
                plan: entry.plan,
                fingerprint: fingerprint,
                homePath: home.path,
                addedAt: entry.addedAt,
                checkedAt: entry.checkedAt,
                quota: entry.quota,
                needsSignIn: entry.needsSignIn
            )
            if let identity = credentials.identity(in: home) {
                account.apply(identity: identity)
            }
            try manager.store.save(account)
            outcome.added.append(account)
        }

        return outcome
    }

    /// Keeps the exporting machine's id when it is free, so the same account
    /// stays recognisable across machines; falls back to a fresh one when that
    /// id is already taken here.
    private static func claim(_ id: String, in manager: AccountManager) -> String {
        guard manager.store.account(id: id) == nil else { return UUID().uuidString }
        guard !FileManager.default.fileExists(atPath: manager.environment.accountHome(id).path) else {
            return UUID().uuidString
        }
        return id
    }
}
