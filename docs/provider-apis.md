# Provider usage APIs — findings & integration notes

How Merlyn gets real, provider-reported rate limits for each agent CLI. Everything here was reverse-engineered on 2026-06-12 from the CLIs installed on this machine (Claude Code 2.1.170, Codex 0.139.0, Kimi Code via `~/.kimi-code/bin/kimi`); expect drift over time. Implementation lives in `Sources/Merlyn/Data/ProviderAPI.swift`, fallbacks in `Readers.swift`.

## TL;DR table

| Provider | Credential location | Token lifetime | Refresh? | Usage endpoint |
|---|---|---|---|---|
| Claude | macOS Keychain, service `Claude Code-credentials[-<hash>]` | ~hours–days | **Never** (we don't) | `GET https://api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` → `tokens.access_token` | ~days (CLI refreshes) | **Never** (we don't) | `GET https://chatgpt.com/backend-api/wham/usage` |
| Kimi | `~/.kimi-code/credentials/kimi-code.json` | **15 minutes** | **Yes — required**, with lockfile protocol | `GET https://api.kimi.com/coding/v1/usages` |

---

## Claude (Claude Code)

### Auth

- OAuth creds live in the **macOS Keychain** as a generic password. There is no `~/.claude/.credentials.json` on macOS (that's the Linux path).
- Service name: `Claude Code-credentials` for the default `~/.claude`. For a custom `CLAUDE_CONFIG_DIR` (e.g. `~/.claude-work`), the service is suffixed:

  ```
  "Claude Code-credentials-" + hex(sha256(absoluteConfigDirPath))[0..8]
  ```

  Verified: `sha256("/Users/micky/.claude-work")[:8] = ed92d010` matches the real keychain item.
