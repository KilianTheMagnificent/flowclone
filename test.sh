#!/bin/bash
# Unit tests run through SwiftPM and require no installed app, TCC grants, model load, or
# user-state mutation. The flags below are deliberately limited to probes whose claim really
# depends on an installed bundle, AppKit/TCC, a device, or a language model.
#
# Why this exists: `open -a FlowClone --args …` against a running instance just reopens
# the existing process and the launch-arg suite never executes, while stale log lines
# from an earlier run happily false-green the grep. So every suite: kill and WAIT for
# the old pid, launch the exact installed bundle path with a fresh `--runid`, wait for
# that marker to appear in the log (the app writes it after rotation), and scope every
# assertion to lines after it. A missing terminal marker, any FAIL line, a binary whose
# SHA-256 doesn't match the installed one, or a dead process all fail the suite.
#
#   ./test.sh                               hermetic FlowCloneCoreTests
#   ./test.sh --integration                 all installed-app integration probes
#   ./test.sh --pastertest --overlaytest    selected integration probes
#   ./test.sh --perf N                      N --selftest runs into a scratch TextEdit doc
set -u
cd "$(dirname "$0")"

APP=FlowClone
LOG="$HOME/Library/Logs/$APP.log"
INSTALL_DIR=$(./build.sh location)
BUNDLE="$INSTALL_DIR/$APP.app"
EXE="$BUNDLE/Contents/MacOS/$APP"

# say8.wav fixture transcript — what a --selftest run must land in the sink app.
FIXTURE_TEXT="The committee reviewed the quarterly financial statements and concluded that projected revenue growth would remain broadly consistent with earlier guidance."

# suite flag | terminal aggregate marker (must be the LAST thing the suite logs) | timeout s
SUITES="
--learntest|LEARNTEST PASS|60
--pastertest|PASTERTEST PASS|60
--transformtest|TRANSFORMTEST PASS|60
--recordertest|RECORDERCHECK signal liveness PASS|60
--pilltest|PILLTEST PASS|60
--overlaytest|OVERLAYTEST PASS|60
--overlaystress|OVERLAYSTRESS PASS|90
--menutest|MENUTEST PASS|60
--updatetest|UPDATETEST PASS|60
--insertiontest|INSERTIONTEST PASS|60
--polishtest|POLISHTEST PASS|180
--prompttest|PROMPTTEST PASS|180
"
ALL_INTEGRATION_FLAGS="--learntest --pastertest --transformtest --recordertest --pilltest --overlaytest --overlaystress --menutest --updatetest --insertiontest --polishtest --prompttest"

usage() {
	echo "usage: $0 [--unit]"
	echo "       $0 --integration"
	echo "       $0 --learntest --pastertest --transformtest --recordertest --pilltest --overlaytest --overlaystress --menutest --updatetest --insertiontest --polishtest --prompttest"
	echo "       $0 --perf N"
	exit 2
}

run_unit() {
	local scratch="${FLOWCLONE_TEST_BUILD_ROOT:-$HOME/Library/Caches/flowclone-tests}"
	mkdir -p "$scratch"
	swift test --scratch-path "$scratch"
}

require_bundle() {
	[ -d "$BUNDLE" ] || { echo "no installed bundle at $BUNDLE — run ./build.sh install first" >&2; exit 1; }
	# Bundle.main resolves /tmp and other symlinks; compare the same physical path.
	BUNDLE=$(cd "$BUNDLE" && pwd -P)
	EXE="$BUNDLE/Contents/MacOS/$APP"
	[ -x "$EXE" ]    || { echo "no executable at $EXE" >&2; exit 1; }
	WANT_SHA=$(shasum -a 256 "$EXE" | cut -c1-16)
}

PASSED=0; FAILED=0; VERDICTS=""

note()  { printf '   %s\n' "$*"; }
verdict() {   # name, PASS/FAIL, detail
	VERDICTS="$VERDICTS
$(printf '%-14s %-4s %s' "$1" "$2" "$3")"
	if [ "$2" = PASS ]; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); fi
}

# Kill the running app and wait for the pid to actually go away — `open` against a
# still-live process is the exact false-green this runner exists to prevent.
kill_app() {
	pgrep -x "$APP" >/dev/null || return 0
	pkill -x "$APP" 2>/dev/null
	local n=0
	while pgrep -x "$APP" >/dev/null; do
		sleep 0.2
		n=$((n + 1))
		if [ "$n" -ge 75 ]; then          # 15s
			note "! $APP would not exit — SIGKILL"
			pkill -9 -x "$APP" 2>/dev/null
			sleep 1
			return 0
		fi
	done
	# Two things outlive the pid: LaunchServices' registration (a next `open` inside
	# ~1s fails with -600, procNotFound) and the focus handoff — macOS gives the front
	# slot to the last regular app about 1.2s after an accessory app dies, which will
	# happily steal it back from a sink we just fronted. Sit out both.
	sleep 2
}

# Launch the exact installed bundle with a fresh runid and wait for the marker line.
# Echoes the log line number of the marker; empty = never appeared.
launch_and_mark() {   # runid, args…
	local runid=$1; shift
	local try=0
	until open "$BUNDLE" --args "$@" --runid "$runid" 2>/dev/null; do
		try=$((try + 1))
		[ "$try" -ge 8 ] && return 1      # LaunchServices never let go (-600)
		sleep 1
	done
	local n=0 line=""
	while [ "$n" -lt 120 ]; do            # 30s to get through log setup
		line=$(grep -n "RUNID $runid" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
		[ -n "$line" ] && { echo "$line"; return 0; }
		pgrep -x "$APP" >/dev/null || return 1
		sleep 0.25
		n=$((n + 1))
	done
	return 1
}

scoped() { tail -n +"$1" "$LOG"; }

# The binary that logged this run must be the binary sitting in the installed bundle.
check_identity() {   # start-line
	local body path sha
	body=$(scoped "$1" | grep -F "app launched —" | head -1)
	path=$(sed -E 's/.*path=(.*) exec-sha256=.*/\1/' <<<"$body")
	sha=$(sed -E 's/.*exec-sha256=([0-9a-f]+).*/\1/' <<<"$body")
	[ "$path" = "$BUNDLE" ] || { echo "bundle path $path != $BUNDLE"; return 1; }
	[ "$sha" = "$WANT_SHA" ] || { echo "exec sha $sha != installed $WANT_SHA"; return 1; }
	return 0
}

run_suite() {   # flag, marker, timeout
	local flag=$1 marker=$2 timeout=$3
	local runid start n body fails count why
	echo "==> $flag"
	kill_app
	runid=$(uuidgen)
	start=$(launch_and_mark "$runid" "$flag")
	if [ -z "$start" ]; then
		pgrep -x "$APP" >/dev/null \
			&& verdict "$flag" FAIL "runid marker never appeared" \
			|| verdict "$flag" FAIL "process died before the runid marker (precondition crash?)"
		return
	fi
	if ! why=$(check_identity "$start"); then
		verdict "$flag" FAIL "$why"
		return
	fi
	note "runid $runid  sha $WANT_SHA  log line $start"

	n=0
	while [ "$n" -lt $((timeout * 2)) ]; do
		body=$(scoped "$start")
		grep -qF "$marker" <<<"$body" && break
		# A terminal failure is already a verdict. Do not spend the entire timeout
		# waiting for a success marker that this completed suite will never emit.
		grep -qE '(OVERLAYSTRESS:|PROMPTTEST:|POLISHTEST:).*FAILURES|MENUTEST FAIL \(' <<<"$body" && break
		if ! pgrep -x "$APP" >/dev/null; then
			verdict "$flag" FAIL "process died before '$marker' (precondition crash?)"
			return
		fi
		sleep 0.5
		n=$((n + 1))
	done

	body=$(scoped "$start")
	count=$(grep -cF "$marker" <<<"$body")
	if [ "$count" -eq 0 ]; then
		if grep -qE 'FAIL' <<<"$body"; then
			verdict "$flag" FAIL "suite reported failure"
		else
			verdict "$flag" FAIL "no '$marker' within ${timeout}s"
		fi
		scoped "$start" | grep -E "FAIL" | sed 's/^/   | /'
		return
	fi
	# A-5: the aggregate is terminal by construction — more than one means a suite is
	# logging its summary before its subchecks finish, which is what X3 fixed. This used
	# to warn and pass; audit A-4 makes it fail, which is what "exactly one terminal
	# aggregate" always meant. Applies to every suite.
	if [ "$count" -ne 1 ]; then
		verdict "$flag" FAIL "'$marker' seen $count times (expected exactly 1)"
		sed 's/^/   | /' <<<"$(grep -F "$marker" <<<"$body")"
		return
	fi
	fails=$(grep -E "FAIL" <<<"$body")
	if [ -n "$fails" ]; then
		verdict "$flag" FAIL "$(wc -l <<<"$fails" | tr -d ' ') FAIL line(s)"
		sed 's/^/   | /' <<<"$fails"
		return
	fi
	sed 's/^/   | /' <<<"$(grep -F "$marker" <<<"$body")"
	verdict "$flag" PASS "$marker"
}

# ---------------------------------------------------------------- perf mode

frontmost() {
	local asn bid
	asn=$(lsappinfo front 2>/dev/null)
	if [ -n "$asn" ]; then
		bid=$(lsappinfo info -only bundleid "$asn" 2>/dev/null \
		      | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' | head -1)
		[ -n "$bid" ] && [ "$bid" != "(null)" ] && { echo "$bid"; return 0; }
	fi
	osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null
}

# Front the sink and keep it fronted. `open -a` wins where AppleScript `activate` is
# silently ignored, and it is issued unconditionally — lsappinfo has been seen naming
# the sink while NSWorkspace (what the app itself checks) still named another app, so
# "already frontmost" is not a safe reason to skip the raise. Two consecutive readings
# then have to agree: one can land inside the post-kill focus handoff and be stale.
ensure_front() {   # bundle-id, app name
	local want=$1 name=$2 i=0
	while [ "$i" -lt 12 ]; do
		open -a "$name" 2>/dev/null
		sleep 0.6
		if [ "$(frontmost)" = "$want" ]; then
			sleep 0.5
			[ "$(frontmost)" = "$want" ] && return 0
		fi
		i=$((i + 1))
	done
	return 1
}

run_perf() {   # N
	local runs=$1 sink=com.apple.TextEdit
	local i runid start body line ms front text seen times n why
	case "$runs" in ''|*[!0-9]*) usage ;; esac
	[ "$runs" -ge 1 ] || usage

	echo "==> perf: $runs --selftest runs into a scratch TextEdit document"
	if ! osascript -e 'tell application "TextEdit" to activate' \
	               -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1; then
		echo "PERF BLOCKED — osascript could not drive TextEdit." >&2
		echo "This needs a one-time human approval: System Settings > Privacy & Security >" >&2
		echo "Automation, allow the terminal to control TextEdit (and System Events)." >&2
		verdict "--perf" FAIL "osascript/TextEdit automation not permitted"
		return
	fi

	times=""
	for i in $(seq 1 "$runs"); do
		kill_app
		if ! ensure_front "$sink" TextEdit; then
			front=$(frontmost)
			verdict "--perf" FAIL "run $i: could not front $sink (frontmost is '$front')"
			break
		fi
		runid=$(uuidgen)
		start=$(launch_and_mark "$runid" --selftest --sink "$sink")
		[ -n "$start" ] || { verdict "--perf" FAIL "run $i: runid marker never appeared"; break; }
		if ! why=$(check_identity "$start"); then
			verdict "--perf" FAIL "run $i: $why"; break
		fi
		# The self-test fires 3s after the model is ready — re-confirm the sink still
		# owns the front slot before that, so a refused paste is a real finding.
		if ! ensure_front "$sink" TextEdit; then
			front=$(frontmost)
			verdict "--perf" FAIL "run $i: sink lost focus after launch (frontmost is '$front')"
			break
		fi

		# Model load + the suite's own 3s focus delay: give it room.
		n=0
		while [ "$n" -lt 240 ]; do
			grep -qF "SELFTEST timings:" <<<"$(scoped "$start")" && break
			pgrep -x "$APP" >/dev/null || break
			sleep 0.5
			n=$((n + 1))
		done
		body=$(scoped "$start")
		line=$(grep -F "SELFTEST timings:" <<<"$body" | tail -1)
		[ -n "$line" ] || { verdict "--perf" FAIL "run $i: no timing line within 120s"; break; }
		grep -q "mode=clean" <<<"$line" || { verdict "--perf" FAIL "run $i: not mode=clean — $line"; break; }
		ms=$(sed -E 's/.*paste ([0-9]+)ms.*/\1/' <<<"$line")

		# A-7 readback: the transcript must actually be in the sink document. The timing
		# line is stamped when Cmd+V is POSTED, so give the sink a moment to apply it.
		seen=0
		for _ in 1 2 3 4 5 6; do
			sleep 0.5
			text=$(osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null)
			seen=$(grep -oF "$FIXTURE_TEXT" <<<"$text" | wc -l | tr -d ' ')
			[ "$seen" = "$i" ] && break
		done
		if [ "$seen" != "$i" ]; then
			verdict "--perf" FAIL "run $i: sink holds $seen copies of the fixture text (want $i)"
			break
		fi
		printf '   run %2d  %sms  (sink verified)\n' "$i" "$ms"
		times="$times $ms"
	done

	osascript -e 'tell application "TextEdit" to close document 1 saving no' >/dev/null 2>&1

	set -- $times
	if [ "$#" -eq "$runs" ]; then
		local sorted median max mid
		sorted=$(printf '%s\n' "$@" | sort -n)
		max=$(tail -1 <<<"$sorted")
		mid=$((runs / 2))
		if [ $((runs % 2)) -eq 1 ]; then
			median=$(sed -n "$((mid + 1))p" <<<"$sorted")
		else
			median=$(( ( $(sed -n "${mid}p" <<<"$sorted") + $(sed -n "$((mid + 1))p" <<<"$sorted") ) / 2 ))
		fi
		echo "   timings:$times"
		echo "   median ${median}ms   max ${max}ms   (release→paste, mode=clean, n=$runs)"
		verdict "--perf" PASS "median ${median}ms max ${max}ms over $runs runs"
	fi
}

# ---------------------------------------------------------------- main

[ "$#" -gt 0 ] || { run_unit; exit; }

if [ "$1" = "--unit" ]; then
	[ "$#" -eq 1 ] || usage
	run_unit
	exit
fi

require_bundle

if [ "$1" = "--perf" ]; then
	[ "$#" -eq 2 ] || usage
	run_perf "$2"
else
	if [ "$1" = "--integration" ]; then
		[ "$#" -eq 1 ] || usage
		set -- $ALL_INTEGRATION_FLAGS
	fi
	for flag in "$@"; do
		entry=$(grep -F -- "$flag|" <<<"$SUITES")
		[ -n "$entry" ] || { echo "unknown suite flag: $flag" >&2; usage; }
		run_suite "$(cut -d'|' -f1 <<<"$entry")" \
		          "$(cut -d'|' -f2 <<<"$entry")" \
		          "$(cut -d'|' -f3 <<<"$entry")"
	done
fi

# Leave the machine with a normal instance: the last test launch is still carrying
# --runid (and in perf mode --sink, which would refuse every real paste).
kill_app
open "$BUNDLE"

echo
echo "==== summary ===="
printf '%s\n' "$VERDICTS" | sed '/^[[:space:]]*$/d'
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
