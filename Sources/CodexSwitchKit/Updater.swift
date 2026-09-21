import CryptoKit
import Foundation

/// Self-update. A Homebrew install is upgraded through Homebrew, because
/// overwriting a Cellar binary behind brew's back leaves it out of sync with
/// its own metadata. Everything else is replaced in place.
public enum Updater {
    public static let repository = "Nature-Select/codex-switch"
    public static let assetName = "codex-switch-macos-universal.tar.gz"

    public struct Release {
        public var version: String
        public var tarball: URL
        public var checksum: URL?
        public var notesURL: URL?
    }

    public enum Installation {
        case homebrew(formula: String)
        case standalone(binary: URL)
    }

    public enum UpdateError: LocalizedError {
        case releaseUnavailable(String)
        case assetMissing
        case checksumMismatch
        case extractionFailed
        case notWritable(URL)

        public var errorDescription: String? {
            switch self {
            case let .releaseUnavailable(detail):
                return "Could not read the latest release: \(detail)"
            case .assetMissing:
                return "The latest release has no \(assetName) asset."
            case .checksumMismatch:
                return "The downloaded archive did not match its published checksum; nothing was changed."
            case .extractionFailed:
                return "The downloaded archive could not be unpacked."
            case let .notWritable(url):
                return "\(url.path) is not writable. Re-run with sudo, or reinstall with Homebrew."
            }
        }
    }

    public static func installation(of executable: URL) -> Installation {
        let path = executable.path
        // Homebrew symlinks <prefix>/bin/x at <prefix>/Cellar/x/<version>/bin/x;
        // either spelling means brew owns this copy.
        if path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Homebrew/")
            || (path.hasPrefix("/usr/local/") && FileManager.default.fileExists(atPath: "/usr/local/Homebrew")) {
            return .homebrew(formula: "codex-switch")
        }
        return .standalone(binary: executable)
    }

    /// What the installed binary answers now.
    ///
    /// `brew upgrade` exits 0 when it had nothing to do, which is exactly what
    /// happens in the window between a release being published and its formula
    /// bump landing in the tap — so the exit status alone cannot tell us
    /// whether anything was installed. Asking the binary can.
    public static func installedVersion(of executable: URL) -> String? {
        guard let output = Shell.capture(executable.path, ["version"]) else { return nil }
        guard let version = output.split(whereSeparator: \.isWhitespace).last.map(String.init),
              version.first?.isNumber == true
        else {
            return nil
        }
        return version
    }

    public static func latest() async throws -> Release {
        do {
            return try await latestFromAPI()
        } catch {
            // The API allows 60 anonymous calls an hour per address, and a
            // shared address burns through that. The web redirect is not
            // rate-limited the same way and still names the release.
            return try await latestFromRedirect()
        }
    }

    /// `/releases/latest` redirects to `/releases/tag/vX.Y.Z`, and release asset
    /// URLs are predictable, so this needs no API budget at all.
    static func latestFromRedirect() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.setValue("codex-switch/\(Version.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let landed = http.url
        else {
            throw UpdateError.releaseUnavailable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let tag = landed.lastPathComponent
        guard tag.hasPrefix("v"), tag.contains(".") else {
            throw UpdateError.releaseUnavailable("could not read a version from \(landed.absoluteString)")
        }

        let base = "https://github.com/\(repository)/releases/download/\(tag)"
        return Release(
            version: String(tag.dropFirst()),
            tarball: URL(string: "\(base)/\(assetName)")!,
            checksum: URL(string: "\(base)/\(assetName).sha256"),
            notesURL: landed
        )
    }

    static func latestFromAPI() async throws -> Release {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-switch/\(Version.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let environment = ProcessInfo.processInfo.environment
        if let token = environment["GITHUB_TOKEN"] ?? environment["GH_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.releaseUnavailable(code == 403 ? "HTTP 403 (rate limited)" : "HTTP \(code)")
        }
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = payload["tag_name"] as? String,
            let assets = payload["assets"] as? [[String: Any]]
        else {
            throw UpdateError.releaseUnavailable("unexpected payload")
        }

        func asset(named name: String) -> URL? {
            assets
                .first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }

        guard let tarball = asset(named: assetName) else {
            throw UpdateError.assetMissing
        }

        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            tarball: tarball,
            checksum: asset(named: "\(assetName).sha256"),
            notesURL: (payload["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Semantic-ish ordering, tolerant of missing components.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(candidate)
        let right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Downloads, verifies, and swaps the binary. Returns where it landed.
    public static func install(_ release: Release, over binary: URL) async throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switch-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let (downloaded, response) = try await URLSession.shared.download(from: release.tarball)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.releaseUnavailable("download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let archive = workspace.appendingPathComponent(assetName)
        try FileManager.default.moveItem(at: downloaded, to: archive)

        if let checksumURL = release.checksum {
            let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
            let expected = String(data: checksumData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let actual = SHA256.hash(data: try Data(contentsOf: archive))
                .map { String(format: "%02x", $0) }
                .joined()
            guard let expected, expected.hasPrefix(actual) || actual == expected else {
                throw UpdateError.checksumMismatch
            }
        }

        guard Shell.status("/usr/bin/tar", ["xzf", archive.path, "-C", workspace.path]) == 0 else {
            throw UpdateError.extractionFailed
        }
        let unpacked = workspace.appendingPathComponent("codex-switch")
        guard FileManager.default.isExecutableFile(atPath: unpacked.path) else {
            throw UpdateError.extractionFailed
        }

        // Replace through the same directory so the swap is a rename, not a copy
        // across devices, and so a half-written binary is never observable.
        let destination = binary.resolvingSymlinksInPath()
        let directory = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw UpdateError.notWritable(directory)
        }

        let staged = directory.appendingPathComponent(".codex-switch.update-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: unpacked, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        return destination
    }
}
