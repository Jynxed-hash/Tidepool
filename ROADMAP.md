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

## Codex (implemented)

**How to tell it is installed.** Official defaults are the `codex` binary and `~/.codex`, overridable with `CODEX_HOME` ([Codex app-server](https://learn.chatgpt.com/docs/app-server), and the credential notes in [Pacebar](https://pacebar.io/docs/providers/codex)). Tidepool detects those. It does not read `auth.json`.

**Documented quota.** [Codex app-server](https://learn.chatgpt.com/docs/app-server) documents JSON-RPC `account/rateLimits/read`. The sample result has `rateLimits.primary.usedPercent`, `windowDurationMins`, and `resetsAt` (Unix seconds), an optional `secondary` window, `rateLimitsByLimitId`, and `rateLimitResetCredits`. `account/usage/read` returns token-activity summaries. `account/rateLimits/updated` is a notification. ChatGPT auth is required; an API key does not serve these limits ([app-server tests](https://github.com/openai/codex/blob/53b50197/codex-rs/app-server/tests/suite/v2/rate_limits.rs)). The interactive `/status` command shows the same windows ([OpenAI Help](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan-usage-limits-and-troubleshooting)).

**Session files.** The Codex rollout recorder writes `sessions/YYYY/MM/DD/rollout-*.jsonl`. A persisted `token_count` event carries `rate_limits` using `RateLimitWindow`: `used_percent`, `window_minutes`, and `resets_at` ([protocol.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)). [Paneherd](https://paneherd.com/guides/codex-usage-limits) notes older builds used `resets_in_seconds`. Tidepool does not read that older field. The file is a fallback, and the panel says so.

**Undocumented HTTP.** Pacebar and OpenUsage describe `GET https://chatgpt.com/backend-api/wham/usage` with the ChatGPT access token. OpenAI's public app-server page does not list that URL. Do not call it from Tidepool until it is confirmed. Do not refresh Codex tokens.

**What Tidepool reads.** `account/rateLimits/read` for windows, `account/usage/read` for today's token bucket, and `thread/list` for status. `waitingOnApproval` is the only active flag the app-server page shows, so that is the only Needs you signal. Session files are the offline copy of `RateLimitWindow` (`used_percent`, `window_minutes`, `resets_at`) under `sessions/YYYY/MM/DD/rollout-*.jsonl`, which is the path the Codex rollout recorder writes. Turn start and completion events in that file are an activity estimate. `ExecApprovalRequest` is not persisted, so the file cannot say Needs you. `/status` stays an interactive command ([developer commands](https://learn.chatgpt.com/docs/developer-commands)).

**Unknown.** Which `limitId` values a given plan returns. A 15-minute sample window in the app-server docs is not relabeled as 5-hour. Compressed `.jsonl.zst` rollouts are not read.

## Grok Bot (detected, limited data)

The desktop app is installed by dragging **Grok Bot** to Applications ([get started](https://docs.x.ai/grok-bot/get-started)). Tidepool treats `Grok Bot.app` as the install marker. It does not treat Cursor as Grok Bot.

[Grok Bot FAQs](https://cursor.com/help/grok-bot/faqs) and [Usage and limits](https://cursor.com/help/models-and-usage/usage-limits) put the weekly pool in Grok Bot under Settings → Usage & Billing and at grok.com/dashboard. [Approvals](https://docs.x.ai/grok-bot/approvals-security-and-privacy) says an action that needs you shows up in the conversation. None of those pages name a local file or a supported API for the percentage or the pending approval. Tidepool shows that limitation and does not invent a request. It does not read `~/.grokbot`, which is not in those docs.

The [xAI API rate limits](https://docs.x.ai/developers/rate-limits) (requests per second and tokens per minute, by model and spend tier) are a different product. They are not Grok Bot's weekly pool.

**Unknown.** Any local file or supported API a menu-bar app can call for that weekly percent. The Organization API path mentioned in Cursor's API overview (`/organizations/teams/{teamId}/grok-bot/operations/*`) is a team rate limit on those endpoints, not the user's allowance.

## Wispr Flow (detected, not implemented)

**How to tell it is installed.** The Mac app must be named `Wispr Flow.app` and live in `/Applications`, `~/Applications`, or `/System/Applications` ([install guide](https://docs.wisprflow.ai/articles/7682075140-how-to-install-wispr-flow-on-mac)). That is the only marker Tidepool uses.

**What the user can see.** On the Free plan, Mac and Windows have a 2,000-word weekly allowance and a 5,000-word maximum ([plans](https://docs.wisprflow.ai/articles/9559327591-flow-plans-and-what-s-included)). The desktop home card shows "N words left" ([troubleshooting](https://docs.wisprflow.ai/articles/3715544288-weekly-word-limit-not-resetting-troubleshooting-guide)). Paid desktop plans have no weekly word limit. The help pages disagree about the reset clock: messages say Sunday 12:00 a.m. PT, and the troubleshooting guide says that text does not match the actual reset. Pro, Student, trial, Growth, and Enterprise are not word-capped on desktop.

**Not the consumer meter.** The [Voice Interface API](https://api-docs.wisprflow.ai/introduction) is a developer transcription API (`/ws`, `/api`). It does not report the signed-in user's remaining words.

**Unknown.** A supported way to read "N words left" without scraping the UI. No config-directory path is cited here, so Tidepool does not look for one.

## OpenRouter (implemented)

**Detection.** `OPENROUTER_API_KEY`, the variable in the [install guide](https://openrouter.ai/docs/install). The value is not stored.

**Source.** [Get current API key](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key): `GET https://openrouter.ai/api/v1/key`. The example names `limit`, `limit_remaining`, `limit_reset`, `usage`, `usage_daily`, `effective_budget` (`limit_usd`, `spend_usd`, `reset_interval`, `resets_at`), and `free_model_daily_requests` (`used`, `limit`, `remaining`).

**Shown.** Percents are `used / limit` from those fields. `limit: null` is unlimited and draws no bar. `usage_daily` is today's dollars, not a token count. `rate_limit` is marked deprecated on that page and is ignored. There is no session feed.

## Gemini CLI (implemented)

**Detection.** The `gemini` binary, or `~/.gemini`. The OAuth file constant is `oauth_creds.json` under the global Gemini directory ([storage.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/config/storage.ts)).

**Source.** The CLI posts `retrieveUserQuota` to `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with `{ "project": "<id>" }` ([server.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts)). The project id is `cloudaicompanionProject` from `loadCodeAssist` ([types.ts](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts)). Buckets carry `modelId`, `remainingFraction`, `remainingAmount`, `resetTime`, and `tokenType`. A captured bucket is in [gemini-cli#14883](https://github.com/google-gemini/gemini-cli/issues/14883). The CLI keeps the lowest `remainingFraction` per model.

**Shown.** Used percent is `100 * (1 - remainingFraction)`. The access token is read from `access_token`. `expiry_date` at or above 1e11 is milliseconds, matching the timestamp the CLI persists. An expired token is not refreshed and `refresh_token` is never sent. API-key and Vertex logins are not this file, so they get the missing-file notice. No session feed.

**Unknown.** A supported local quota cache that would survive an expired access token without a refresh.

## OpenCode (implemented)

**Detection.** The `opencode` binary, `~/.local/share/opencode` ([troubleshooting](https://opencode.ai/docs/troubleshooting/)), or `OPENCODE_API_KEY`.

**Source.** `GET https://opencode.ai/zen/go/v1/usage` is the route in [usage.ts](https://github.com/anomalyco/opencode/blob/dev/packages/console/app/src/routes/zen/go/v1/usage.ts), added in [opencode#16513](https://github.com/anomalyco/opencode/pull/16513). Live responses in [opencode#53701](https://github.com/anomalyco/opencode/issues/53701) are `{ "usage": { "rolling": { "status", "percent", "resetsAt" }, "weekly", "monthly" } }`. `percent` is used percent, floored. The key variable is `OPENCODE_API_KEY` ([Pi harness](https://opencode.ai/v2/docs/console/harnesses/pi/)).

**Shown.** Rolling, weekly, and monthly rows. The rolling title stays "Rolling" because the JSON does not include a duration. Dollars are not in this payload. `auth.json` is documented as the credential file, but not its JSON shape, so Tidepool does not read it. No session feed.

## z.ai (implemented)

**Detection.** `ZAI_API_KEY` ([Z.AI OpenAI guide](https://docs.z.ai/guides/develop/openai/python)) or `ZHIPUAI_API_KEY`.

**Source.** Official plan pages describe a 5-hour limit and a weekly quota in the subscription UI ([FAQ](https://docs.z.ai/devpack/faq)). They do not publish this HTTP shape. The path `GET /api/monitor/usage/quota/limit` is the one OpenUsage, CodexBar, and pi-glm-usage call. Captured bodies agree on `data.limits[]` with `type`, `unit`, `number`, `percentage`, and `nextResetTime` (epoch milliseconds). `unit` 3 with `number` 5 is the 5-hour token window. `unit` 6 is the weekly token window (`number` 1, and in one write-up 7). `type` `TIME_LIMIT` with `unit` 5 is the monthly tool ceiling. `percentage` is used percent. `success: false` is an error even on HTTP 200.

**Shown.** Those three windows, and only when `percentage` is present. Other `unit` values are skipped. Counts such as `usage` and `currentValue` are not turned into a second percent, because write-ups disagree on which field is the cap. The global key is sent only to `https://api.z.ai`. The China key is sent only to `https://open.bigmodel.cn`, and only when the global key is unset. No session feed.

**Unknown.** A Z.AI-authored schema for this monitor path. Standard API balance for a key that is not on a Coding Plan.

## DeepSeek (implemented)

**Detection.** `DEEPSEEK_API_KEY`, the variable in the [first API call](https://api-docs.deepseek.com/) guide.

**Source.** [Get User Balance](https://api-docs.deepseek.com/api/get-user-balance): `GET https://api.deepseek.com/user/balance`. Fields: `is_available`, `balance_infos[].currency`, `total_balance`, `granted_balance`, `topped_up_balance`. Balances are strings. Currency is `CNY` or `USD`.

**Shown.** The balance sentence. No bar, because no spending cap is in the payload. No session feed.

## Left without a meter

These are detected and labeled coming soon. None of them has a request Tidepool can cite without guessing or scraping a session.

**GitHub Copilot.** The CLI binary is `copilot`, the config directory is `~/.copilot`, and `COPILOT_HOME` overrides it ([config directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)). `/usage` inside the CLI is an interactive command ([best practices](https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-best-practices)). The [Copilot SDK](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing) documents `account.getQuota` → `quotaSnapshots.premium_interactions` (`entitlementRequests`, `usedRequests`, `remainingPercentage`, `resetDate`) as an SDK RPC, not as an HTTP call. `GET https://api.github.com/copilot_internal/user` is not in the public REST docs, so Tidepool does not call it.

**Windsurf, now Devin Desktop.** On June 2, 2026 the Mac app changed from Windsurf to `Devin.app` ([FAQ](https://docs.devin.ai/desktop/devin-desktop-faq)). The config directory in the uninstall steps is `~/.codeium/windsurf` ([getting started](https://docs.windsurf.com/windsurf/getting-started)). The usage meter in the app and the plan page show the daily and weekly quota ([plans and usage](https://docs.devin.ai/desktop/accounts/usage)). The [Analytics API](https://docs.devin.ai/desktop/accounts/api-reference/analytics-v2-introduction) is an organization consumption report for a service key, not that personal remaining quota. No local file for the meter was found.

**Kiro.** Installs as `kiro-cli` and, via Homebrew, `Kiro CLI.app` ([downloads](https://kiro.dev/downloads/), [Homebrew cask](https://formulae.brew.sh/cask/kiro-cli)). `/usage` prints a credit breakdown inside the chat session ([slash commands](https://kiro.dev/docs/reference/slash-commands/)). That output is not a documented machine-readable contract, so Tidepool does not scrape it. The IDE download is not given a bundle name here.

**Amp.** The install script provides the `amp` binary (`https://ampcode.com/install.sh`). Published readers use browser cookies. No local quota file or documented usage API was confirmed.

**Aider.** The command is `aider` ([install](https://aider.chat/docs/install.html)). Aider spends another provider's API key. It does not publish a quota of its own.

**Factory.** The Droid CLI installs the `droid` binary ([quickstart](https://docs.factory.com/droid-cli/quickstart) and `https://app.factory.ai/cli`). Readers that show Factory usage use browser cookies and WorkOS. No documented local or key-based usage response was confirmed.

**ChatGPT desktop.** The current Mac app and the previous one show up as ChatGPT and ChatGPT Classic ([moving to the new app](https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app)). Tidepool looks for `ChatGPT.app` and `ChatGPT Classic.app`. Codex usage for the coding agent is already the Codex provider (`codex app-server` and `~/.codex`). No separate documented usage file for the desktop chat plan was found, so the app is detection only and is not given a second invented meter.

**Cursor.** Still the detected-not-implemented entry above. The dashboard call and `state.vscdb` stay unused.

## Later, still inside the protocol

A new provider implements `UsageProvider` and returns `UsageWindow` values with an honest `DataOrigin`. Sessions use `needsYou`, `working`, and `idle`. Anything that is not a documented server figure is `estimate` and the UI already prints `est.`. Detection changes belong in `ToolCatalog` and need a source in this file. Do not add a network call whose request shape is only a guess.
