# AGENTS.md

## What This Is

`codex-switch` is a macOS command-line tool for keeping several Codex accounts on one machine and switching the active one.

- `Sources/CodexSwitchKit`: the domain — environment paths, credential handling, registry persistence, the Codex app-server client, quota parsing, desktop-app control, auto-switch planning
- `Sources/CodexSwitchCLIKit`: argument parsing, terminal rendering, and the commands themselves
- `Sources/CodexSwitchCLI`: the executable entry point
- `Sources/CodexSwitchSelfTest`: self-tests, no XCTest
- `scripts/install.sh`, `scripts/package.sh`: install from source, package a universal binary

## Stack

- Swift 5.9, SwiftPM, macOS 13+
- Foundation only — no third-party dependencies, no AppKit

## Rules

- Keep presentation in `CodexSwitchCLIKit` and behavior in `CodexSwitchKit`; the domain never prints.
- No new dependencies without a clear reason.
- Credentials stay local, per-account, `0700`/`0600`, written atomically. Never log them, never copy them anywhere but an account home, `CODEX_HOME`, or a file the user explicitly named — `export` is the only command that writes them elsewhere, and it says so.
- `export` / `import` move accounts between Macs. The bundle carries no absolute paths, and an import is matched by credential fingerprint, so re-importing is a no-op instead of a duplicate.
- Account rotation exists only as the opt-in `auto` command. It ships disabled, and `auto disable` must leave nothing running.
- Commands stay scriptable: honor `--json`, send errors to stderr, exit non-zero on failure (`2` usage, `130` cancelled).
- Never prompt when stdin is not a TTY or `--json` is set; require `--yes` instead.

## Things That Bite

- The desktop client is `/Applications/ChatGPT.app` with bundle id `com.openai.codex`. Identify it by bundle id — never by process or bundle name.
- While that app runs it also owns `~/.codex/auth.json`, so a switch without restarting it can be silently undone.
- Quitting it can raise its own confirmation sheet; the escalation in `DesktopApp.quit()` (AppleScript → SIGTERM → SIGKILL) is what keeps an unattended switch from stalling.
- Quota windows differ per plan. Match them by `durationMinutes`, never by position, and treat "no window reported" as unknown rather than zero.
- Several short-lived CLI runs can touch the registry at once. Mutations go through `RegistryStore`, which re-reads the file if it changed underneath.
- `CommandLine.arguments[0]` is what the launchd job will run, so `auto enable` must resolve it to an absolute path.

## Releasing

- `Version.current` in `Sources/CodexSwitchKit/AppServer.swift` is the single source of truth; the release workflow refuses a tag that disagrees with it.
- Tagging `v<version>` builds a universal binary, publishes it with checksums, and opens a PR that points the Homebrew formula at the new tarball. `main` requires PRs, so that bump is never pushed directly.
- `codex-switch update` reads the published release, so a release without the `codex-switch-macos-universal.tar.gz` asset breaks self-update.
- The formula bump lands after the release, so for a while `brew upgrade` has nothing to install and still exits 0. `update` reports the version it reads back from the binary, never the one it hoped for.

## Build And Test

```bash
swift build
swift run CodexSwitchSelfTest
./.build/debug/codex-switch --help
```

`CODEX_SWITCH_HOME` and `CODEX_HOME` relocate the state directory and the live Codex home — the safe way to exercise `adopt` / `use` / `forget` without touching real accounts:

```bash
export CODEX_SWITCH_HOME=/tmp/cs-sandbox/state CODEX_HOME=/tmp/cs-sandbox/codex
```

## Expectations

- Run the self-tests after any logic change; add one for anything a user could hit twice.
- Exercise failure paths, not just success: a sandboxed adopt → use → use-back round trip must leave every account's own credentials intact.
- `codex-switch use` restarts the desktop app by default; pass `--no-restart` while testing so a real session is not killed.
