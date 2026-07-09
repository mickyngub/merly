# Provider integration reference

How Usage Dock obtains **real, provider-reported** rate limits — the same numbers as Claude's `/usage` screen, Codex Analytics, and the Kimi Console. This is the load-bearing knowledge for adding providers or debugging auth; the parsing lives in `Sources/UsageDock/Data/ProviderAPI.swift`, the orchestration in `Readers.swift`.

Everything here was reverse-engineered from the installed CLIs (June 2026 versions). Endpoints and payload shapes can drift — when something breaks, re-derive from the binaries (see [Re-deriving from the CLIs](#re-deriving-from-the-clis)).

## Design: API-first, with cache + estimate fallback

Each reader tries the live API first. The failure ladder (`apiFirst` in `Readers.swift`) is:

```
ProviderCard
   └─ Reader.read()                         // Readers.swift, per ProviderKind
        └─ apiFirst(fetch:fallback:)
             ├─ try fetch()                  // real limits → isEstimated:false; cached as last-good
             ├─ catch → cached real reading  // < 6h old   → isStale:true  ("as of 12m ago")
             └─ else  → local fallback       // estimate    → isEstimated:true  (≈ on ring)
```

**Why the cache tier matters.** The usage endpoints rate-limit (Anthropic's `/api/oauth/usage` will `429` under frequent polling). Without the cache, a single transient `429` would drop the card to local token estimation — and the estimate's "vs your busiest week" bars trend to ~100% by construction, which *looks like you're maxed out when you're not*. That was a real bug. Now a transient failure shows the last real numbers flagged stale; estimation only happens when there's no recent real reading at all (e.g. first run while offline).

**429 cooldown.** A `429` sets a 5-minute per-provider cooldown (`ReaderContext.cooldownUntil`) so we stop hammering an endpoint that's already refusing us; during cooldown the reader serves cached/estimated data without calling the API.

**Estimates never alarm.** When `isEstimated`, the mascot mood uses the *session* figure only (not the self-referential weekly ratio), weekly bars render in the provider accent instead of escalating amber/red, and the ring shows `≈`. Estimated percentages are relative to the user's own busiest period, not a real quota — never present them as official.

**Persistence.** Last-good readings live in `~/Library/Application Support/UsageDock/last-good.json` (`LastGoodStore`); the file-parse cache for estimation lives in `usage-cache.json`. Both are safe to delete.

Refresh runs every 60s off the main thread (`UsageEngine.workQueue`), threading a `ReaderContext` (file cache + last-good + cooldowns) through all readers in one pass. All HTTP is synchronous via the `HTTP` helper in `ProviderAPI.swift` (a semaphore-blocked `URLSession` task) — fine because it's never on the main thread.

---

## Claude  (`kind: claude`)

Works for any Claude-Code-compatible CLI keyed by its config dir, so the two accounts (`~/.claude`, `~/.claude-work`) are just two provider entries.

**Credentials — macOS Keychain, generic password.** Service name depends on the config dir:

| Config dir | Keychain service |
|---|---|
| `$HOME/.claude` (the default) | `Claude Code-credentials` |
| anything else | `Claude Code-credentials-<hex>` where `<hex>` = first 8 chars of `sha256(absoluteConfigDir)` |

Verified: `/Users/micky/.claude-work` → `ed92d010` → `Claude Code-credentials-ed92d010`. Implemented in `ClaudeUsageAPI.keychainService(forConfigDir:)`.

**Read it via `/usr/bin/security`, not `SecItemCopyMatching`.** The keychain ACL prompt attaches to the *requesting binary's code signature*. Our app is ad-hoc signed, so every rebuild is a new identity and re-prompts forever. Shelling out to the stable, already-authorized `/usr/bin/security find-generic-password -s <service> -w` sidesteps that — one "Always Allow" (usually already granted by Claude Code itself) sticks across rebuilds. See `ClaudeUsageAPI.readKeychain`.

The returned blob is JSON. Tokens may be nested under `claudeAiOauth` or flat:

```jsonc
{ "claudeAiOauth": {
    "accessToken":  "...",
    "refreshToken": "...",
    "expiresAt":    1781234567890,        // epoch MILLISECONDS
    "scopes":       ["user:inference", "user:profile", ...],
    "subscriptionType": "max",            // or "team", "pro", ...
    "rateLimitTier":    "default_claude_max_20x"
}}
```

**Never refresh this token.** If `expiresAt` is past, throw `expiredToken` and fall back — let the user's own `claude` re-auth. Racing Claude Code's refresh risks invalidating its session.

**Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
**Headers:** `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`

```jsonc
{
  "five_hour":        { "utilization": 23.0, "resets_at": "2026-06-11T22:20:00.311155+00:00" },
  "seven_day":        { "utilization": 11.0, "resets_at": "2026-06-18T13:00:00+00:00" },
  "seven_day_sonnet": null,                  // legacy per-model keys — now GOING NULL (see limits[])
  "seven_day_opus":   null,
  "extra_usage":      { "is_enabled": false, "monthly_limit": null, ... },
  "limits": [                                // newer unified array — the live source for per-model caps
    { "kind": "session",       "group": "session", "percent": 7,  "resets_at": "..." },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 49, "resets_at": "..." },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 83, "resets_at": "...",
      "scope": { "model": { "id": null, "display_name": "Fable" } }, "is_active": true }
  ]
}
```

- `utilization` is already a percentage (0–100). `resets_at` is ISO 8601 with **microsecond** precision + offset — trim to milliseconds before `ISO8601DateFormatter` (`parseAPIDate` does this).
- Mapping: `five_hour` → session ring; `seven_day` → "All models" weekly bar.
- **Per-model weekly caps migrated to `limits[]`.** As of July 2026 the top-level `seven_day_sonnet`/`_opus` keys return `null`; the model-scoped caps (Sonnet, Opus, and now **Fable**) arrive as `limits[]` entries with `kind: "weekly_scoped"` and `scope.model.display_name`. `ClaudeUsageAPI.fetch` prefers the array (each `weekly_scoped` → a "`<display_name>` only" weekly bar via `percent`/`resets_at`) and falls back to the legacy keys only when `limits[]` is absent. The array also carries `session`/`weekly_all` entries mirroring the top-level windows.
- **Plan label:** combine `subscriptionType` + the `Nx` suffix of `rateLimitTier` → "Max (20x)", "Team (5x)". See `ClaudeUsageAPI.planLabel`.

---

## Codex  (`kind: codex`)

**Credentials — `~/.codex/auth.json`** (plain file):

```jsonc
{
  "OPENAI_API_KEY": "...",
  "auth_mode": "chatgpt",
  "last_refresh": "2026-06-05T16:43:01Z",
  "tokens": { "access_token": "...", "account_id": "user-...", "id_token": "...", "refresh_token": "..." }
}
```

**Never refresh** (same reasoning as Claude). The Codex CLI manages its own token lifecycle.

**Endpoint:** `GET https://chatgpt.com/backend-api/wham/usage`
(The binary also references `/backend-api/api/codex/usage`; `/wham/usage` is the one that returns the full structure.)
**Headers:** `Authorization: Bearer <access_token>`, `chatgpt-account-id: <account_id>`, `User-Agent: UsageDock`

```jsonc
{
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window":   { "used_percent": 8,  "limit_window_seconds": 18000,  "reset_at": 1781214822 },
    "secondary_window": { "used_percent": 11, "limit_window_seconds": 604800, "reset_at": 1781762602 }
  },
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
      "rate_limit": { "primary_window": {...}, "secondary_window": {...} } }
  ],
  "credits": { "has_credits": false, "balance": "0", ... }
}
```

- `primary_window` (18000s = 5h) → session ring. `secondary_window` (604800s = weekly) → "Weekly" bar.
- `used_percent` is a plain number; `reset_at` is **epoch seconds** (not ISO). `parseAPIDate` handles both.
- `additional_rate_limits[]` become extra weekly/5h bars labeled by `limit_name` (capped at 4 total).
- `plan_type` → capitalized plan label ("Prolite").

**Fallback** (offline/expired): Codex *also* writes `rate_limits` events into its rollout files at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. `CodexReader.rolloutFallback` tail-reads the newest such event — same window shape, just stale. This is why Codex degrades more gracefully than Claude/Kimi.

---

## Kimi  (`kind: kimi`)  — the tricky one

**Credentials — `~/.kimi-code/credentials/kimi-code.json`:**

```jsonc
{ "access_token": "...", "refresh_token": "...", "expires_at": 1781166713,  // epoch SECONDS
  "scope": "...", "token_type": "Bearer", "expires_in": 900 }
```

⚠️ **The access token lives only 15 minutes (`expires_in: 900`), so it is almost always expired when we read it — we must refresh, and the refresh token ROTATES.** If we refresh and don't persist the new refresh token back, the user's `kimi` CLI is logged out on its next launch. This is the single most dangerous integration in the app.

Replicate the CLI's exact protocol (`KimiUsageAPI.freshAccessToken`):

1. If `expires_at > now + 60`, use the cached `access_token` — no refresh.
2. Otherwise acquire an **exclusive `flock`** on `~/.kimi-code/oauth/kimi-code` (the CLI's own lockfile; serializes refreshes across the CLI and us so we don't both spend the same single-use refresh token).
3. **Re-read** the credentials under the lock — another process may have refreshed while we waited; if it's now fresh, use it.
4. `POST https://auth.kimi.com/api/oauth/token`, form-encoded:
   - `client_id = 17e5f671-d194-4dfb-9706-5516cb48c098`  (Kimi Code's public OAuth client id, from the binary)
   - `grant_type = refresh_token`
   - `refresh_token = <current>`
   - Response: `{ access_token, refresh_token, expires_in, scope, token_type }`
5. **Atomically persist** the rotated creds: write `credentials/kimi-code.json.tmp`, then `replaceItemAt`. Update `access_token`, `refresh_token` (if returned), `expires_in`, and recompute `expires_at = now + expires_in`.
6. Release the lock.

Overridable like the CLI: `KIMI_CODE_OAUTH_HOST` / `KIMI_OAUTH_HOST` (default `https://auth.kimi.com`).

**Endpoint:** `GET https://api.kimi.com/coding/v1/usages`
(Base overridable via `KIMI_CODE_BASE_URL`, default `https://api.kimi.com/coding/v1`, then `+ /usages`.)
**Headers:** `Authorization: Bearer <token>`

```jsonc
{
  "user":  { "userId": "...", "region": "REGION_OVERSEA", "membership": { "level": "LEVEL_BASIC" } },
  "usage": { "limit": "100", "used": "82", "remaining": "18", "resetTime": "2026-06-13T16:08:51.026808Z" },
  "limits": [
    { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
      "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-06-12T01:08:51Z" } }
  ],
  "parallel":  { "limit": "10" },
  "totalQuota": { "limit": "100", "remaining": "99" }
}
```

- **All numeric values are strings** — parse with `flexDouble` (handles String/Int/Double).
- `usage` = the weekly summary → "Weekly" bar. `limits[]` = shorter windows; `duration: 300 / TIME_UNIT_MINUTE` is the ~5h rate-limit window → session ring.
- The CLI's parser is deliberately loose because field names drift across versions: `used` vs `remaining` (derive `used = limit - remaining`), `resetTime` vs `resetAt` vs `reset_at`. `KimiUsageAPI.window` mirrors that tolerance.
- `membership.level` (`LEVEL_BASIC`) → plan label ("Basic").

**Fallback:** estimate from `~/.kimi-code/sessions/wd_*/ses_*/agents/main/wire.jsonl` — `step.end` events carry `usage: {inputOther, output, inputCacheRead, inputCacheCreation}` and an epoch-ms `time` (`KimiReader.estimate` + `TokenWindowEstimator`).

---

## Cross-cutting notes

- **Mood & menu bar track the *closest* limit, not just the session.** `ProviderSnapshot.pressurePct = max(sessionPct, max(weekly%))`. A fresh session with a near-full weekly cap should still show a stressed mascot. The menu bar extra renders the provider with the highest `pressurePct`.
- **Reset-time suppression:** session windows report a `resets_at` even when idle at 0%. `sessionReset()` returns `nil` at 0% so the card reads "No active session" instead of counting down to nothing.
- **Refresh policy summary:** Kimi — yes, with lock + persist. Claude & Codex — **never**; fall back on expiry.
- **Token hygiene:** tokens are read, used for one request, and discarded. They are never logged, cached to disk by us (except Kimi's own credential file we must write back), or sent anywhere but the provider's API.

## Adding a provider

If it's Claude-Code / Codex / Kimi-compatible, just add an entry to `~/Library/Application Support/UsageDock/providers.json` (`kind`, `dir`, `style`, `palette`) — no code. For a genuinely new backend:

1. Add a case to `ProviderKind` (`Models.swift`).
2. Add a `<Name>UsageAPI` enum to `ProviderAPI.swift` returning windows + plan label.
3. Add a `<Name>Reader: UsageReader` to `Readers.swift` (API-first, file fallback), and wire it in `reader(for:)`.
4. Pick a `MascotStyle` silhouette and a `MascotPalette` preset (or add one).

## Re-deriving from the CLIs

When an endpoint changes, the CLIs are the source of truth. Locations as of June 2026:

- **Kimi:** `~/.kimi-code/bin/kimi` — a ~126 MB bundled-JS binary. The original TS is embedded as `//#region ../../packages/oauth/src/<file>.ts` blocks. Grep with Python:
  ```python
  data = open('/Users/micky/.kimi-code/bin/kimi','rb').read()
  i = data.find(b'packages/oauth/src/managed-usage.ts'); print(data[i:i+3800].decode('utf-8','replace'))
  ```
  Key files: `managed-usage.ts` (endpoint + parser), `constants.ts` (`clientId`, `oauthHost`), and the `refreshAccessToken` fn (`/api/oauth/token`, flock).
- **Codex:** `/opt/homebrew/Caskroom/codex/<ver>/codex-aarch64-apple-darwin` (Rust). `strings | grep` for `/wham/usage`, `/api/codex/usage`, `backend-api`.
- **Claude:** `/opt/homebrew/Caskroom/claude-code@latest/<ver>/claude` (~222 MB). Contains the usage strings (`/api/oauth/usage`, `five_hour`, `seven_day`). Note the npm `cli.js` under `~/.claude/local/...` may lag and *not* contain them — prefer the Caskroom binary.

Live probes (read-only except Kimi, which rotates tokens — run sparingly):

```bash
# Claude
TOK=$(security find-generic-password -s "Claude Code-credentials" -w | python3 -c 'import json,sys;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -s https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $TOK" -H "anthropic-beta: oauth-2025-04-20" | jq

# Codex
python3 - <<'PY'
import json,urllib.request,os
a=json.load(open(os.path.expanduser('~/.codex/auth.json')))['tokens']
r=urllib.request.Request('https://chatgpt.com/backend-api/wham/usage',
  headers={'Authorization':f'Bearer {a["access_token"]}','chatgpt-account-id':a['account_id']})
print(urllib.request.urlopen(r,timeout=20).read().decode())
PY
```
