# Provider integration reference

How Merly obtains **real, provider-reported** rate limits — the same numbers as Claude's `/usage` screen, Codex Analytics, and the Kimi Console. This is the load-bearing knowledge for adding providers or debugging auth; the parsing lives in `Sources/Merly/Data/ProviderAPI.swift`, the orchestration in `Readers.swift`.

Everything here was reverse-engineered from the installed CLIs, last re-verified against live responses on **2026-09-05** (Claude Code 2.1.258, Codex CLI 0.152.1, Kimi Code 0.37.2). Endpoints and payload shapes can drift — when something breaks, re-derive from the binaries (see [Re-deriving from the CLIs](#re-deriving-from-the-clis)).

Kimi compatibility was additionally checked against the [official 2.2.0 release](https://github.com/MoonshotAI/kimi-code/releases/tag/%40moonshot-ai%2Fkimi-code%402.2.0) source on **2026-10-18**. This was a source and fixture check, not a live authenticated API probe.

## Design: API-first, with cache + estimate fallback

Each reader tries the live API first. The failure ladder (`apiFirst` in `Readers.swift`) is:

```
ProviderCard
   └─ Reader.read()                         // Readers.swift, per ProviderKind
        └─ apiFirst(fetch:fallback:)
             ├─ try fetch()                  // real limits → isEstimated:false; cached as last-good
             ├─ catch → cached real reading  // < 6h old   → isStale:true  ("as of 12m ago")
             └─ else  → fallback(error)
                  ├─ failureSnapshot(error)  // typed failure → error card, NO estimate
                  └─ else → local estimate   // isEstimated:true  (≈ on ring)
```

**A failure is a reading, not a reason to guess.** `failureSnapshot(_:config:)` maps the fetch error onto a `ProviderFailure` — `.signedOut` (no creds / expired / 401), `.refused` (any other 4xx: a 403 from a lapsed or org-disabled subscription), `.rateLimited` (429, including a live cooldown), `.offline` (network / 5xx) — and the card renders that instead of numbers. Only an *unclassifiable* failure (schema drift, an unreadable response from a healthy account) is allowed to fall through to the estimate. Every reader calls this before its own fallback; the plan pill survives all four kinds because it comes from the keychain.

**Why the cache tier matters.** The usage endpoints rate-limit (Anthropic's `/api/oauth/usage` will `429` under frequent polling). Without the cache, a single transient `429` would drop the card to local token estimation — and the estimate's "vs your busiest week" bars trend to ~100% by construction, which *looks like you're maxed out when you're not*. That was a real bug. Now a transient failure shows the last real numbers flagged stale; estimation only happens when there's no recent real reading at all (e.g. first run while offline).

**429 cooldown.** A `429` sets a 5-minute per-provider cooldown (`ReaderContext.cooldownUntil`) so we stop hammering an endpoint that's already refusing us; during cooldown the reader serves the cached real reading without calling the API. With no cache left, the cooldown reports itself as `http(429)` to the fallback — never as a nil error, which used to be read as "no reason given" and papered over a standing rate limit with an estimate.

**Estimates never alarm.** When `isEstimated`, the mascot mood uses the *session* figure only (not the self-referential weekly ratio), weekly bars render in the provider accent instead of escalating amber/red, and the ring shows `≈`. Estimated percentages are relative to the user's own busiest period, not a real quota — never present them as official.

**Persistence.** Last-good readings live in `~/Library/Application Support/Merly/last-good.json` (`LastGoodStore`); the file-parse cache for estimation lives in `usage-cache.json`. Both are safe to delete.

By default, refresh runs every 5 minutes in the rail or while hidden, and every 2 minutes with the panel expanded. Opening the panel immediately requests a refresh while respecting provider cooldowns. `refreshSeconds` customizes the expanded interval; background polling never runs faster than every 5 minutes. Readers run off the main thread (`UsageEngine.workQueue`), threading a `ReaderContext` (file cache + last-good + cooldowns) through each pass. All HTTP is synchronous via the `HTTP` helper in `ProviderAPI.swift` (a semaphore-blocked `URLSession` task), never on the main thread.

---

## Claude  (`kind: claude`)

Works for any Claude-Code-compatible CLI keyed by its config dir, so the two accounts (`~/.claude`, `~/.claude-work`) are just two provider entries.

**Credentials — macOS Keychain, generic password.** Service name depends on the config dir:

| Config dir | Keychain service |
|---|---|
| `$HOME/.claude` (the default) | `Claude Code-credentials` |
| anything else | `Claude Code-credentials-<hex>` where `<hex>` = first 8 chars of `sha256(absoluteConfigDir)` |

Verified on the author's machine: the absolute path of `~/.claude-work` hashed to `ed92d010`, giving `Claude Code-credentials-ed92d010`. The hex is machine-specific — it hashes the *absolute* config-dir path, so it differs per home directory. Implemented in `ClaudeUsageAPI.keychainService(forConfigDir:)`.

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
  "five_hour":        { "utilization": 23.0, "resets_at": "2026-06-11T22:20:00.311155+00:00",
                        "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null },
  "seven_day":        { "utilization": 11.0, "resets_at": "2026-06-18T13:00:00+00:00", ...same extra keys... },
  "seven_day_sonnet": null,                  // legacy per-model keys, now null (see limits[])
  "seven_day_opus":   null,
  "seven_day_oauth_apps": null, "seven_day_cowork": null, "seven_day_omelette": null,
  "tangelo": null, "iguana_necktie": null, "omelette_promotional": null, "cinder_cove": null, ...,
  "nimbus_quill":     { "utilization": 0.0, "resets_at": null, ... },   // unlabeled experiment buckets, ignored
  "extra_usage":      { "is_enabled": false, "monthly_limit": null, "user_disabled": true, "daily": null, "weekly": null, ... },
  "limits": [                                // unified array, the live source for per-model caps
    { "kind": "session",       "group": "session", "percent": 7,  "severity": "normal", "resets_at": "...", "scope": null, "is_active": true },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 49, "severity": "normal", "resets_at": "...", "scope": null, "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 83, "severity": "normal", "resets_at": "...",
      "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null }, "is_active": false }
  ],
  "spend": { "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 }, "limit": null, "percent": 0,
             "severity": "normal", "enabled": false, "can_purchase_credits": false, ... },
  "member_dashboard_available": false
}
```

Shape as of 2026-09-05. Newer than the June payload: per-window `*_dollars` / `locked_reason`, `severity` + `is_active` on each `limits[]` row, `scope.surface`, the `spend` block, and a churn of codenamed experiment buckets at the top level (`nimbus_quill`, `tangelo`, …). None of it is load-bearing for Merly; the decoder only reads `five_hour`, `seven_day`, and `limits[]`. Claude Code itself now calls `/api/oauth/usage?at_wall=1&skip_spend=1` when it hits a limit and filters `weekly_scoped` rows by a remote-config model allowlist, titling them "Current week (Fable)"; it ignores `is_active` too, so a 0% scoped row with `resets_at: null` is a normal idle state, not drift.

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
**Headers:** `Authorization: Bearer <access_token>`, `chatgpt-account-id: <account_id>`, `User-Agent: Merly`

```jsonc
{
  "user_id": "user-…", "account_id": "…", "email": "…",
  "plan_type": "prolite",
  "rate_limit": {
    "allowed": true, "limit_reached": false,
    "primary_window":   { "used_percent": 28, "limit_window_seconds": 604800, "reset_after_seconds": 190240, "reset_at": 1788787026 },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox", "normal_model_slug": null,
      "rate_limit": { "allowed": true, "limit_reached": false,
                      "primary_window":   { "used_percent": 0, "limit_window_seconds": 18000,  "reset_after_seconds": 18000,  "reset_at": … },
                      "secondary_window": { "used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 604800, "reset_at": … } } }
  ],
  "model_usage": { "gpt-6-astra": { "available": true, "available_at": null, "credits_would_enable": false } },
  "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0",
               "approx_local_messages": [0, 0], "approx_cloud_messages": [0, 0] },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "rate_limit_reset_credits": { "available_count": 3, "applicable_available_count": 0 }
}
```

Shape as of 2026-09-05. Newer than the June payload: `reset_after_seconds` beside `reset_at`, `code_review_rate_limit`, `model_usage`, `spend_control`, `rate_limit_reached_type`, `promo`, and `normal_model_slug` on additional limits. Merly reads none of them; the decoder's keys (`rate_limit.*_window`, `additional_rate_limits[]`, `plan_type`, `rate_limit_reset_credits`) are all still present. The binary (now at `/opt/homebrew/Caskroom/codex/<ver>/bin/codex`) still names `/wham/usage` alongside `/api/codex/usage`.

- `primary_window` → the primary limit, **whatever its span**: as of Aug 2026 this account reports `limit_window_seconds: 604800` with `secondary_window: null`, i.e. the primary *is* the weekly budget. Never assume 5h from the field name (see `LimitWindow`).
- `used_percent` is a plain number; `reset_at` is **epoch seconds** (not ISO). `parseAPIDate` handles both.
- `additional_rate_limits[]` become extra weekly/5h bars labeled by `limit_name` (capped at 4 total).
- `plan_type` → plan label via a lookup, not `.capitalized` ("prolite" is the rate-limited Pro tier → "Pro (5x)").
- `rate_limit_reset_credits` → `ResetCredits`: one-shot grants that clear a rate-limit window early. `available_count` is what the account holds; `applicable_available_count` is what can be spent on the window currently blocking you — **they differ** (1 / 0 here), so the card's `↺ N` tag only lights up (green) when `applicable > 0`. A missing `applicable_available_count` is read as 0, never as "all of them".

**Fallback** (offline/expired): Codex *also* writes `rate_limits` events into its rollout files at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. `CodexReader.rolloutFallback` tail-reads the newest such event — same window shape, just stale. This is why Codex degrades more gracefully than Claude/Kimi.

---

## Kimi  (`kind: kimi`)  — the tricky one

**Credentials — `~/.kimi-code/credentials/kimi-code.json`:**

```jsonc
{ "access_token": "...", "refresh_token": "...", "expires_at": 1781166713,  // epoch SECONDS
  "scope": "...", "token_type": "Bearer", "expires_in": 900 }
```

⚠️ **The access token lives only 15 minutes (`expires_in: 900`), so it is almost always expired when we read it — we must refresh, and the refresh token ROTATES.** If we refresh and don't persist the new refresh token back, the user's `kimi` CLI is logged out on its next launch. This is the single most dangerous integration in the app.

Coordinate with both supported CLI lock protocols (`KimiUsageAPI.freshAccessToken`):

1. If `expires_at > now + 60`, use the cached `access_token` — no refresh.
2. Otherwise acquire a nonblocking **exclusive `flock`** on `~/.kimi-code/oauth/kimi-code` for older clients, and atomically create the newer CLI's `oauth/kimi-code.lock` directory. Keep its modification time fresh while the request runs; current Kimi uses `proper-lockfile` with a five-second stale threshold. Contention fails closed. Merly never removes another owner's lock, including an abandoned one; the CLI handles stale-lock recovery.
3. **Re-read** the credentials under the lock — another process may have refreshed while we waited; if it's now fresh, use it.
4. `POST https://auth.kimi.com/api/oauth/token`, form-encoded:
   - `client_id = 17e5f671-d194-4dfb-9706-5516cb48c098`  (Kimi Code's public OAuth client id, from the binary)
   - `grant_type = refresh_token`
   - `refresh_token = <current>`
   - Response: `{ access_token, refresh_token, expires_in, scope, token_type }`
5. **Atomically persist** the rotated creds: write a uniquely named temporary file next to the credentials, then `replaceItemAt`. Update `access_token`, `refresh_token` (if returned), `expires_in`, and recompute `expires_at = now + expires_in`.
6. Stop the heartbeat and release only locks still owned by this operation. If ownership is lost after a token grant, adopt a fresh credential already written by the CLI when possible; otherwise report a coordination failure without overwriting another writer. A compromised lock can still require signing in again.

Merly uses the default mainland OAuth host, `https://auth.kimi.com`. The CLI's global/custom endpoint pairs and their `kimi-code-env-<hash>.json` credential slots are not currently supported; the CLI's host overrides do not change Merly's endpoints.

**Endpoint:** `GET https://api.kimi.com/coding/v1/usages`
(The CLI can override its base with `KIMI_CODE_BASE_URL`; Merly uses the default URL above.)
**Headers:** `Authorization: Bearer <token>`

```jsonc
{
  "user":  { "userId": "...", "region": "REGION_OVERSEA", "membership": { "level": "LEVEL_BASIC" } },
  "usage": { "limit": "100", "used": "82", "remaining": "18", "resetTime": "2026-06-13T16:08:51.026808Z" },
  "limits": [
    { "name": "…optional…",                          // CLI 0.37 reads an optional per-row name
      "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },   // MINUTE | HOUR | DAY | WEEK
      "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-06-12T01:08:51Z" } }
  ],
  "parallel":  { "limit": "10" },
  "totalQuota": { "limit": "100", "remaining": "99" },
  "boosterWallet": { "balance": { "type": "BOOSTER", "amount": …, "amountLeft": … },   // paid extra-usage wallet, fixed-point 1e6 = 1 cent
                     "monthlyChargeLimit": { "priceInCents": …, "currency": "USD" }, "monthlyUsed": {…} }
}
```

**When the subscription has lapsed or the credits are spent, the endpoint does not return this at all.** Observed 2026-09-05 on an expired subscription: the token refresh still succeeds, then `GET /usages` answers **HTTP 429** with

```jsonc
{ "code": "resource_exhausted", "message": "insufficient balance",
  "details": [{ "type": "common.error.v1.ErrorDetail",
                "debug": { "reason": "REASON_QUOTA_EXCEEDED", "localizedMessage": { "locale": "en-US", "message": "Credits used up." } } }] }
```

By status alone that is a transient rate limit: Merly used to show "Rate-limited, won't report quota right now" and back off for 5 minutes, forever. `KimiUsageAPI.classifyUsageFailure` reads the body (`REASON_QUOTA_EXCEEDED`, `exceeded_current_quota_error`, or the CLI's own `kimi-errors.ts` wording patterns: "insufficient balance", "please recharge", "in arrears", "exceeded your current quota") and throws `ProviderAPIError.quotaExhausted`, which classifies as `isAccessDenied` → the `.refused` card ("No usage access · no quota (Credits used up.)"). A 429 whose body doesn't match stays a real rate limit. The CLI's own `fetchManagedUsage` just surfaces the body text for any non-2xx, so this is the same verdict it shows.

- **All numeric values are strings** — parse with `flexDouble` (handles String/Int/Double).
- `usage` = the weekly summary → "Weekly" bar. `limits[]` = shorter windows; `duration: 300 / TIME_UNIT_MINUTE` is the ~5h rate-limit window → session ring. CLI 0.37's `parseManagedUsagePayload` also defaults the `usage` summary's window to 1 week when none is given, so Merly's 7-day assumption matches the CLI's. `timeUnit` now includes `TIME_UNIT_WEEK`; an optional `name` on a row overrides the generated "<span> limit" label. `boosterWallet` (paid extra usage) is parsed by the CLI but not shown by Merly.
- ⚠️ **`usage` states no window span** — unlike `limits[]`, which carries `duration` + `timeUnit`. "Weekly" is a *documented assumption* (7 × 86400 is passed in by `KimiReader`), which is why the menu bar tags it `wk` rather than claiming `7d`. Observed 2026-08-05 on a `LEVEL_BASIC` / `TYPE_PURCHASE` account: `usage: { limit: "100", used: "100", resetTime: <3 days out> }` with **no `remaining` key**, while `limits[0].detail` read `{ limit: "100", remaining: "100" }` — i.e. the rolling budget genuinely exhausted (100/100 used) while the 5h rate window was untouched. The two are independent; a maxed `usage` with a fresh `limits[0]` is a real state, not a parse error. Note it also makes that provider win the menu bar's "busiest" auto-pick for as long as it stays at 100%.
- The CLI's parser is deliberately loose because field names drift across versions: `used` vs `remaining` (derive `used = limit - remaining`), `resetTime` vs `resetAt` vs `reset_at`. `KimiUsageAPI.window` mirrors that tolerance.
- `membership.level` (`LEVEL_BASIC`) → plan label ("Basic").

**Current usage response:** Kimi Code 2.2.0 reads `usages.limit_5h`, `limit_7d`, `limit_month_total`, and `limit_month_code`. Each reports `used_ratio` and `reset_time`. Merly supports these alongside the older `usage`/`limits` response above, promotes the shortest reported window, and keeps monthly labels distinct from weekly limits. An unrecognized response is a parse failure, never a reported zero.

**Fallback:** estimate from `~/.kimi-code/sessions/wd_*/ses_*/agents/main/wire.jsonl`. Fallback estimates and usage details share `KimiUsageParser`. Both turn- and session-scoped `usage.record` events are additive; session scope includes compaction. Legacy `step.end` records remain counted unless a nearby modern record repeats the same counters within the same request boundary. Because usage records omit request IDs, pairing is conservative: matching counters within one second, without crossing a turn, step, or request start. Session-scoped usage never replaces a legacy step. Both formats carry `usage: {inputOther, output, inputCacheRead, inputCacheCreation}` and an epoch-ms `time`. The Kimi parse-cache namespace changes with this interpretation. Analytics derive the session identity above `agents`, keeping worker identity separate; legacy direct `ses_*/wire.jsonl` paths remain supported.

---

## Cross-cutting notes

- **Mood & menu bar track the *closest* limit, not just the session.** `ProviderSnapshot.pressurePct = max(sessionPct, max(weekly%))`. A fresh session with a near-full weekly cap should still show a stressed mascot. The menu bar extra renders the provider with the highest `pressurePct`.
- **Reset-time suppression:** session windows report a `resets_at` even when idle at 0%. `sessionReset()` returns `nil` at 0% so the card reads "No active session" instead of counting down to nothing.
- **Refresh policy summary:** Kimi — yes, with lock + persist. Claude & Codex — **never**; fall back on expiry.
- **Token hygiene:** tokens are read, used for one request, and discarded. They are never logged, cached to disk by us (except Kimi's own credential file we must write back), or sent anywhere but the provider's API.

## Adding a provider

If it's Claude-Code / Codex / Kimi-compatible, just add an entry to `~/Library/Application Support/Merly/providers.json` (`kind`, `dir`, `style`, `palette`) — no code. For a genuinely new backend:

1. Add a case to `ProviderKind` plus its `ProviderDescriptor` (`ProviderKind.swift`) — the descriptor is the one-stop fact table (name, default dir, login command, sprite family, lane hue, reader factory) every other switch derives from.
2. Add a `<Name>UsageAPI` enum to `ProviderAPI.swift` returning windows + plan label.
3. Add a `<Name>Reader: UsageReader` to `Readers.swift` (API-first, file fallback) — the descriptor's `makeReader` wires it up; there is no separate switch to touch.
4. Add an entry to `AppConfig.knownProviders` (with on-disk markers) so first-run auto-detection finds it, plus a bundled sprite sheet for its `spriteFamily`.

## Re-deriving from the CLIs

When an endpoint changes, the CLIs are the source of truth. Locations as of June 2026:

- **Kimi:** `~/.kimi-code/bin/kimi` — a ~170 MB bundled-JS binary (0.37.2). The original TS is embedded as `//#region ../../packages/oauth/src/<file>.ts` blocks. Grep with Python:
  ```python
  import os; data = open(os.path.expanduser('~/.kimi-code/bin/kimi'), 'rb').read()
  i = data.find(b'packages/oauth/src/managed-usage.ts'); print(data[i:i+3800].decode('utf-8','replace'))
  ```
  Key files: `managed-usage.ts` (endpoint + `parseManagedUsagePayload` + `fetchManagedUsage`), `constants.ts` (`clientId`, `oauthHost`), `kimi-errors.ts` (the quota-exhausted wording patterns), and the `refreshAccessToken` fn (`/api/oauth/token`, flock).
- **Codex:** `/opt/homebrew/Caskroom/codex/<ver>/bin/codex` (Rust; was `codex-aarch64-apple-darwin` in older casks). `strings | grep` for `/wham/usage`, `/api/codex/usage`, `backend-api`.
- **Claude:** `/opt/homebrew/Caskroom/claude-code@latest/<ver>/claude` (~222 MB). Contains the usage strings (`/api/oauth/usage`, `five_hour`, `seven_day`, `weekly_scoped`); grep around `weekly_scoped` for the `limits[]` filter (`Nue()` in 2.1.258). Note the npm `cli.js` under `~/.claude/local/...` may lag and *not* contain them — prefer the Caskroom binary.

Live probes (read-only except Kimi, which rotates tokens — run sparingly). For Kimi, let Merly do the refresh (`.build/debug/Merly --print`), then reuse the token it persisted while it is still fresh:

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

# Kimi (after a Merly --print has just refreshed the token)
python3 - <<'PY'
import json,urllib.request,os
c=json.load(open(os.path.expanduser('~/.kimi-code/credentials/kimi-code.json')))
r=urllib.request.Request('https://api.kimi.com/coding/v1/usages',headers={'Authorization':'Bearer '+c['access_token']})
try: print(urllib.request.urlopen(r,timeout=20).read().decode())
except urllib.error.HTTPError as e: print(e.code, e.read().decode())   # 429 + "insufficient balance" = lapsed, not rate-limited
PY
```
