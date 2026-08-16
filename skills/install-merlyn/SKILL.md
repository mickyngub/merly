---
name: install-merlyn
description: Install, update, or troubleshoot Merlyn — the macOS menu bar app that tracks Claude/Codex/Kimi agent quota usage with pixel mascots. Merlyn ships as source only (no DMG, no download), so installing means build → /Applications via scripts/install.sh. Use this skill whenever someone wants to install, set up, build, reinstall, update, or upgrade Merlyn, or get it running on a new Mac. Also use it when Merlyn misbehaves after an install — nothing appears in the menu bar, usage alerts never show up, the Keychain prompt keeps coming back after every build, "no providers configured", missing or stale usage numbers, `≈` estimates instead of real limits, or a build that won't compile. Also use it if they describe wanting "that quota mascot app" running.
---

# Installing Merlyn

Merlyn is a native macOS menu bar app that reads how much of your AI coding agent
quota you've burned (Claude across multiple accounts, Codex, Kimi) and gives each
provider a pixel critter whose mood tracks usage.

**It is distributed as source only** — there is no DMG and no prebuilt download, by
design. Notarizing a Mac app requires a paid Apple Developer membership, and an
unsigned download would train people to click past Gatekeeper's malware warning for
an app that reads their credential tokens. Building locally is both free and
friction-free: **an app you compile yourself is never quarantined**, so Gatekeeper
never gates it. If someone asks where to download it, that's the answer.

Repo: <https://github.com/mickyngub/merlyn>

## Install

Once per machine, before the first build — this is what lets macOS remember the
notification permission and the Keychain grant across rebuilds (see *First launch*
for why it matters):

```sh
scripts/make-signing-cert.sh
```

Then one command does everything — preflight, build, quit any running copy,
install, launch:

```sh
scripts/install.sh
```

It builds whatever is currently checked out. Pulling is opt-in (`--update`),
because an installer that silently moves your HEAD can discard work in progress.

No checkout yet? Either clone first, or let the script do it:

```sh
git clone https://github.com/mickyngub/merlyn.git ~/dev/merlyn
cd ~/dev/merlyn && scripts/install.sh
```

Useful variants:

| Command | Effect |
|---|---|
| `scripts/install.sh --update` | `git pull --ff-only` first, then build and install |
| `scripts/install.sh ~/code/merlyn` | Use (or clone into) that directory |
| `NO_INSTALL=1 scripts/install.sh` | Build only; don't touch `/Applications` |
| `NO_LAUNCH=1 scripts/install.sh` | Install but don't open the app |
| `MERLYN_REPO=<url> scripts/install.sh <dir>` | Clone from a fork or mirror instead |

The script refuses to proceed on macOS 13 or older, or without a Swift 5.9+
toolchain — both are hard requirements (`Package.swift` declares `.macOS(.v14)`;
`Info.plist` sets `LSMinimumSystemVersion 14.0`). If `swift` is missing,
`xcode-select --install` is enough; a full Xcode install is not needed.

To do it by hand instead, the whole of it is: `scripts/bundle.sh`, then quit any
running Merlyn, then `cp -R build/Merlyn.app /Applications/`.

## Verify headlessly before touching the UI

Run this **before** debugging anything visual. The installed app's own binary takes
the flag, so this needs no extra build:

```sh
/Applications/Merlyn.app/Contents/MacOS/Merlyn --print
```

(Working in a checkout instead? `swift build && .build/debug/Merlyn --print`. Note
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

Merlyn sets `LSUIElement`, so **there is no Dock icon and no window**. Look at the
top of the screen for a small critter with `5h` and `w` bars beneath it. Left-click
toggles the panel; right-click opens the menu.

It will ask for **Keychain access** to read the Claude Code credentials — click
**Always Allow**.

> ### Run the signing-identity script once, before the first build
>
> ```sh
> scripts/make-signing-cert.sh
> ```
>
> macOS ties two grants to an app's exact code signature. Without a stable
> identity, an *ad-hoc* signed Merlyn has a designated requirement that is a hash of
> that one binary:
>
> ```sh
> codesign -d -r- /Applications/Merlyn.app   # => cdhash H"..."
> ```
>
> Every build produces a different hash, so every build is a new app as far as
> macOS is concerned, and the **Keychain prompt returns after every rebuild**.
>
> `make-signing-cert.sh` creates a local self-signed identity once, which
> `scripts/bundle.sh` and `install.sh` then pick up automatically. It asks for your
> login password once (to trust the certificate), and the first build after it asks
> once for Keychain access to the *signing key* — choose **Always Allow**. It does
> nothing for Gatekeeper (a self-signed leaf isn't a trusted anchor) and only helps
> the machine holding it. Undo:
> `security delete-certificate -c "Merlyn Local Signing"`.
>
> It has **no effect on notifications**, which look like they should be governed by
> the same thing but are keyed to the bundle id instead — see Troubleshooting.

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
On first run Merlyn auto-detects installed CLIs by looking for *specific marker
files* under `~/.claude*`, `~/.codex`, `~/.kimi-code` — not bare directories, so a
`skills/`-only folder isn't a false positive. If none of those CLIs are installed
there is genuinely nothing to report. Otherwise add a provider by hand:

```sh
open ~/Library/Application\ Support/Merlyn/providers.json
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
Deliberate: Merlyn refuses to invent a number it can't read, so a failure gets a
badge rather than a 0% gauge that would read as "plenty left". The tooltip and card
name the cause. If a login lapsed, sign in with that CLI's own command
(`claude auth login`, `codex login`, `kimi login`) or the panel's sign-in button —
Merlyn never mints or refreshes tokens itself.

**Percentages show `≈`**
Local estimates, not real quota: the API was unreachable or a login is stale, so it
fell back to analyzing local logs relative to your busiest period. Fix the auth and
real figures return.

**Nothing in the menu bar**
Check it's running (`pgrep -fl Merlyn`). If it is, the menu bar is probably full —
on notch Macs, items silently overflow behind the notch. Quit something else up
there, or use a menu bar manager. There's no Dock icon to fall back on.

**Numbers look frozen or wrong**
Delete the parse cache; it rebuilds safely (first rescan ~20s):

```sh
rm ~/Library/Application\ Support/Merlyn/usage-cache.json
```

**Usage alerts never appear**
First check they're on: panel → gear → **Alerts**. That section's bottom row says
what macOS will do with an alert and has a **Send a test** button — use it before
anything else, since silence otherwise looks the same as "nothing crossed a limit".

- *"Notifications are turned off"* / *"alert style is None"* → fix it in System
  Settings › Notifications › Merlyn (the row's button opens it).
- Also check Focus / Do Not Disturb isn't swallowing them.

From a terminal, `/Applications/Merlyn.app/Contents/MacOS/Merlyn --notify-test`
posts one alert and logs the authorization callback and the permission state.

**`requestAuthorization` fails with "Notifications are not allowed for this
application"** (`UNErrorDomain Code=1`)
A bundle id can get stuck in a denied state that nothing clears. Do **not** chase
the code signature — that was measured and ruled out, along with the entitlements
blob, duplicate LaunchServices registrations, the usernoted database,
`com.apple.ncprefs.plist`, `tccutil reset`, and MDM profiles. The same binary under
a fresh bundle id is granted immediately, so the fix is a new `CFBundleIdentifier`
in `scripts/bundle.sh`. Full evidence table: `docs/specs/distribution.md`
§ Notifications.

**Kimi CLI got logged out**
Kimi's refresh tokens rotate, and only Merlyn's own refresh path persists the
rotated ones correctly. Never hand-edit
`~/.kimi-code/credentials/kimi-code.json` — re-run `kimi login`.

## Uninstall

```sh
osascript -e 'quit app "Merlyn"' 2>/dev/null || true
rm -rf /Applications/Merlyn.app
rm -rf ~/Library/Application\ Support/Merlyn   # config + parse cache
```

Merlyn stores nothing else and has no telemetry. Removing it doesn't touch any
CLI's credentials.

## Reference

QA flags. These work on any build of the binary — the installed one
(`/Applications/Merlyn.app/Contents/MacOS/Merlyn`) or a checkout's
`.build/debug/Merlyn` after `swift build`:

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

- Config: `~/Library/Application Support/Merlyn/providers.json`
- Parse cache: `~/Library/Application Support/Merlyn/usage-cache.json` (safe to delete)
- Build output: `build/Merlyn.app` in the checkout
- Bundle id: `com.mickyngub.merlyn` — keep it stable; the Keychain grant is tied to it

Deeper detail: [docs/specs/distribution.md](../../docs/specs/distribution.md) for
signing, [docs/provider-integration.md](../../docs/provider-integration.md) for
auth flows and endpoints.
