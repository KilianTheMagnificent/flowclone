#!/bin/bash
# Explicit local workflow. Build/check/package are non-installing; sign/install/run each
# require their own invocation so a compile can never replace or relaunch the trusted app.
set -euo pipefail
cd "$(dirname "$0")"

APP=FlowClone
BUILD_ROOT="${FLOWCLONE_BUILD_ROOT:-$HOME/Library/Caches/flowclone-build}"
SCRATCH="$BUILD_ROOT/.build"
OUT="$BUILD_ROOT/$APP.app"
usage() {
	cat <<'EOF'
usage: ./build.sh [build|check|package|sign|install|run|location|release|publish]

  build    compile the release executable (default)
  check    run FlowCloneCoreTests, then compile the release executable
  package  build and assemble an unsigned app in the user-private build cache
  sign     sign the assembled app with a cryptographic Apple timestamp; defaults to
           app/Info.plist's pinned bundle/team IDs and resolves Team 36B25Z964W in Keychain
  install  install the already-signed package; never builds, signs, or launches
  run      launch the installed app; never builds or installs
  location print the destination shared by install, run, and integration tests
  release  run tests, bump CFBundleVersion, package + timestamp-sign, validate and stage the
           installer zip; never uploads. Public installer updates need no account or token.
  publish  re-verify signature/manifest/archive, upload as GitHub release b<build> on
           FLOWCLONE_RELEASE_REPO with gh, and verify anonymous public download readback

Optional: FLOWCLONE_SIGN_IDENTITY, FLOWCLONE_TEAM_OU, FLOWCLONE_BUNDLE_ID,
          FLOWCLONE_BUILD_ROOT, FLOWCLONE_INSTALL_DIR, FLOWCLONE_ALLOW_DR_CHANGE=1,
          FLOWCLONE_RELEASE_NOTES_FILE, FLOWCLONE_RELEASE_REPO (defaults to app/Info.plist),
          FLOWCLONE_PUBLISH_LEGACY_BRIDGE=1 (only for the old private release feed)
EOF
	exit 2
}

ensure_build_root() {
	mkdir -p "$BUILD_ROOT"
}

# Install, run, and the integration runner must resolve the same destination. Never fall
# back to whichever copy happens to exist: that can launch a stale /Applications build
# after an install correctly selected the user's Applications directory.
resolve_install_dir() {
	if [ -n "${FLOWCLONE_INSTALL_DIR:-}" ]; then
		printf '%s\n' "$FLOWCLONE_INSTALL_DIR"
	elif [ -w /Applications ]; then
		printf '%s\n' /Applications
	else
		printf '%s\n' "$HOME/Applications"
	fi
}

build_release() {
	ensure_build_root
	echo "==> compiling"
	swift build -c release --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
}

run_checks() {
	ensure_build_root
	python3 tools/check_app_permissions.py
	echo "==> unit tests"
	swift test --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
	build_release
}

package_app() {
	ensure_build_root
	python3 tools/check_app_permissions.py
	python3 tools/release_manifest.py "$BUILD_ROOT/package-inputs-before.json"
	build_release
	python3 tools/release_manifest.py "$BUILD_ROOT/package-inputs-after.json"
	cmp -s "$BUILD_ROOT/package-inputs-before.json" "$BUILD_ROOT/package-inputs-after.json" || {
		echo "source changed during compilation — rebuild before packaging" >&2; exit 1;
	}
	local bin checkout
	bin=$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)

	# OUT is a fixed child of the user-private build root, never an unresolved/glob target.
	rm -rf "$OUT"
	mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
	cp "$bin/$APP" "$OUT/Contents/MacOS/$APP"
	cp app/Info.plist "$OUT/Contents/Info.plist"
	# Hash the reviewed inputs without reading local credentials or unrelated files.
	cp "$BUILD_ROOT/package-inputs-after.json" "$OUT/Contents/Resources/BuildManifest.json"
	local source_hash
	source_hash=$(shasum -a 256 "$OUT/Contents/Resources/BuildManifest.json" | awk '{print $1}')
	/usr/libexec/PlistBuddy -c "Add :FlowCloneSourceSHA256 string $source_hash" "$OUT/Contents/Info.plist"
	cp spikes/say8.wav "$OUT/Contents/Resources/say8.wav"
	# Dictation-start cue: /System/Library/Sounds/Pop.aiff with its sample-rate header raised
	# 25% (same samples, a major third up), so it matches the finish "Pop".
	cp app/StartCue.aiff "$OUT/Contents/Resources/StartCue.aiff"
	cp app/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
	# macOS 26+ reads its light/dark/tinted icon from here (CFBundleIconName); 14 and 15 use the .icns.
	cp app/Assets.car "$OUT/Contents/Resources/Assets.car"

	mkdir -p "$OUT/Contents/Resources/Licenses"
	cp app/Parakeet-Ultra-NOTICE.txt "$OUT/Contents/Resources/Licenses/"
	checkout="$SCRATCH/checkouts/FluidAudio"
	if [ -d "$checkout" ]; then
		mkdir -p "$OUT/Contents/Resources/Licenses"
		cp "$checkout/LICENSE" "$OUT/Contents/Resources/Licenses/FluidAudio-Apache-2.0.txt" 2>/dev/null || true
		cp "$checkout/ThirdPartyLicenses/"*.md "$OUT/Contents/Resources/Licenses/" 2>/dev/null || true
	else
		echo "!! FluidAudio checkout not found at $checkout — skipping license bundling" >&2
	fi
	echo "==> packaged unsigned app at $OUT"
}

CUSTOM_BUILD_ROOT="${FLOWCLONE_BUILD_ROOT:-}"
PINNED_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' app/Info.plist)
PINNED_TEAM_OU=$(/usr/libexec/PlistBuddy -c 'Print :FlowCloneTeamIdentifier' app/Info.plist)

resolve_signing_inputs() {
	FLOWCLONE_BUNDLE_ID="${FLOWCLONE_BUNDLE_ID:-$PINNED_BUNDLE_ID}"
	FLOWCLONE_TEAM_OU="${FLOWCLONE_TEAM_OU:-$PINNED_TEAM_OU}"
	[ "$FLOWCLONE_BUNDLE_ID" = "$PINNED_BUNDLE_ID" ] || {
		echo "bundle id '$FLOWCLONE_BUNDLE_ID' does not match pinned '$PINNED_BUNDLE_ID'" >&2
		exit 1
	}
	if [ "$FLOWCLONE_TEAM_OU" != "$PINNED_TEAM_OU" ] && [ "${FLOWCLONE_ALLOW_DR_CHANGE:-0}" != 1 ]; then
		echo "team OU '$FLOWCLONE_TEAM_OU' does not match pinned '$PINNED_TEAM_OU' — recipient updates and permissions would break" >&2
		exit 1
	fi
	if [ -z "${FLOWCLONE_SIGN_IDENTITY:-}" ]; then
		FLOWCLONE_SIGN_IDENTITY=$(python3 tools/resolve_signing_identity.py --team-ou "$FLOWCLONE_TEAM_OU")
	fi
}

sign_app() {
	resolve_signing_inputs
	[ -d "$OUT" ] || { echo "no package at $OUT — run ./build.sh package first" >&2; exit 1; }

	local packaged_id requirement requirements_file
	packaged_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUT/Contents/Info.plist")
	[ "$packaged_id" = "$FLOWCLONE_BUNDLE_ID" ] || {
		echo "bundle id input '$FLOWCLONE_BUNDLE_ID' does not match packaged '$packaged_id'" >&2
		exit 1
	}
	requirement="identifier \"$FLOWCLONE_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$FLOWCLONE_TEAM_OU\""
	requirements_file="$BUILD_ROOT/flowclone.rqset"
	printf 'designated => %s\n' "$requirement" > "$requirements_file"

	local timestamp_flag=(--timestamp)
	if [ "${FLOWCLONE_ALLOW_UNTIMESTAMPED:-0}" = 1 ]; then
		timestamp_flag=(--timestamp=none)
	fi

	echo "==> signing for bundle '$FLOWCLONE_BUNDLE_ID' and team '$FLOWCLONE_TEAM_OU'"
	codesign -f -s "$FLOWCLONE_SIGN_IDENTITY" "${timestamp_flag[@]}" --options runtime \
		--entitlements app/FlowClone.entitlements --requirements "$requirements_file" "$OUT"
	codesign --verify --strict --deep -R="$requirement" "$OUT" || {
		echo "CANARY FAILED — designated requirement does not match; TCC grants and updates would break." >&2
		exit 1
	}
	if [ "${FLOWCLONE_ALLOW_UNTIMESTAMPED:-0}" != 1 ]; then
		local sig_info
		sig_info=$(codesign -dvvv "$OUT" 2>&1)
		case "$sig_info" in
			*$'\nTimestamp='*|Timestamp=*) ;;
			*) echo "TIMESTAMP FAILED — signature lacks a cryptographic Apple timestamp." >&2; exit 1 ;;
		esac
	fi
	python3 tools/check_app_permissions.py --app "$OUT"
	echo "==> signed package at $OUT"
}

install_app() {
	[ -d "$OUT" ] || { echo "no package at $OUT — run package and sign first" >&2; exit 1; }
	codesign --verify --strict "$OUT" || {
		echo "package is not validly signed — run ./build.sh sign first" >&2
		exit 1
	}
	python3 tools/check_app_permissions.py --app "$OUT"

	local destination installed new_requirement old_requirement
	destination=$(resolve_install_dir)
	mkdir -p "$destination"
	if [ "$destination" = "$HOME/Applications" ]; then
		echo "!! /Applications not writable — installing to $destination"
	fi
	installed="$destination/$APP.app"
	new_requirement=$(codesign -d -r- "$OUT" 2>&1 | sed -n 's/^designated => //p')
	[ -n "$new_requirement" ] || { echo "signed package has no designated requirement" >&2; exit 1; }

	if [ -d "$installed" ] && [ "${FLOWCLONE_ALLOW_DR_CHANGE:-0}" != 1 ]; then
		old_requirement=$(codesign -d -r- "$installed" 2>&1 | sed -n 's/^designated => //p')
		if [ "$old_requirement" != "$new_requirement" ]; then
			echo "DR CHANGED — TCC grants would be lost (set FLOWCLONE_ALLOW_DR_CHANGE=1 to proceed)." >&2
			echo "old: $old_requirement" >&2
			echo "new: $new_requirement" >&2
			exit 1
		fi
	fi

	echo "==> installing to $installed"
	pkill -x "$APP" 2>/dev/null || true
	rm -rf "$installed"
	ditto "$OUT" "$installed"
	echo "==> installed (not launched)"
}

run_installed() {
	local destination installed
	destination=$(resolve_install_dir)
	installed="$destination/$APP.app"
	[ -d "$installed" ] || { echo "no installed app — run ./build.sh install first" >&2; exit 1; }
	open "$installed"
	sleep 1
	pgrep -x "$APP" >/dev/null \
		&& echo "==> running (pid $(pgrep -x "$APP" | head -1))" \
		|| { echo "LAUNCH FAILED" >&2; exit 1; }
}

UPDATE_REPO=$(/usr/libexec/PlistBuddy -c 'Print :FlowCloneUpdateRepository' app/Info.plist)
RELEASE_REPO="${FLOWCLONE_RELEASE_REPO:-$UPDATE_REPO}"
DIST="$BUILD_ROOT/dist"

# Bump CFBundleVersion (YYYYMMDDNN — the in-app updater compares it as an integer),
# package without credentials, sign, and stage the friends zip.
# Publishing is a separate invocation so a build can never ship by accident.
release_app() {
	resolve_signing_inputs
	ensure_build_root
	swift test --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
	python3 -m unittest discover -s tools -p 'test_*.py'
	local today cur build ver stage zip saved_notes=""
	today=$(date +%Y%m%d)
	cur=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' app/Info.plist)
	build="${today}01"
	if [ "$cur" -ge "$build" ]; then build=$((cur + 1)); fi
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" app/Info.plist
	ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)
	package_app
	sign_app
	if [ -f "$DIST/release-notes.md" ]; then
		saved_notes=$(mktemp "$BUILD_ROOT/release-notes.XXXXXX")
		cp "$DIST/release-notes.md" "$saved_notes"
	fi
	rm -rf "$DIST"
	stage="$DIST/FlowClone-$ver"
	mkdir -p "$stage"
	if [ -n "$saved_notes" ]; then
		mv "$saved_notes" "$DIST/release-notes.md"
	fi
	ditto "$OUT" "$stage/FlowClone.app"
	cp app/DISTRIBUTION-README.txt "$stage/README.txt"
	zip="FlowClone-$ver-$build.zip"
	ditto -c -k --keepParent "$stage" "$DIST/$zip"
	rm -rf "$stage"
	local archive_flags=()
	if [ "${FLOWCLONE_ALLOW_UNTIMESTAMPED:-0}" = 1 ]; then
		archive_flags+=(--allow-untimestamped)
	fi
	python3 tools/validate_release_archive.py \
		--bundle-id "$FLOWCLONE_BUNDLE_ID" --team-ou "$FLOWCLONE_TEAM_OU" --update-repo "$UPDATE_REPO" \
		${archive_flags[@]+"${archive_flags[@]}"} "$DIST/$zip"
	if [ -z "$CUSTOM_BUILD_ROOT" ]; then
		mkdir -p dist
		rm -f dist/FlowClone-*-*.zip
		cp "$DIST/$zip" "dist/$zip"
		cp app/DISTRIBUTION-README.txt dist/README.txt
	fi
	echo "==> release $ver ($build) staged and verified at $DIST/$zip — ./build.sh publish uploads it"
}

# Release tag b<build> + asset FlowClone-<version>-<build>.zip is what Updater.swift parses.
publish_release() {
	# A distributor's gh login must never hide a feed that fresh Macs cannot read.
	# Keep the historical private feed private: publish the same repair there only as
	# an explicit bridge for older installations that still have working access.
	if [ "$RELEASE_REPO" = "$UPDATE_REPO" ]; then
		local visibility
		visibility=$(gh api "repos/$RELEASE_REPO" --jq '.visibility')
		[ "$visibility" = public ] || {
			echo "update repository must be public so fresh Macs can download updates" >&2; exit 1;
		}
	elif [ "${FLOWCLONE_PUBLISH_LEGACY_BRIDGE:-0}" != 1 ] || \
	     [ "$RELEASE_REPO" != KilianTheMagnificent/flowclone-releases ]; then
		echo "publication destination differs from the app's update feed" >&2; exit 1
	fi
	local zip name build ver
	local archives=("$DIST"/FlowClone-*-*.zip)
	[ "${#archives[@]}" -eq 1 ] && [ -f "${archives[0]}" ] || {
		echo "expected exactly one staged release zip" >&2; exit 1;
	}
	zip=${archives[0]}
	name=$(basename "$zip" .zip)
	build=${name##*-}
	ver=${name#FlowClone-}; ver=${ver%-*}
	ensure_build_root
	# Verify the actual archive that will be uploaded against recipient-Mac rules and source hashes.
	local verification archive_flags=()
	verification=$(mktemp -d "$BUILD_ROOT/publish-verify.XXXXXX")
	trap 'rm -rf "$verification"' EXIT
	python3 tools/release_manifest.py "$verification/current-inputs.json"
	if [ "${FLOWCLONE_ALLOW_UNTIMESTAMPED:-0}" = 1 ]; then
		archive_flags+=(--allow-untimestamped)
	fi
	python3 tools/validate_release_archive.py \
		--bundle-id "$PINNED_BUNDLE_ID" --team-ou "$PINNED_TEAM_OU" --update-repo "$UPDATE_REPO" \
		--current-manifest "$verification/current-inputs.json" \
		${archive_flags[@]+"${archive_flags[@]}"} "$zip"
	local notes="${FLOWCLONE_RELEASE_NOTES_FILE:-$DIST/release-notes.md}"
	[ -f "$notes" ] || { echo "missing $notes — describe the reviewed changes before publishing" >&2; exit 1; }
	gh release create "b$build" --repo "$RELEASE_REPO" --latest --title "FlowClone $ver ($build)" \
		--notes-file "$notes" "$zip"
	if [ "$RELEASE_REPO" = "$UPDATE_REPO" ] && [ "${FLOWCLONE_SKIP_REMOTE_VERIFY:-0}" != 1 ]; then
		python3 tools/validate_release_archive.py --verify-published "$RELEASE_REPO" "$zip"
	fi
	rm -rf "$verification"
	trap - EXIT
	echo "==> published https://github.com/$RELEASE_REPO/releases/tag/b$build"
}

[ "$#" -le 1 ] || usage
case "${1:-build}" in
	build) build_release ;;
	check) run_checks ;;
	package) package_app ;;
	sign) sign_app ;;
	install) install_app ;;
	run) run_installed ;;
	location) resolve_install_dir ;;
	release) release_app ;;
	publish) publish_release ;;
	*) usage ;;
esac
