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

The token is read from the macOS login Keychain, then from `~/.claude/.credentials.json`. The document is `claudeAiOauth.accessToken` with `expiresAt` in milliseconds when the number is ≥ 1e11 (otherwise seconds). A bare `{ "accessToken", "expiresAt" }` object is accepted. An `mcpOAuth`-only document is not a login. That file layout is described in the claudeops note above, not in Claude's public docs. On macOS, Claude Code usually does not write the file. It stores the same JSON as a generic password, service `Claude Code-credentials`, account the macOS user name, or `claude-code-user` when that name is not a plain account label. [cc-usage](https://github.com/yyongpil/cc-usage) reads it with `security find-generic-password -s "Claude Code-credentials" -w`. Tidepool does that and passes `-a` for the account, because several items share the service and an unscoped read can return MCP state (`account` `unknown`) and look like a missing login. `SecItemCopyMatching` is only a second try: match-all, authentication UI disabled, login payloads preferred over `mcpOAuth`. `CLAUDE_CONFIG_DIR`, or `CLAUDE_SECURESTORAGE_CONFIG_DIR` when it is non-empty, selects the alternate service Claude Code derives (the default name, a dash, and the first 8 hex characters of SHA-256 over the NFC directory string) and the `.credentials.json` in that directory. An empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps the default store. Tidepool never calls the refresh endpoint. A successful read stays in memory until `expiresAt` (ten minutes when the document has no expiry) so a keychain prompt is not repeated on every refresh.

List prices for the footer are the public [pricing table](https://platform.claude.com/docs/en/about-claude/pricing) (rate card effective 2026-10-07). They are not the user's plan price.

## Cursor (implemented, unofficial)

**How to tell it is installed.** The Mac app bundle is `Cursor.app`, and the documented shell command is `cursor`. OpenUsage records the macOS user-data directory as `~/Library/Application Support/Cursor` ([OpenUsage: Cursor](https://openusage.sh/docs/providers/cursor/)). Tidepool treats any one of those as detection.

**What the user can see.** [Usage and limits](https://cursor.com/help/models-and-usage/usage-limits) says The X Subscription has one weekly pool shared by Cursor, Grok Bot, and the Grok apps, shown at grok.com/dashboard and in editor settings. Legacy Cursor plans have two monthly pools on the dashboard Spending tab. No personal HTTP API is specified on that page.

**Unofficial source.** Community clients call `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` with body `{}`, `Authorization: Bearer`, and `Connect-Protocol-Version: 1` ([OpenTokenUsage](https://github.com/PowerUserZ/OpenTokenUsage/blob/main/docs/providers/cursor.md), [ASU provider contracts](https://github.com/allixsenos/asu/blob/main/docs/provider-contracts.md)). The access token is `cursorAuth/accessToken` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` ([onWatch](https://github.com/onllm-dev/onWatch/blob/main/docs/CURSOR_SETUP.md)). Tidepool runs `sqlite3 -readonly` on a `file:` URI with `mode=ro`. The SQL is a constant that names only `cursorAuth/accessToken`.

**Shown, all server figures, none estimated.**

- Included: `planUsage.includedSpend / planUsage.limit`. Both are cents. [Traycer](https://github.com/traycerai/traycer/pull/1265) shows Cursor's included-usage sentence matching that division rather than `totalPercentUsed`.
- Total: `planUsage.totalPercentUsed`, when finite.
- Auto: `planUsage.autoPercentUsed`, when finite.
- On-demand: `spendLimitUsage.individualUsed / individualLimit`, only when the limit is greater than zero.
- Team pool: `spendLimitUsage.pooledUsed / pooledLimit`, only when the limit is greater than zero.
- Reset: `billingCycleEnd` (unix milliseconds, often a string). No countdown.

`totalPercentUsed` and `includedSpend / limit` use different denominators ([cursor-sdk2api #19](https://github.com/Sunnyender-org/cursor-sdk2api/issues/19)). Tidepool shows them as separate rows. `apiPercentUsed` is omitted: the same notes show it disagreeing with Included, including on plan-only accounts. `displayMessage` is not parsed into a percent.

**Not called.** `POST https://api2.cursor.sh/oauth/token`, `GetPlanInfo`, `GetUsageLimitPolicyStatus`, `cursor.com/api/auth/stripe`, and `cursor.com/api/usage`. The refresh token and the keychain item `cursor-access-token` are not read. The database is not written. The [Origin rate limit](https://cursor.com/docs/api/origin/reference/get-rate-limit) and the [Admin API](https://cursor.com/docs/api) are not the personal meter.

**When it fails.** A 200 body with none of Included, Total, or Auto, or HTTP 404 or 410, becomes availability `.limited` and a notice that starts with "Limited data". HTTP 401 or 403 says the saved session was rejected and Tidepool does not refresh it. Settings → Unofficial providers skips the read and the call. The panel badge says Unofficial.

**Unknown.** A published schema for this Connect method. Whether every plan still returns `billingCycleEnd` as milliseconds.

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

## GitHub Copilot (implemented, unofficial)

**Detection.** The CLI binary is `copilot`, the config directory is `~/.copilot`, and `COPILOT_HOME` overrides it ([config directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)). Editor plugins write `~/.config/github-copilot`, and `gh` writes `~/.config/gh` ([OpenUsage](https://github.com/robinebers/openusage/blob/main/docs/providers/copilot.md)). Tidepool treats any of those as detection.

**Not the meter.** `/usage` inside the CLI is an interactive command ([best practices](https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-best-practices)). The [Copilot SDK](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing) documents `account.getQuota` as an SDK RPC, not as an HTTP call. Org billing (`/orgs/{org}/settings/billing/usage/summary`) is not the personal quota.

**Unofficial source.** `GET https://api.github.com/copilot_internal/user` ([OpenTokenUsage](https://github.com/PowerUserZ/OpenTokenUsage/blob/main/docs/providers/copilot.md), [burnrate](https://upld-internal.github.io/burnrate-copilot/research/copilot-api.html), [aistat](https://github.com/drogers0/aistat/pull/19)). It is not in the public REST docs. The token is read from, in order, `~/.config/github-copilot/apps.json`, the older `hosts.json`, then `oauth_token` in the `github.com` block of `~/.config/gh/hosts.yml`, then the same file under `GH_CONFIG_DIR` when that directory exists. Only `oauth_token` is accepted. `refresh_token` is ignored. Another host's token is ignored. The macOS keychain service `gh:github.com` is not read, and `gh auth token` is not run.

The request uses the headers those community clients send: `Authorization: Bearer`, `Accept: application/json`, `X-Github-Api-Version: 2025-04-01`, `Editor-Version: vscode/1.96.2`, `Editor-Plugin-Version: copilot-chat/0.26.7`, and `User-Agent: GitHubCopilotChat/0.26.7`. Those headers are the unofficial route's client shape. Tidepool is not VS Code.

**Shown, all server figures, none estimated.**

- Premium, Chat, and Completions from `quota_snapshots`, in that order. Used percent is `100 - percent_remaining`. If `percent_remaining` is missing and `entitlement` is greater than zero, used percent is `(entitlement - remaining) / entitlement`.
- `unlimited: true` or `entitlement` below zero skips that row. Since June 2026, paid chat and completions are often unlimited ([burnrate live capture](https://upld-internal.github.io/burnrate-copilot/research/copilot-api.html)).
- Free tier: `limited_user_quotas` is the remaining count and `monthly_quotas` is the cap ([OpenTokenUsage](https://github.com/PowerUserZ/OpenTokenUsage/blob/main/docs/providers/copilot.md), [OmniRoute #2881](https://github.com/diegosouzapw/OmniRoute/pull/2881)). A percent is drawn only when both numbers exist for the same key and remaining is not above the cap.
- Reset prefers a non-zero `quota_reset_at` (epoch milliseconds; zero is ignored), then `quota_reset_date_utc`, then `quota_reset_date`, then `limited_user_reset_date`.

**When it fails.** A JSON object with none of `quota_snapshots`, `limited_user_quotas`, or `monthly_quotas`, or HTTP 404 or 410, becomes **Limited data**. A recognized body whose buckets are all unlimited stays ready, with no bars, and says Copilot reports no finite quota. HTTP 401 or 403 says the saved token was rejected and Tidepool does not refresh it. Login, `analytics_tracking_id`, and the token are not shown. Settings → Unofficial providers skips the read and the call. The panel badge says Unofficial.

**Unknown.** A GitHub-authored schema for `copilot_internal/user`. The editor `apps.json` map is read one level deep for `oauth_token` only; other keys in that file are not documented here.

## Left without a meter

These are detected and labeled coming soon. None of them has a request Tidepool can cite without guessing or scraping a session.

**Windsurf, now Devin Desktop.** On June 2, 2026 the Mac app changed from Windsurf to `Devin.app` ([FAQ](https://docs.devin.ai/desktop/devin-desktop-faq)). The config directory in the uninstall steps is `~/.codeium/windsurf` ([getting started](https://docs.windsurf.com/windsurf/getting-started)). The usage meter in the app and the plan page show the daily and weekly quota ([plans and usage](https://docs.devin.ai/desktop/accounts/usage)). The [Analytics API](https://docs.devin.ai/desktop/accounts/api-reference/analytics-v2-introduction) is an organization consumption report for a service key, not that personal remaining quota. No local file for the meter was found.

**Kiro.** Installs as `kiro-cli` and, via Homebrew, `Kiro CLI.app` ([downloads](https://kiro.dev/downloads/), [Homebrew cask](https://formulae.brew.sh/cask/kiro-cli)). `/usage` prints a credit breakdown inside the chat session ([slash commands](https://kiro.dev/docs/reference/slash-commands/)). That output is not a documented machine-readable contract, so Tidepool does not scrape it. The IDE download is not given a bundle name here.

**Amp.** The install script provides the `amp` binary (`https://ampcode.com/install.sh`). Published readers use browser cookies. No local quota file or documented usage API was confirmed.

**Aider.** The command is `aider` ([install](https://aider.chat/docs/install.html)). Aider spends another provider's API key. It does not publish a quota of its own.

**Factory.** The Droid CLI installs the `droid` binary ([quickstart](https://docs.factory.com/droid-cli/quickstart) and `https://app.factory.ai/cli`). Readers that show Factory usage use browser cookies and WorkOS. No documented local or key-based usage response was confirmed.

**ChatGPT desktop.** The current Mac app and the previous one show up as ChatGPT and ChatGPT Classic ([moving to the new app](https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app)). Tidepool looks for `ChatGPT.app` and `ChatGPT Classic.app`. Codex usage for the coding agent is already the Codex provider (`codex app-server` and `~/.codex`). No separate documented usage file for the desktop chat plan was found, so the app is detection only and is not given a second invented meter.

## Later, still inside the protocol

A new provider implements `UsageProvider` and returns `UsageWindow` values with an honest `DataOrigin`. Sessions use `needsYou`, `working`, and `idle`. Anything that is not a documented server figure is `estimate` and the UI already prints `est.`. Detection changes belong in `ToolCatalog` and need a source in this file. Do not add a network call whose request shape is only a guess.
