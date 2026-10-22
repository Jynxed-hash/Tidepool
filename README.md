# Tidepool

A macOS 26 menu bar app for Claude Code. It shows the 5-hour and weekly limits, when they reset, and which session is waiting on you.

The panel follows the Floating Needs-you mockup: light on the left, dark on the right, example data.

![Floating Needs-you mockup, light and dark, example data](mockups/glass-b.png)

Live screenshots replace that mockup after the first signed build. The HTML for the mockup is `mockups/glass-b.html`.

Tidepool is not affiliated with Anthropic. The 5-hour block estimate follows the behavior described by [ccusage](https://github.com/ryoppippi/ccusage) (MIT). This project does not copy that code.

## What is real, and what is an estimate

| What you see | Source | Kind |
|---|---|---|
| 5-hour, weekly all-models, and weekly Opus or Sonnet percents, plus reset times | `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token and `anthropic-beta: oauth-2025-04-20` | Server figure. The endpoint is undocumented. It is the one Claude Code's `/usage` command uses. Buckets can be null. |
| The same percents when that call fails | Status-line JSON `rate_limits.five_hour` and `rate_limits.seven_day` (`used_percentage`, `resets_at` as Unix seconds), written by the optional `cmb-hook statusline` wrapper | Server figure, relayed by Claude Code. Present for Pro and Max after the first API response. The panel says "From the status line". |
| Today's tokens and dollars, and the block burn rate in Settings | `~/.claude/projects/**/*.jsonl`, `message.usage`, deduped by message id plus request id | **Estimate.** List price from the [Claude API pricing page](https://platform.claude.com/docs/en/about-claude/pricing) as checked on 2026-10-22. Cache writes without a 5-minute / 1-hour split use the 5-minute rate. Unknown models omit the dollar amount. The footer uses ≈. |
| A 5-hour block with no server window | Floored hour of the first message, five hours long. A gap of more than five hours starts another block | **Estimate.** Anthropic's real window can differ. Rows are labeled `est.` |
| Needs you / Working / Idle, and "Waiting on permission: run …" | Notification (`permission_prompt`, `idle_prompt`, `agent_needs_input`), PermissionRequest, Stop, SessionStart, SessionEnd, and UserPromptSubmit hooks | From Claude Code. PermissionRequest is included because the Notification `message` is generic and `permission_prompt` waits about six seconds. The hook prints nothing to stdout, so it does not approve or deny the prompt. |
| The same states with `(est.)` | Last transcript role, only for sessions with no hook events | **Estimate.** |

Extra usage is shown only when the payload includes `extra_usage.utilization`. Community notes disagree on whether `used_credits` is dollars or cents, so Tidepool does not display that field.

The menu bar item is the template symbol `gauge.with.dots.needle.50percent` plus the 5-hour percent. It is drawn in system orange only while a session needs you. Settings can hide the percent or add the reset countdown.

## Install

Requires macOS 26.

Build from source:

```bash
git clone https://github.com/Jynxed-hash/Tidepool.git
cd Tidepool
swift build -c release --product Tidepool --product cmb-hook
swift run Tidepool
```

`swift run` shows a Dock icon. For a menu-bar-only app, wrap the binaries:

```bash
scripts/assemble-app.sh
open dist/Tidepool.app
```

Then open Tidepool and turn on **Claude Code hooks** in Settings. That copies `cmb-hook` into `~/Library/Application Support/Tidepool/`, backs up `~/.claude/settings.json` under `~/.claude/tidepool-backups/`, and merges hook entries. Running it again does not duplicate them. Turning the switch off removes only Tidepool's entries and restores a status line Tidepool replaced.

Tidepool reads the Claude Code token from the Keychain item `Claude Code-credentials` or from `~/.claude/.credentials.json`. It does not copy the token and it does not refresh it. If the token is expired, open Claude Code once and let it refresh.

### Signed DMG and Homebrew

Not done in this repository yet.

1. On a Mac with a Developer ID certificate, run `scripts/build-dmg.sh`, sign the app, then `NOTARY_KEYCHAIN_PROFILE=… scripts/notarize.sh`.
2. Attach `Tidepool-<version>.dmg` to a GitHub release.
3. Fill in the real `sha256` in `Casks/tidepool.rb` and copy that cask into [Jynxed-hash/homebrew-tap](https://github.com/Jynxed-hash/homebrew-tap).

After that, the install is:

```bash
brew install --cask jynxed-hash/tap/tidepool
```

`Casks/tidepool.rb` in this repo is a template. The checksum is a placeholder, so installing it today will fail.

## Privacy

Everything stays on this Mac except one request. When a Claude Code token is available, Tidepool sends it as `Authorization: Bearer` to `https://api.anthropic.com/api/oauth/usage` and nowhere else. There is no analytics.

The token is not written to Tidepool's support folder, the event log, or the log. Prompt text from `UserPromptSubmit` is discarded. Transcript parsing keeps usage, timestamps, cwd, git branch, role, and ids. A permission hook keeps the tool name and a short command or path, not the conversation.

## Other tools

Claude Code is the only provider that reads usage. On launch, Tidepool looks for install markers it can actually name:

- Claude Code: a `claude` binary, or `~/.claude`
- Cursor: `Cursor.app`, a `cursor` binary, or `~/Library/Application Support/Cursor`
- Codex: a `codex` binary, `~/.codex`, or `CODEX_HOME`
- Wispr Flow: `Wispr Flow.app`

Detected tools without a provider show as **coming soon**. Grok Bot has no documented on-disk marker, so it is not reported as installed just because Cursor is. See [ROADMAP.md](ROADMAP.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Develop

```bash
swift test
```

Tests cover the usage JSON, the status-line JSON, transcript dedupe, block boundaries, list prices, hook ingestion, the settings installer, and install detection. They do not call Anthropic.

GitHub Actions runs `swift test` and `swift build -c release` on `macos-26`. A Linux checkout can run `swift test` (the SwiftUI app is not part of the package there). It cannot compile the menu bar app.

## License

MIT. See [LICENSE](LICENSE).
