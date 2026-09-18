import Foundation

public struct StoredAccount: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var email: String?
    public var plan: String?
    /// SHA-256 of the Codex account id. The raw id never touches the registry.
    public var fingerprint: String?
    public var homePath: String
    public var addedAt: Date
    public var checkedAt: Date?
    public var quota: QuotaReport?
    public var lastError: String?
    /// Set when Codex says the stored token is no longer valid. The quota
    /// numbers stay for reference, but they describe an account that cannot be
    /// used until someone signs in again.
    public var needsSignIn: Bool?

    public init(
        id: String = UUID().uuidString,
        label: String,
        email: String? = nil,
        plan: String? = nil,
        fingerprint: String? = nil,
        homePath: String,
        addedAt: Date = Date(),
        checkedAt: Date? = nil,
        quota: QuotaReport? = nil,
        lastError: String? = nil,
        needsSignIn: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.plan = plan
        self.fingerprint = fingerprint
        self.homePath = homePath
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.quota = quota
        self.lastError = lastError
        self.needsSignIn = needsSignIn
    }

    public var isUsable: Bool {
        needsSignIn != true
    }

    public var home: URL {
        URL(fileURLWithPath: homePath, isDirectory: true)
    }

    /// A label the user typed stays put; one that merely echoed the email follows it.
    public mutating func apply(identity: AccountIdentity) {
        if let email = identity.email {
            if label == email || label == self.email || StoredAccount.placeholderLabels.contains(label) {
                label = email
            }
            self.email = email
        }
        plan = identity.plan ?? plan
    }

    public static let placeholderLabels: Set<String> = ["Unnamed account", "ChatGPT Account", "Current Account"]
}

public struct AccountIdentity: Equatable {
    public var email: String?
    public var plan: String?

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }

    public var isEmpty: Bool { email == nil && plan == nil }
}

public struct SwitchRecord: Codable, Equatable {
    public var accountID: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(accountID: String, startedAt: Date = Date(), endedAt: Date? = nil) {
        self.accountID = accountID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct AutoSwitchPolicy: Codable, Equatable {
    public var enabled: Bool
    public var thresholdPercent: Int
    public var intervalSeconds: Int
    public var restartDesktop: Bool

    public static let off = AutoSwitchPolicy(enabled: false, thresholdPercent: 5, intervalSeconds: 300, restartDesktop: true)

    public init(enabled: Bool, thresholdPercent: Int, intervalSeconds: Int, restartDesktop: Bool) {
        self.enabled = enabled
        self.thresholdPercent = thresholdPercent
        self.intervalSeconds = intervalSeconds
        self.restartDesktop = restartDesktop
    }
}

public struct Registry: Codable, Equatable {
    public var version: Int
    public var accounts: [StoredAccount]
    public var activeAccountID: String?
    public var history: [SwitchRecord]
    public var autoSwitch: AutoSwitchPolicy?

    public static let currentVersion = 1

    public init(
        version: Int = Registry.currentVersion,
        accounts: [StoredAccount] = [],
        activeAccountID: String? = nil,
        history: [SwitchRecord] = [],
        autoSwitch: AutoSwitchPolicy? = nil
    ) {
        self.version = version
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.history = history
        self.autoSwitch = autoSwitch
    }
}

public enum CodexSwitchError: LocalizedError {
    case codexBinaryMissing
    case appServerFailed(String)
    case appServerUnexpectedReply(String)
    case appServerGone
    case timedOut
    case credentialsMissing(URL)
    case accountUnknown
    case loginIncomplete

    public var errorDescription: String? {
        switch self {
        case .codexBinaryMissing:
            return "No `codex` binary found. Install the ChatGPT desktop app or the Codex CLI first."
        case let .appServerFailed(message):
            return message
        case let .appServerUnexpectedReply(message):
            return "Unexpected reply from the Codex app-server: \(message)"
        case .appServerGone:
            return "The Codex app-server exited before answering."
        case .timedOut:
            return "Timed out waiting for the Codex app-server."
        case let .credentialsMissing(url):
            return "No credentials at \(url.path)."
        case .accountUnknown:
            return "That account is not in the registry."
        case .loginIncomplete:
            return "The sign-in never completed, so nothing was saved."
        }
    }
}
