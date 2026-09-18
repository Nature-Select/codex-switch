import Foundation

/// The desktop client ships as ChatGPT.app and its executable is named ChatGPT,
/// so it is always identified by bundle id — never by app or process name.
public enum DesktopApp {
    public static let bundleID = "com.openai.codex"

    public struct Instance {
        public var pid: pid_t
        public var bundle: URL
    }

    public static func instances() -> [Instance] {
        guard let listing = Shell.capture("/bin/ps", ["-axo", "pid=,comm="]) else { return [] }

        return listing.split(separator: "\n").compactMap { row in
            let entry = row.trimmingCharacters(in: .whitespaces)
            guard let gap = entry.firstIndex(of: " "), let pid = pid_t(entry[..<gap]) else { return nil }
            let executable = String(entry[entry.index(after: gap)...]).trimmingCharacters(in: .whitespaces)
            guard let bundle = bundle(forExecutable: executable), identifier(of: bundle) == bundleID else {
                return nil
            }
            return Instance(pid: pid, bundle: bundle)
        }
    }

    public static var isRunning: Bool {
        !instances().isEmpty
    }

    /// True while a `codex` session is alive in someone's terminal. Those keep
    /// using the credentials they started with, so they are worth warning about
    /// even though nothing can be restarted for them.
    public static var hasTerminalSessions: Bool {
        Shell.status("/usr/bin/pgrep", ["-f", "/codex( exec|$)|codex exec|codex$"]) == 0
    }

    public static func location() -> URL? {
        if let running = instances().first?.bundle {
            return running
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let guesses = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/Codex.app")
        ]
        if let found = guesses.first(where: { identifier(of: $0) == bundleID }) {
            return found
        }

        return Shell.capture("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(bundleID)'"])?
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .first { identifier(of: $0) == bundleID }
    }

    /// Restarts the client so it picks up the credentials that were just swapped in.
    @discardableResult
    public static func restart() -> Bool {
        let location = location()
        guard quit() else { return false }
        launch(location)
        return true
    }

    /// A polite quit can raise the app's own "are you sure" sheet, and during an
    /// automatic switch nobody is there to click it. Escalate instead: ask,
    /// then SIGTERM (Chromium exits without asking), then SIGKILL.
    @discardableResult
    public static func quit() -> Bool {
        guard isRunning else { return true }

        Shell.status("/usr/bin/osascript", ["-e", "tell application id \"\(bundleID)\" to quit"])
        if waitForExit(3) { return true }

        for instance in instances() {
            kill(instance.pid, SIGTERM)
        }
        if waitForExit(4) { return true }

        for instance in instances() {
            kill(instance.pid, SIGKILL)
        }
        return waitForExit(3)
    }

    public static func launch(_ location: URL? = nil) {
        if Shell.status("/usr/bin/open", ["-b", bundleID]) == 0 { return }
        if let location {
            Shell.status("/usr/bin/open", [location.path])
        }
    }

    public static func identifier(of bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return root["CFBundleIdentifier"] as? String
    }

    /// `/Applications/ChatGPT.app/Contents/MacOS/ChatGPT` -> `/Applications/ChatGPT.app`
    public static func bundle(forExecutable path: String) -> URL? {
        let executable = URL(fileURLWithPath: path)
        guard executable.deletingLastPathComponent().lastPathComponent == "MacOS" else { return nil }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !isRunning
    }
}

public enum Shell {
    @discardableResult
    public static func status(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
    }

    public static func capture(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
