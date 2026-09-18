import CodexSwitchKit
import Foundation

extension Commands {
    struct AutoPayload: Encodable {
        var enabled: Bool
        var thresholdPercent: Int
        var intervalSeconds: Int
        var restartDesktop: Bool
        var agentInstalled: Bool
        var agentLoaded: Bool
        var logPath: String
        var currentAccount: String?
        var currentRemainingPercent: Int?
    }

    static func auto(_ arguments: Arguments, json: Bool) async throws {
        var rest = arguments
        let subcommand = arguments.positionals.first ?? "status"
        if arguments.positionals.first != nil {
            rest.dropFirstPositional()
        }

        switch subcommand {
        case "status":
            try await autoStatus(rest, json: json)
        case "enable", "on":
            try await autoEnable(rest, json: json)
        case "disable", "off":
            try await autoDisable(rest, json: json)
        case "tick":
            try await autoTick(rest, json: json)
        default:
            throw CLIError("Unknown `auto` subcommand \"\(subcommand)\". Use status, enable, or disable.", code: 2)
        }
    }

    private static func autoStatus(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: [])
        let manager = try AccountManager()
        let policy = manager.store.autoSwitch
        let current = manager.accountOwningLiveHome()

        if json {
            try Term.emit(AutoPayload(
                enabled: policy.enabled,
                thresholdPercent: policy.thresholdPercent,
                intervalSeconds: policy.intervalSeconds,
                restartDesktop: policy.restartDesktop,
                agentInstalled: AutoAgent.isInstalled,
                agentLoaded: AutoAgent.isLoaded,
                logPath: AutoAgent.log.path,
                currentAccount: current?.label,
                currentRemainingPercent: current?.quota?.remainingPercent
            ))
            return
        }

        Term.say(Present.field("Auto-switch", policy.enabled ? Style.green("on") : Style.faint("off")))
        Term.say(Present.field("Switch below", "\(policy.thresholdPercent)% left"))
        Term.say(Present.field("Checks every", "\(policy.intervalSeconds)s"))
        Term.say(Present.field("Restart desktop", policy.restartDesktop ? "yes" : "no"))

        if policy.enabled {
            let health = AutoAgent.isLoaded ? Style.green("running") : Style.red("not running — re-run `codex-switch auto enable`")
            Term.say(Present.field("Background job", health))
            Term.say(Present.field("Log", Style.faint(AutoAgent.log.path)))
        } else {
            Term.say(Style.faint("`codex-switch auto enable` turns it on and keeps it running in the background."))
        }

        if let current {
            let left = current.quota?.remainingPercent.map { Present.percent($0) + " left" } ?? Style.faint("quota unknown")
            Term.say(Present.field("Account", current.label + Style.faint("  ·  ") + left))
        }
    }

    private static func autoEnable(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["threshold", "interval", "restart", "no-restart"])
        let manager = try AccountManager()
        var policy = manager.store.autoSwitch
        policy.enabled = true

        if let threshold = arguments.number("threshold") {
            guard (0...100).contains(threshold) else {
                throw CLIError("--threshold must be between 0 and 100.", code: 2)
            }
            policy.thresholdPercent = threshold
        }
        if let interval = arguments.number("interval") {
            guard interval >= 60 else {
                throw CLIError("--interval must be at least 60 seconds.", code: 2)
            }
            policy.intervalSeconds = interval
        }
        if arguments.flag("no-restart") { policy.restartDesktop = false }
        if arguments.flag("restart") { policy.restartDesktop = true }

        try manager.store.setAutoSwitch(policy)

        let executable = AutoAgent.currentExecutable()
        try AutoAgent.install(
            executable: executable,
            intervalSeconds: policy.intervalSeconds,
            environment: manager.environment
        )

        if json {
            try await autoStatus(Arguments([]), json: true)
            return
        }

        Term.say(Style.green("✓") + " Auto-switch is on: below \(policy.thresholdPercent)% left, switch to the account with the most left.")
        Term.say(Style.faint("  Checked every \(policy.intervalSeconds)s by a background job — nothing to keep open."))
        Term.say(Style.faint("  Log: \(AutoAgent.log.path)"))
        if !AutoAgent.isLoaded {
            Term.warn(Style.yellow("The background job did not start. Check `launchctl print gui/\(getuid())/\(AutoAgent.label)`."))
        }
        if executable.path.contains("/.build/") {
            Term.warn(Style.yellow("Heads up: the job runs \(executable.path) — re-run `auto enable` after installing the release binary."))
        }
    }

    private static func autoDisable(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: [])
        let manager = try AccountManager()
        var policy = manager.store.autoSwitch
        policy.enabled = false
        try manager.store.setAutoSwitch(policy)
        AutoAgent.uninstall()

        if json {
            try await autoStatus(Arguments([]), json: true)
        } else {
            Term.say(Style.green("✓") + " Auto-switch is off and the background job was removed.")
        }
    }

    /// What the background job runs. Also useful by hand: `auto tick --dry-run`.
    private static func autoTick(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["dry-run", "force", "quiet"])
        let manager = try AccountManager()
        let policy = manager.store.autoSwitch
        let quiet = arguments.flag("quiet")

        func report(_ message: String) {
            guard !quiet, !json else { return }
            Term.say(message)
        }

        guard policy.enabled || arguments.flag("force") else {
            report(Style.faint("Auto-switch is off."))
            return
        }

        guard var current = manager.accountOwningLiveHome() else {
            throw CLIError("The account in ~/.codex is not saved here, so there is nothing to switch away from.")
        }

        let liveCheck = await manager.refresh([current], concurrency: 1)
        current = liveCheck.updated.first ?? current

        switch AutoSwitchPlanner.decide(
            policy: policy,
            current: current,
            pool: manager.accounts,
            force: arguments.flag("force")
        ) {
        case .stay(let remaining):
            report("\(current.label) has \(Present.percent(remaining)) left — above \(policy.thresholdPercent)%, staying.")
            return
        case .quotaUnknown:
            throw CLIError("Could not read the quota of \(current.label).")
        case .liveHomeUnmanaged, .disabled:
            return
        case .nothingBetter, .move:
            break
        }

        // Only now is it worth paying for a full sweep.
        let others = manager.accounts.filter { $0.id != current.id }
        let sweep = await manager.refresh(others)
        let pool = manager.accounts.map { account in
            sweep.updated.first { $0.id == account.id } ?? account
        }

        let decision = AutoSwitchPlanner.decide(
            policy: policy,
            current: current,
            pool: pool,
            force: arguments.flag("force")
        )

        guard case let .move(target, from, to) = decision else {
            let left = current.quota?.remainingPercent ?? 0
            Term.warn(Style.yellow("No account has \(policy.thresholdPercent)% or more left; staying on \(current.label) (\(left)%)."))
            return
        }

        if arguments.flag("dry-run") {
            if json {
                try Term.emit(AccountPayload(target, isActive: false))
            } else {
                Term.say("Would switch \(current.label) (\(from)%) → \(Style.bold(target.label)) (\(to)%).")
            }
            return
        }

        let restart = policy.restartDesktop && DesktopApp.isRunning
        try manager.activate(target, restartDesktop: restart)

        if json {
            try Term.emit(AccountPayload(target, isActive: true))
        } else {
            // Always printed, even with --quiet: this is the line worth having in the log.
            Term.say("\(Clock.stamp(Date(), now: .distantPast) ?? "")  switched \(current.label) (\(from)%) → \(target.label) (\(to)%)\(restart ? ", desktop restarted" : "")")
        }
    }
}
