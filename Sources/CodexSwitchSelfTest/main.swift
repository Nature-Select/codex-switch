import CodexSwitchCLIKit
import CodexSwitchKit
import Foundation

struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw Failure(message: message)
    }
}

func scratch() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-switch-selftest-\(UUID().uuidString)", isDirectory: true)
}

func environment(_ root: URL) -> CodexEnvironment {
    CodexEnvironment(
        stateDirectory: root.appendingPathComponent("state", isDirectory: true),
        liveHome: root.appendingPathComponent("live", isDirectory: true)
    )
}

func writeCredentials(_ home: URL, accountID: String, email: String? = nil) throws {
    try Privacy.makeDirectory(home)
    var tokens: [String: Any] = ["account_id": accountID]
    if let email {
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        tokens["id_token"] = "header.\(payload).signature"
    }
    let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens])
    try data.write(to: CodexEnvironment.credentialFile(in: home))
}

func testQuotaParsingPrefersTheCodexBucket() throws {
    let reply: [String: Any] = [
        "rateLimits": ["primary": ["usedPercent": 1, "windowDurationMins": 10080]],
        "rateLimitsByLimitId": [
            "codex": [
                "planType": "pro",
                "primary": ["usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1_789_835_666],
                "secondary": ["usedPercent": 90, "windowDurationMins": 300],
                "credits": ["balance": "0", "hasCredits": false, "unlimited": false]
            ]
        ]
    ]

    let quota = try XCTUnwrap(QuotaReport.parse(reply), "Expected the codex bucket to parse.")
    try expect(quota.plan == "pro", "Expected the plan to come from the codex bucket.")
    try expect(quota.weekly?.remainingPercent == 60, "Expected the weekly window to be matched by length.")
    try expect(quota.fiveHour?.remainingPercent == 10, "Expected the 5h window to be matched by length.")
    try expect(quota.remainingPercent == 10, "Expected the tightest window to define what is left.")
    try expect(quota.nextReset != nil, "Expected a reset date to decode.")
    try expect(quota.credits?.hasCredits == false, "Expected credits to decode.")

    let partial: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 20]]]
    let single = try XCTUnwrap(QuotaReport.parse(partial), "Expected a bucket without lengths to parse.")
    try expect(single.windows.count == 1, "Expected one window.")
    try expect(single.fiveHour == nil && single.weekly == nil, "Expected an unlabelled window not to claim a length.")
    try expect(single.remainingPercent == 80, "Expected the unlabelled window to still report what is left.")
}

func testCredentialsIdentifyTheAccountWithoutLeakingTheID() throws {
    let root = scratch()
    let home = root.appendingPathComponent("home", isDirectory: true)
    try writeCredentials(home, accountID: "acct_secret", email: "person@example.com")

    let store = CredentialStore()
    let fingerprint = try XCTUnwrap(try store.fingerprint(in: home), "Expected a fingerprint.")
    try expect(fingerprint.count == 64, "Expected a SHA-256 hex digest.")
    try expect(!fingerprint.contains("acct_secret"), "Expected the raw account id never to be stored.")

    let identity = try XCTUnwrap(store.identity(in: home), "Expected the id token to name the account.")
    try expect(identity.email == "person@example.com", "Expected the email claim.")
    try expect(identity.plan == "pro", "Expected the plan claim.")

    let bare = root.appendingPathComponent("bare", isDirectory: true)
    try writeCredentials(bare, accountID: "acct_bare")
    try expect(store.identity(in: bare) == nil, "Expected no identity without an id token.")
}

func testActivationParksTheOutgoingCredentials() throws {
    let root = scratch()
    let env = environment(root)
    let manager = try AccountManager(environment: env)

    let alphaHome = env.accountHome("alpha")
    let betaHome = env.accountHome("beta")
    try writeCredentials(alphaHome, accountID: "acct_alpha", email: "alpha@example.com")
    try writeCredentials(betaHome, accountID: "acct_beta", email: "beta@example.com")
    try manager.store.save(StoredAccount(id: "alpha", label: "alpha", fingerprint: try CredentialStore().fingerprint(in: alphaHome), homePath: alphaHome.path))
    try manager.store.save(StoredAccount(id: "beta", label: "beta", fingerprint: try CredentialStore().fingerprint(in: betaHome), homePath: betaHome.path))

    try manager.activate(try XCTUnwrap(manager.store.account(id: "alpha"), "alpha"), restartDesktop: false)
    try expect(manager.accountOwningLiveHome()?.id == "alpha", "Expected alpha to be live.")

    // Codex refreshes tokens in place; switching away must keep that change.
    try writeCredentials(env.liveHome, accountID: "acct_alpha", email: "alpha@example.com")
    let refreshed = try Data(contentsOf: CodexEnvironment.credentialFile(in: env.liveHome))
    try manager.activate(try XCTUnwrap(manager.store.account(id: "beta"), "beta"), restartDesktop: false)

    try expect(manager.accountOwningLiveHome()?.id == "beta", "Expected beta to be live.")
    let parked = try Data(contentsOf: CodexEnvironment.credentialFile(in: alphaHome))
    try expect(parked == refreshed, "Expected the outgoing credentials to be parked with their own account.")
}

func testRegistrySurvivesInterleavedWriters() throws {
    let root = scratch()
    let env = environment(root)
    let first = try RegistryStore(environment: env)
    let second = try RegistryStore(environment: env)

    try first.save(StoredAccount(id: "a", label: "A", homePath: "/tmp/a"))
    try second.save(StoredAccount(id: "b", label: "B", homePath: "/tmp/b"))
    let afterBoth = try RegistryStore(environment: env).accounts.count
    try expect(afterBoth == 2, "Expected both writes to survive.")

    _ = try first.forget(id: "b")
    try second.save(StoredAccount(id: "c", label: "C", homePath: "/tmp/c"))
    let final = try RegistryStore(environment: env).accounts.map(\.id).sorted()
    try expect(final == ["a", "c"], "Expected a removal to stick when another writer follows.")
}

func testAutoSwitchPicksTheAccountWithTheMostLeft() throws {
    func account(_ id: String, weekly: Int, fiveHour: Int? = nil) -> StoredAccount {
        var windows = [QuotaWindow(usedPercent: 100 - weekly, durationMinutes: QuotaReport.weeklyMinutes, resetsAt: nil)]
        if let fiveHour {
            windows.append(QuotaWindow(usedPercent: 100 - fiveHour, durationMinutes: QuotaReport.fiveHourMinutes, resetsAt: nil))
        }
        return StoredAccount(id: id, label: id, homePath: "/tmp/\(id)", quota: QuotaReport(windows: windows))
    }

    let pool = [
        account("current", weekly: 2),
        account("plenty", weekly: 90),
        account("some", weekly: 40),
        account("drained", weekly: 0),
        account("throttled", weekly: 95, fiveHour: 1),
        StoredAccount(id: "unknown", label: "unknown", homePath: "/tmp/unknown")
    ]

    let ranked = AutoSwitchPlanner.candidates(among: pool, excluding: "current", atLeast: 5)
    try expect(ranked.map(\.id) == ["plenty", "some"], "Expected accounts above the threshold, most left first.")

    let policy = AutoSwitchPolicy(enabled: true, thresholdPercent: 5, intervalSeconds: 300, restartDesktop: true)
    guard case let .move(target, from, to) = AutoSwitchPlanner.decide(policy: policy, current: pool[0], pool: pool) else {
        throw Failure(message: "Expected a move decision.")
    }
    try expect(target.id == "plenty" && from == 2 && to == 90, "Expected the fullest account to win.")

    guard case .stay = AutoSwitchPlanner.decide(policy: policy, current: pool[1], pool: pool) else {
        throw Failure(message: "Expected a healthy account to stay put.")
    }
    guard case .disabled = AutoSwitchPlanner.decide(policy: .off, current: pool[0], pool: pool) else {
        throw Failure(message: "Expected a disabled policy to do nothing.")
    }
    guard case .nothingBetter = AutoSwitchPlanner.decide(
        policy: AutoSwitchPolicy(enabled: true, thresholdPercent: 99, intervalSeconds: 300, restartDesktop: true),
        current: pool[0],
        pool: pool
    ) else {
        throw Failure(message: "Expected no candidate above an unreachable threshold.")
    }
}

func testLookupAcceptsNumbersLabelsAndPrefixes() throws {
    let accounts = [
        StoredAccount(id: "1111aaaa", label: "Work", email: "work@example.com", homePath: "/tmp/a"),
        StoredAccount(id: "2222bbbb", label: "Personal", email: "me@example.com", homePath: "/tmp/b")
    ]

    let byNumber = try Lookup.find("2", in: accounts)
    let byEmail = try Lookup.find("work@example.com", in: accounts)
    let byLabel = try Lookup.find("PERSONAL", in: accounts)
    let byPrefix = try Lookup.find("1111", in: accounts)
    try expect(byNumber.id == "2222bbbb", "Expected a list number to resolve.")
    try expect(byEmail.id == "1111aaaa", "Expected an email to resolve.")
    try expect(byLabel.id == "2222bbbb", "Expected case-insensitive labels.")
    try expect(byPrefix.id == "1111aaaa", "Expected an id prefix to resolve.")

    do {
        _ = try Lookup.find("e", in: accounts)
        throw Failure(message: "Expected an ambiguous reference to be rejected.")
    } catch let error as CLIError {
        try expect(error.code == 2, "Expected a usage exit code.")
    }
}

func testLayoutMeasuresWhatTheTerminalShows() throws {
    try expect(Layout.width("账号") == 4, "Expected CJK glyphs to take two columns.")
    let painted = Style.green("●")
    try expect(Layout.width(painted) == 1, "Expected color escapes to take no columns.")
    try expect(Layout.width(Layout.padRight(painted, 6)) == 6, "Expected padding to ignore escapes.")
    try expect(Layout.clip("abcdefgh", 5) == "abcd…", "Expected clipping to leave room for the ellipsis.")
}

func testClockRendersLocalResetTimes() throws {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let reset = Date(timeIntervalSince1970: 1_789_835_666)
    let now = Date(timeIntervalSince1970: 1_789_700_000)

    try expect(Clock.stamp(reset, now: now, zone: zone) == "Sun 09-20 00:34", "Expected a local timestamp.")
    try expect(Clock.stamp(reset, now: Date(timeIntervalSince1970: 1_789_836_000), zone: zone) == "today 00:34", "Expected a same-day reset to read as today.")
    try expect(Clock.until(reset, now: now) == "1d 13h", "Expected a coarse countdown.")
    try expect(Clock.since(nil) == "never", "Expected a missing timestamp to read as never.")
}

func testDesktopAppIsFoundByBundleIdentifier() throws {
    try expect(
        DesktopApp.bundle(forExecutable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")?.path == "/Applications/ChatGPT.app",
        "Expected an app executable to resolve to its bundle."
    )
    try expect(DesktopApp.bundle(forExecutable: "/usr/bin/login") == nil, "Expected a plain executable not to resolve.")
    try expect(
        DesktopApp.bundle(forExecutable: "/Applications/Foo.app/Contents/Helpers/bar") == nil,
        "Expected a helper outside MacOS/ not to resolve."
    )

    let candidates = CodexBinary.candidates(environment: ["PATH": "/usr/bin:/bin"], home: "/Users/example").map(\.path)
    try expect(
        candidates.contains("/Applications/ChatGPT.app/Contents/Resources/codex"),
        "Expected the desktop bundle's codex binary to be considered."
    )
    try expect(
        candidates.contains("/opt/homebrew/bin/codex"),
        "Expected Homebrew's path to be considered even with a minimal PATH."
    )
}

func testLabelsFollowTheEmailUntilSomeoneRenamesThem() throws {
    let identity = AccountIdentity(email: "new@example.com", plan: "pro")

    var unnamed = StoredAccount(label: "Unnamed account", homePath: "/tmp/a")
    unnamed.apply(identity: identity)
    try expect(unnamed.label == "new@example.com", "Expected a placeholder label to be replaced.")

    var renamed = StoredAccount(label: "备用号", email: "old@example.com", homePath: "/tmp/b")
    renamed.apply(identity: identity)
    try expect(renamed.label == "备用号", "Expected a chosen label to survive.")
    try expect(renamed.email == "new@example.com", "Expected the email to still update.")

    var mirroring = StoredAccount(label: "old@example.com", email: "old@example.com", homePath: "/tmp/c")
    mirroring.apply(identity: identity)
    try expect(mirroring.label == "new@example.com", "Expected a label mirroring the email to follow it.")

    var plan = StoredAccount(label: "x", plan: "plus", homePath: "/tmp/d")
    plan.apply(identity: AccountIdentity(email: nil, plan: nil))
    try expect(plan.plan == "plus", "Expected a missing plan not to erase the stored one.")
}

func testOrphanDirectoriesAreDetected() throws {
    let root = scratch()
    let env = environment(root)
    let manager = try AccountManager(environment: env)

    try writeCredentials(env.accountHome("orphan"), accountID: "acct_orphan")
    try Privacy.makeDirectory(env.accountHome("empty"))

    let orphans = manager.orphans()
    try expect(orphans.count == 2, "Expected both unregistered directories to show up.")
    try expect(orphans.filter(\.hasCredentials).map(\.accountID) == ["orphan"], "Expected only one to be recoverable.")

    try manager.store.save(StoredAccount(id: "orphan", label: "Adopted", homePath: env.accountHome("orphan").path))
    try expect(manager.orphans().map(\.accountID) == ["empty"], "Expected a registered directory to drop off the list.")
}

func testLegacyImportCopiesAccountsWithoutMovingThem() throws {
    let root = scratch()
    let env = environment(root)
    let manager = try AccountManager(environment: env)

    let legacy = root.appendingPathComponent("legacy", isDirectory: true)
    let legacyHome = legacy.appendingPathComponent("Profiles/old-1/codex-home", isDirectory: true)
    try writeCredentials(legacyHome, accountID: "acct_legacy", email: "legacy@example.com")

    let profiles: [String: Any] = [
        "profiles": [[
            "id": "old-1",
            "displayName": "ChatGPT Account",
            "codexHomePath": legacyHome.path,
            "createdAt": "2026-01-01T00:00:00Z",
            "lastUsageSnapshot": ["primary": ["usedPercent": 30, "windowDurationMins": 10080]]
        ]],
        "activeProfileID": "old-1"
    ]
    try JSONSerialization.data(withJSONObject: profiles).write(to: legacy.appendingPathComponent("profiles.json"))

    let result = try LegacyImport.run(from: legacy, into: manager)
    try expect(result.imported.count == 1, "Expected one account to be imported.")

    let imported = try XCTUnwrap(manager.store.account(id: "old-1"), "Expected the account in the registry.")
    try expect(imported.label == "legacy@example.com", "Expected the placeholder label to be resolved from the id token.")
    try expect(imported.quota?.weekly?.remainingPercent == 70, "Expected the stored quota to carry over.")
    try expect(FileManager.default.fileExists(atPath: CodexEnvironment.credentialFile(in: legacyHome).path), "Expected the source to stay in place.")
    try expect(manager.store.registry.activeAccountID == "old-1", "Expected the active pointer to carry over.")

    let again = try LegacyImport.run(from: legacy, into: manager)
    try expect(again.imported.isEmpty && again.skipped == 1, "Expected a second import to be a no-op.")
}

func XCTUnwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(message: "Expected a value: \(message)") }
    return value
}

let tests: [(String, () throws -> Void)] = [
    ("quota parsing prefers the codex bucket", testQuotaParsingPrefersTheCodexBucket),
    ("credentials identify the account without leaking the id", testCredentialsIdentifyTheAccountWithoutLeakingTheID),
    ("activation parks the outgoing credentials", testActivationParksTheOutgoingCredentials),
    ("registry survives interleaved writers", testRegistrySurvivesInterleavedWriters),
    ("auto-switch picks the account with the most left", testAutoSwitchPicksTheAccountWithTheMostLeft),
    ("lookup accepts numbers, labels and prefixes", testLookupAcceptsNumbersLabelsAndPrefixes),
    ("layout measures what the terminal shows", testLayoutMeasuresWhatTheTerminalShows),
    ("clock renders local reset times", testClockRendersLocalResetTimes),
    ("desktop app is found by bundle identifier", testDesktopAppIsFoundByBundleIdentifier),
    ("labels follow the email until someone renames them", testLabelsFollowTheEmailUntilSomeoneRenamesThem),
    ("orphan directories are detected", testOrphanDirectoriesAreDetected),
    ("legacy import copies accounts without moving them", testLegacyImportCopiesAccountsWithoutMovingThem)
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

if failures > 0 {
    fputs("\(failures) test\(failures == 1 ? "" : "s") failed\n", stderr)
    exit(1)
}
