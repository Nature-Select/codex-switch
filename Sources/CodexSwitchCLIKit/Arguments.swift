import Foundation

public struct Arguments {
    public private(set) var positionals: [String] = []
    private var flags: Set<String> = []
    private var options: [String: String] = [:]
    private var danglingOption: String?

    public static let valueOptions: Set<String> = ["label", "timeout", "sort", "threshold", "interval", "only"]

    private static let shorthand: [String: String] = [
        "h": "help",
        "y": "yes",
        "a": "all",
        "j": "json",
        "l": "label",
        "n": "label",
        "V": "version"
    ]

    public init(_ tokens: [String], valueOptions: Set<String> = Arguments.valueOptions) {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1

            guard token.hasPrefix("-"), token != "-", token != "--" else {
                positionals.append(token)
                continue
            }

            let body = token.hasPrefix("--") ? String(token.dropFirst(2)) : String(token.dropFirst())
            if let equals = body.firstIndex(of: "=") {
                options[Self.canonical(String(body[..<equals]))] = String(body[body.index(after: equals)...])
                continue
            }

            let name = Self.canonical(body)
            guard valueOptions.contains(name) else {
                flags.insert(name)
                continue
            }
            guard index < tokens.count else {
                danglingOption = name
                continue
            }
            options[name] = tokens[index]
            index += 1
        }
    }

    private static func canonical(_ name: String) -> String {
        shorthand[name] ?? name
    }

    public func flag(_ name: String) -> Bool { flags.contains(name) }
    public func value(_ name: String) -> String? { options[name] }
    public func number(_ name: String) -> Int? { options[name].flatMap(Int.init) }

    public mutating func dropFirstPositional() {
        if !positionals.isEmpty { positionals.removeFirst() }
    }

    public mutating func raise(_ name: String) {
        flags.insert(name)
    }

    public func check(allowing allowed: Set<String>) throws {
        if let danglingOption {
            throw CLIError("--\(danglingOption) needs a value.", code: 2)
        }
        let always: Set<String> = ["json", "no-color", "help"]
        let unknown = flags.union(options.keys).subtracting(allowed).subtracting(always).sorted()
        guard unknown.isEmpty else {
            throw CLIError("Unknown option\(unknown.count > 1 ? "s" : ""): " + unknown.map { "--\($0)" }.joined(separator: ", "), code: 2)
        }
    }
}

public struct CLIError: LocalizedError {
    public let message: String
    public let code: Int32

    public init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}
