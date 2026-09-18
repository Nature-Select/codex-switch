import Foundation

/// Where everything lives. Codex itself keeps exactly one signed-in account in
/// `CODEX_HOME` (`~/.codex` by default); codex-switch parks the others in its
/// own state directory and swaps them in on demand.
public struct CodexEnvironment {
    public var stateDirectory: URL
    public var liveHome: URL

    public var accountsDirectory: URL { stateDirectory.appendingPathComponent("accounts", isDirectory: true) }
    public var stagingDirectory: URL { stateDirectory.appendingPathComponent("staging", isDirectory: true) }
    public var registryFile: URL { stateDirectory.appendingPathComponent("accounts.json") }
    public var liveCredentialFile: URL { CodexEnvironment.credentialFile(in: liveHome) }

    public init(stateDirectory: URL, liveHome: URL) {
        self.stateDirectory = stateDirectory
        self.liveHome = liveHome
    }

    public static let defaultStateDirectoryName = "codex-switch"

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexEnvironment {
        func override(_ key: String) -> URL? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }

        let applicationSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return CodexEnvironment(
            stateDirectory: override("CODEX_SWITCH_HOME")
                ?? applicationSupport.appendingPathComponent(defaultStateDirectoryName, isDirectory: true),
            liveHome: override("CODEX_HOME") ?? home.appendingPathComponent(".codex", isDirectory: true)
        )
    }

    public func accountHome(_ accountID: String) -> URL {
        accountsDirectory
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    public func stagingHome(_ ticket: String) -> URL {
        stagingDirectory
            .appendingPathComponent(ticket, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    public static func credentialFile(in codexHome: URL) -> URL {
        codexHome.appendingPathComponent("auth.json")
    }

    public func prepareDirectories() throws {
        for directory in [stateDirectory, accountsDirectory, stagingDirectory] {
            try Privacy.makeDirectory(directory)
        }
    }
}

/// Credentials are the whole point of this tool, so every directory it creates
/// is owner-only and every file it writes is 0600.
public enum Privacy {
    public static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, 0o700)
    }

    public static func lockDown(_ url: URL) {
        chmod(url.path, 0o600)
    }
}
