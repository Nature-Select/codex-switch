import CodexSwitchKit
import Foundation

public enum Commands {}

extension Commands {
    struct StatusPayload: Encodable {
        var signedIn: Bool
        var email: String?
        var plan: String?
        var managed: AccountPayload?
        var remainingPercent: Int?
        var resetsAt: Date?
        var localTokens: Int64
        var localThreads: Int
        var codexHome: String
        var autoSwitchEnabled: Bool
    }

    static func status(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["offline"])
        let manager = try AccountManager()
        manager.reconcileActivePointer()

        var account = manager.accountOwningLiveHome()
        var identity = account.map { AccountIdentity(email: $0.email, plan: $0.plan) }

        if !arguments.flag("offline"), manager.credentials.exists(in: manager.environment.liveHome) {
            if let snapshot = try? await manager.service.inspect(codexHome: manager.environment.liveHome) {
                identity = snapshot.identity ?? identity
                if var copy = account {
                    if let live = snapshot.identity { copy.apply(identity: live) }
                    if let quota = snapshot.quota {
                        copy.quota = quota
                        copy.checkedAt = Date()
                        copy.lastError = nil
                    }
                    try? manager.store.save(copy)
                    account = copy
                }
            }
        }

        let activity = manager.localActivity(for: account)
        let signedIn = manager.credentials.exists(in: manager.environment.liveHome)

        if json {
            try Term.emit(StatusPayload(
                signedIn: signedIn,
                email: identity?.email,
                plan: identity?.plan,
                managed: account.map { AccountPayload($0, isActive: true) },
                remainingPercent: account?.quota?.remainingPercent,
                resetsAt: account?.quota?.nextReset,
                localTokens: activity.tokens,
                localThreads: activity.threads,
                codexHome: manager.environment.liveHome.path,
                autoSwitchEnabled: manager.store.autoSwitch.enabled
            ))
            return
        }

        guard signedIn else {
            Term.say(Style.yellow("No Codex account is signed in on this Mac."))
            Term.say(Style.faint("`codex-switch add` signs one in, `codex-switch use <account>` activates a saved one."))
            return
        }

        let name = identity?.email ?? account?.label ?? "Current account"
        Term.say(Present.field("Account", Style.bold(name) + (identity?.plan.map { Style.faint("  (\($0))") } ?? "")))

        if let account {
            let position = manager.accounts.firstIndex { $0.id == account.id }.map { "\($0 + 1). " } ?? ""
            Term.say(Present.field("Saved as", Style.green("✓ ") + position + account.label + Style.faint("  ·  \(Present.shortID(account.id))")))
        } else {
            Term.say(Present.field("Saved as", Style.yellow("✗ not saved yet") + Style.faint("  ·  `codex-switch adopt` keeps it")))
        }

        for line in Present.quotaLines(account?.quota) {
            Term.say(line)
        }

        Term.say(Present.field("This Mac", "\(Clock.compact(activity.tokens)) tokens  ·  \(activity.threads) threads"))
        Term.say(Present.field("Codex home", Style.faint(manager.environment.liveHome.path)))

        let policy = manager.store.autoSwitch
        if policy.enabled {
            Term.say(Present.field("Auto-switch", Style.green("on") + Style.faint("  ·  below \(policy.thresholdPercent)%, every \(policy.intervalSeconds)s")))
        }
    }

    static func list(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["offline", "sort"])
        let manager = try AccountManager()
        manager.reconcileActivePointer()

        if !arguments.flag("offline"), let live = manager.accountOwningLiveHome() {
            let outcome = await manager.refresh([live], concurrency: 1)
            _ = outcome
        }

        let accounts = manager.accounts
        let activeID = manager.accountOwningLiveHome()?.id

        if json {
            try Term.emit(accounts.map { AccountPayload($0, isActive: $0.id == activeID) })
            return
        }

        guard !accounts.isEmpty else {
            Term.say("No accounts saved yet.")
            if LegacyImport.isAvailable(at: LegacyImport.defaultSource()) {
                Term.say(Style.yellow("Accounts from the old menu-bar app were found — `codex-switch migrate` imports them."))
            }
            Term.say(Style.faint("`codex-switch adopt` saves the account you are signed in as; `codex-switch add` signs in to another."))
            return
        }

        let ordered = try order(accounts, by: arguments.value("sort"))
        let showEmail = accounts.contains { $0.email != nil && $0.email != $0.label }
        let showFiveHour = accounts.contains { $0.quota?.fiveHour != nil }
        let showWeekly = accounts.contains { $0.quota?.weekly != nil }

        var headers = ["#", " ", "ACCOUNT"]
        if showEmail { headers.append("EMAIL") }
        headers.append("PLAN")
        if showFiveHour { headers.append("5H") }
        if showWeekly { headers.append("WEEKLY") }
        headers += ["RESETS IN", "RESET AT", "CHECKED"]

        let rows = ordered.map { position, account -> [String] in
            var row = [
                "\(position)",
                account.id == activeID ? Style.green("●") : " ",
                Layout.clip(account.label, 28)
            ]
            if showEmail { row.append(Layout.clip(account.email ?? "–", 30)) }
            row.append(account.plan ?? "–")
            if showFiveHour { row.append(Present.remainingCell(account.quota?.fiveHour)) }
            if showWeekly { row.append(Present.remainingCell(account.quota?.weekly)) }
            row.append(Clock.until(account.quota?.nextReset) ?? Style.faint("–"))
            row.append(Clock.stamp(account.quota?.nextReset) ?? Style.faint("–"))
            row.append(Style.faint(Clock.since(account.checkedAt)))
            return row
        }

        Term.say(Present.table(headers, rows))

        let orphans = manager.orphans().filter(\.hasCredentials)
        if !orphans.isEmpty {
            Term.say()
            Term.say(Style.yellow("\(orphans.count) account director\(orphans.count == 1 ? "y has" : "ies have") credentials but no entry — `codex-switch repair` adopts \(orphans.count == 1 ? "it" : "them")."))
        }
        if activeID == nil, manager.credentials.exists(in: manager.environment.liveHome) {
            Term.say()
            Term.say(Style.yellow("The account in ~/.codex is not saved here yet — `codex-switch adopt` keeps it."))
        }
    }

    /// The printed number always refers to the canonical (label-sorted) order,
    /// so sorting the view never changes what `use 3` means.
    private static func order(_ accounts: [StoredAccount], by key: String?) throws -> [(Int, StoredAccount)] {
        let numbered = accounts.enumerated().map { ($0.offset + 1, $0.element) }

        switch key {
        case nil, "name", "label":
            return numbered
        case "quota", "left":
            return numbered.sorted { left, right in
                let a = left.1.quota?.remainingPercent ?? -1
                let b = right.1.quota?.remainingPercent ?? -1
                return a == b ? left.0 < right.0 : a > b
            }
        case "reset", "resets":
            return numbered.sorted { left, right in
                let a = left.1.quota?.nextReset ?? .distantFuture
                let b = right.1.quota?.nextReset ?? .distantFuture
                return a == b ? left.0 < right.0 : a < b
            }
        case "checked":
            return numbered.sorted { ($0.1.checkedAt ?? .distantPast) > ($1.1.checkedAt ?? .distantPast) }
        case let other?:
            throw CLIError("Unknown --sort \"\(other)\". Use name, quota, reset, or checked.", code: 2)
        }
    }

    static func paths(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["open"])
        let manager = try AccountManager()
        let environment = manager.environment

        if json {
            try Term.emit([
                "state": environment.stateDirectory.path,
                "registry": environment.registryFile.path,
                "accounts": environment.accountsDirectory.path,
                "codexHome": environment.liveHome.path,
                "autoSwitchAgent": AutoAgent.plist.path,
                "autoSwitchLog": AutoAgent.log.path
            ])
        } else {
            Term.say(Present.field("State", environment.stateDirectory.path))
            Term.say(Present.field("Registry", environment.registryFile.path))
            Term.say(Present.field("Accounts", environment.accountsDirectory.path))
            Term.say(Present.field("Codex home", environment.liveHome.path))
            if AutoAgent.isInstalled {
                Term.say(Present.field("Auto-switch log", AutoAgent.log.path))
            }
        }

        if arguments.flag("open") {
            Shell.status("/usr/bin/open", [environment.stateDirectory.path])
        }
    }

    static func migrate(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: [])
        let manager = try AccountManager()
        let source = arguments.positionals.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? LegacyImport.defaultSource()

        guard LegacyImport.isAvailable(at: source) else {
            throw CLIError("Nothing to import from \(source.path).")
        }

        let result = try LegacyImport.run(from: source, into: manager)

        if json {
            try Term.emit(result.imported.map { AccountPayload($0, isActive: false) })
            return
        }

        for account in result.imported {
            Term.say(Style.green("✓") + " Imported " + Style.bold(account.label))
        }
        if result.skipped > 0 {
            Term.say(Style.faint("Skipped \(result.skipped) already-known or credential-less entr\(result.skipped == 1 ? "y" : "ies")."))
        }
        if result.imported.isEmpty {
            Term.say("Nothing new to import.")
        } else {
            Term.say(Style.faint("Credentials were copied, not moved — \(source.path) still holds the originals."))
        }
    }
}
