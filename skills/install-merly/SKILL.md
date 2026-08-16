---
name: install-merly
description: Install, update, or troubleshoot Merly — the macOS menu bar app that tracks Claude/Codex/Kimi agent quota usage with pixel mascots. Merly ships as source only (no DMG, no download), so installing means build → /Applications via scripts/install.sh. Use this skill whenever someone wants to install, set up, build, reinstall, update, or upgrade Merly, or get it running on a new Mac. Also use it when Merly misbehaves after an install — nothing appears in the menu bar, usage alerts never show up, the Keychain prompt keeps coming back after every build, "no providers configured", missing or stale usage numbers, `≈` estimates instead of real limits, or a build that won't compile. Also use it if they describe wanting "that quota mascot app" running.
---

# Installing Merly

Merly is a native macOS menu bar app that reads how much of your AI coding agent
quota you've burned (Claude across multiple accounts, Codex, Kimi) and gives each
provider a pixel critter whose mood tracks usage.

**It is distributed as source only** — there is no DMG and no prebuilt download, by
design. Notarizing a Mac app requires a paid Apple Developer membership, and an
unsigned download would train people to click past Gatekeeper's malware warning for
an app that reads their credential tokens. Building locally is both free and
friction-free: **an app you compile yourself is never quarantined**, so Gatekeeper
never gates it. If someone asks where to download it, that's the answer.

Repo: <https://github.com/mickyngub/merly>

## Install

One command does everything — preflight, build, quit any running copy, install,
launch:

```sh
scripts/install.sh
```

It builds whatever is currently checked out. Pulling is opt-in (`--update`),
because an installer that silently moves your HEAD can discard work in progress.

No checkout yet? Either clone first, or let the script do it:

```sh
git clone https://github.com/mickyngub/merly.git ~/dev/merly
cd ~/dev/merly && scripts/install.sh
```

Useful variants:

| Command | Effect |
|---|---|
| `scripts/install.sh --update` | `git pull --ff-only` first, then build and install |
| `scripts/install.sh ~/code/merly` | Use (or clone into) that directory |
| `NO_INSTALL=1 scripts/install.sh` | Build only; don't touch `/Applications` |
| `NO_LAUNCH=1 scripts/install.sh` | Install but don't open the app |
| `MERLY_REPO=<url> scripts/install.sh <dir>` | Clone from a fork or mirror instead |

The script refuses to proceed on macOS 13 or older, or without a Swift 5.9+
toolchain — both are hard requirements (`Package.swift` declares `.macOS(.v14)`;
`Info.plist` sets `LSMinimumSystemVersion 14.0`). If `swift` is missing,
`xcode-select --install` is enough; a full Xcode install is not needed.

To do it by hand instead, the whole of it is: `scripts/bundle.sh`, then quit any
running Merly, then `cp -R build/Merly.app /Applications/`.

## Verify headlessly before touching the UI

Run this **before** debugging anything visual. The installed app's own binary takes
the flag, so this needs no extra build:

```sh
/Applications/Merly.app/Contents/MacOS/Merly --print
```

(Working in a checkout instead? `swift build && .build/debug/Merly --print`. Note
that `install.sh` builds *release* only, so `.build/debug/` won't exist until you run
a plain `swift build`.)

`--print` fetches every provider and dumps the readings to stdout with no UI at
all — it's checked before `NSApplication` is even created, so nothing appears on
screen. It separates the two failure classes that look identical from the menu bar:

- **Numbers print** → auth, network and parsing all work. Anything still wrong is
  presentation — see "Nothing in the menu bar" below.
- **Nothing prints, or every provider errors** → it's a data problem. Each
  provider's line says what failed.

A first run scans your agent history once (~20s, in the background) and caches it,
so the first `--print` is slow and later ones take milliseconds.

## First launch

Merly sets `LSUIElement`, so **there is no Dock icon and no window**. Look at the
top of the screen for a small critter with `5h` and `w` bars beneath it. Left-click
toggles the panel; right-click opens the menu.

It will ask for **Keychain access** to read the Claude Code credentials — click
**Always Allow**.

> ### That Keychain prompt returns after every rebuild — this is expected
>
> Merly is never signed *for* distribution: there is no shipped artifact to sign.
> Each machine signs its own build, locally, with whatever identity that machine
> has. Signing still happens on every build because Apple Silicon refuses to
> execute an entirely unsigned binary — so with no certificate present the build is
> **ad-hoc** signed, a signature carrying no identity. Its designated requirement is
> then a hash of that one binary:
>
> ```sh
> codesign -d -r- /Applications/Merly.app   # => cdhash H"..."
> ```
>
> Every build produces a different hash, so every build is a new app to the
> Keychain, and the "Always Allow" grant for the Claude credentials is asked for
> again. Say this up front so a returning prompt doesn't read as sinister.
>
> **Install once and it costs one prompt, so there is nothing to fix.**
>
> If someone proposes curing it with a self-signed code-signing certificate:
> don't. It was tried and reverted. Signing with a real key makes `codesign` pull
> a private key out of the login Keychain, so **the build** starts stopping with
> *"codesign wants to use key …"* — a much more alarming prompt than the one it
> removes, and it comes back whenever the key's ACL is invalidated. It also needs
> a login-password dialog to trust the certificate, helps no other machine, and
> has **no effect on notifications**. Details in `docs/specs/distribution.md`.

## Update

```sh
scripts/install.sh --update
```

Expect the Keychain prompt again, for the reason above.

## Troubleshooting

Work from the symptom.

**`swift: command not found`, or `unable to find utility "xcrun"`**
Command Line Tools missing or not selected. `xcode-select --install`, then
`xcode-select -p` should print a path.

**Build fails on a Swift syntax error**
Check `swift --version` is 5.9+. Older toolchains fail on syntax the package uses.

**"no providers configured", or cards with no data**
On first run Merly auto-detects installed CLIs by looking for *specific marker
files* under `~/.claude*`, `~/.codex`, `~/.kimi-code` — not bare directories, so a
`skills/`-only folder isn't a false positive. If none of those CLIs are installed
there is genuinely nothing to report. Otherwise add a provider by hand:

```sh
open ~/Library/Application\ Support/Merly/providers.json
```

```json
{
  "id": "claude-work",
  "name": "Claude",
  "account": "Work",
  "kind": "claude",
  "dir": "~/.claude-work"
}
```

`kind` is `claude` | `codex` | `kimi`. The file is re-read every refresh cycle
(≤60s) — no restart needed.

**A provider shows an error badge instead of a gauge**
Deliberate: Merly refuses to invent a number it can't read, so a failure gets a
badge rather than a 0% gauge that would read as "plenty left". The tooltip and card
name the cause. If a login lapsed, sign in with that CLI's own command
(`claude auth login`, `codex login`, `kimi login`) or the panel's sign-in button —
Merly never mints or refreshes tokens itself.

**Percentages show `≈`**
Local estimates, not real quota: the API was unreachable or a login is stale, so it
fell back to analyzing local logs relative to your busiest period. Fix the auth and
real figures return.

**Nothing in the menu bar**
Check it's running (`pgrep -fl Merly`). If it is, the menu bar is probably full —
on notch Macs, items silently overflow behind the notch. Quit something else up
there, or use a menu bar manager. There's no Dock icon to fall back on.

**Numbers look frozen or wrong**
Delete the parse cache; it rebuilds safely (first rescan ~20s):

```sh
rm ~/Library/Application\ Support/Merly/usage-cache.json
```

**Usage alerts never appear**
First check they're on: panel → gear → **Alerts**. That section's bottom row says
what macOS will do with an alert and has a **Send a test** button — use it before
anything else, since silence otherwise looks the same as "nothing crossed a limit".

- *"Notifications are turned off"* / *"alert style is None"* → fix it in System
  Settings › Notifications › Merly (the row's button opens it).
- Also check Focus / Do Not Disturb isn't swallowing them.

From a terminal, `/Applications/Merly.app/Contents/MacOS/Merly --notify-test`
posts one alert and logs the authorization callback and the permission state.

**`requestAuthorization` fails with "Notifications are not allowed for this
application"** (`UNErrorDomain Code=1`)
It means exactly what it says: **the permission has not been granted**. Grant it —
allow notifications for Merly — and the same binary reads `granted` at once.

Do **not** go hunting for a technical cause. Every one of these was measured and
ruled out over a long session: the code signature (ad-hoc, self-signed, and
self-signed-and-trusted all behaved identically), the entitlements blob, duplicate
LaunchServices registrations, the usernoted database, `com.apple.ncprefs.plist`,
`tccutil reset`, and MDM profiles.

And **never change `CFBundleIdentifier` to fix it** — the grant hangs off the id, so
a rename throws it away and the prompt does not reliably come back. That mistake is
what made this look unfixable. Full write-up: `docs/specs/distribution.md`
§ Notifications.

**Kimi CLI got logged out**
Kimi's refresh tokens rotate, and only Merly's own refresh path persists the
rotated ones correctly. Never hand-edit
`~/.kimi-code/credentials/kimi-code.json` — re-run `kimi login`.

## Uninstall

```sh
osascript -e 'quit app "Merly"' 2>/dev/null || true
rm -rf /Applications/Merly.app
rm -rf ~/Library/Application\ Support/Merly   # config + parse cache
```

Merly stores nothing else and has no telemetry. Removing it doesn't touch any
CLI's credentials.

## Reference

QA flags. These work on any build of the binary — the installed one
(`/Applications/Merly.app/Contents/MacOS/Merly`) or a checkout's
`.build/debug/Merly` after `swift build`:

| Flag | Effect |
|---|---|
| `--print` | Headless dump of every provider reading, then exit |
| `--open` | Launch with the panel already open |
| `--expand` | With `--open`: cards expanded |
| `--rail` | With `--open`: collapsed to the mascot rail |
| `--edit` | With `--open`: the list in reorder/delete mode |
| `--light` | Force the light theme |
| `--mascot` | Jump straight to the mascot editor |
| `--notify-test` | Post one alert and log macOS's verdict on it |

Paths:

- Config: `~/Library/Application Support/Merly/providers.json` (moved from
  `Merlyn/` on first launch after the rename — if someone reports "all my
  providers vanished", check whether a stray `Merly/` folder pre-empted the move)
- Parse cache: `~/Library/Application Support/Merly/usage-cache.json` (safe to delete)
- Build output: `build/Merly.app` in the checkout
- Bundle id: `sh.micky.merly` — keep it stable; the Keychain grant is tied to it.
  It changed from `sh.micky.merlyn` in the rename, so anyone upgrading across it
  must re-allow notifications and re-approve the Keychain prompt once.

Deeper detail: [docs/specs/distribution.md](../../docs/specs/distribution.md) for
signing, [docs/provider-integration.md](../../docs/provider-integration.md) for
auth flows and endpoints.
