import Foundation

/// Locates the `codex` binary. The desktop app bundles one, Homebrew and the
/// standalone installer put one on PATH; a GUI-launched process has a minimal
/// PATH, so the bundled copies are checked directly.
public enum CodexBinary {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL? {
        candidates(environment: environment, home: home)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func candidates(environment: [String: String], home: String) -> [URL] {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        var result: [URL] = []

        for bundle in ["/Applications/ChatGPT.app", "/Applications/Codex.app"] {
            result.append(URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources/codex"))
        }
        for bundle in ["Applications/ChatGPT.app", "Applications/Codex.app"] {
            result.append(homeURL.appendingPathComponent(bundle).appendingPathComponent("Contents/Resources/codex"))
        }
        result.append(homeURL.appendingPathComponent(".codex/packages/standalone/current/bin/codex"))
        result.append(homeURL.appendingPathComponent(".local/bin/codex"))

        let searchPath = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seenDirectories = Set<String>()
        for directory in searchPath + fallbacks where seenDirectories.insert(directory).inserted {
            result.append(URL(fileURLWithPath: directory).appendingPathComponent("codex"))
        }

        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }
}

/// One `codex app-server` child process, spoken to over newline-delimited
/// JSON-RPC on stdio. A session is bound to a single `CODEX_HOME`, which is how
/// a parked account can be queried without becoming the active one.
public final class AppServerSession: @unchecked Sendable {
    public typealias Reply = [String: Any]

    private let codexHome: URL
    private let binary: URL
    private let queue = DispatchQueue(label: "codex-switch.app-server")
    private var child: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Reply, Error>] = [:]

    public var timeout: TimeInterval = 30
    public var onNotification: ((String, Reply?) -> Void)?

    public init(codexHome: URL, binary: URL? = CodexBinary.locate()) throws {
        guard let binary else { throw CodexSwitchError.codexBinaryMissing }
        self.codexHome = codexHome
        self.binary = binary
    }

    deinit {
        shutdown()
    }

    public static func withSession<T>(
        codexHome: URL,
        _ body: (AppServerSession) async throws -> T
    ) async throws -> T {
        let session = try AppServerSession(codexHome: codexHome)
        defer { session.shutdown() }
        try await session.handshake()
        return try await body(session)
    }

    public func handshake() async throws {
        _ = try await send(
            "initialize",
            [
                "clientInfo": ["name": "codex-switch", "title": "codex-switch", "version": Version.current],
                "capabilities": ["experimentalApi": true, "optOutNotificationMethods": []]
            ]
        )
    }

    public func shutdown() {
        queue.sync {
            stdout?.fileHandleForReading.readabilityHandler = nil
            stderr?.fileHandleForReading.readabilityHandler = nil
        }
        try? stdin?.fileHandleForWriting.close()
        if let child, child.isRunning {
            child.terminate()
        }
        child = nil
        stdin = nil
        stdout = nil
        stderr = nil
    }

    public func send(_ method: String, _ params: Reply? = nil) async throws -> Reply {
        try launchIfNeeded()

        let id = queue.sync { () -> Int in
            defer { nextID += 1 }
            return nextID
        }

        var message: Reply = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params {
            message["params"] = params
        }
        var line = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8) ?? ""
        line.append("\n")

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.waiting[id] = continuation
                self.stdin?.fileHandleForWriting.write(Data(line.utf8))
                self.queue.asyncAfter(deadline: .now() + self.timeout) {
                    self.waiting.removeValue(forKey: id)?.resume(throwing: CodexSwitchError.timedOut)
                }
            }
        }
    }

    private func launchIfNeeded() throws {
        guard child == nil else { return }

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        child.executableURL = binary
        child.arguments = ["app-server", "--listen", "stdio://", "--disable", "plugins"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        child.environment = environment

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ingest(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        child.terminationHandler = { [weak self] _ in
            self?.failAllWaiting(with: CodexSwitchError.appServerGone)
        }

        try child.run()
        self.child = child
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    private func ingest(_ chunk: Data) {
        queue.async {
            self.buffer.append(chunk)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<newline)
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                self.dispatch(line)
            }
        }
    }

    private func dispatch(_ line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? Reply
        else {
            return
        }

        if let id = object["id"] as? Int {
            let continuation = waiting.removeValue(forKey: id)
            if let failure = object["error"] as? Reply {
                let message = failure["message"] as? String ?? "The Codex app-server rejected the request."
                continuation?.resume(throwing: CodexSwitchError.appServerFailed(message))
            } else {
                continuation?.resume(returning: object["result"] as? Reply ?? [:])
            }
            return
        }

        if let method = object["method"] as? String {
            onNotification?(method, object["params"] as? Reply)
        }
    }

    private func failAllWaiting(with error: Error) {
        queue.async {
            let pending = self.waiting
            self.waiting.removeAll()
            for (_, continuation) in pending {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum Version {
    public static let current = "1.0.0"
}
