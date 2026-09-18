import CodexSwitchKit
import Foundation

extension Commands {
    static func use(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["yes", "restart", "no-restart"])
        let manager = try AccountManager()
        let accounts = manager.accounts
        guard !accounts.isEmpty else {
            throw CLIError("No accounts saved yet. Run `codex-switch adopt` or `codex-switch add` first.")
        }

        let reference = try arguments.positionals.first ?? choose(accounts, json: json)
        let target = try Lookup.find(reference, in: accounts)
        let current = manager.accountOwningLiveHome()

        if current?.id == target.id {
            if json {
                try Term.emit(AccountPayload(target, isActive: true))
            } else {
                Term.say("Already on " + Style.bold(target.label) + ".")
            }
            return
        }

        let desktopRunning = DesktopApp.isRunning
        let terminalRunning = DesktopApp.hasTerminalSessions
        let restart = arguments.flag("restart") || (desktopRunning && !arguments.flag("no-restart"))

        if (desktopRunning || terminalRunning), !arguments.flag("yes") {
            let subject = desktopRunning ? "The ChatGPT desktop app is running" : "A codex session is running in a terminal"
            if Term.interactive, !json {
                guard Term.confirm("\(subject). Switch anyway?", standard: true) else {
                    throw CLIError("Cancelled.", code: 130)
                }
            } else if !json {
                Term.warn(Style.yellow("Warning: \(subject.lowercased()); it keeps the old account until it restarts."))
            }
        }

        try manager.activate(target, restartDesktop: restart)

        if json {
            try Term.emit(AccountPayload(target, isActive: true))
        } else {
            Term.say(Style.green("✓") + " Now on " + Style.bold(target.label) + (target.email.map { Style.faint("  (\($0))") } ?? ""))
            if restart {
                Term.say(Style.faint("  ChatGPT desktop was restarted."))
            } else if desktopRunning {
                Term.say(Style.yellow("  ChatGPT desktop is still running on the previous account — restart it to pick this one up."))
            }
        }
    }

    static func adopt(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["label"])
        let manager = try AccountManager()
        let account = try await manager.adoptLiveHome(label: arguments.value("label"))

        if json {
            try Term.emit(AccountPayload(account, isActive: true))
        } else {
            Term.say(Style.green("✓") + " Saved " + Style.bold(account.label) + Style.faint("  ·  \(Present.shortID(account.id))"))
            Term.say(Style.faint("  Credentials copied to \(account.homePath)"))
        }
    }

    static func add(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["switch", "label", "timeout", "open", "no-open"])
        let manager = try AccountManager()
        let login = try await manager.service.beginDeviceLogin()
        defer { login.session.shutdown() }

        if json {
            Term.warn("Code \(login.userCode) — \(login.verificationURL.absoluteString)")
        } else {
            let copied = Term.interactive && Term.copyToClipboard(login.userCode)
            Term.say("Sign in to the ChatGPT account you want to add.")
            Term.say()
            Term.say(Present.field("Code", Style.bold(login.userCode) + (copied ? Style.faint("  (copied to clipboard)") : "")))
            Term.say(Present.field("URL", login.verificationURL.absoluteString))
            Term.say()
            Term.say(Style.faint("Waiting for the browser sign-in… (Ctrl-C to cancel)"))
        }

        if arguments.flag("open") || (!arguments.flag("no-open") && !json && Term.interactive) {
            Shell.status("/usr/bin/open", [login.verificationURL.absoluteString])
        }

        let timeout = TimeInterval(arguments.number("timeout") ?? 300)
        let identity: AccountIdentity
        do {
            identity = try await manager.service.awaitLogin(login, timeout: timeout)
        } catch {
            manager.credentials.discard(login.stagedHome.deletingLastPathComponent())
            throw CLIError("Sign-in did not complete within \(Int(timeout))s. Nothing was saved.")
        }

        let (account, wasKnown) = try await manager.register(
            login: login,
            identity: identity,
            label: arguments.value("label")
        )

        if arguments.flag("switch") {
            try manager.activate(account, restartDesktop: DesktopApp.isRunning)
        }

        if json {
            try Term.emit(AccountPayload(account, isActive: arguments.flag("switch")))
        } else {
            Term.say(Style.green("✓") + " \(wasKnown ? "Updated" : "Added") " + Style.bold(account.label) + Style.faint("  ·  \(Present.shortID(account.id))"))
            Term.say(Style.faint(arguments.flag("switch")
                ? "  It is the active account now."
                : "  `codex-switch use \(account.email ?? account.label)` switches to it."))
        }
    }

    static func rename(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: [])
        guard arguments.positionals.count >= 2 else {
            throw CLIError("Usage: codex-switch rename <account> <new-label>", code: 2)
        }

        let manager = try AccountManager()
        var account = try Lookup.find(arguments.positionals[0], in: manager.accounts)
        let label = arguments.positionals.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else {
            throw CLIError("The new label cannot be empty.", code: 2)
        }

        let previous = account.label
        account.label = label
        try manager.store.save(account)

        if json {
            try Term.emit(AccountPayload(account, isActive: false))
        } else {
            Term.say(Style.green("✓") + " " + Style.faint(previous) + " → " + Style.bold(label))
        }
    }

    static func forget(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["yes", "keep-credentials"])
        guard let reference = arguments.positionals.first else {
            throw CLIError("Usage: codex-switch forget <account> [--yes] [--keep-credentials]", code: 2)
        }

        let manager = try AccountManager()
        let account = try Lookup.find(reference, in: manager.accounts)
        let keep = arguments.flag("keep-credentials")

        if !arguments.flag("yes") {
            guard Term.interactive, !json else {
                throw CLIError("Refusing to forget \"\(account.label)\" without --yes.", code: 2)
            }
            let question = keep
                ? "Forget \"\(account.label)\" but keep its credentials on disk?"
                : "Forget \"\(account.label)\" and delete its saved credentials?"
            guard Term.confirm(question) else {
                throw CLIError("Cancelled.", code: 130)
            }
        }

        let wasActive = manager.accountOwningLiveHome()?.id == account.id
        try manager.forget(account, deleteCredentials: !keep)

        if json {
            try Term.emit(["forgot": account.id, "label": account.label])
        } else {
            Term.say(Style.green("✓") + " Forgot " + Style.bold(account.label))
            if keep {
                Term.say(Style.faint("  Kept \(account.homePath)"))
            }
            if wasActive {
                Term.say(Style.faint("  ~/.codex still holds this login — `codex-switch use <account>` swaps it out."))
            }
        }
    }

    static func refresh(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["all"])
        let manager = try AccountManager()
        let accounts = manager.accounts
        guard !accounts.isEmpty else {
            throw CLIError("No accounts saved yet.")
        }

        let targets: [StoredAccount]
        if arguments.flag("all") {
            targets = accounts
        } else if let reference = arguments.positionals.first {
            targets = [try Lookup.find(reference, in: accounts)]
        } else if let live = manager.accountOwningLiveHome() {
            targets = [live]
        } else {
            throw CLIError("The account in ~/.codex is not saved here. Name an account, or pass --all.")
        }

        let outcome = await manager.refresh(targets)
        let activeID = manager.accountOwningLiveHome()?.id

        if json {
            try Term.emit(outcome.updated.map { AccountPayload($0, isActive: $0.id == activeID) })
        } else {
            for account in outcome.updated {
                let left = account.quota?.remainingPercent.map { Present.percent($0) } ?? Style.faint("–")
                let reset = Clock.until(account.quota?.nextReset).map { Style.faint("  resets in \($0)") } ?? ""
                Term.say(Style.green("✓") + " " + Layout.padRight(Layout.clip(account.label, 28), 30) + left + reset)
            }
            for failure in outcome.failed {
                Term.say(Style.red("✗") + " " + Layout.padRight(Layout.clip(failure.account.label, 28), 30) + Style.faint(failure.reason))
            }
        }

        if outcome.updated.isEmpty {
            throw CLIError("Could not refresh any account.")
        }
    }

    static func repair(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["prune"])
        let manager = try AccountManager()
        let orphans = manager.orphans()

        var reclaimed: [StoredAccount] = []
        for orphan in orphans where orphan.hasCredentials {
            if let account = try await manager.reclaim(orphan) {
                reclaimed.append(account)
            }
        }

        let empty = orphans.filter { !$0.hasCredentials }
        if arguments.flag("prune") {
            for orphan in empty {
                manager.credentials.discard(orphan.home.deletingLastPathComponent())
            }
        }

        if json {
            try Term.emit(reclaimed.map { AccountPayload($0, isActive: false) })
            return
        }

        for account in reclaimed {
            Term.say(Style.green("✓") + " Recovered " + Style.bold(account.label) + Style.faint("  ·  \(Present.shortID(account.id))"))
        }
        if !empty.isEmpty {
            let verb = arguments.flag("prune") ? "Removed" : "Found"
            let tail = arguments.flag("prune") ? "" : " — `--prune` deletes \(empty.count == 1 ? "it" : "them")"
            Term.say(Style.faint("\(verb) \(empty.count) empty account director\(empty.count == 1 ? "y" : "ies")\(tail)."))
        }
        if reclaimed.isEmpty, empty.isEmpty {
            Term.say("Nothing to repair — every account directory is registered.")
        }
    }

    private static func choose(_ accounts: [StoredAccount], json: Bool) throws -> String {
        guard Term.interactive, !json else {
            throw CLIError("Usage: codex-switch use <account>", code: 2)
        }

        for (index, account) in accounts.enumerated() {
            let left = account.quota?.remainingPercent.map { "  " + Present.percent($0) + " left" } ?? ""
            Term.say("  \(index + 1)) \(account.label)\(left)")
        }
        guard let answer = Term.ask("Switch to which account?"), !answer.isEmpty else {
            throw CLIError("Cancelled.", code: 130)
        }
        return answer
    }
}
