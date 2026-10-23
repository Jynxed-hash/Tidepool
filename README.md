# Tidepool

A macOS 26 menu bar app for AI usage limits. Claude Code is the session view: the 5-hour and weekly limits, when they reset, and which session is waiting on you. Codex, OpenRouter, Gemini CLI, OpenCode, z.ai, and DeepSeek add the meters their own docs or clients actually expose. Cursor and GitHub Copilot are unofficial: community endpoints, labeled Unofficial, and off when Settings → Unofficial providers is off.

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

The menu bar item is the template symbol `gauge.with.dots.needle.50percent` plus a percent: the 5-hour window when the selected provider has one, otherwise the first usage row. Cursor's menu percent is Included. GitHub Copilot's is Premium. It is drawn in system orange only while a session needs you. Settings can hide the percent or add the reset countdown. The countdown stays on the 5-hour window.

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

Tidepool does not run analytics. A credential is read into memory and sent only to that product's own usage host:

| Credential | Sent to |
|---|---|
| Claude Code OAuth token | `https://api.anthropic.com/api/oauth/usage` |
| Codex, through the local `codex app-server` process | no extra host; Codex speaks for itself |
| `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1/key` |
| Gemini CLI `access_token` from `~/.gemini/oauth_creds.json`, and only while `expiry_date` is still in the future | `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` and `:retrieveUserQuota` |
| `OPENCODE_API_KEY` | `https://opencode.ai/zen/go/v1/usage` |
| `ZAI_API_KEY` | `https://api.z.ai/api/monitor/usage/quota/limit` |
| `ZHIPUAI_API_KEY`, only when `ZAI_API_KEY` is unset | `https://open.bigmodel.cn/api/monitor/usage/quota/limit` |
| `DEEPSEEK_API_KEY` | `https://api.deepseek.com/user/balance` |
| Cursor `cursorAuth/accessToken` from `state.vscdb`, read-only. The refresh token is not read. | `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` |
| GitHub `oauth_token` from `~/.config/github-copilot/apps.json` or `hosts.json`, or the `github.com` block of `~/.config/gh/hosts.yml` (or `GH_CONFIG_DIR`). The keychain is not read. | `GET https://api.github.com/copilot_internal/user` |

Tokens and keys are not written to Tidepool's support folder. Tidepool does not refresh OAuth tokens. Prompt text from `UserPromptSubmit` is discarded. Transcript parsing keeps usage, timestamps, cwd, git branch, role, and ids. A permission hook keeps the tool name and a short command or path, not the conversation.

## Other tools

The header switches among providers that are actually installed. A selected unofficial provider shows a monochrome **Unofficial** badge. Wispr Flow, Devin Desktop, Kiro, Amp, Aider, Factory, and the ChatGPT app still show as **coming soon** when detected. See [ROADMAP.md](ROADMAP.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

### Codex

| What you see | Source | Kind |
|---|---|---|
| 5-hour, weekly, or other windows, named from `windowDurationMins` (300 minutes is the 5-hour row, 10080 is weekly) | `codex app-server` JSON-RPC `account/rateLimits/read` after `initialize` / `initialized` | Server figure. ChatGPT auth inside Codex. Tidepool does not call `account/read`, log in, or redeem a reset. |
| The same windows when app-server does not answer | Newest `token_count` event in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (`used_percent`, `window_minutes`, `resets_at`) | Server figure Codex already wrote down. The panel says it came from the session file. |
| Today's tokens | `account/usage/read` `dailyUsageBuckets` for the local calendar day | Server figure. No dollar amount. |
| Needs you | `thread/list` status `active` with `activeFlags` containing `waitingOnApproval` | From Codex, while app-server is reachable. The waiting line does not include the command. Thread previews are not shown. |
| Working / Idle with `(est.)` | Last persisted `task_started` / `turn_started` or `task_complete` / `turn_complete` / `turn_aborted` in a rollout from the last 12 hours | **Estimate.** Approval requests are not stored in the rollout, so a session file alone never becomes Needs you. |

`/status` is an interactive TUI command. It has no machine-readable contract, so Tidepool does not scrape it.

### Grok Bot

Detection is the app the install guide tells you to drag to Applications: `Grok Bot.app`. Cursor being installed does not count. The weekly pool is shown in Grok Bot under Settings → Usage & Billing and at grok.com/dashboard. No supported local file or API exposes that percentage, or which conversation is waiting on approval. The panel says so and does not draw a bar. Settings labels the tool **Limited data**.

### OpenRouter

| What you see | Source | Kind |
|---|---|---|
| Key limit percent, from `limit` and `limit_remaining` (or `usage` when remaining is absent) | `GET https://openrouter.ai/api/v1/key` | Server dollars. The percent is that division. A null `limit` draws no bar. |
| Budget percent, from `effective_budget.spend_usd` / `limit_usd`, with `resets_at` | Same response | Server dollars. |
| Free models today, from `free_model_daily_requests.used` / `limit` | Same response | Server counts. |
| Today, dollars only | `usage_daily` | Server dollars for the current UTC day. Not a token count. |

The key is `OPENROUTER_API_KEY` ([install](https://openrouter.ai/docs/install)). Tidepool does not copy it.

### Gemini CLI

| What you see | Source | Kind |
|---|---|---|
| One row per model, used percent `100 * (1 - remainingFraction)` | `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` after `loadCodeAssist` returns `cloudaicompanionProject` | Server fraction, from the [Gemini CLI client](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts). Several buckets for one model keep the lowest remaining fraction. |
| Nothing, with a notice | `~/.gemini/oauth_creds.json` `expiry_date` already passed, or no `access_token` | Tidepool does not refresh the token and does not read `refresh_token`. |

### OpenCode

| What you see | Source | Kind |
|---|---|---|
| Rolling, weekly, and monthly percents, plus `resetsAt` | `GET https://opencode.ai/zen/go/v1/usage` | Server percent. The rolling row stays "Rolling" because the payload has no duration. |

The key is `OPENCODE_API_KEY` ([Pi harness](https://opencode.ai/v2/docs/console/harnesses/pi/)). `auth.json` is not parsed.

### z.ai

| What you see | Source | Kind |
|---|---|---|
| 5-hour, weekly, and monthly tool-call percents, plus `nextResetTime` | `GET /api/monitor/usage/quota/limit` on `api.z.ai` or `open.bigmodel.cn` | `percentage` is the server figure used by OpenUsage and CodexBar. Rows with another `unit` are skipped. This path is not in Z.AI's public API reference. |

`ZAI_API_KEY` is the name in the [Z.AI OpenAI guide](https://docs.z.ai/guides/develop/openai/python) and is sent only to `api.z.ai`. `ZHIPUAI_API_KEY` is sent only to `open.bigmodel.cn`, and only when the global key is unset.

### DeepSeek

| What you see | Source | Kind |
|---|---|---|
| Balance text, and whether it is enough for API calls | `GET https://api.deepseek.com/user/balance` | Server strings: `is_available`, `total_balance`, `granted_balance`, `topped_up_balance`, `currency`. No percent, because the API publishes no cap. |

### Cursor (Unofficial)

| What you see | Source | Kind |
|---|---|---|
| Included percent | `includedSpend / limit` on `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`. Both fields are cents. | Server cents, divided. This is the figure Cursor's included-usage sentence is described as using. |
| Total and Auto percents | `planUsage.totalPercentUsed` and `autoPercentUsed` on the same response | Server percents. They are not the same denominator as Included. |
| On-demand and Team pool, only when that limit is greater than zero | `spendLimitUsage.individualUsed / individualLimit` and `pooledUsed / pooledLimit` | Server cents, divided. |
| Reset | `billingCycleEnd`, unix milliseconds | Server timestamp. No countdown; it is a billing period. |

`apiPercentUsed` is not shown. It can disagree with Included on the same payload. Nothing here is an estimate. The access token is a read-only sqlite query of `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`. Tidepool does not read `cursorAuth/refreshToken`, does not write the database, and does not call the token endpoint. A body with none of Included, Total, or Auto becomes **Limited data**. Settings → Unofficial providers turns the call off.

### GitHub Copilot (Unofficial)

| What you see | Source | Kind |
|---|---|---|
| Premium, Chat, and Completions used percents | `GET https://api.github.com/copilot_internal/user` `quota_snapshots.*.percent_remaining` | Server remaining percent. The bar is `100 - percent_remaining`. |
| The same rows when `percent_remaining` is absent | `entitlement` and `remaining` on that snapshot, when `entitlement` is greater than zero | Server counts, divided. |
| Chat and Completions on the free tier | `limited_user_quotas` as the remaining count and `monthly_quotas` as the cap, and only when both exist for that key | Server counts, divided. |
| Reset | `quota_reset_date_utc`, `quota_reset_date`, a non-zero `quota_reset_at`, or `limited_user_reset_date` | Server timestamp. |

`unlimited: true` and `entitlement: -1` draw no bar. A response with no `quota_snapshots`, `limited_user_quotas`, or `monthly_quotas` becomes **Limited data**. The token comes from the Copilot editor config or the `github.com` block of gh's `hosts.yml`. Tidepool does not read the keychain, does not run `gh auth token`, and does not refresh the token. Org billing is not called. Settings → Unofficial providers turns the call off.

## Develop

```bash
swift test
```

Tests cover the usage JSON, the status-line JSON, transcript dedupe, block boundaries, list prices, hook ingestion, the settings installer, install detection, and the unofficial Cursor and Copilot fixtures. They do not call Anthropic, Cursor, or GitHub.

GitHub Actions runs `swift test` and `swift build -c release` on `macos-26`. A Linux checkout can run `swift test` (the SwiftUI app is not part of the package there). It cannot compile the menu bar app.

## License

MIT. See [LICENSE](LICENSE).
