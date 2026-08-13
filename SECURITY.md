# Security Policy

Merlyn reads authentication tokens belonging to other tools on your machine, so
it takes credential handling seriously. This document explains exactly what it
touches, where data goes, and how to report a problem.

## What Merlyn accesses

Merlyn is a read-only usage viewer. It never signs you in, never creates
accounts, and never sends your tokens to any server other than each provider's
own official API.

**Credentials it reads locally:**

| Provider | Source | Notes |
|---|---|---|
| Claude | macOS Keychain item `Claude Code-credentials[-<hash>]`, read via `/usr/bin/security` | The OAuth token created by Claude Code itself. Merlyn never refreshes it. |
| Codex | `~/.codex/auth.json` | The ChatGPT OAuth token created by the Codex CLI. Merlyn never refreshes it. |
| Kimi | `~/.kimi-code/credentials/kimi-code.json` | 15-minute tokens. Merlyn **must** refresh them, following the CLI's exact lockfile protocol, and writes the rotated credentials back to that same file (see below). |

**Files it reads for offline fallback estimates (read-only):** agent transcript
and rollout logs under `~/.claude*`, `~/.codex/sessions/…`, and
`~/.kimi-code/sessions/…`.

**Files it writes:** only its own state, under
`~/Library/Application Support/Merlyn/` (`providers.json`, `usage-cache.json`,
`last-good.json`) — plus, for Kimi only, the rotated credential file named above.

## Where data goes on the network

Merlyn makes outbound HTTPS requests to these hosts and no others:

- `api.anthropic.com` — Claude usage
- `chatgpt.com` — Codex usage
- `api.kimi.com` / `auth.kimi.com` — Kimi usage and token refresh

A token is read, used for a single request, and discarded. Tokens are **never**
logged, **never** written to disk by Merlyn (the one exception being Kimi's own
credential file, which the CLI protocol requires us to update in place), and
**never** transmitted anywhere except the provider's own API above.

## Token-handling guarantees

- **Claude & Codex tokens are never refreshed.** If a token is expired, Merlyn
  falls back to a local estimate and leaves re-authentication to the provider's
  own CLI. This avoids racing the CLI's token lifecycle.
- **Kimi token refresh is done safely.** Because Kimi's refresh token rotates
  and is single-use, Merlyn acquires the CLI's own `flock` before refreshing,
  re-reads under the lock, and atomically persists the new credentials — so it
  cannot invalidate your `kimi` CLI login.
- Merlyn has no telemetry, analytics, or crash reporting. It phones home to no
  one.

## Distribution & code signing

Merlyn is distributed **as source only** — there is no signed, notarized build and
no official download. Notarization requires a paid Apple Developer Program
membership, and an unsigned download would force every user to click past
Gatekeeper's "cannot verify this app is free of malware" warning. For a tool that
reads credential tokens, that is the wrong habit to teach.

Build it yourself (see the README). A locally compiled app is never quarantined, so
Gatekeeper does not gate it at all. The bundle is ad-hoc signed because Apple
Silicon will not execute an unsigned binary; one consequence is that each rebuild is
a new code identity, so macOS re-asks for Keychain access after every build.

**Treat any `Merlyn.dmg` or prebuilt `Merlyn.app` offered to you as untrusted** — we
publish neither. See [`docs/specs/distribution.md`](docs/specs/distribution.md).

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately using GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab → **Report a vulnerability**
   (`https://github.com/mickyngub/merlyn/security/advisories/new`).
2. Describe the issue, affected version, and reproduction steps.

You can expect an initial response within a few days. Because this is a
small volunteer-maintained project, please allow reasonable time for a fix
before any public disclosure.

## Supported versions

Merlyn is source-distributed. Version tags (`v*`) exist so a built app can
report which version it came from, but they are not release artifacts: only
the latest `main` receives security fixes. Rebuild with
`scripts/install.sh --update` to pick them up.
