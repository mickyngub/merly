# lens — Usage Dock

Native macOS menu bar app (Swift/AppKit + SwiftUI) showing AI agent quota usage for Claude (×2 accounts), Codex, and Kimi, with pixel-art mascots whose mood tracks usage. Every provider must expose a real usage API — local-log-only estimation is not a basis for a supported provider. Design source: Claude Design bundle "Usage Dock" (see `docs/design/`).

## Commands

- `swift build` — debug build
- `.build/debug/Lens --print` — headless snapshot of all readers (fast smoke test, no UI)
- `.build/debug/Lens --open [--expand|--light|--rail]` — launch with QA flags (panel open / cards expanded / forced light theme / collapsed rail)
- `scripts/bundle.sh` — release build + assemble `build/Lens.app`

## Architecture

- `Sources/Lens/Mascot/Sprite.swift` — 16×16 pixel critter builder (palette + ear style + mood face). New provider = palette preset + `MascotStyle`.
- `Sources/Lens/Data/ProviderAPI.swift` — real rate limits: Claude via Keychain OAuth token → `api.anthropic.com/api/oauth/usage`; Codex via `auth.json` → `chatgpt.com/backend-api/wham/usage`; Kimi via credentials file + refresh (flock protocol, **must** persist rotated tokens back or the CLI gets logged out) → `api.kimi.com/coding/v1/usages`.
- `Sources/Lens/Data/Readers.swift` — API-first per `ProviderKind`, falling back to local file analysis (`TokenWindowEstimator` for Claude/Kimi transcripts, rollout `rate_limits` events for Codex) with `isEstimated: true`. The estimate is only an offline safety net for an API-backed provider — never the sole basis for one.
- `Sources/Lens/PanelController.swift` — hidden/open/rail state machine, NSPanel slide animations.
- User config: `~/Library/Application Support/Lens/providers.json`. On first run (no file) `AppConfig.firstRun()` auto-detects installed CLIs via `knownProviders` on-disk markers — specific files, not bare dirs, so a `skills/`-only dir isn't a false positive — and falls back to the curated default if none found. Parse cache: `usage-cache.json` next to it (safe to delete; first fallback rescan takes ~20s).

See [docs/provider-integration.md](docs/provider-integration.md) for exact auth flows, endpoints, payload shapes, the API-first→cache→estimate fallback ladder, and how to re-derive endpoints from the CLIs.

## Footguns

- **Kimi refresh tokens rotate.** Any refresh MUST hold the `oauth/kimi-code` flock and atomically persist new creds to `credentials/kimi-code.json`, or the user's Kimi CLI login breaks.
- **Never refresh Claude/Codex tokens.** Risk of racing the CLIs' own refresh; on expiry, fall back to estimates and let the CLI re-auth on next use.
- Keychain "Always Allow" is tied to the binary's code signature — every ad-hoc rebuild re-prompts. Expected during dev.
- Estimated fallback percentages are relative to the user's busiest period, not real quota — the UI marks them with `≈`.
- Readers run off-main-thread via `UsageEngine.workQueue`; keep file I/O and HTTP out of views.
- `providers.json` is user-editable at runtime; `engine.refresh()` reloads it every cycle — never cache `AppConfig` across refreshes.
