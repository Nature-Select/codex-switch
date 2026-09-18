import Foundation

enum Help {
    static func show(_ topic: String?) {
        switch topic {
        case "status":
            page("codex-switch status [--offline] [--json]", [
                "Show which account Codex is signed in as, what is left of its quota,",
                "and when that quota resets.",
                "",
                "  --offline   Use the stored numbers instead of asking Codex."
            ])
        case "list", "ls":
            page("codex-switch list [--sort name|quota|reset|checked] [--offline] [--json]", [
                "List saved accounts. The active one is marked ●.",
                "The leading number is a stable reference other commands accept; it keeps",
                "pointing at the same account no matter how the view is sorted.",
                "",
                "  --sort quota   Most quota left first — what to switch to.",
                "  --sort reset   Soonest reset first — what frees up next."
            ])
        case "use", "switch":
            page("codex-switch use <account> [--yes] [--no-restart]", [
                "Make an account the one Codex uses. The credentials in ~/.codex are",
                "parked back with their own account first, then the target's are swapped in.",
                "",
                "  <account>      List number, label, email, or id. Omit to pick from a list.",
                "  --yes          Do not ask when the desktop app or a codex session is running.",
                "  --no-restart   Leave the ChatGPT desktop app alone (it keeps the old account).",
                "",
                "While the desktop app runs it owns ~/.codex too, so a switch without a",
                "restart can be undone by it. Restarting is the default for that reason."
            ])
        case "add", "login":
            page("codex-switch add [--switch] [--label <name>] [--timeout <seconds>] [--no-open]", [
                "Sign in to another ChatGPT account and save it in its own home.",
                "The sign-in never touches ~/.codex unless --switch is passed.",
                "",
                "  --switch     Make it the active account once it is added.",
                "  --label      Label to show (defaults to the account email).",
                "  --timeout    Seconds to wait for the browser sign-in (default 300).",
                "  --no-open    Do not open the verification page automatically."
            ])
        case "adopt", "import":
            page("codex-switch adopt [--label <name>]", [
                "Save the account you are already signed in as, so it can be switched",
                "back to later."
            ])
        case "auto":
            page("codex-switch auto [status] | enable [options] | disable", [
                "Switch away from the account in use once its quota runs low.",
                "Off until you enable it.",
                "",
                "  enable --threshold 5     Switch below 5% left (default 5).",
                "  enable --interval 300    How often to check, in seconds (minimum 60).",
                "  enable --no-restart      Do not restart the desktop app after switching.",
                "  disable                  Stop, and remove the background job.",
                "",
                "`enable` installs a background job (launchd) that does the checking, so",
                "there is nothing to keep open in a terminal. It logs every switch to",
                "~/Library/Logs/codex-switch/auto.log.",
                "",
                "Quota is judged on the tightest window the account reports, and the",
                "target must itself be at or above the threshold."
            ])
        case "refresh":
            page("codex-switch refresh [<account>] [--all]", [
                "Ask Codex for fresh quota numbers and store them.",
                "With no argument it refreshes the account in use; --all sweeps every",
                "account, several at a time."
            ])
        case "reauth", "relogin":
            page("codex-switch reauth <account> [--switch] [--timeout <seconds>] [--no-open]", [
                "Sign in again to an account whose stored login was revoked, keeping",
                "its label, id and history. An ordinary expiry does not need this —",
                "Codex renews those on its own; a revoked login cannot be renewed.",
                "",
                "If the browser sign-in produces a different account, nothing is",
                "changed: `codex-switch add` is how a new account gets saved.",
                "",
                "  --switch   Make it the active account once it is restored."
            ])
        case "rename":
            page("codex-switch rename <account> <new-label>", [
                "Change an account's label. Credentials are untouched."
            ])
        case "forget", "remove", "rm":
            page("codex-switch forget <account> [--yes] [--keep-credentials]", [
                "Drop an account from the registry.",
                "",
                "  --yes                Skip the confirmation (required when not on a TTY).",
                "  --keep-credentials   Leave its home directory on disk."
            ])
        case "repair":
            page("codex-switch repair [--prune]", [
                "Re-register account directories that exist on disk but are missing from",
                "the registry. Credentials are read from the directory, so no sign-in is",
                "needed.",
                "",
                "  --prune   Also delete account directories that hold no credentials."
            ])
        case "migrate":
            page("codex-switch migrate [<directory>]", [
                "Import accounts from the menu-bar app this CLI replaces.",
                "Credentials are copied, not moved, so the old directory stays intact."
            ])
        case "update", "upgrade":
            page("codex-switch update [--check] [--yes]", [
                "Update codex-switch itself from the latest GitHub release.",
                "",
                "  --check   Only report whether an update exists.",
                "  --yes     Do not ask before replacing the binary.",
                "",
                "A Homebrew install is upgraded through `brew upgrade`; a standalone",
                "binary is replaced in place after its published checksum is verified."
            ])
        case "paths":
            page("codex-switch paths [--open] [--json]", [
                "Print where the registry, account homes, and logs live."
            ])
        default:
            overview()
        }
    }

    private static func overview() {
        Term.say(Style.bold("codex-switch") + " — keep several Codex accounts side by side and switch between them")
        Term.say()
        Term.say(Style.bold("USAGE"))
        Term.say("  codex-switch <command> [options]")
        Term.say()
        Term.say(Style.bold("COMMANDS"))
        for (name, summary) in commands {
            Term.say("  " + Layout.padRight(name, 24) + summary)
        }
        Term.say()
        Term.say(Style.bold("GLOBAL OPTIONS"))
        Term.say("  " + Layout.padRight("--json", 24) + "Machine-readable output")
        Term.say("  " + Layout.padRight("--no-color", 24) + "Disable colors (honors NO_COLOR / CLICOLOR_FORCE)")
        Term.say("  " + Layout.padRight("-h, --help", 24) + "Help; `codex-switch help <command>` for details")
        Term.say()
        Term.say(Style.faint("Accounts can be named by list number, label, email, or id."))
        Term.say(Style.faint("Credentials never leave this Mac: each account keeps its own isolated Codex home."))
    }

    private static let commands: [(String, String)] = [
        ("status", "Account in use, quota left, and when it resets"),
        ("list", "List saved accounts"),
        ("use <account>", "Switch the account Codex uses"),
        ("add", "Sign in to another account and save it"),
        ("adopt", "Save the account you are signed in as"),
        ("auto", "Switch automatically when quota runs low"),
        ("refresh [<account>]", "Ask Codex for fresh quota numbers"),
        ("reauth <account>", "Sign in again to an account whose login was revoked"),
        ("rename <account>", "Change an account's label"),
        ("forget <account>", "Drop an account from the registry"),
        ("repair", "Re-register account directories missing from the registry"),
        ("migrate", "Import accounts from the old menu-bar app"),
        ("update", "Update codex-switch itself"),
        ("paths", "Show where everything is stored"),
        ("version", "Print the version")
    ]

    private static func page(_ usage: String, _ lines: [String]) {
        Term.say(Style.bold("USAGE"))
        Term.say("  " + usage)
        Term.say()
        for line in lines {
            Term.say(line.isEmpty ? "" : "  " + line)
        }
    }
}
