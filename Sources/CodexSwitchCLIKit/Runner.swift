import CodexSwitchKit
import Foundation

public enum Runner {
    public static func run(_ input: [String]) async -> Int32 {
        var tokens = input
        let command = tokens.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        if command != nil {
            tokens.removeFirst()
        }

        let arguments = Arguments(tokens)
        let json = arguments.flag("json")
        let environment = ProcessInfo.processInfo.environment
        Style.colored = !arguments.flag("no-color")
            && environment["NO_COLOR"] == nil
            && (isatty(fileno(stdout)) == 1 || environment["CLICOLOR_FORCE"] != nil)

        if command == "version" || arguments.flag("version") {
            Term.say("codex-switch \(Version.current)")
            return 0
        }
        if command == nil || command == "help" || arguments.flag("help") {
            Help.show(command == "help" ? arguments.positionals.first : command)
            return 0
        }

        do {
            switch command {
            case "status", "st":
                try await Commands.status(arguments, json: json)
            case "list", "ls":
                try await Commands.list(arguments, json: json)
            case "use", "switch":
                try await Commands.use(arguments, json: json)
            case "add", "login":
                try await Commands.add(arguments, json: json)
            case "adopt", "import":
                try await Commands.adopt(arguments, json: json)
            case "auto":
                try await Commands.auto(arguments, json: json)
            case "refresh":
                try await Commands.refresh(arguments, json: json)
            case "rename":
                try await Commands.rename(arguments, json: json)
            case "forget", "remove", "rm", "delete":
                try await Commands.forget(arguments, json: json)
            case "repair":
                try await Commands.repair(arguments, json: json)
            case "migrate":
                try await Commands.migrate(arguments, json: json)
            case "paths", "path", "dir":
                try await Commands.paths(arguments, json: json)
            default:
                Term.warn("Unknown command: \(command ?? "")")
                Term.warn("`codex-switch help` lists what there is.")
                return 2
            }
            return 0
        } catch let error as CLIError {
            Term.warn(Style.red("error: ") + error.message)
            return error.code
        } catch let error as CodexSwitchError {
            Term.warn(Style.red("error: ") + (error.errorDescription ?? "\(error)"))
            return 1
        } catch {
            Term.warn(Style.red("error: ") + error.localizedDescription)
            return 1
        }
    }
}
