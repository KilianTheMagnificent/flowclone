#!/bin/sh
# Offscreen visual review: renders every page, dialog and both appearances for each theme
# into OUTDIR from a DEBUG build, on synthetic data in a throwaway home folder. Never opens
# a window, never touches the installed app, its preferences, history or vocabulary.
#   tools/review-render.sh OUTDIR [--review-themes classic,anthropic] [--review-pages dictation,settings,dialogs]
# Parallel agents: set FLOWCLONE_REVIEW_BUILD to a private scratch path (a shared .build locks).
set -eu
cd "$(dirname "$0")/.."
out=$1; shift
build=${FLOWCLONE_REVIEW_BUILD:-$HOME/Library/Caches/flowclone-review/.build}
nice -n 10 swift build --scratch-path "$build" --product FlowClone -Xswiftc -warnings-as-errors >&2
bin=$(swift build --scratch-path "$build" --show-bin-path)/FlowClone
home=$(mktemp -d "${TMPDIR:-/tmp}/flowclone-review-home.XXXXXX")
trap 'rm -rf "$home"' EXIT
support="$home/Library/Application Support/FlowClone"
mkdir -p "$support" "$home/Library/Logs" "$home/Library/Preferences"
printf 'Kubernetes\nFluidAudio\nPostgreSQL\nFigma\nNotion\n' > "$support/dictionary.txt"
printf 'my address -> 221B Baker Street, London\nsign off -> Thanks,\\nAlex\nstandup -> Yesterday: / Today: / Blockers:\n' > "$support/snippets.txt"
printf 'cooper netties -> Kubernetes\nfloyd audio -> FluidAudio\npost gress -> Postgres\n' > "$support/corrections.txt"
chmod 600 "$support"/*.txt
mkdir -p "$out"
CFFIXED_USER_HOME="$home" "$bin" --theme-preview --review-render "$out" "$@" 2>/dev/null | grep -E 'REVIEWRENDER' || { echo "REVIEWRENDER FAIL (no marker)"; exit 1; }
