# Distribution & signing

How Merlyn is packaged and handed to other Macs. There are two states, and the
same script (`scripts/dmg.sh`) produces both:

1. **Free / unsigned** — works today with no Apple Developer account. Fine for
   sending to people you know; they clear Gatekeeper once.
2. **Notarized** — signed with a Developer ID certificate and notarized by
   Apple. Opens with a normal double-click, no warnings, for anyone.

> **Why not the Mac App Store?** Merlyn reads *other* apps' Keychain items and
> config files under `$HOME` (`~/.codex`, `~/.claude*`, `~/.kimi-code`). The App
> Store mandates the App Sandbox, which forbids exactly that. Merlyn therefore
> ships as a notarized Developer ID app outside the store. See
> [`scripts/Merlyn.entitlements`](../../scripts/Merlyn.entitlements).

## Build a DMG today (no account needed)

```sh
scripts/dmg.sh            # → dist/Merlyn-1.0.dmg  (unsigned/ad-hoc)
```

Send that `.dmg`. The recipient drags **Merlyn** to Applications, then opens it
once via **one** of:

- **System Settings → Privacy & Security →** scroll to the *Merlyn* message **→
  "Open Anyway"**, then confirm; or
- Terminal: `xattr -dr com.apple.quarantine /Applications/Merlyn.app` then
  `open /Applications/Merlyn.app`.

They only do this once per install.

## Go notarized (one-time setup)

Requires the **Apple Developer Program** ($99/yr).

1. **Enroll:** <https://developer.apple.com/programs/> and note your **Team ID**
   (Membership page).
2. **Create a Developer ID Application certificate.** Xcode → Settings →
   Accounts → your team → *Manage Certificates* → **+** → *Developer ID
   Application*. It installs into your login keychain. Verify:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
3. **Create an app-specific password** at <https://appleid.apple.com>
   (Sign-In & Security → App-Specific Passwords).
4. **Store notary credentials** once, under the profile name the script expects:

   ```sh
   xcrun notarytool store-credentials merlyn-notary \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "abcd-efgh-ijkl-mnop"   # the app-specific password
   ```

## Cut a notarized release

```sh
MERLYN_VERSION=1.1 MERLYN_BUILD=5 NOTARIZE=1 scripts/dmg.sh
```

This will, in order:

1. `swift build -c release` and assemble `build/Merlyn.app`.
2. Sign the app with your Developer ID **+ Hardened Runtime** (required for
   notarization) using `scripts/Merlyn.entitlements`.
3. Package `dist/Merlyn-1.1.dmg`, sign the DMG.
4. Submit to Apple's notary service and **wait**, then **staple** the ticket.

Verify the result:

```sh
spctl -a -vvv -t open --context context:primary-signature build/Merlyn.app
xcrun stapler validate dist/Merlyn-1.1.dmg
```

Then attach the DMG to a GitHub Release.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `MERLYN_VERSION` | `1.0` | Marketing version → `CFBundleShortVersionString` + DMG filename |
| `MERLYN_BUILD` | `1` | Build number → `CFBundleVersion` |
| `NOTARIZE` | `0` | `1` = notarize + staple (needs a Developer ID + stored creds) |
| `NOTARY_PROFILE` | `merlyn-notary` | `notarytool store-credentials` profile name |
| `SIGN_IDENTITY` | auto-detected | Force a specific codesign identity |
| `MERLYN_ADHOC` | `0` | `1` = force ad-hoc signing even if a Developer ID exists |

## Notes & footguns

- **Bundle id is `sh.micky.merlyn`.** Keep it stable — the Keychain "Always
  Allow" grant for Claude credentials is tied to the app's signature/identity.
- A stable Developer ID signature also **fixes the repeated Keychain re-prompts**
  seen with ad-hoc dev builds (each ad-hoc rebuild is a new identity).
- Notarization needs network + Hardened Runtime; the app must have **no**
  `get-task-allow` entitlement (release signing omits it automatically).
- If `notarytool submit` reports `Invalid`, fetch the log with
  `xcrun notarytool log <submission-id> --keychain-profile merlyn-notary`.
