import CodexSwitchKit
import Foundation

extension Commands {
    struct ExportPayload: Encodable {
        var file: String
        var exportedAt: Date
        var accounts: [ExportedPayload]
        var skipped: [SkippedPayload]
    }

    struct ImportPayload: Encodable {
        var file: String
        var exportedAt: Date
        var imported: [AccountPayload]
        var replaced: [AccountPayload]
        var skipped: [SkippedPayload]
    }

    /// An exported entry is not a local account — it has no home on this Mac yet.
    struct ExportedPayload: Encodable {
        var id: String
        var label: String
        var email: String?
        var plan: String?
        var needsSignIn: Bool?
    }

    struct SkippedPayload: Encodable {
        var label: String
        var reason: String
    }

    static func export(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["only", "force"])
        guard let destination = arguments.positionals.first else {
            throw CLIError("Usage: codex-switch export <file> [--only <accounts>]  ·  `-` writes to stdout.", code: 2)
        }

        let manager = try AccountManager()
        let accounts = manager.accounts
        guard !accounts.isEmpty else {
            throw CLIError("No accounts saved yet — nothing to export.")
        }

        let selected: [StoredAccount]
        if let only = arguments.value("only") {
            let references = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !references.isEmpty else {
                throw CLIError("--only needs at least one account.", code: 2)
            }
            var picked: [StoredAccount] = []
            for reference in references {
                let account = try Lookup.find(reference, in: accounts)
                if !picked.contains(where: { $0.id == account.id }) { picked.append(account) }
            }
            selected = picked
        } else {
            selected = accounts
        }

        let outcome = AccountTransfer.export(selected, from: manager)
        guard !outcome.bundle.accounts.isEmpty else {
            throw CLIError("None of those accounts has readable credentials — nothing was written.")
        }

        let toStdout = destination == "-"
        let file = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath)

        if toStdout {
            FileHandle.standardOutput.write(try AccountTransfer.encode(outcome.bundle))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            if FileManager.default.fileExists(atPath: file.path), !arguments.flag("force") {
                throw CLIError("\(file.path) already exists. Pass --force to overwrite it.", code: 2)
            }
            try AccountTransfer.write(outcome.bundle, to: file)
        }

        // With `-` the bundle already owns stdout, so the summary goes to stderr
        // whatever --json says: one machine-readable thing per stream.
        if json, !toStdout {
            try Term.emit(ExportPayload(
                file: file.path,
                exportedAt: outcome.bundle.exportedAt,
                accounts: outcome.bundle.accounts.map {
                    ExportedPayload(id: $0.id, label: $0.label, email: $0.email, plan: $0.plan, needsSignIn: $0.needsSignIn)
                },
                skipped: outcome.skipped.map { SkippedPayload(label: $0.account.label, reason: $0.reason) }
            ))
            return
        }

        let count = outcome.bundle.accounts.count
        let headline = Style.green("✓") + " Exported \(count) account\(count == 1 ? "" : "s")"
        let say: (String) -> Void = toStdout ? Term.warn : Term.say

        if toStdout {
            say(headline + " to stdout")
        } else {
            say(headline + " to " + Style.bold(file.path))
            say(Style.faint("  The file holds live sign-ins, owner-readable only — move it over scp, not a chat app."))
            say(Style.faint("  On the other Mac: `codex-switch import \(file.lastPathComponent)`"))
        }
        for skipped in outcome.skipped {
            say(Style.yellow("!") + " Skipped " + skipped.account.label + Style.faint("  ·  \(skipped.reason)"))
        }
    }

    static func importAccounts(_ arguments: Arguments, json: Bool) async throws {
        try arguments.check(allowing: ["replace"])
        guard let source = arguments.positionals.first else {
            throw CLIError(
                "Usage: codex-switch import <file> [--replace]  ·  `-` reads stdin."
                    + " (`codex-switch adopt` is what saves the account you are signed in as.)",
                code: 2
            )
        }

        let manager = try AccountManager()
        let bundle: AccountTransfer.Bundle
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            bundle = try AccountTransfer.decode(data)
        } else {
            bundle = try AccountTransfer.read(URL(fileURLWithPath: (source as NSString).expandingTildeInPath))
        }

        let outcome = try AccountTransfer.restore(bundle, into: manager, replacingKnown: arguments.flag("replace"))

        if json {
            try Term.emit(ImportPayload(
                file: source,
                exportedAt: bundle.exportedAt,
                imported: outcome.added.map { AccountPayload($0, isActive: false) },
                replaced: outcome.replaced.map { AccountPayload($0, isActive: false) },
                skipped: outcome.skipped.map { SkippedPayload(label: $0.label, reason: $0.reason) }
            ))
            return
        }

        for account in outcome.added {
            Term.say(Style.green("✓") + " Imported " + Style.bold(account.label) + Style.faint("  ·  \(Present.shortID(account.id))"))
        }
        let live = manager.accountOwningLiveHome()
        for account in outcome.replaced {
            Term.say(Style.green("✓") + " Replaced credentials for " + Style.bold(account.label))
            guard account.id == live?.id else { continue }
            Term.say(Style.faint("  This is the account in use, so ~/.codex now holds the imported sign-in."))
            if DesktopApp.isRunning {
                Term.say(Style.yellow("  Restart the ChatGPT desktop app to pick it up."))
            }
        }
        for skipped in outcome.skipped {
            Term.say(Style.faint("· Skipped \(skipped.label) — \(skipped.reason)"))
        }

        if outcome.added.isEmpty, outcome.replaced.isEmpty {
            Term.say("Nothing new to import.")
            if !outcome.skipped.isEmpty, !arguments.flag("replace") {
                Term.say(Style.faint("`--replace` overwrites the stored credentials of accounts already saved here."))
            }
        } else {
            Term.say(Style.faint("Quota numbers came from the export — `codex-switch refresh --all` brings them up to date."))
        }
    }
}
