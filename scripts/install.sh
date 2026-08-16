#!/bin/bash
# install.sh — build Merly from source and install it to /Applications.
#
# Merly ships as source only, so this is the install path. Safe to re-run: it
# rebuilds and replaces the installed app, quitting a running copy first.
#
# Usage:
#   scripts/install.sh                 # build this checkout, install it
#   scripts/install.sh --update        # git pull --ff-only first, then build
#   scripts/install.sh ~/code/merly   # clone there if absent, then build it
#
# Env:
#   MERLY_REPO=<url>   override the clone URL (default: the public GitHub repo)
#   NO_INSTALL=1        build only; leave /Applications alone
#   NO_LAUNCH=1         install but don't open the app
set -euo pipefail

REPO="${MERLY_REPO:-https://github.com/mickyngub/merly.git}"
APP="/Applications/Merly.app"
UPDATE=0
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --update) UPDATE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) TARGET="$arg" ;;
  esac
done

die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
say() { printf '\033[36m▶ %s\033[0m\n' "$*"; }
ok()  { printf '\033[32m✔ %s\033[0m\n' "$*"; }

is_merly() { [ -f "$1/Sources/Merly/main.swift" ] && [ -f "$1/scripts/bundle.sh" ]; }

# Run from inside a checkout (the normal case — this script ships in it), that
# checkout is what we build. Only fall back to cloning when we're not in one.
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "$TARGET" ]; then
  DIR="$TARGET"
elif is_merly "$SELF_ROOT"; then
  DIR="$SELF_ROOT"
else
  DIR="$HOME/dev/merly"
fi

# ── Preflight ──────────────────────────────────────────────────────────────
# Checked before anything else: failing partway through a build is a worse
# experience than being told up front what's missing.
macos="$(sw_vers -productVersion)"
if [ "$(printf '%s\n14.0\n' "$macos" | sort -V | head -n1)" != "14.0" ]; then
  die "Merly needs macOS 14 (Sonoma) or newer; this is $macos.
   Package.swift and Info.plist both pin 14.0, so there is no flag to bypass this."
fi

command -v swift >/dev/null 2>&1 || die "No Swift toolchain found.
   Run: xcode-select --install
   (the Command Line Tools are enough — a full Xcode install is not needed)"

swiftver="$(swift -version 2>&1 | sed -n 's/.*Apple Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -n1)"
if [ -n "$swiftver" ] && [ "$(printf '%s\n5.9\n' "$swiftver" | sort -V | head -n1)" != "5.9" ]; then
  die "Swift $swiftver is too old; this package needs 5.9+. Update Xcode or the Command Line Tools."
fi
ok "macOS $macos, Swift ${swiftver:-unknown}"

# ── Fetch ──────────────────────────────────────────────────────────────────
if is_merly "$DIR"; then
  : # already have it
elif [ -d "$DIR/.git" ]; then
  die "$DIR is a git repo but not a Merly checkout. Pick another directory."
elif [ -e "$DIR" ]; then
  die "$DIR already exists and is not a Merly checkout. Move it or pick another directory."
else
  say "Cloning into $DIR"
  mkdir -p "$(dirname "$DIR")"
  git clone "$REPO" "$DIR"
fi

# Pulling is opt-in. An installer that silently moves your checkout's HEAD can
# discard work in progress, and you may well be installing a local branch on purpose.
if [ "$UPDATE" = "1" ]; then
  say "Updating $DIR"
  git -C "$DIR" pull --ff-only \
    || die "git pull --ff-only failed — local commits or changes in the way. Sort out $DIR, then re-run."
fi

# ── Build ──────────────────────────────────────────────────────────────────
say "Building release (~40s the first time)"
cd "$DIR"
./scripts/bundle.sh

[ -d "$DIR/build/Merly.app" ] || die "bundle.sh exited 0 but $DIR/build/Merly.app is missing."

if [ "${NO_INSTALL:-0}" = "1" ]; then
  ok "Built $DIR/build/Merly.app (NO_INSTALL=1, not installed)"
  exit 0
fi

# ── Install ────────────────────────────────────────────────────────────────
# Quit first. Copying over a running bundle leaves the old process alive against
# deleted files, so the "new" version you then see is actually still the old one.
if pgrep -x Merly >/dev/null 2>&1; then
  say "Quitting the running copy"
  osascript -e 'quit app "Merly"' >/dev/null 2>&1 || true
  for _ in $(seq 10); do
    pgrep -x Merly >/dev/null 2>&1 || break
    sleep 0.3
  done
  if pgrep -x Merly >/dev/null 2>&1; then
    say "Still running — forcing"
    pkill -x Merly || true
    sleep 0.5
  fi
fi

say "Installing to $APP"
rm -rf "$APP"
cp -R "$DIR/build/Merly.app" "$APP"
# Version from Info.plist, never by running the binary: Merly has no --version
# flag and ignores unknown arguments, so `Merly --version` would just silently
# launch the menu bar app and never return.
ok "Installed Merly $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"

[ "${NO_LAUNCH:-0}" = "1" ] || { say "Launching"; open "$APP"; }

cat <<NEXT

Next:
  • Merly is a MENU BAR app — no Dock icon, no window. Look at the top of the
    screen for a small critter with "5h" and "w" bars under it.
  • It will ask for Keychain access to read your Claude Code credentials →
    click "Always Allow". That prompt returns after every rebuild: a locally
    built app is ad-hoc signed, so each build is a new code identity to macOS.
    Expected, not a problem. See docs/specs/distribution.md.
  • Check every provider headlessly, no UI needed:
        cd $DIR && .build/debug/Merly --print

NEXT
