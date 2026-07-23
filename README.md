# Merlyn

[![CI](https://github.com/mickyngub/merlyn/actions/workflows/ci.yml/badge.svg)](https://github.com/mickyngub/merlyn/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)](#build-from-source)

A native macOS menu bar app that tracks how much of your AI coding agent quota you've burned — across **Claude** (multiple accounts), **Codex**, **Kimi**, and any future provider you point at a config folder.

Each provider gets a cute 8-bit pixel critter whose **mood tracks your usage**: `CHILL` → `OK` → `BUSY` → `FRIED`. They idle-bob, blink, and hop when you poke them.

> **Unofficial project.** Merlyn is a third-party tool and is **not affiliated with, endorsed by, or sponsored by** Anthropic, OpenAI, or Moonshot AI. "Claude", "Codex", "Kimi", and related names and mascots are trademarks of their respective owners, used here only to identify the services whose usage Merlyn displays. Merlyn only *reads* usage data these tools already store on your Mac — see [Privacy & security](#privacy--security).

## What it looks like

- **Menu bar**: the busiest provider's mascot + its session percentage. Click to reveal.
- **Dock panel**: a frosted-glass column that slides in from the right screen edge. One card per provider: session ring (`58% used · resets in 57m`), mood tag, and a tap-to-expand section with weekly bars and the source folder.
- **Rail**: collapse the panel (chevron handle) to a slim strip of peeking mascots.
- Follows the system light/dark appearance. It's a menu bar app — there's no Dock icon; look up top.

## Install

Merlyn requires **macOS 14 (Sonoma) or newer**.

Grab `Merlyn-<version>.dmg` from the [Releases](https://github.com/mickyngub/merlyn/releases) page, open it, and drag **Merlyn** to your Applications folder.

**First launch (unsigned builds).** Until a release is notarized by Apple, macOS Gatekeeper will block the first open. Do one of:

- **System Settings** → **Privacy & Security** → scroll to the message about *Merlyn* → **Open Anyway**, then confirm. Or,
- In Terminal, clear the quarantine flag, then open normally:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Merlyn.app
  open /Applications/Merlyn.app
  ```

You only need to do this once. Notarized releases open with a normal double-click and no warning.

On first run, Merlyn asks for **Keychain access** to read the Claude Code credentials — click **Always Allow**.

## Build from source

No dependencies; just a Swift toolchain.

```sh
swift build
.build/debug/Merlyn --print     # headless data check (no UI)
.build/debug/Merlyn --open      # run with the panel open

scripts/bundle.sh               # → build/Merlyn.app
scripts/dmg.sh                  # → dist/Merlyn-<version>.dmg
```

Requires macOS 14+ and a Swift 5.9+ toolchain. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev loop and [docs/specs/distribution.md](docs/specs/distribution.md) for signing/notarization.

## Where the numbers come from

All providers show **real, provider-reported rate limits** — the same numbers as Claude's `/usage` screen, Codex Analytics, and the Kimi Console:

| Provider | Auth source | API |
|---|---|---|
| Claude | macOS Keychain (`Claude Code-credentials`, per-config-dir suffix for extra accounts) | `api.anthropic.com/api/oauth/usage` → 5h session + weekly + per-model weekly utilization |
| Codex | `~/.codex/auth.json` ChatGPT OAuth token | `chatgpt.com/backend-api/wham/usage` → 5h + weekly windows, per-model extras, plan type |
| Kimi | `~/.kimi-code/credentials/kimi-code.json` (15-min tokens; refreshed with the CLI's own lockfile protocol, rotated creds persisted back) | `api.kimi.com/coding/v1/usages` → weekly + rate-limit windows |

Merlyn never sends tokens anywhere except the provider's own API.

**Fallback:** if an API is unreachable or a login is stale, the card falls back to local analysis (Codex: last `rate_limits` event in rollout files; Claude/Kimi: token counts from transcripts relative to your busiest period) and marks the ring with `≈`. Pin `sessionTokenLimit` / `weeklyTokenLimit` in the config to make fallback bars absolute.

## Adding a provider

Click **Add a provider** in the panel (or edit `~/Library/Application Support/Merlyn/providers.json`):

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

The app picks up config changes on the next refresh (≤60s, or hit the refresh button). For a genuinely new backend, see [docs/provider-integration.md](docs/provider-integration.md).

## Privacy & security

Merlyn is a **read-only** usage viewer with no telemetry. It reads tokens that your existing CLIs already store locally, uses each for a single request to that provider's official API, and discards it — nothing is logged or sent anywhere else. It never refreshes Claude/Codex tokens; the one credential file it writes is Kimi's own (required by the CLI's rotation protocol). Full details and vulnerability reporting: [SECURITY.md](SECURITY.md).

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) © 2026 Pichaya Puttekulangkura.

## Notes

- First launch scans recent history once (~20s in the background); afterwards refreshes are incremental and take milliseconds. The parse cache lives at `~/Library/Application Support/Merlyn/usage-cache.json` and is safe to delete.
- Right-click the menu bar item for Refresh / Edit Providers / Quit.
