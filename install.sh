#!/bin/bash
# FlowClone installer. In Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/KilianTheMagnificent/flowclone/main/install.sh | bash
#
# Downloads the latest release, checks its checksum and that it is signed by the maintainer's
# Apple team, puts FlowClone.app into Applications and opens it. FlowClone is not notarized by
# Apple; a build fetched this way opens without the "Apple could not verify" refusal that a
# browser download gets, which is why the signature is checked here instead.
#
# For testing: FLOWCLONE_INSTALL_DIR (where the app goes), FLOWCLONE_NO_OPEN=1 (do not open
# it), FLOWCLONE_RELEASE_API (another address for the release description). None of them
# loosens the signature check.
set -euo pipefail

RELEASES="KilianTheMagnificent/flowclone-updates"
BUNDLE_ID="com.andre.flowclone"
TEAM_ID="36B25Z964W"
APP_NAME="FlowClone.app"
# The same rule macOS and FlowClone's own updater hold a build to.
REQUIREMENT="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""

say() { printf '%s\n' "$*"; }
stop() { printf 'FlowClone was not installed: %s\n' "$*" >&2; exit 1; }

# 1 when version $1 is lower than $2 (dotted numbers), else 0.
version_lower() {
  [ "$1" = "$2" ] && { echo 0; return; }
  local lowest
  lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  [ "$lowest" = "$1" ] && echo 1 || echo 0
}

plist_value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

main() {
  [ "$(uname -s)" = "Darwin" ] || stop "FlowClone runs on macOS only."
  [ "$(uname -m)" = "arm64" ] || stop "FlowClone needs an Apple Silicon Mac (M1 or newer). Intel Macs are not supported."
  local mac_version
  mac_version=$(/usr/bin/sw_vers -productVersion)

  local work
  work=$(mktemp -d "${TMPDIR:-/tmp}/flowclone-install.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  say "Looking up the latest FlowClone release…"
  local api="${FLOWCLONE_RELEASE_API:-https://api.github.com/repos/$RELEASES/releases/latest}"
  local protocols="=https"
  [ -z "${FLOWCLONE_RELEASE_API:-}" ] || protocols="=https,http"
  curl -fsSL --proto "$protocols" -H "Accept: application/vnd.github+json" -o "$work/release.json" "$api" \
    || stop "could not reach GitHub. Check the internet connection and try again."

  local count name url digest index=0
  count=$(plist_value "$work/release.json" assets)
  case "$count" in ''|*[!0-9]*) stop "GitHub's answer did not list a release." ;; esac
  name=""
  while [ "$index" -lt "$count" ]; do
    name=$(plist_value "$work/release.json" "assets.$index.name")
    if printf '%s' "$name" | grep -Eq '^FlowClone-[0-9][0-9.]*-[0-9]{10}\.zip$'; then
      url=$(plist_value "$work/release.json" "assets.$index.browser_download_url")
      digest=$(plist_value "$work/release.json" "assets.$index.digest")
      break
    fi
    name=""
    index=$((index + 1))
  done
  [ -n "$name" ] || stop "the latest release has no FlowClone download."
  if [ -z "${FLOWCLONE_RELEASE_API:-}" ]; then
    case "$url" in
      "https://github.com/$RELEASES/releases/download/"*) ;;
      *) stop "the release points at an unexpected download address." ;;
    esac
  fi

  local offered="${name%.zip}"
  offered="${offered##*-}"
  local folder="${FLOWCLONE_INSTALL_DIR:-/Applications}"
  if [ ! -w "$folder" ]; then
    folder="$HOME/Applications"
    mkdir -p "$folder"
  fi
  local destination="$folder/$APP_NAME"
  if [ -d "$destination" ]; then
    local installed
    installed=$(plist_value "$destination/Contents/Info.plist" CFBundleVersion)
    if /usr/bin/pgrep -f "$destination/Contents/MacOS/" >/dev/null 2>&1; then
      say "FlowClone (build ${installed:-unknown}) is already installed and running. It keeps itself up to date: Settings > Updates & diagnostics > Check for updates."
      return 0
    fi
    case "$installed" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$installed" -ge "$offered" ]; then
          say "FlowClone (build $installed) is already installed in $folder."
          [ -n "${FLOWCLONE_NO_OPEN:-}" ] || /usr/bin/open "$destination"
          return 0
        fi
        ;;
    esac
  fi

  say "Downloading ${name}…"
  local progress="-sS"
  [ ! -t 2 ] || progress="--progress-bar"
  curl -fL --proto "$protocols" "$progress" -o "$work/app.zip" "$url" \
    || stop "the download failed. Try again."
  case "$digest" in
    sha256:*)
      [ "sha256:$(/usr/bin/shasum -a 256 "$work/app.zip" | cut -d' ' -f1)" = "$digest" ] \
        || stop "the download does not match the checksum GitHub lists for it."
      ;;
  esac

  /usr/bin/ditto -x -k "$work/app.zip" "$work/unpacked" || stop "the download could not be unpacked."
  local app
  app=$(/usr/bin/find "$work/unpacked" -maxdepth 2 -name "$APP_NAME" -type d | head -1)
  [ -n "$app" ] || stop "the download does not contain $APP_NAME."

  say "Checking the signature…"
  /usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null \
    || stop "the app's signature is broken."
  /usr/bin/codesign --verify -R="$REQUIREMENT" "$app" 2>/dev/null \
    || stop "the app is not signed by FlowClone's maintainer."

  local needs build
  needs=$(plist_value "$app/Contents/Info.plist" LSMinimumSystemVersion)
  build=$(plist_value "$app/Contents/Info.plist" CFBundleVersion)
  [ "$build" = "$offered" ] || stop "the download is not the build the release names."
  if [ -n "$needs" ] && [ "$(version_lower "$mac_version" "$needs")" = 1 ]; then
    stop "this release needs macOS $needs or newer; this Mac has $mac_version."
  fi

  say "Installing into ${folder}…"
  local staged="$folder/.FlowClone-installing.$$"
  rm -rf "$staged"
  /usr/bin/ditto "$app" "$staged" || { rm -rf "$staged"; stop "could not write to $folder."; }
  /usr/bin/xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  /usr/bin/codesign --verify -R="$REQUIREMENT" "$staged" 2>/dev/null \
    || { rm -rf "$staged"; stop "the installed copy did not pass the signature check."; }
  rm -rf "$destination"
  mv "$staged" "$destination"

  say ""
  say "FlowClone (build $build) is installed in $folder."
  say "Next: allow Microphone, Accessibility and Input Monitoring when FlowClone asks, and wait"
  say "for the one-time speech model download (about 630 MB). Then hold fn and speak."
  [ -n "${FLOWCLONE_NO_OPEN:-}" ] || /usr/bin/open "$destination"
}

main "$@"
