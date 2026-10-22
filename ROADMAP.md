# Roadmap

v1 reads Claude Code only. The provider protocol is in `ProviderKit`: a tool exposes usage windows (percent, reset, origin), sessions, a needs-attention state, and an estimate. `ToolDetector` only reports an install when a cited marker is present. This file is what a later provider is allowed to rely on. Where a number is not in a public document, it stays unknown.

Checked 2026-10-22.

## Claude Code (shipped)

Server windows come from `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20` and the Claude Code OAuth access token. The body uses `five_hour`, `seven_day`, `seven_day_opus`, and `seven_day_sonnet`, each `{ utilization, resets_at }` or null, plus optional `extra_usage`. Anthropic does not document this route. The same shape is described by [claudeops](https://github.com/FullFran/claudeops-tui/blob/main/docs/oauth-usage-endpoint.md), [cc-usage](https://github.com/yyongpil/cc-usage), and [Claude Code issue 63659](https://github.com/anthropics/claude-code/issues/63659). [Pacebar](https://pacebar.io/docs/providers/claude) also mentions `seven_day_omelette` and treats extra-usage credits as cents. claudeops shows a `utilization` field and dollar-like credit numbers. Tidepool displays `utilization` only.

The official fallback is the [status line](https://code.claude.com/docs/en/statusline): `rate_limits.five_hour` and `rate_limits.seven_day` with `used_percentage` and `resets_at` (Unix seconds). It is omitted until the first API response, and a window can be absent. There is no documented per-model weekly field on the status line.

Session state uses the [hooks reference](https://code.claude.com/docs/en/hooks):

- `Notification` matchers include `permission_prompt`, `idle_prompt`, and `agent_needs_input`. Input adds `message`, `title`, and `notification_type`. `permission_prompt` waits about six seconds in a terminal.
- `PermissionRequest` carries `tool_name` and `tool_input` at the moment a prompt is shown. A hook that prints nothing and exits 0 does not grant permission.
- `Stop` carries `last_assistant_message` and `background_tasks`. Tidepool stores the task count, not the message text.
- `SessionStart`, `SessionEnd` (`reason`), and `UserPromptSubmit` (`prompt`, which Tidepool drops) mark working and ended sessions.

The token is read from `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`, `expiresAt` in milliseconds when the number is ≥ 1e11). That file layout is described in the claudeops note above, not in Claude's public docs. The Keychain item `Claude Code-credentials` is the location [cc-usage](https://github.com/yyongpil/cc-usage) reads with `security find-generic-password -s "Claude Code-credentials"`. Tidepool never calls the refresh endpoint.

List prices for the footer are the public [pricing table](https://platform.claude.com/docs/en/about-claude/pricing) (rate card effective 2026-10-07). They are not the user's plan price.

## Cursor (detected, not implemented)

**How to tell it is installed.** The Mac app bundle is `Cursor.app`, and the documented shell command is `cursor`. OpenUsage records the macOS user-data directory as `~/Library/Application Support/Cursor` ([OpenUsage: Cursor](https://openusage.sh/docs/providers/cursor/)). Tidepool treats any one of those as detection. It does not read the directory. The bundle name is the app's own; there is no separate install-path page in the Cursor docs linked below.

**What the user can see.** [Usage and limits](https://cursor.com/help/models-and-usage/usage-limits) says The X Subscription has one weekly pool shared by Cursor, Grok Bot, and the Grok apps, shown at grok.com/dashboard and in editor settings. Legacy Cursor plans have two monthly pools on the dashboard Spending tab. Reset is weekly for The X Subscription. The legacy reset cadence is described there as monthly pools. No personal HTTP API is specified on that page.

**Do not confuse these with plan usage.**

- [Get Rate Limit](https://cursor.com/docs/api/origin/reference/get-rate-limit) is the Origin API's per-minute point budget (`resources.core.limit`, `remaining`, `used`, `reset`). It is not the editor's weekly or monthly allowance.
- The [Admin and Analytics APIs](https://cursor.com/docs/api) expose team usage. They are not a single-user menu-bar source, and Tidepool has no team token.

**Undocumented, not used.** OpenUsage and [Harnery](https://harnery.com/cli/devtools/) describe a dashboard call authenticated with the IDE session in `state.vscdb` (`GetCurrentPeriodUsage` / `cursor.com/api/dashboard/get-current-period-usage`) returning a percent used and cycle bounds. That is not in Cursor's public API reference. A Cursor provider should not call it until the request and response are confirmed against a current client, and it should say the figure is unofficial.

**Unknown.** The on-disk schema of `state.vscdb`, whether a local file contains the weekly percent without a network call, and the exact JSON for legacy versus X Subscription pools.

## Codex (detected, not implemented)

**How to tell it is installed.** Official defaults are the `codex` binary and `~/.codex`, overridable with `CODEX_HOME` ([Codex app-server](https://learn.chatgpt.com/docs/app-server), and the credential notes in [Pacebar](https://pacebar.io/docs/providers/codex)). Tidepool detects those. It does not read `auth.json`.

**Documented quota.** [Codex app-server](https://learn.chatgpt.com/docs/app-server) documents JSON-RPC `account/rateLimits/read`. The sample result has `rateLimits.primary.usedPercent`, `windowDurationMins`, and `resetsAt` (Unix seconds), an optional `secondary` window, `rateLimitsByLimitId`, and `rateLimitResetCredits`. `account/usage/read` returns token-activity summaries. `account/rateLimits/updated` is a notification. ChatGPT auth is required; an API key does not serve these limits ([app-server tests](https://github.com/openai/codex/blob/53b50197/codex-rs/app-server/tests/suite/v2/rate_limits.rs)). The interactive `/status` command shows the same windows ([OpenAI Help](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan-usage-limits-and-troubleshooting)).

**Session files, unofficial shape.** People read `~/.codex/sessions/**/rollout-*.jsonl` for a `token_count` event whose `payload.rate_limits` has `primary` / `secondary` `used_percent`, `window_minutes`, and `resets_at`. [Paneherd](https://paneherd.com/guides/codex-usage-limits) says this format is not documented and older builds used `resets_in_seconds`. Treat it as a fallback and label it.

**Undocumented HTTP.** Pacebar and OpenUsage describe `GET https://chatgpt.com/backend-api/wham/usage` with the ChatGPT access token. OpenAI's public app-server page does not list that URL. Do not call it from Tidepool until it is confirmed. Do not refresh Codex tokens.

**Unknown.** Which `limitId` values a given plan returns, and the session JSON for "needs you" versus merely idle. There is no Codex hook story in the sources above.

## Grok Bot (not detected)

Grok Bot is a Cursor surface, not a separate Mac app we can point at. [Grok Bot on The X Subscription](https://docs.x.ai/x-subscription/grok-bot) says usage is the weekly shared pool and is visible at grok.com/dashboard (Usage) or the Cursor dashboard before a switch. [Grok Bot FAQs](https://cursor.com/help/grok-bot/faqs) say the meter is also under Grok Bot → Settings → Usage & Billing, and that it is not the SuperGrok meter.

No CLI binary, bundle name, or config directory for Grok Bot itself showed up in those docs. Tidepool therefore has no signature and will not mark Grok Bot installed when Cursor is.

The [xAI API rate limits](https://docs.x.ai/developers/rate-limits) (requests per second and tokens per minute, by model and spend tier) are a different product. They are not Grok Bot's weekly pool.

**Unknown.** Any local file or supported API a menu-bar app can call for that weekly percent. The Organization API path mentioned in Cursor's API overview (`/organizations/teams/{teamId}/grok-bot/operations/*`) is a team rate limit on those endpoints, not the user's allowance.

## Wispr Flow (detected, not implemented)

**How to tell it is installed.** The Mac app must be named `Wispr Flow.app` and live in `/Applications`, `~/Applications`, or `/System/Applications` ([install guide](https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac)). That is the only marker Tidepool uses.

**What the user can see.** On the Free plan, Mac and Windows have a 2,000-word weekly allowance and a 5,000-word maximum ([plans](https://docs.wisprflow.ai/articles/9559327591-flow-plans-and-what-s-included)). The desktop home card shows "N words left" ([troubleshooting](https://docs.wisprflow.ai/articles/3715544288-weekly-word-limit-not-resetting-troubleshooting-guide)). Paid desktop plans have no weekly word limit. The help pages disagree about the reset clock: messages say Sunday 12:00 a.m. PT, and the troubleshooting guide says that text does not match the actual reset. Pro, Student, trial, Growth, and Enterprise are not word-capped on desktop.

**Not the consumer meter.** The [Voice Interface API](https://api-docs.wisprflow.ai/introduction) is a developer transcription API (`/ws`, `/api`). It does not report the signed-in user's remaining words.

**Unknown.** A supported way to read "N words left" without scraping the UI. No config-directory path is cited here, so Tidepool does not look for one.

## Later, still inside the protocol

A new provider implements `UsageProvider` and returns `UsageWindow` values with an honest `DataOrigin`. Sessions use `needsYou`, `working`, and `idle`. Anything that is not a documented server figure is `estimate` and the UI already prints `est.`. Detection changes belong in `ToolCatalog` and need a source in this file. Do not add a network call whose request shape is only a guess.
