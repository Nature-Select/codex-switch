import Foundation

/// The registry is a single JSON file that several short-lived CLI runs may
/// touch at once, so every mutation re-reads it if the file moved underneath us
/// and every write is atomic.
public final class RegistryStore {
    public private(set) var registry: Registry

    private let environment: CodexEnvironment
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var seenModification: Date?

    public init(environment: CodexEnvironment) throws {
        self.environment = environment
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        try environment.prepareDirectories()

        if FileManager.default.fileExists(atPath: environment.registryFile.path) {
            self.registry = try decoder.decode(Registry.self, from: Data(contentsOf: environment.registryFile))
            self.seenModification = Self.modified(environment.registryFile)
        } else {
            self.registry = Registry()
            try write()
        }
    }

    public var accounts: [StoredAccount] {
        registry.accounts.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public var autoSwitch: AutoSwitchPolicy {
        registry.autoSwitch ?? .off
    }

    public func account(id: String) -> StoredAccount? {
        registry.accounts.first { $0.id == id }
    }

    public func account(fingerprint: String) -> StoredAccount? {
        registry.accounts.first { $0.fingerprint == fingerprint }
    }

    public func save(_ account: StoredAccount) throws {
        try mutate { registry in
            if let index = registry.accounts.firstIndex(where: { $0.id == account.id }) {
                registry.accounts[index] = account
            } else {
                registry.accounts.append(account)
            }
        }
    }

    @discardableResult
    public func forget(id: String) throws -> StoredAccount {
        var removed: StoredAccount?
        try mutate { registry in
            guard let index = registry.accounts.firstIndex(where: { $0.id == id }) else { return }
            removed = registry.accounts.remove(at: index)
            registry.history.removeAll { $0.accountID == id }
            if registry.activeAccountID == id {
                registry.activeAccountID = nil
            }
        }
        guard let removed else { throw CodexSwitchError.accountUnknown }
        return removed
    }

    public func markActive(_ id: String?) throws {
        try mutate { registry in
            guard registry.activeAccountID != id else { return }
            let now = Date()
            if let open = registry.history.lastIndex(where: { $0.endedAt == nil }) {
                registry.history[open].endedAt = now
            }
            registry.activeAccountID = id
            if let id {
                registry.history.append(SwitchRecord(accountID: id, startedAt: now))
            }
        }
    }

    public func setAutoSwitch(_ policy: AutoSwitchPolicy) throws {
        try mutate { registry in
            registry.autoSwitch = policy
        }
    }

    public func sessions(of accountID: String) -> [SwitchRecord] {
        registry.history.filter { $0.accountID == accountID }
    }

    private func mutate(_ change: (inout Registry) -> Void) throws {
        refreshIfStale()
        change(&registry)
        try write()
    }

    private func write() throws {
        let data = try encoder.encode(registry)
        try data.write(to: environment.registryFile, options: [.atomic])
        Privacy.lockDown(environment.registryFile)
        seenModification = Self.modified(environment.registryFile)
    }

    private func refreshIfStale() {
        let current = Self.modified(environment.registryFile)
        guard current != seenModification else { return }
        guard
            let data = try? Data(contentsOf: environment.registryFile),
            let fresh = try? decoder.decode(Registry.self, from: data)
        else {
            return
        }
        registry = fresh
        seenModification = current
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
