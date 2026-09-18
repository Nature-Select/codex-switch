import Foundation

public struct AccountSnapshot {
    public var identity: AccountIdentity?
    public var quota: QuotaReport?

    public var isEmpty: Bool { identity == nil && quota == nil }
}

public struct DeviceLogin {
    public var userCode: String
    public var verificationURL: URL
    public var stagedHome: URL
    public var session: AppServerSession
}

/// Everything that needs to talk to Codex itself.
public struct CodexService {
    private let environment: CodexEnvironment
    private let credentials: CredentialStore

    public init(environment: CodexEnvironment, credentials: CredentialStore = CredentialStore()) {
        self.environment = environment
        self.credentials = credentials
    }

    /// One child process answers both questions, which keeps `list` and `status`
    /// to a single spawn per account.
    public func inspect(codexHome: URL) async throws -> AccountSnapshot {
        try await AppServerSession.withSession(codexHome: codexHome) { session in
            var snapshot = AccountSnapshot()
            snapshot.identity = try? await readIdentity(session)

            var quotaFailure: Error?
            do {
                snapshot.quota = QuotaReport.parse(try await session.send("account/rateLimits/read", [:]))
            } catch {
                quotaFailure = error
            }

            if snapshot.isEmpty {
                // Report what Codex actually said — "revoked" and "offline" need
                // very different things from the user.
                throw quotaFailure ?? CodexSwitchError.appServerFailed("Codex returned no account data for \(codexHome.path).")
            }
            // The local credential file names the account even when the
            // app-server is still warming up.
            if snapshot.identity?.email == nil, let local = credentials.identity(in: codexHome) {
                snapshot.identity = local
            }
            return snapshot
        }
    }

    public func readIdentity(_ session: AppServerSession, refreshToken: Bool = false) async throws -> AccountIdentity {
        let reply = try await session.send("account/read", ["refreshToken": refreshToken])
        let account = reply["account"] as? [String: Any]
        return AccountIdentity(
            email: account?["email"] as? String,
            plan: account?["planType"] as? String
        )
    }

    public func beginDeviceLogin(ticket: String = UUID().uuidString) async throws -> DeviceLogin {
        let staged = environment.stagingHome(ticket)
        try Privacy.makeDirectory(staged)

        let session = try AppServerSession(codexHome: staged)
        try await session.handshake()
        let reply = try await session.send("account/login/start", ["type": "chatgptDeviceCode"])

        guard
            reply["type"] as? String == "chatgptDeviceCode",
            let code = reply["userCode"] as? String,
            let link = (reply["verificationUrl"] as? String).flatMap(URL.init(string:))
        else {
            session.shutdown()
            throw CodexSwitchError.appServerUnexpectedReply("login/start returned \(reply.keys.sorted())")
        }

        return DeviceLogin(userCode: code, verificationURL: link, stagedHome: staged, session: session)
    }

    /// Polls until the staged home holds credentials, then waits a little longer
    /// for the email to appear so the account is not stored as "Unnamed account".
    public func awaitLogin(_ login: DeviceLogin, timeout: TimeInterval, tick: @escaping () -> Void = {}) async throws -> AccountIdentity {
        let deadline = Date().addingTimeInterval(timeout)
        let completed = Signal()
        login.session.onNotification = { method, _ in
            if method == "account/login/completed" {
                completed.raise()
            }
        }

        while Date() < deadline {
            if completed.isRaised || credentials.exists(in: login.stagedHome) {
                break
            }
            if let identity = try? await readIdentity(login.session, refreshToken: true), identity.email != nil {
                break
            }
            tick()
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        guard credentials.exists(in: login.stagedHome) else {
            throw CodexSwitchError.loginIncomplete
        }

        var identity = credentials.identity(in: login.stagedHome) ?? AccountIdentity(email: nil, plan: nil)
        let settle = Date().addingTimeInterval(15)
        while identity.email == nil, Date() < settle {
            if let live = try? await readIdentity(login.session, refreshToken: true), live.email != nil {
                identity = live
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return identity
    }
}

final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func raise() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
