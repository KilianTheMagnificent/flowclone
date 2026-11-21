#!/bin/sh
# Hands-free UI testing for agents: builds the debug FlowClone and starts it as a hidden,
# never-frontmost session driven by tools/handsfree.mjs. The installed app, its preferences,
# data, log, hotkey, microphone, clipboard and the owner's focus are never touched.
#   tools/handsfree-flowclone.sh [--with-model] [-- app args, e.g. -appearanceTheme interface]
# --with-model clones the local Parakeet Ultra model into the session (APFS clone: no copy, no
# download) so the `dictate` action can run; without it the session is UI only.
# Parallel sessions: set HANDSFREE_SESSION=<name> for this and every later command.
set -eu
cd "$(dirname "$0")/.."
root=${FLOWCLONE_BUILD_ROOT:-$HOME/Library/Caches/flowclone-handsfree}
with_model=0
if [ "${1:-}" = "--with-model" ]; then with_model=1; shift; fi
if [ "${1:-}" = "--" ]; then shift; fi
nice -n 10 swift build --scratch-path "$root/.build" -Xswiftc -warnings-as-errors >&2
bin=$(swift build --scratch-path "$root/.build" --show-bin-path)/FlowClone
if [ "$with_model" = 1 ]; then
  source="${FLOWCLONE_PARAKEET_MODEL_DIR:-$HOME/Library/Application Support/FluidAudio/Models/parakeet-ultra}"
  [ -d "$source" ] || { echo "handsfree: no local Parakeet Ultra model at $source" >&2; exit 1; }
  # The same session directory tools/handsfree.mjs derives (HANDSFREE_SESSION, else the cwd hash).
  session=$(node -e 'const c=require("crypto"),o=require("os"),p=require("path");console.log(p.join(o.tmpdir(),"handsfree",process.env.HANDSFREE_SESSION||c.createHash("sha1").update(process.cwd()).digest("hex").slice(0,8)))')
  [ ! -e "$session/session.json" ] || { echo "handsfree: a session is running; stop it first" >&2; exit 1; }
  models="$session/home/Library/Application Support/FluidAudio/Models"
  mkdir -p "$models"
  cp -cR "$source" "$models/parakeet-ultra"
fi
exec nice -n 10 node tools/handsfree.mjs start native -- "$bin" "$@"
