# Distribution & signing

Merlyn is distributed as **source that each user builds themselves**. There is no
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
Anyway**, or `xattr -dr com.apple.quarantine`. Merlyn reads credential tokens.
Training its users to click past *"macOS cannot verify this app is free of
malware"* works directly against the reason this project is open source at all.

A locally compiled app is **never quarantined**, so building from source has zero
Gatekeeper friction — better than an unsigned download, and free.

> **Why not the Mac App Store?** Merlyn reads *other* apps' Keychain items and
> config files under `$HOME` (`~/.codex`, `~/.claude*`, `~/.kimi-code`). The App
> Store mandates the App Sandbox, which forbids exactly that. See
> [`scripts/Merlyn.entitlements`](../../scripts/Merlyn.entitlements).

## Building the app

```sh
scripts/bundle.sh          # → build/Merlyn.app
```

Requires macOS 14+ and a Swift 5.9+ toolchain; nothing else. `scripts/Merlyn.icns`
is committed, so `scripts/make-icon.py` (and therefore `uv`) only runs if you
delete it.

What the script does:

1. `swift build -c release`, then assembles `build/Merlyn.app` with `Info.plist`
   (`LSUIElement`, `LSMinimumSystemVersion 14.0`, bundle id `com.mickyngub.merlyn`).
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
codesign -d -r- build/Merlyn.app
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
(`identifier "com.mickyngub.merlyn" and certificate leaf = H"…"`) and does stop the
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

## Notifications are keyed to the bundle id, not the signature

Worth writing down because the opposite is very plausible and wrong, and the
failure is silent either way.

`UNUserNotificationCenter.requestAuthorization` can come straight back with
`UNErrorDomain Code=1 "Notifications are not allowed for this application"`. Alerts
are then delivered to Notification Center and never drawn, which looks exactly like
"nothing crossed a limit".

Signing is not the lever. Measured on one machine, same source, same certificate:

| Build | `requestAuthorization` |
|---|---|
| ad-hoc signed | Code=1, denied |
| stable self-signed, untrusted | Code=1, denied |
| stable self-signed, trusted | Code=1, denied |
| **same binary, bundle id changed** | **granted** |

Ruled out along the way: the entitlements blob, duplicate LaunchServices
registrations of the same id from stray `build/Merlyn.app` copies, the
`group.com.apple.usernoted/db2/db` record store, `com.apple.ncprefs.plist` (no
entry there for the *granted* id either, so that file is not the store on macOS
26), `tccutil reset`, and MDM configuration profiles.

So a bundle id can end up in a stuck denied state that survives all of the above.
The remedy that works is a fresh identifier. Two corollaries:

- `~/Library/Group Containers/group.com.apple.usernoted/db2/db` is a *history*
  store. Its `presented` / `displayed` columns read 0 even for an app that is
  granted, so they prove nothing about whether a banner appeared.
- Diagnose with `Merlyn.app/Contents/MacOS/Merlyn --notify-test`, which posts one
  alert and logs the authorization callback and the permission state around it.
  Settings › Alerts shows the same verdict in the UI.

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
| `MERLYN_VERSION` | `1.0` | Marketing version → `CFBundleShortVersionString` |
| `MERLYN_BUILD` | `1` | Build number → `CFBundleVersion` |
| `SIGN_IDENTITY` | auto-detected | Force a specific codesign identity |
| `MERLYN_ADHOC` | `0` | `1` = force ad-hoc signing even if a Developer ID exists |

`scripts/install.sh` adds `NO_INSTALL`, `NO_LAUNCH` and `MERLYN_REPO`.

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
notary credentials once with `xcrun notarytool store-credentials merlyn-notary`; and
restore a packaging script (see above). `bundle.sh` itself needs no changes — it
already picks a Developer ID up automatically and switches on Hardened Runtime,
which notarization requires. The entitlements dict is intentionally empty; no
exceptions are needed, since Keychain reads shell out to `/usr/bin/security` rather
than using in-process APIs.

## Footguns

- **Keep the bundle id `com.mickyngub.merlyn` stable.** The Keychain grant for Claude
  credentials is tied to the app's signature and identity.
- Should notarization ever come back: it needs network, Hardened Runtime, and **no**
  `get-task-allow` entitlement (release signing omits it automatically). If
  `notarytool submit` reports `Invalid`, fetch the log with `xcrun notarytool log
  <submission-id> --keychain-profile merlyn-notary`.
