# Contributing a provider

A tool gets a real provider only after the numbers it shows are in [ROADMAP.md](ROADMAP.md) with a source. If the source does not name a field, do not invent one. Claude Code, Codex, OpenRouter, Gemini CLI, OpenCode Go, z.ai, and DeepSeek each have a source written down there. Grok Bot is detected and reports limited data.

## 1. Write down the source

Add a section to `ROADMAP.md` before writing the client. Link the page that names the endpoint, file, or RPC. Mark unofficial shapes as unofficial. Leave unknowns as unknowns.

## 2. Detect it without guessing

Add a `CatalogEntry` in `ToolCatalog.v1` (`Sources/ProviderKit/Detection.swift`).

A signature may include only markers you can cite:

- `applicationNames`: bundle names such as `Cursor.app`
- `executableNames`: binaries on `PATH`
- `homeRelativePaths`: directories under the home folder
- `environmentDirectoryVariables`: variables like `CODEX_HOME` whose value is a directory
- `environmentValueVariables`: variables like `OPENROUTER_API_KEY` that count when non-empty. Record the name only. Never put the value in evidence, logs, or the panel.

If you cannot name a marker, leave `signature` nil and set `undetectableReason`. An empty signature must not become "coming soon" just because a related app is installed. Set `limitedData` when the tool is detectable but no supported source exposes usage or session state, and return `ProviderSnapshot.availability = .limited` with a notice that says where the person can look. Cover that with a test in `Tests/TidepoolTests`.

## 3. Implement `UsageProvider`

Put the client in its own types under `Sources/`, depending on `ProviderKit`. Conform to `UsageProvider`:

```swift
public protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot
}
```

`ProviderSnapshot` wants:

- `windows`: one `UsageWindow` per limit. `usedPercent` is 0–100. `resetsAt` is optional. `origin` is `.server` or `.statusline` for a figure the product itself reports, and `.estimate` otherwise. Set `showsCountdown` for a short rolling window.
- `sessions`: `TrackedSession` values. `activity` is `.needsYou`, `.working`, or `.idle`. `origin` is `.hook` when a product event said so, and `.estimate` for a heuristic. `waitingDetail` is a short command or path, never a prompt.
- `today`: token or cost estimates. Leave `costUSD` nil when you do not have a published price. Set `costIncomplete` when a model is missing from the table.
- `notice`: one quiet sentence when the usual source failed. Do not throw out of `refresh`.
- `retryAfter`: set it when the service returns a wait, so the app does not poll through a 429.

`ProviderRefreshRequest.allowNetwork` is false on the fast local tick. Skip the network and read a cached snapshot if you have one.

Read credentials in memory. Do not copy them into Application Support, and do not refresh them yourself.

## 4. Register it

`TidepoolStore.refresh` constructs the live providers in one detached task. Add the new provider beside those calls. Coming-soon rows are produced by `ToolDetector` and should disappear once `implemented` is true and the tool is detected (`CatalogState.active`).

Keep the panel on the design in `README.md`: monochrome, flat bars, orange only for Needs you, red only at or above 90 percent, glass only on the bell, the needs-you pill, session rows, and their buttons.

## 5. Test the parser

Add fixtures as strings in `TidepoolTests`. Parse them with no network. Include a null window, a missing file, and a payload that must not retain prompt text.

`swift test` is the check that runs without the macOS 26 SDK. The app target is compiled on the `macos-26` GitHub Actions runner.
