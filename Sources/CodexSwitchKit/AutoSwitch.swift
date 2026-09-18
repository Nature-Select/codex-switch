import Foundation

public enum AutoSwitchDecision: Equatable {
    case disabled
    case liveHomeUnmanaged
    case quotaUnknown
    case stay(remaining: Int)
    case move(to: StoredAccount, from: Int, to_: Int)
    case nothingBetter(remaining: Int)
}

public enum AutoSwitchPlanner {
    /// Accounts worth moving to, most headroom first. Ties break on label so the
    /// same situation always produces the same choice.
    public static func candidates(
        among accounts: [StoredAccount],
        excluding currentID: String?,
        atLeast threshold: Int
    ) -> [StoredAccount] {
        var scored: [(account: StoredAccount, remaining: Int)] = []
        for account in accounts where account.id != currentID {
            guard let remaining = account.quota?.remainingPercent, remaining >= threshold else { continue }
            scored.append((account, remaining))
        }

        scored.sort { left, right in
            if left.remaining != right.remaining {
                return left.remaining > right.remaining
            }
            return left.account.label.localizedCaseInsensitiveCompare(right.account.label) == .orderedAscending
        }
        return scored.map(\.account)
    }

    public static func decide(
        policy: AutoSwitchPolicy,
        current: StoredAccount?,
        pool: [StoredAccount],
        force: Bool = false
    ) -> AutoSwitchDecision {
        guard policy.enabled || force else { return .disabled }
        guard let current else { return .liveHomeUnmanaged }
        guard let remaining = current.quota?.remainingPercent else { return .quotaUnknown }
        guard remaining < policy.thresholdPercent else { return .stay(remaining: remaining) }

        let options = candidates(among: pool, excluding: current.id, atLeast: policy.thresholdPercent)
        guard let best = options.first, let bestRemaining = best.quota?.remainingPercent else {
            return .nothingBetter(remaining: remaining)
        }
        return .move(to: best, from: remaining, to_: bestRemaining)
    }
}

/// `auto enable` is meant to be the whole story, so it installs a LaunchAgent
/// that performs the check on an interval. Nothing has to stay open in a terminal.
public enum AutoAgent {
    public static let label = "tech.natureselect.codex-switch.auto"

    public static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/codex-switch/auto.log")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plist.path)
    }

    public static var isLoaded: Bool {
        Shell.status("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    /// The path the agent will run. Resolved at install time, because the agent
    /// outlives this process and cannot ask us later.
    public static func currentExecutable() -> URL {
        let raw = CommandLine.arguments.first ?? "codex-switch"
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        if resolved.path.hasPrefix("/") {
            return resolved
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(raw)
    }

    public static func install(executable: URL, intervalSeconds: Int, environment: CodexEnvironment) throws {
        try Privacy.makeDirectory(log.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var variables: [String: String] = [:]
        if let override = ProcessInfo.processInfo.environment["CODEX_SWITCH_HOME"] {
            variables["CODEX_SWITCH_HOME"] = override
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            variables["CODEX_HOME"] = override
        }

        var job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "auto", "tick", "--quiet"],
            "StartInterval": intervalSeconds,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path
        ]
        if !variables.isEmpty {
            job["EnvironmentVariables"] = variables
        }

        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist, options: [.atomic])

        unload()
        Shell.status("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
    }

    public static func uninstall() {
        unload()
        try? FileManager.default.removeItem(at: plist)
    }

    private static func unload() {
        Shell.status("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }
}
