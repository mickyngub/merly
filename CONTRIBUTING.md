# Contributing to Merlyn

Thanks for your interest! Merlyn is a small native macOS menu bar app written in
Swift (AppKit + SwiftUI), with no third-party dependencies.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- macOS 14 (Sonoma) or newer
- A Swift 5.9+ toolchain (Xcode 15+ or the Swift toolchain / Command Line Tools)

## Build & run

```sh
swift build                       # debug build
.build/debug/Merlyn --print       # headless snapshot of all readers (fast smoke test, no UI)
.build/debug/Merlyn --open        # launch with the panel open
```

Useful QA flags:

| Flag | Effect |
|---|---|
| `--print` | Print a headless snapshot of every provider reader and exit (no UI). |
| `--open` | Launch with the dock panel already open. |
| `--open --expand` | …with all cards expanded. |
| `--open --light` | …forcing light appearance. |
| `--open --rail` | …collapsed to the mascot rail. |
| `--mascot` | Launch straight into the menu bar mascot editor. |

To assemble a runnable `.app`:

```sh
scripts/bundle.sh                 # → build/Merlyn.app
open build/Merlyn.app
```

`--print` is the fastest way to check your change didn't break a reader — it
exercises the whole data path without launching any UI. Please run it before
opening a PR.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/Merlyn/Data/` | Providers, readers, usage engine, API clients |
| `Sources/Merlyn/Mascot/` | Pixel-critter builder + sprite-sheet recoloring |
| `Sources/Merlyn/Views/` | SwiftUI views (dock, cards, editor, settings) |
| `Sources/Merlyn/Resources/` | Baked sprite sheets |
| `scripts/` | `bundle.sh` builds `build/Merlyn.app` (repo-only, what CI runs); `install.sh` wraps it and installs to `/Applications`; plus asset generation |
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
- [ ] `.build/debug/Merlyn --print` runs without crashing.
- [ ] No secrets, tokens, or personal paths are added (the app reads
      credentials — never hardcode or log any).
- [ ] File I/O and HTTP stay **off** the main thread (readers run on
      `UsageEngine.workQueue`).
- [ ] `docs/provider-integration.md` updated if you changed provider integration behavior.

Keep PRs focused. Describe what changed and how you verified it.

## Releasing (maintainers)

Merlyn ships as source; there are no release artifacts to publish. How the app
bundle is assembled and ad-hoc signed — and what changing that would take — is
documented in [`docs/specs/distribution.md`](docs/specs/distribution.md).

CI (`.github/workflows/ci.yml`) is manual-only: `gh workflow run ci.yml`, or the
Actions tab. Run it when you want proof a clean machine can build the app.
