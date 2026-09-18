import CodexSwitchCLIKit
import Darwin
import Foundation

// A dead app-server would otherwise take the CLI down mid-write.
signal(SIGPIPE, SIG_IGN)

let status = await Runner.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
