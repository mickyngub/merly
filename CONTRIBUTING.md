# Contributing to Merly

Thanks for your interest! Merly is a small native macOS menu bar app written in
Swift (AppKit + SwiftUI), with no third-party dependencies.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- macOS 14 (Sonoma) or newer
- A Swift 5.9+ toolchain (Xcode 15+ or the Swift toolchain / Command Line Tools)

## Build & run

```sh
swift build                       # debug build
.build/debug/Merly --print       # headless snapshot of all readers (fast smoke test, no UI)
.build/debug/Merly --open        # launch with the panel open
```

Useful QA flags:

| Flag | Effect |
|---|---|
| `--print` | Print a headless snapshot of every provider reader and exit (no UI). |
| `--open` | Launch with the dock panel already open. |
| `--open --expand` | …with all cards expanded. |
| `--open --light` | …forcing light appearance. |
| `--open --rail` | …collapsed to the mascot rail. |
| `--open --edit` | …in reorder/delete mode (grips, edit + delete buttons, drag). |
| `--mascot` | Launch straight into the menu bar mascot editor. |
| `--notify-test` | Post one alert at launch and log what macOS says about it. Bundled app only — the dev binary has no bundle id to deliver to. |

To assemble a runnable `.app`:

```sh
scripts/bundle.sh                 # → build/Merly.app
open build/Merly.app
```

`--print` is the fastest way to check your change didn't break a reader — it
exercises the whole data path without launching any UI. Please run it before
opening a PR.

## Tests

```sh
swift test
```

The suite (`Tests/MerlyTests/`) covers the pure logic: the token-window
estimator, snapshot lane/gauge derivation, payload parsing against fixture
transcripts, and the config store's corrupt-file quarantine. It uses XCTest,
which ships with **Xcode** — on a Command Line Tools-only machine `swift test`
fails with "no such module 'XCTest'"; `swift build` and `--print` still work,
and CI runs the tests on every pull request.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/Merly/Data/` | Providers, readers, usage engine, API clients |
| `Sources/Merly/Mascot/` | Pixel-critter builder + sprite-sheet recoloring |
| `Sources/Merly/Views/` | SwiftUI views (dock, cards, editor, settings) |
| `Sources/Merly/Resources/` | Baked sprite sheets |
| `scripts/` | `bundle.sh` builds `build/Merly.app` (repo-only, what CI runs); `install.sh` wraps it and installs to `/Applications`; plus asset generation |
| `skills/` | Agent skills published for `npx skills add mickyngub/merly` |
| `docs/` | Provider-integration reference, provider API notes, specs |

Read [`AGENTS.md`](AGENTS.md) for an architecture map and the load-bearing
footguns (Keychain signing, Kimi token rotation, off-main-thread readers).

## Adding a provider

If the provider is Claude-Code / Codex / Kimi-compatible, no code is needed —
users just add an entry to `providers.json`. For a genuinely new backend, follow
the four steps in
[`docs/provider-integration.md`](docs/provider-integration.md) § *Adding a
provider*. Every supported provider **must** expose a real usage API;
local-log-only estimation is only an offline fallback, never the sole basis for
a provider.

## Commit messages

This repo uses [gitmoji](https://gitmoji.dev) shortcodes, lowercase, imperative:

```
:sparkles: add kimi weekly bar
:bug: fix session ring at 0%
:memo: document the refresh lockfile protocol
```

Common ones: `:sparkles:` feature · `:bug:` fix · `:lipstick:` UI · `:recycle:`
refactor · `:memo:` docs · `:art:` structure/format · `:fire:` remove code.

## Pull requests

Before opening a PR, please make sure:

- [ ] `swift build` succeeds with no new warnings.
- [ ] `swift test` passes (or let CI run it if you're on Command Line Tools only).
- [ ] `.build/debug/Merly --print` runs without crashing.
- [ ] No secrets, tokens, or personal paths are added (the app reads
      credentials — never hardcode or log any).
- [ ] File I/O and HTTP stay **off** the main thread (readers run on
      `UsageEngine.workQueue`).
- [ ] `docs/provider-integration.md` updated if you changed provider integration behavior.

Keep PRs focused. Describe what changed and how you verified it.

## Localization

Merly is deliberately **English-only** for now: all user-facing strings are
inline literals, and date formatting is pinned to `en_US_POSIX` (formatted
strings are persisted into cached readings, so a mid-cache locale change would
mix formats). If you're adding strings, keep them inline — please don't
introduce `String(localized:)` or `.strings` catalogs piecemeal; localization
would be adopted repo-wide in one pass if it ever lands.

## Releasing (maintainers)

Merly ships as source; there are no release artifacts to publish. How the app
bundle is assembled and ad-hoc signed — and what changing that would take — is
documented in [`docs/specs/distribution.md`](docs/specs/distribution.md).

CI (`.github/workflows/ci.yml`) builds and tests every pull request, and can be
run manually (`gh workflow run ci.yml`, or the Actions tab) for proof a clean
machine can build the app.
