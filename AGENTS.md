# merly — Usage Dock

Native macOS menu bar app (Swift/AppKit + SwiftUI) showing AI agent quota usage for Claude (×2 accounts), Codex, and Kimi, with pixel-art mascots whose mood tracks usage. Every provider must expose a real usage API — local-log-only estimation is not a basis for a supported provider. The UI was originally prototyped as "Usage Dock" in Claude Design.

## Commands

- `swift build` — debug build
- `swift test` — unit tests (needs full Xcode for XCTest; on Command Line Tools only, rely on `--print` + CI)
- `.build/debug/Merly --print` — headless snapshot of all readers (fast smoke test, no UI)
- `.build/debug/Merly --open [--expand|--light|--rail|--edit]` — launch with QA flags (panel open / cards expanded / forced light theme / collapsed rail / reorder mode)
- `.build/debug/Merly --mascot` — launch straight to the app-mascot editor (the Merly critter beside the panel title)
- `scripts/bundle.sh` — release build + assemble `build/Merly.app`
- `Merly.app/Contents/MacOS/Merly --notify-test` — post one alert and log macOS's verdict on it (bundled app only)

## Architecture

- `Sources/Merly/Data/ProviderKind.swift` — the provider registry: each kind's `ProviderDescriptor` (name, default dir, login command, sprite family, lane hue, reader factory) is the single fact table everything else derives from. **New provider = one descriptor + one reader/API pair + a `knownProviders` entry + sprite art.**
- `Sources/Merly/Mascot/Sprite.swift` — 16×16 pixel critter builder (palette + ear style + mood face).
- `Sources/Merly/Mascot/SpriteRecolor.swift` — duotone-tints baked sprite sheets toward the palette accent (luminance → dark→accent→light ramp), so sprite mascots follow their chosen color like the drawn critter does. Both renderers (`MascotView`, `StatusItemController`) go through `SpriteSheetStore.recoloredFrame`; results are memoized per (frame, accent).
- `Sources/Merly/Data/ProviderAPI.swift` — real rate limits: Claude via Keychain OAuth token → `api.anthropic.com/api/oauth/usage`; Codex via `auth.json` → `chatgpt.com/backend-api/wham/usage`; Kimi via credentials file + refresh (flock protocol, **must** persist rotated tokens back or the CLI gets logged out) → `api.kimi.com/coding/v1/usages`.
- `Sources/Merly/Data/Readers.swift` — API-first per `ProviderKind`, falling back to local file analysis (`TokenWindowEstimator` for Claude/Kimi transcripts, rollout `rate_limits` events for Codex) with `isEstimated: true`. The estimate is only an offline safety net for an API-backed provider — never the sole basis for one.
- `Sources/Merly/PanelController.swift` — hidden/open/rail state machine, NSPanel slide animations. Clicking outside collapses to the rail; the panel's chevron tab and the rail's X are the two full dismissals. The rail drags to any screen edge and snaps there (`RailPlacement` in `AppConfig`, persisted): side edges lay it out as a column, top and bottom as a row, and the expanded dock mirrors to whichever side the rail is on.
- `Sources/Merly/Data/Notifier.swift` — `MacNotifications` wraps UNUserNotificationCenter (permission state, posting, the Settings test button); `NotificationManager` watches snapshots for a threshold crossing and for any limit window rolling over. Delivery ≠ display: see Footguns.
- User config: `~/Library/Application Support/Merly/providers.json`. On first run (no file) `AppConfig.firstRun()` auto-detects installed CLIs via `knownProviders` on-disk markers — specific files, not bare dirs, so a `skills/`-only dir isn't a false positive — and falls back to the curated default if none found. Parse cache: `usage-cache.json` next to it (safe to delete; first fallback rescan takes ~20s). The folder was `Merlyn/` before the 2026-08-16 rename; `AppPaths.migrateLegacySupportDir()` moves it once at launch, and only when `Merly/` doesn't already exist.

See [docs/provider-integration.md](docs/provider-integration.md) for exact auth flows, endpoints, payload shapes, the API-first→cache→estimate fallback ladder, and how to re-derive endpoints from the CLIs.

## Footguns

- **Kimi refresh tokens rotate.** Any refresh MUST hold the `oauth/kimi-code` flock and atomically persist new creds to `credentials/kimi-code.json`, or the user's Kimi CLI login breaks.
- **Never refresh Claude/Codex tokens.** Risk of racing the CLIs' own refresh; on expiry, fall back to estimates and let the CLI re-auth on next use.
- Keychain "Always Allow" is tied to the binary's code signature — every ad-hoc rebuild re-prompts. Expected during dev. **Don't "fix" it with a self-signed identity**: that makes `codesign` need a private key, so the *build* starts demanding Keychain access, which is a worse prompt than the one it removes. Tried and reverted — see [docs/specs/distribution.md](docs/specs/distribution.md). Nothing is ever signed *for* distribution; each machine signs its own build (ad-hoc, because Apple Silicon won't run an unsigned binary at all).
- **`UNErrorDomain Code=1` on notifications means the permission, nothing else.** Alerts are then delivered but never drawn — identical, from the outside, to "nothing crossed a limit". Signing, entitlements, LaunchServices duplicates, the usernoted db, ncprefs and `tccutil` were all measured and ruled out at length; the fix was the user allowing notifications. Check with `--notify-test` or the Settings › Alerts row; never read silence as "under the limit".
- **Never change `CFBundleIdentifier`** (`sh.micky.merly`). The notification grant and the Keychain grant both hang off it, so a rename silently throws them away — and the permission prompt does not reliably reappear for an id macOS has already refused. Cost a long debugging session. It was changed exactly once, deliberately, for the Merlyn → Merly rename on 2026-08-16, which cost a one-time re-grant of both. See [docs/specs/distribution.md](docs/specs/distribution.md) § Notifications.
- Estimated fallback percentages are relative to the user's busiest period, not real quota — the UI marks them with `≈`.
- Readers run off-main-thread via `UsageEngine.workQueue`; keep file I/O and HTTP out of views.
- `providers.json` is user-editable at runtime; `engine.refresh()` reloads it every cycle — never cache `AppConfig` across refreshes.
