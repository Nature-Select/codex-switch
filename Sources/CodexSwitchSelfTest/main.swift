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

func writeCredentials(_ home: URL, accountID: String, email: String? = nil, refreshToken: String? = nil) throws {
    try Privacy.makeDirectory(home)
    var tokens: [String: Any] = ["account_id": accountID]
    if let refreshToken { tokens["refresh_token"] = refreshToken }
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
    // Only a reset still ahead of us counts as the next one, so this has to be
    // relative — a fixed date turns the test into a time bomb.
    let resetsAt = Int(Date().addingTimeInterval(3_600).timeIntervalSince1970)
    let reply: [String: Any] = [
        "rateLimits": ["primary": ["usedPercent": 1, "windowDurationMins": 10080]],
        "rateLimitsByLimitId": [
            "codex": [
                "planType": "pro",
                "primary": ["usedPercent": 40, "windowDurationMins": 10080, "resetsAt": resetsAt],
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

func testUpdateComparesVersionsAndSpotsHomebrew() throws {
    try expect(Updater.isNewer("1.1.0", than: "1.0.9"), "Expected a minor bump to count as newer.")
    try expect(Updater.isNewer("1.0.10", than: "1.0.9"), "Expected numeric, not lexical, comparison.")
    try expect(Updater.isNewer("2.0", than: "1.9.9"), "Expected a missing patch component to be treated as zero.")
    try expect(!Updater.isNewer("1.0.1", than: "1.0.1"), "Expected the same version not to be newer.")
    try expect(!Updater.isNewer("1.0.0", than: "1.1.0"), "Expected an older release not to be newer.")

    switch Updater.installation(of: URL(fileURLWithPath: "/opt/homebrew/bin/codex-switch")) {
    case .homebrew: break
    case .standalone: throw Failure(message: "Expected a Homebrew prefix to be recognised.")
    }
    switch Updater.installation(of: URL(fileURLWithPath: "/usr/local/Cellar/codex-switch/1.0.0/bin/codex-switch")) {
    case .homebrew: break
    case .standalone: throw Failure(message: "Expected a Cellar path to be recognised.")
    }
    switch Updater.installation(of: URL(fileURLWithPath: "/Users/someone/.local/bin/codex-switch")) {
    case .homebrew: throw Failure(message: "Expected a plain path to be treated as standalone.")
    case let .standalone(binary): try expect(binary.lastPathComponent == "codex-switch", "Expected the binary path back.")
    }
}

func testRevokedAccountsAreRecognisedAndSkipped() throws {
    let revoked = """
    failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed:     401 Unauthorized; body={"error":{"message":"Encountered invalidated oauth token for user,     failing request","code":"token_revoked"}}
    """
    try expect(AccountManager.isSignedOut(revoked), "Expected a revoked token to be recognised.")
    try expect(!AccountManager.isSignedOut("The Internet connection appears to be offline."), "Expected a network failure not to look like a revoked login.")
    try expect(
        AccountManager.explain(CodexSwitchError.appServerFailed(revoked)).contains("codex-switch add"),
        "Expected the explanation to say what to do about it."
    )

    let healthy = QuotaReport(windows: [QuotaWindow(usedPercent: 0, durationMinutes: QuotaReport.weeklyMinutes, resetsAt: nil)])
    let dead = StoredAccount(id: "dead", label: "dead", homePath: "/tmp/dead", quota: healthy, needsSignIn: true)
    let alive = StoredAccount(id: "alive", label: "alive", homePath: "/tmp/alive", quota: QuotaReport(windows: [QuotaWindow(usedPercent: 50, durationMinutes: QuotaReport.weeklyMinutes, resetsAt: nil)]))
    let current = StoredAccount(id: "current", label: "current", homePath: "/tmp/current", quota: QuotaReport(windows: [QuotaWindow(usedPercent: 99, durationMinutes: QuotaReport.weeklyMinutes, resetsAt: nil)]))

    // The revoked account still shows 100% left; it must not win anyway.
    let ranked = AutoSwitchPlanner.candidates(among: [current, dead, alive], excluding: "current", atLeast: 5)
    try expect(ranked.map(\.id) == ["alive"], "Expected a revoked account to be skipped despite its stale quota.")
}

func testReauthRefusesToOverwriteWithADifferentAccount() throws {
    let root = scratch()
    let env = environment(root)
    let manager = try AccountManager(environment: env)

    let home = env.accountHome("target")
    try writeCredentials(home, accountID: "acct_target", email: "target@example.com")
    let fingerprint = try CredentialStore().fingerprint(in: home)
    let account = StoredAccount(
        id: "target",
        label: "target",
        email: "target@example.com",
        fingerprint: fingerprint,
        homePath: home.path,
        needsSignIn: true
    )
    try manager.store.save(account)
    let originalCredentials = try Data(contentsOf: CodexEnvironment.credentialFile(in: home))

    // Signing in as someone else must leave the account it was aimed at alone.
    let strangerStaging = env.stagingHome("stranger")
    try writeCredentials(strangerStaging, accountID: "acct_stranger", email: "stranger@example.com")
    let refusal = try runAsync {
        try await manager.reauthenticate(account, stagedHome: strangerStaging, identity: AccountIdentity(email: "stranger@example.com", plan: nil))
    }
    guard case let .wrongAccount(signedInAs) = refusal else {
        throw Failure(message: "Expected a different account to be refused.")
    }
    try expect(signedInAs == "stranger@example.com", "Expected the refusal to name who signed in.")
    let afterRefusal = try Data(contentsOf: CodexEnvironment.credentialFile(in: home))
    try expect(afterRefusal == originalCredentials, "Expected the target's credentials to be untouched.")
    try expect(manager.store.account(id: "target")?.needsSignIn == true, "Expected the account to still need a sign-in.")

    // The right account restores it, keeping label and id.
    let properStaging = env.stagingHome("proper")
    try writeCredentials(properStaging, accountID: "acct_target", email: "target@example.com")
    let outcome = try runAsync {
        try await manager.reauthenticate(account, stagedHome: properStaging, identity: AccountIdentity(email: "target@example.com", plan: "pro"))
    }
    guard case let .restored(restored) = outcome else {
        throw Failure(message: "Expected the matching account to be restored.")
    }
    try expect(restored.id == "target" && restored.label == "target", "Expected identity and label to survive.")
    try expect(restored.needsSignIn == nil, "Expected the sign-in mark to be cleared.")
    try expect(!FileManager.default.fileExists(atPath: properStaging.path), "Expected staging to be consumed.")
}


func testExportCarriesAccountsToAnotherMachine() throws {
    let source = environment(scratch())
    let origin = try AccountManager(environment: source)

    let mainHome = source.accountHome("main")
    let spareHome = source.accountHome("spare")
    try writeCredentials(mainHome, accountID: "acct_main", email: "main@example.com")
    try writeCredentials(spareHome, accountID: "acct_spare", email: "spare@example.com")
    try origin.store.save(StoredAccount(id: "main", label: "Main", fingerprint: try CredentialStore().fingerprint(in: mainHome), homePath: mainHome.path))
    try origin.store.save(StoredAccount(id: "spare", label: "Spare", fingerprint: try CredentialStore().fingerprint(in: spareHome), homePath: spareHome.path))
    try origin.activate(try XCTUnwrap(origin.store.account(id: "main"), "main"), restartDesktop: false)

    // Codex renewed the live account's token since the last switch; the export
    // has to carry that, not the copy parked next to the account.
    try writeCredentials(source.liveHome, accountID: "acct_main", email: "main@example.com", refreshToken: "renewed")
    let renewed = try Data(contentsOf: CodexEnvironment.credentialFile(in: source.liveHome))
    let parked = try Data(contentsOf: CodexEnvironment.credentialFile(in: mainHome))
    try expect(renewed != parked, "Expected the parked copy to be stale for this test.")

    let exported = AccountTransfer.export(origin.accounts, from: origin)
    try expect(exported.skipped.isEmpty, "Expected every account to be exportable.")
    try expect(exported.bundle.accounts.count == 2, "Expected both accounts in the bundle.")

    let file = source.stateDirectory.appendingPathComponent("accounts-export.json")
    try AccountTransfer.write(exported.bundle, to: file)
    let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber, "permissions")
    try expect(mode.int16Value == 0o600, "Expected the export to be owner-only.")
    let text = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8), "bundle text")
    try expect(!text.contains(source.stateDirectory.path), "Expected no local paths in the bundle.")

    // The other Mac: a different state directory, nothing known yet.
    let destination = environment(scratch())
    let arrival = try AccountManager(environment: destination)
    let landed = try AccountTransfer.restore(try AccountTransfer.read(file), into: arrival, replacingKnown: false)

    try expect(landed.added.count == 2 && landed.skipped.isEmpty, "Expected both accounts to land.")
    let main = try XCTUnwrap(arrival.accounts.first { $0.label == "Main" }, "Main")
    try expect(main.homePath.hasPrefix(destination.accountsDirectory.path), "Expected the account to live under the receiving state directory.")
    let travelled = try Data(contentsOf: CodexEnvironment.credentialFile(in: main.home))
    try expect(travelled == renewed, "Expected the live credentials to travel.")
    try expect(!arrival.credentials.exists(in: destination.liveHome), "Expected importing not to sign anyone in.")

    // Importing the same bundle again recognises the accounts and leaves them be.
    try writeCredentials(main.home, accountID: "acct_main", email: "main@example.com", refreshToken: "local")
    let local = try Data(contentsOf: CodexEnvironment.credentialFile(in: main.home))
    let again = try AccountTransfer.restore(try AccountTransfer.read(file), into: arrival, replacingKnown: false)
    try expect(again.added.isEmpty && again.skipped.count == 2, "Expected a repeated import to add nothing.")
    let kept = try Data(contentsOf: CodexEnvironment.credentialFile(in: main.home))
    try expect(kept == local, "Expected known accounts to keep their own credentials.")
    try expect(arrival.accounts.count == 2, "Expected no duplicates.")

    // --replace is what overwrites them.
    let replaced = try AccountTransfer.restore(try AccountTransfer.read(file), into: arrival, replacingKnown: true)
    try expect(replaced.replaced.count == 2, "Expected both accounts to be replaced.")
    let overwritten = try Data(contentsOf: CodexEnvironment.credentialFile(in: main.home))
    try expect(overwritten == renewed, "Expected the bundle's credentials to win with --replace.")
    try expect(arrival.accounts.count == 2, "Expected replacing not to duplicate accounts.")
}

func testImportKeepsTheLiveHomeInStepAndDistrustsIDs() throws {
    let env = environment(scratch())
    let manager = try AccountManager(environment: env)

    let home = env.accountHome("live")
    try writeCredentials(home, accountID: "acct_live", email: "live@example.com", refreshToken: "old")
    let account = StoredAccount(id: "live", label: "Live", fingerprint: try CredentialStore().fingerprint(in: home), homePath: home.path)
    try manager.store.save(account)
    try manager.activate(account, restartDesktop: false)

    // An export of the same account taken after Codex renewed its token.
    let elsewhere = environment(scratch())
    let other = try AccountManager(environment: elsewhere)
    let otherHome = elsewhere.accountHome("live")
    try writeCredentials(otherHome, accountID: "acct_live", email: "live@example.com", refreshToken: "renewed")
    let copy = StoredAccount(id: "live", label: "Live", fingerprint: try CredentialStore().fingerprint(in: otherHome), homePath: otherHome.path)
    try other.store.save(copy)
    let bundle = AccountTransfer.export([copy], from: other).bundle
    let renewed = try Data(contentsOf: CodexEnvironment.credentialFile(in: otherHome))

    // Replacing the account that owns ~/.codex has to reach the live home too,
    // or the next switch parks the old sign-in back over the imported one.
    let outcome = try AccountTransfer.restore(bundle, into: manager, replacingKnown: true)
    try expect(outcome.replaced.count == 1, "Expected the known account to be replaced.")
    let parked = try Data(contentsOf: CodexEnvironment.credentialFile(in: home))
    let liveNow = try Data(contentsOf: CodexEnvironment.credentialFile(in: env.liveHome))
    try expect(parked == renewed, "Expected the stored copy to be replaced.")
    try expect(liveNow == renewed, "Expected ~/.codex to hold the imported sign-in.")
    try expect(manager.accountOwningLiveHome()?.id == "live", "Expected the account in use not to change.")

    // An id from someone else's file must not choose where the home lands.
    var hostile = bundle
    hostile.accounts[0].id = "../../../escaped"
    hostile.accounts[0].fingerprint = nil
    hostile.accounts[0].auth = try XCTUnwrap(String(data: renewed, encoding: .utf8), "auth")
    let fresh = environment(scratch())
    let target = try AccountManager(environment: fresh)
    let landed = try AccountTransfer.restore(hostile, into: target, replacingKnown: false)
    let imported = try XCTUnwrap(landed.added.first, "imported account")
    try expect(imported.id != "../../../escaped", "Expected the id to be refused.")
    try expect(imported.homePath.hasPrefix(fresh.accountsDirectory.path), "Expected the home to stay inside the state directory.")
    try expect(!FileManager.default.fileExists(atPath: fresh.accountsDirectory.appendingPathComponent("../../../escaped").path), "Expected nothing outside the state directory.")
}

func testImportRejectsTamperedAndForeignFiles() throws {
    let env = environment(scratch())
    let manager = try AccountManager(environment: env)

    let home = env.accountHome("one")
    try writeCredentials(home, accountID: "acct_one", email: "one@example.com")
    let account = StoredAccount(id: "one", label: "One", fingerprint: try CredentialStore().fingerprint(in: home), homePath: home.path)
    try manager.store.save(account)

    var bundle = AccountTransfer.export([account], from: manager).bundle
    // Someone edited the file: the credentials no longer belong to the entry
    // they are filed under.
    let other = env.stagingHome("other")
    try writeCredentials(other, accountID: "acct_other", email: "other@example.com")
    bundle.accounts[0].auth = try String(data: Data(contentsOf: CodexEnvironment.credentialFile(in: other)), encoding: .utf8) ?? ""

    let target = try AccountManager(environment: environment(scratch()))
    let outcome = try AccountTransfer.restore(bundle, into: target, replacingKnown: false)
    try expect(outcome.added.isEmpty, "Expected mismatched credentials to be refused.")
    try expect(outcome.skipped.first?.reason.contains("do not match") == true, "Expected the refusal to say why.")

    do {
        _ = try AccountTransfer.decode(Data(#"{"format":"something-else","version":1,"exportedAt":"2026-01-01T00:00:00Z","accounts":[]}"#.utf8))
        throw Failure(message: "Expected a foreign file to be refused.")
    } catch is CodexSwitchError {}

    do {
        _ = try AccountTransfer.decode(Data("not json at all".utf8))
        throw Failure(message: "Expected garbage to be refused.")
    } catch is CodexSwitchError {}
}

func testUpdateReadsBackWhatWasInstalled() throws {
    let root = scratch()
    try Privacy.makeDirectory(root)

    func fakeBinary(named name: String, printing line: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\necho '\(line)'\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o700)
        return url
    }

    // A brew upgrade that installed nothing still exits 0, so `update` asks the
    // binary itself what it is now — that answer is the only honest one.
    let upgraded = try fakeBinary(named: "new", printing: "codex-switch 9.9.9")
    try expect(Updater.installedVersion(of: upgraded) == "9.9.9", "Expected the version the binary reports.")

    let stale = try fakeBinary(named: "old", printing: "codex-switch 1.3.0")
    let landed = try XCTUnwrap(Updater.installedVersion(of: stale), "installed version")
    try expect(landed != "1.4.0", "Expected a stale install to be distinguishable from the release.")

    let mute = try fakeBinary(named: "mute", printing: "")
    try expect(Updater.installedVersion(of: mute) == nil, "Expected unparsable output to report nothing.")
    try expect(Updater.installedVersion(of: root.appendingPathComponent("absent")) == nil, "Expected a missing binary to report nothing.")
}

/// The self-tests are synchronous; this bridges the few async entry points.
/// The result travels through a reference so nothing mutable is captured by the
/// concurrently-running task.
final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        do {
            box.value = .success(try await body())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    guard let value = box.value else {
        throw Failure(message: "The asynchronous body produced no result.")
    }
    return try value.get()
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
    ("legacy import copies accounts without moving them", testLegacyImportCopiesAccountsWithoutMovingThem),
    ("update compares versions and spots homebrew", testUpdateComparesVersionsAndSpotsHomebrew),
    ("update reads back what was installed", testUpdateReadsBackWhatWasInstalled),
    ("revoked accounts are recognised and skipped", testRevokedAccountsAreRecognisedAndSkipped),
    ("reauth refuses to overwrite with a different account", testReauthRefusesToOverwriteWithADifferentAccount),
    ("export carries accounts to another machine", testExportCarriesAccountsToAnotherMachine),
    ("import keeps the live home in step and distrusts ids", testImportKeepsTheLiveHomeInStepAndDistrustsIDs),
    ("import rejects tampered and foreign files", testImportRejectsTamperedAndForeignFiles)
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
