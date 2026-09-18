import CryptoKit
import Foundation

/// Reads and moves `auth.json` around. Everything here treats the file as
/// opaque except for two facts: the account id identifies the account, and the
/// id token carries the account's email.
public struct CredentialStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exists(in codexHome: URL) -> Bool {
        fileManager.fileExists(atPath: CodexEnvironment.credentialFile(in: codexHome).path)
    }

    public func fingerprint(in codexHome: URL) throws -> String? {
        guard let payload = try read(codexHome) else { return nil }
        guard
            let tokens = payload["tokens"] as? [String: Any],
            let accountID = tokens["account_id"] as? String,
            !accountID.isEmpty
        else {
            return nil
        }
        return SHA256.hash(data: Data(accountID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The id token already names the account, so a freshly added account has a
    /// real label even before the app-server answers.
    public func identity(in codexHome: URL) -> AccountIdentity? {
        guard
            let payload = (try? read(codexHome)) ?? nil,
            let tokens = payload["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String
        else {
            return nil
        }

        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded += String(repeating: "=", count: padding)

        guard
            let data = Data(base64Encoded: encoded),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let identity = AccountIdentity(
            email: claims["email"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String
        )
        return identity.isEmpty ? nil : identity
    }

    public func copy(from source: URL, to destination: URL) throws {
        let sourceFile = CodexEnvironment.credentialFile(in: source)
        guard fileManager.fileExists(atPath: sourceFile.path) else {
            throw CodexSwitchError.credentialsMissing(sourceFile)
        }

        try Privacy.makeDirectory(destination)
        let destinationFile = CodexEnvironment.credentialFile(in: destination)
        let scratch = destination.appendingPathComponent(".auth.json.\(UUID().uuidString)")

        let data = try Data(contentsOf: sourceFile)
        try data.write(to: scratch, options: [.atomic])
        Privacy.lockDown(scratch)
        _ = try fileManager.replaceItemAt(destinationFile, withItemAt: scratch)
        Privacy.lockDown(destinationFile)
    }

    public func adopt(stagedHome: URL, as destination: URL) throws {
        try Privacy.makeDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: stagedHome, to: destination)
        try Privacy.makeDirectory(destination)
        let credential = CodexEnvironment.credentialFile(in: destination)
        if fileManager.fileExists(atPath: credential.path) {
            Privacy.lockDown(credential)
        }
    }

    public func discard(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    private func read(_ codexHome: URL) throws -> [String: Any]? {
        let file = CodexEnvironment.credentialFile(in: codexHome)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
