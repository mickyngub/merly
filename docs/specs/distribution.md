# Distribution & signing

Merly is distributed as **source that each user builds themselves**. There is no
prebuilt download, no DMG on the Releases page, and no notarized artifact. This
document covers how the app bundle is assembled, what signing actually happens,
and what it would take to change the channel.

## Why source-only

A signed, notarized app requires an **Apple Developer Program** membership
($99/yr): Developer ID Application certificates are issued only to paid members,
and `notarytool` authenticates against that same account. There is no free path to
notarization.

Without it, any DMG lands with `com.apple.quarantine` set, and every user has to
clear Gatekeeper by hand — since macOS 15 the Control-click → Open shortcut is
gone, so that means a trip to **System Settings → Privacy & Security → Open
Anyway**, or `xattr -dr com.apple.quarantine`. Merly reads credential tokens.
Training its users to click past *"macOS cannot verify this app is free of
malware"* works directly against the reason this project is open source at all.

A locally compiled app is **never quarantined**, so building from source has zero
Gatekeeper friction — better than an unsigned download, and free.

> **Why not the Mac App Store?** Merly reads *other* apps' Keychain items and
> config files under `$HOME` (`~/.codex`, `~/.claude*`, `~/.kimi-code`). The App
> Store mandates the App Sandbox, which forbids exactly that. See
> [`scripts/Merly.entitlements`](../../scripts/Merly.entitlements).

## Building the app

```sh
scripts/bundle.sh          # → build/Merly.app
```

Requires macOS 14+ and a Swift 5.9+ toolchain; nothing else. `scripts/Merly.icns`
is committed, so `scripts/make-icon.py` (and therefore `uv`) only runs if you
delete it.

What the script does:

1. `swift build -c release`, then assembles `build/Merly.app` with `Info.plist`
   (`LSUIElement`, `LSMinimumSystemVersion 14.0`, bundle id `sh.micky.merly`).
2. **Repacks the SwiftPM resource bundle.** SwiftPM emits a *flat* bundle
   (`Resources/`, no `Info.plist`), which `codesign` rejects as "bundle format
   unrecognized". The script rebuilds it in standard `Contents/` layout;
   `Bundle.module` still resolves from `Contents/Resources` at runtime.
3. **Signs ad-hoc** (`codesign --force --sign -`), since no Developer ID exists.
   Apple Silicon refuses to execute an entirely unsigned binary, so this is
   required, not cosmetic.
4. `codesign --verify --strict` as a gate.

The build is **host-native** — Intel and Apple Silicon each produce a binary for
the machine that built it, which is exactly what source distribution wants. There
is no universal binary and no need for one.

## The ad-hoc signature has one visible consequence

Ad-hoc signing produces a designated requirement of `cdhash H"<hash of this exact
build>"`, verifiable with:

```sh
codesign -d -r- build/Merly.app
```

**Keychain "Always Allow" grants** are keyed to that requirement, so **every rebuild
is a new identity and macOS re-prompts** for the Claude credentials. This is normal
for source distribution and is called out in the README so it doesn't read as a
problem.

Nothing here is about *distribution*. The project signs no artifact — each machine
signs its own build and the signature never leaves it. Signing happens regardless
because Apple Silicon will not execute an unsigned binary, so "no certificate"
means ad-hoc, not unsigned.

### Don't "fix" it with a self-signed identity

A self-signed code-signing certificate does give a stable designated requirement
(`identifier "sh.micky.merly" and certificate leaf = H"…"`) and does stop the
Claude re-prompt. **It was tried and reverted**, because the cure is worse:

- Signing with a real key means `codesign` has to *use a private key from your
  login Keychain*, and macOS gates that — so **the build itself** stops with
  *"codesign wants to use key …"*. A build that demands Keychain access looks far
  more alarming than the credential prompt it was meant to remove, and it recurs
  whenever the key's ACL or partition list is invalidated (adding the trust
  setting does exactly that).
- Trusting the certificate needs a login-password dialog of its own, otherwise
  `security find-identity -v -p codesigning` reports `CSSMERR_TP_NOT_TRUSTED`.
- It helps nobody else: a self-signed leaf is not a trusted anchor, so it does
  nothing for Gatekeeper, and every user would have to mint their own.
- It does **not** affect notifications, which is what it was reached for in the
  first place. See § Notifications.

Net: two scary dialogs and a keychain modification, to remove one familiar prompt
that a normal install shows once. Ad-hoc is the right default.

## Notifications: the answer is always the permission, and the bundle id owns it

Worth writing down, because this cost a very long debugging session and every
intuition along the way was wrong.

`UNUserNotificationCenter.requestAuthorization` can come straight back with
`UNErrorDomain Code=1 "Notifications are not allowed for this application"`. Alerts
are then delivered to Notification Center and never drawn, which looks exactly like
"nothing crossed a limit". **The app cannot tell the difference and neither can
you** — hence the Settings › Alerts row and `--notify-test`.

**It means what it says: the user has not granted permission.** Nothing in the
build fixes it. What actually resolved it was the user allowing notifications for
Merly, after which the same binary read `granted` immediately.

Things that look like the cause and are not — each measured, so don't re-run them:

| Tried | Result |
|---|---|
| ad-hoc vs. stable self-signed vs. trusted self-signed | denied in all three |
| dropping the entitlements blob | denied |
| unregistering duplicate `build/Merly.app` copies from LaunchServices | denied |
| deleting the app's row from `usernoted/db2/db` + restarting the daemons | denied (and see the warning below) |
| `tccutil reset All <id>` | denied |
| MDM configuration profiles | none installed |

### Never change `CFBundleIdentifier` to try to fix this

The permission belongs to the bundle id. A fresh id starts unauthorized, so a
rename **throws the grant away** and lands you back on `Code=1` — with no prompt,
because on this macOS the prompt does not reliably reappear for an id it has
already refused. That is exactly what happened during that debugging session: the
id was renamed mid-debug, the user then granted permission to the *new* name, and
the running app stayed denied until the id was put back.

### The one deliberate id change: `sh.micky.merlyn` → `sh.micky.merly`

On 2026-08-16 the app was renamed Merlyn → Merly, and the bundle id was changed
with it, on purpose and with the cost above understood. The id is reverse-DNS of
the author's own domain (`micky.sh` reversed, then the app name), so leaving it as
`…merlyn` would have been permanently misleading.

macOS treats the new id as a different app, so a one-time re-grant is required:

1. Rebuild and reinstall (`scripts/install.sh`), then launch.
2. Notifications: confirm with `Merly.app/Contents/MacOS/Merly --notify-test`, or
   the Settings › Alerts row. If it reports denied, allow *Merly* in
   System Settings › Notifications.
3. Keychain: the first Claude read re-prompts for `Claude Code-credentials`.
   Approve it once (see the ad-hoc signing note above for why it recurs per build).

`sh.micky.merlyn` is now dead — its old grants are unreachable and were abandoned
knowingly. **The id is stable again from here.**

### Don't go digging in the notification database

`~/Library/Group Containers/group.com.apple.usernoted/db2/db` is a *history* store,
not the permission store. Two traps:

- Its `presented` / `displayed` columns read 0 even for an app that is granted, so
  they prove nothing about whether a banner appeared. They are not evidence.
- Deleting rows and restarting `usernoted` does not clear a denial, and appeared to
  leave new-app registration wedged afterwards. There is nothing to win here.

`com.apple.ncprefs.plist` holds no entry for Merly even when granted, so it is not
the store on macOS 26 either — don't read state out of it.

### How to check

```sh
/Applications/Merly.app/Contents/MacOS/Merly --notify-test
```

Posts one alert and logs the authorization callback plus the permission state
either side of it. Settings › Alerts shows the same verdict in the UI. If it says
denied, the fix is in System Settings › Notifications › Merly — not in this repo.

## CI

`.github/workflows/ci.yml` is **`workflow_dispatch` only** — it does not run on
push or pull request. Trigger it from the Actions tab or:

```sh
gh workflow run ci.yml
```

It builds debug, builds release, and runs `scripts/bundle.sh` on a `macos-14`
runner, which is the check worth having: proof that a clean machine with nothing
but a toolchain can build the app. Since every user builds from source anyway, a
run on every push proves nothing their own `swift build` doesn't.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `MERLY_VERSION` | `1.0` | Marketing version → `CFBundleShortVersionString` |
| `MERLY_BUILD` | `1` | Build number → `CFBundleVersion` |
| `SIGN_IDENTITY` | auto-detected | Force a specific codesign identity |
| `MERLY_ADHOC` | `0` | `1` = force ad-hoc signing even if a Developer ID exists |

`scripts/install.sh` adds `NO_INSTALL`, `NO_LAUNCH` and `MERLY_REPO`.

## There is no packaging script

`scripts/dmg.sh` was removed once source-only became
the decided channel — keeping it implied a distribution path this project doesn't
use. It stays in git history if it's ever wanted back:

```sh
git log --diff-filter=D --format='%h %s' -- scripts/dmg.sh   # the deleting commit
git show <commit>^:scripts/dmg.sh > scripts/dmg.sh           # restore it
```

## If the channel ever changes

Going notarized needs, in order: enroll in the Developer Program and note the Team
ID; create a *Developer ID Application* certificate (Xcode → Settings → Accounts →
Manage Certificates); create an app-specific password at appleid.apple.com; store
notary credentials once with `xcrun notarytool store-credentials merly-notary`; and
restore a packaging script (see above). `bundle.sh` itself needs no changes — it
already picks a Developer ID up automatically and switches on Hardened Runtime,
which notarization requires. The entitlements dict is intentionally empty; no
exceptions are needed, since Keychain reads shell out to `/usr/bin/security` rather
than using in-process APIs.

## Footguns

- **Keep the bundle id `sh.micky.merly` stable.** The Keychain grant for Claude
  credentials is tied to the app's signature and identity, and the notification
  grant is tied to the id alone. It was changed exactly once, for the Merlyn →
  Merly rename; see § The one deliberate id change.
- Should notarization ever come back: it needs network, Hardened Runtime, and **no**
  `get-task-allow` entitlement (release signing omits it automatically). If
  `notarytool submit` reports `Invalid`, fetch the log with `xcrun notarytool log
  <submission-id> --keychain-profile merly-notary`.
