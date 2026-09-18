import Foundation

public struct Orphan {
    public var accountID: String
    public var home: URL
    public var hasCredentials: Bool
}

public struct RefreshOutcome {
    public var updated: [StoredAccount] = []
    public var failed: [(account: StoredAccount, reason: String)] = []
}

/// The operations the CLI is made of. Nothing here prints; callers decide what
/// the user sees.
public final class AccountManager {
    public let environment: CodexEnvironment
    public let store: RegistryStore
    public let credentials: CredentialStore
    public let service: CodexService

    public init(environment: CodexEnvironment = .standard()) throws {
        self.environment = environment
        self.store = try RegistryStore(environment: environment)
        self.credentials = CredentialStore()
        self.service = CodexService(environment: environment, credentials: credentials)
        sweepStaleStaging()
    }

    public var accounts: [StoredAccount] {
        store.accounts
    }

    public func fingerprintOfLiveHome() -> String? {
        try? credentials.fingerprint(in: environment.liveHome)
    }

    /// Which managed account the live credentials actually belong to — the
    /// registry's own "active" pointer is only a cache of this.
    public func accountOwningLiveHome() -> StoredAccount? {
        guard let fingerprint = fingerprintOfLiveHome() else { return nil }
        return store.account(fingerprint: fingerprint)
    }

    public func reconcileActivePointer() {
        let owner = accountOwningLiveHome()
        if store.registry.activeAccountID != owner?.id {
            try? store.markActive(owner?.id)
        }
    }

    /// Parks whatever is in the live home back with its owner, then swaps the
    /// target in. Losing the first step would strand a refreshed token.
    public func activate(_ account: StoredAccount, restartDesktop: Bool) throws {
        if let owner = accountOwningLiveHome(), owner.id != account.id {
            try? credentials.copy(from: environment.liveHome, to: owner.home)
        }

        guard credentials.exists(in: account.home) else {
            throw CodexSwitchError.credentialsMissing(CodexEnvironment.credentialFile(in: account.home))
        }

        try Privacy.makeDirectory(environment.liveHome)
        try credentials.copy(from: account.home, to: environment.liveHome)
        try store.markActive(account.id)

        if restartDesktop {
            DesktopApp.restart()
        }
    }

    public func adoptLiveHome(label: String?) async throws -> StoredAccount {
        guard let fingerprint = fingerprintOfLiveHome() else {
            throw CodexSwitchError.credentialsMissing(environment.liveCredentialFile)
        }
        if let existing = store.account(fingerprint: fingerprint) {
            throw CodexSwitchError.appServerFailed("Already managed as \"\(existing.label)\".")
        }

        let id = UUID().uuidString
        let home = environment.accountHome(id)
        try Privacy.makeDirectory(home)
        try credentials.copy(from: environment.liveHome, to: home)

        var account = StoredAccount(
            id: id,
            label: label ?? "Unnamed account",
            fingerprint: fingerprint,
            homePath: home.path
        )
        if let identity = credentials.identity(in: home), label == nil {
            account.apply(identity: identity)
        }
        account = await enrich(account, allowLabelChange: label == nil)

        try store.save(account)
        try store.markActive(account.id)
        return account
    }

    /// Moves a finished device login out of staging. If those credentials belong
    /// to an account that is already known, the existing entry is refreshed
    /// instead of a duplicate being created.
    public func register(login: DeviceLogin, identity: AccountIdentity, label: String?) async throws -> (account: StoredAccount, wasKnown: Bool) {
        guard let fingerprint = try credentials.fingerprint(in: login.stagedHome) else {
            throw CodexSwitchError.loginIncomplete
        }

        if var existing = store.account(fingerprint: fingerprint) {
            try credentials.adopt(stagedHome: login.stagedHome, as: existing.home)
            existing.apply(identity: identity)
            if let label { existing.label = label }
            existing = await enrich(existing, allowLabelChange: label == nil)
            try store.save(existing)
            return (existing, true)
        }

        let id = UUID().uuidString
        let home = environment.accountHome(id)
        try credentials.adopt(stagedHome: login.stagedHome, as: home)

        var account = StoredAccount(
            id: id,
            label: label ?? identity.email ?? "Unnamed account",
            email: identity.email,
            plan: identity.plan,
            fingerprint: fingerprint,
            homePath: home.path
        )
        account = await enrich(account, allowLabelChange: label == nil)
        try store.save(account)
        return (account, false)
    }

    public func forget(_ account: StoredAccount, deleteCredentials: Bool) throws {
        let removed = try store.forget(id: account.id)
        if deleteCredentials {
            credentials.discard(removed.home.deletingLastPathComponent())
        }
    }

    /// Refreshes several accounts at once. Each one spawns its own app-server,
    /// so a full sweep of a dozen accounts takes seconds rather than a minute.
    public func refresh(_ targets: [StoredAccount], concurrency: Int = 4) async -> RefreshOutcome {
        var outcome = RefreshOutcome()

        await withTaskGroup(of: (StoredAccount, Result<AccountSnapshot, Error>).self) { group in
            var queue = targets.makeIterator()
            var running = 0

            func start() {
                guard let account = queue.next() else { return }
                running += 1
                group.addTask {
                    do {
                        return (account, .success(try await self.service.inspect(codexHome: account.home)))
                    } catch {
                        return (account, .failure(error))
                    }
                }
            }

            for _ in 0..<max(1, concurrency) { start() }

            while running > 0, let (account, result) = await group.next() {
                running -= 1
                start()

                switch result {
                case let .success(snapshot):
                    var copy = account
                    if let identity = snapshot.identity { copy.apply(identity: identity) }
                    if let quota = snapshot.quota {
                        copy.quota = quota
                        copy.checkedAt = Date()
                    }
                    copy.lastError = nil
                    outcome.updated.append(copy)
                case let .failure(error):
                    outcome.failed.append((account, error.localizedDescription))
                }
            }
        }

        for account in outcome.updated {
            try? store.save(account)
        }
        for failure in outcome.failed {
            var copy = failure.account
            copy.lastError = failure.reason
            try? store.save(copy)
        }

        return outcome
    }

    /// Account directories with no registry entry: what a clobbered write leaves
    /// behind. The credentials are fine, so the entry can be rebuilt.
    public func orphans() -> [Orphan] {
        let known = Set(store.registry.accounts.map(\.id))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: environment.accountsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return entries
            .map(\.lastPathComponent)
            .filter { !known.contains($0) }
            .sorted()
            .map { id in
                let home = environment.accountHome(id)
                return Orphan(accountID: id, home: home, hasCredentials: credentials.exists(in: home))
            }
    }

    public func reclaim(_ orphan: Orphan) async throws -> StoredAccount? {
        guard let fingerprint = try credentials.fingerprint(in: orphan.home) else { return nil }
        guard store.account(fingerprint: fingerprint) == nil else { return nil }

        var account = StoredAccount(
            id: orphan.accountID,
            label: "Unnamed account",
            fingerprint: fingerprint,
            homePath: orphan.home.path
        )
        if let identity = credentials.identity(in: orphan.home) {
            account.apply(identity: identity)
        }
        account = await enrich(account, allowLabelChange: true)
        try store.save(account)
        return account
    }

    public func localActivity(for account: StoredAccount?) -> LocalActivity {
        LocalActivityReader(environment: environment)
            .measure(sessions: account.map { store.sessions(of: $0.id) } ?? [])
    }

    private func enrich(_ account: StoredAccount, allowLabelChange: Bool) async -> StoredAccount {
        var copy = account
        guard let snapshot = try? await service.inspect(codexHome: account.home) else { return copy }

        if let identity = snapshot.identity {
            let label = copy.label
            copy.apply(identity: identity)
            if !allowLabelChange { copy.label = label }
        }
        if let quota = snapshot.quota {
            copy.quota = quota
            copy.checkedAt = Date()
        }
        return copy
    }

    /// A cancelled login leaves a staging directory behind; anything older than
    /// an hour cannot belong to a sign-in still in progress.
    private func sweepStaleStaging() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: environment.stagingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-3_600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
