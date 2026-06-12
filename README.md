# Usage Dock

A native macOS menu bar app that tracks how much of your AI coding agent quota you've burned — across **Claude** (multiple accounts), **Codex**, **Kimi**, and any future provider you point at a config folder.

Each provider gets a cute 8-bit pixel critter whose **mood tracks your usage**: `CHILL` → `OK` → `BUSY` → `FRIED`. They idle-bob, blink, and hop when you poke them.

## What it looks like

- **Menu bar**: the busiest provider's mascot + its session percentage. Click to reveal.
- **Dock panel**: a frosted-glass column that slides in from the right screen edge. One card per provider: session ring (`58% used · resets in 57m`), mood tag, and a tap-to-expand section with weekly bars and the source folder.
- **Rail**: collapse the panel (chevron handle) to a slim strip of peeking mascots.
- Follows the system light/dark appearance.

## Build & run

```sh
scripts/bundle.sh          # → build/Usage Dock.app
open "build/Usage Dock.app"
```

Dev loop:

```sh
swift build
.build/debug/UsageDock --print     # headless data check
.build/debug/UsageDock --open      # run with panel open
```

Requires macOS 14+ and a Swift 5.9+ toolchain. No dependencies.

## Where the numbers come from

All providers show **real, provider-reported rate limits** — the same numbers as Claude's `/usage` screen, Codex Analytics, and the Kimi Console:

| Provider | Auth source | API |
|---|---|---|
| Claude | macOS Keychain (`Claude Code-credentials`, per-config-dir suffix for extra accounts) | `api.anthropic.com/api/oauth/usage` → 5h session + weekly + per-model weekly utilization |
| Codex | `~/.codex/auth.json` ChatGPT OAuth token | `chatgpt.com/backend-api/wham/usage` → 5h + weekly windows, per-model extras, plan type |
| Kimi | `~/.kimi-code/credentials/kimi-code.json` (15-min tokens; refreshed with the CLI's own lockfile protocol, rotated creds persisted back) | `api.kimi.com/coding/v1/usages` → weekly + rate-limit windows |

First launch asks for Keychain access to the Claude credentials — click **Always Allow**. Usage Dock never sends tokens anywhere except the provider's own API.

**Fallback:** if an API is unreachable or a login is stale, the card falls back to local analysis (Codex: last `rate_limits` event in rollout files; Claude/Kimi: token counts from transcripts relative to your busiest period) and marks the ring with `≈`. Pin `sessionTokenLimit` / `weeklyTokenLimit` in the config to make fallback bars absolute.

## Adding a provider

Click **Add a provider** in the panel (or edit `~/Library/Application Support/UsageDock/providers.json`):

```json
{
  "id": "claude-client",
  "name": "Claude",
  "account": "Client X",
  "kind": "claude",
  "dir": "~/.claude-clientx",
  "style": "cat",
  "palette": "gold"
}
```

- `kind`: `claude` | `codex` | `kimi` — picks the reader (any Claude-Code-compatible CLI works with `claude`).
- `style`: `cat`, `catTie`, `robot`, `round` — the critter's silhouette.
- `palette`: `coral`, `steel`, `green`, `purple`, `gold`, `pink`.

The app picks up config changes on the next refresh (≤60s, or hit the refresh button).

## Notes

- First launch scans recent history once (~20s in the background); afterwards refreshes are incremental and take milliseconds. The parse cache lives at `~/Library/Application Support/UsageDock/usage-cache.json` and is safe to delete.
- Right-click the menu bar item for Refresh / Edit Providers / Quit.
- The design was prototyped in Claude Design; the bundle is archived in `docs/design/`.
