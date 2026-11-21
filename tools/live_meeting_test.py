#!/usr/bin/env python3
"""Live acceptance test for automatic meeting notes in the installed FlowClone.

Unlike tools/mock-meeting.sh, nothing is simulated: a real Google Calendar event
reaches the Mac through Internet Accounts, the installed app's own timer detects
it, ScreenCaptureKit and the microphone record, Parakeet transcribes, the
on-device model summarizes and the note is saved. This script only observes and
plays a scripted dialogue through the speakers (system audio) while the app
records. It never changes the app, its preferences, or the calendar.

Before running:
  1. One-time setup in FlowClone → Meetings: Sign in with Google (the primary
     calendar is selected), confirm participant consent, turn on
     "Automatically record scheduled meetings".
  2. In Google Calendar, on a selected calendar, create an event titled e.g.
     "FlowClone live test" that starts 5+ minutes from now, lasts 3 minutes,
     has "Add Google Meet video conferencing" and no guests.
  3. python3 tools/live_meeting_test.py --title "FlowClone live test" [--speak]

Variations (the event is created the same way):
  --talk-past-end       plays the dialogue across the scheduled end; the recording must
                        continue and stop within about a minute of the last words.
  --max-start-delay N   for a late start (FlowClone opened or the Mac woke during the
                        meeting): accept a start up to N seconds after the scheduled start.
Quitting FlowClone unexpectedly mid-recording (kill -9) and reopening it must continue the
same note; this script keeps watching until the note is finished for good.

The first recording may show the macOS Screen & System Audio Recording prompt.
Exit status: 0 pass, 1 fail, 2 not set up.
"""
import argparse
import json
import os
import plistlib
import struct
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

BUNDLE = "com.andre.flowclone"
APP_BINARY = "/Applications/FlowClone.app/Contents/MacOS/FlowClone"
MEETINGS = Path.home() / "Library/Application Support/FlowClone/Meetings"
LOG = Path.home() / "Library/Logs/FlowClone.log"
REFERENCE_EPOCH = 978307200  # JSONEncoder's default Date encoding counts from 2001-01-01.

# Played through the speakers, so it reaches the app as system audio.
DIALOGUE = [
    ("Samantha", "This is Jordan. Let's confirm the warehouse move. The movers arrive on Tuesday at nine. "
                 "Priya, can you book the freight elevator by Monday?"),
    ("Daniel", "This is Priya. Agreed. I will book the freight elevator by Monday. The budget for the move "
               "is fifteen hundred dollars. We still need someone to label the server racks."),
]
SYSTEM_WORDS = ["warehouse", "tuesday", "elevator", "monday", "budget", "racks"]
# Read aloud by the person at the Mac (with --speak) to prove the microphone track.
SPOKEN = "The quarterly review moves to Thursday afternoon."
SPOKEN_WORDS = ["quarterly", "thursday"]


def stamp(value):
    return datetime.fromtimestamp(value + REFERENCE_EPOCH)


def say(message):
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def write_private_text(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
    finally:
        if fd >= 0:
            os.close(fd)


def preferences():
    try:
        out = subprocess.run(["defaults", "export", BUNDLE, "-"], capture_output=True, check=True).stdout
        return plistlib.loads(out)
    except (subprocess.CalledProcessError, plistlib.InvalidFileException):
        return {}


def notes():
    found = {}
    if not MEETINGS.is_dir():
        return found
    for path in MEETINGS.glob("*/note.json"):
        try:
            found[path.parent.name] = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            pass  # Mid-write; the next poll reads it.
    return found


class LogTail:
    """Prints the app's meeting lifecycle lines (builds after 2026-11-08 log them)."""

    def __init__(self):
        self.offset = LOG.stat().st_size if LOG.exists() else 0
        self.lines = []

    def poll(self):
        if not LOG.exists():
            return
        size = LOG.stat().st_size
        if size < self.offset:
            self.offset = 0  # Rotated.
        with LOG.open("rb") as handle:
            handle.seek(self.offset)
            chunk = handle.read()
        self.offset += len(chunk)
        for line in chunk.decode("utf-8", "replace").splitlines():
            if "meeting" in line:
                self.lines.append(line)
                print(f"    app log: {line}", flush=True)


def preflight():
    problems = []
    if subprocess.run(["pgrep", "-f", APP_BINARY], capture_output=True).returncode != 0:
        problems.append("FlowClone is not running from /Applications.")
    prefs = preferences()
    if not prefs.get("meetingCalendarIDs"):
        problems.append("No calendar is selected in Meetings (Sign in with Google, then tick a calendar).")
    if not prefs.get("meetingConsent"):
        problems.append("Participant consent is not confirmed in Meetings.")
    if not prefs.get("meetingAutoStart"):
        problems.append('"Automatically record scheduled meetings" is off.')
    return problems, prefs


def peak(path):
    """Loudest sample of a FlowClone segment (16 kHz mono float32 WAV)."""
    data = path.read_bytes()
    index = 12
    while index < len(data) - 8:
        chunk, size = data[index:index + 4], struct.unpack("<I", data[index + 4:index + 8])[0]
        if chunk == b"data":
            body = data[index + 8:index + 8 + size]
            count = len(body) // 4
            return max((abs(v) for v in struct.unpack("<%df" % count, body[:count * 4])), default=0.0)
        index += 8 + size + (size & 1)
    return 0.0


def check(results, name, ok, detail, hard=True):
    level = "PASS" if ok else ("FAIL" if hard else "WARN")
    results.append({"check": name, "result": level, "detail": detail})
    print(f"  {level:4}  {name}: {detail}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--title", required=True, help="exact title of the test event")
    parser.add_argument("--speak", action="store_true", help="prompt the person at the Mac to read a line aloud")
    parser.add_argument("--no-audio", action="store_true", help="do not play the dialogue")
    parser.add_argument("--wait-minutes", type=float, default=40, help="how long to wait for recording to start")
    parser.add_argument("--talk-past-end", action="store_true",
                        help="play the dialogue across the scheduled end; recording must continue until it is quiet")
    parser.add_argument("--max-start-delay", type=float, default=30,
                        help="seconds after the scheduled start by which recording must begin (raise for a late start)")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent
                        / "work" / f"live-meeting-{datetime.now():%Y%m%d-%H%M%S}")
    args = parser.parse_args()

    problems, prefs = preflight()
    if problems:
        print("Not set up for a live meeting test:")
        for problem in problems:
            print(f"  - {problem}")
        return 2
    say(f"Watching {len(prefs['meetingCalendarIDs'])} selected calendar(s) for a recording of {args.title!r}.")

    tail = LogTail()
    before = set(notes())
    deadline = time.time() + args.wait_minutes * 60
    note_id = None
    while note_id is None:
        tail.poll()
        for key, note in notes().items():
            if key not in before and note.get("event", {}).get("title") == args.title:
                note_id = key
        if note_id is None:
            if time.time() > deadline:
                print(f"FAIL: no recording of {args.title!r} started within {args.wait_minutes:g} minutes.")
                print("  Check that the event is on a selected calendar, has a Meet link or guests, and appears in")
                print("  Meetings → Upcoming (Refresh). The app log lines above show what it saw.")
                return 1
            time.sleep(2)

    note = notes()[note_id]
    event = note["event"]
    start, end = stamp(event["start"]), stamp(event["end"])
    say(f"Recording detected: note {note_id}, meeting {start:%H:%M:%S}–{end:%H:%M:%S}, "
        f"started {note['startedAt'] - event['start']:.1f}s after the scheduled start.")

    if not args.no_audio and (args.talk_past_end or note.get("phase") == "recording"):
        if args.talk_past_end:
            # The first voice ends just before the scheduled end; the second speaks after it.
            pause = (end - datetime.now()).total_seconds() - 14
            say(f"Waiting {max(0, pause):.0f}s to talk across the scheduled end.")
            until = time.time() + max(0, pause)
            while time.time() < until:
                tail.poll()
                time.sleep(1)
        else:
            time.sleep(2)
        for voice, line in DIALOGUE:
            if not args.talk_past_end and datetime.now() >= end:
                break
            say(f"Playing {voice} through the speakers.")
            subprocess.run(["say", "-v", voice, "-r", "165", line], check=False)
            tail.poll()
    if args.speak and datetime.now() < end:
        say(f'Please read aloud now: "{SPOKEN}"')

    finish_by = time.time() + max(0, (end - datetime.now()).total_seconds()) + 600
    while True:
        tail.poll()
        note = notes().get(note_id, note)
        # An interrupted recording is summarized, then continues while its meeting runs
        # (autoResume); it is finished once that flag is gone.
        if note.get("phase") in ("complete", "failed") and not note.get("autoResume"):
            break
        if time.time() > finish_by:
            break
        time.sleep(2)
    tail.poll()

    args.out.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.out.chmod(0o700)
    write_private_text(args.out / "note.json", json.dumps(note, indent=2, sort_keys=True))
    segments = note.get("segments", [])
    by_source = {}
    for segment in segments:
        by_source.setdefault(segment["source"], []).append(segment.get("text") or "")
    system_text = " ".join(by_source.get("system", [])).lower()
    mic_text = " ".join(by_source.get("microphone", [])).lower()
    summary = note.get("summary", "").lower()
    start_delay = note["startedAt"] - event["start"]
    end_delay = (note["endedAt"] - event["end"]) if note.get("endedAt") else None

    print("\nResults")
    results = []
    check(results, "detected and started automatically", 0 <= start_delay <= args.max_start_delay,
          f"{start_delay:.1f}s after the scheduled start (10s countdown + up to 2s timer expected)")
    # Past the scheduled end the app keeps recording while people talk, then stops once it is quiet.
    spoken_until = max((s["offset"] + s["duration"] for s in segments if (s.get("text") or "").strip()), default=None)
    quiet = None if end_delay is None or spoken_until is None else note["endedAt"] - (note["startedAt"] + spoken_until)
    on_time = end_delay is not None and abs(end_delay) <= 15
    ran_over = end_delay is not None and 15 < end_delay <= 1800 and quiet is not None and quiet <= 75
    check(results, "stopped at the scheduled end, or once the talking stopped", on_time or ran_over,
          "not stopped" if end_delay is None else f"{end_delay:+.1f}s from the scheduled end"
          + (f", {quiet:.0f}s after the last words" if quiet is not None else ""))
    if args.talk_past_end:
        late_words = [w for w in ("budget", "racks") if w in system_text]
        check(results, "kept recording past the scheduled end while talking",
              end_delay is not None and end_delay > 5 and bool(late_words),
              f"ended {end_delay:+.1f}s from the scheduled end; words spoken after it: {', '.join(late_words) or 'none'}"
              if end_delay is not None else "not stopped")
    check(results, "note finished", note.get("phase") == "complete",
          f"phase={note.get('phase')}" + (f", issue: {note['issue']}" if note.get("issue") else ""))
    check(results, "both audio tracks recorded", {"microphone", "system"} <= set(by_source),
          f"{len(segments)} segments: " + ", ".join(f"{k}={len(v)}" for k, v in sorted(by_source.items())))
    # A track of exact zeros means the wrong (or a muted) device was opened, not a quiet room.
    folder = MEETINGS / note_id
    mic_peak = max((peak(folder / s["audioFile"]) for s in segments
                    if s["source"] == "microphone" and (folder / s["audioFile"]).exists()), default=0.0)
    check(results, "microphone captured sound", mic_peak > 0.001, f"loudest microphone sample {mic_peak:.4f}")
    if not args.no_audio:
        heard = [w for w in SYSTEM_WORDS if w in system_text]
        check(results, "system audio transcribed", len(heard) >= 4,
              f"{len(heard)}/{len(SYSTEM_WORDS)} dialogue words: {', '.join(heard) or 'none'}")
        in_summary = [w for w in SYSTEM_WORDS if w in summary]
        check(results, "summary reflects the dialogue", len(in_summary) >= 2,
              f"{len(in_summary)} dialogue words in a {len(summary.split())}-word summary ({note.get('summaryMethod', '')})",
              hard=False)
    check(results, "summary generated", bool(summary.strip()), f"{len(summary.split())} words")
    if args.speak:
        heard = [w for w in SPOKEN_WORDS if w in mic_text]
        check(results, "microphone transcribed", len(heard) == len(SPOKEN_WORDS),
              f"heard {', '.join(heard) or 'none'} in the microphone track", hard=False)

    failed = any(r["result"] == "FAIL" for r in results)
    report = {"title": args.title, "note": note_id, "passed": not failed, "results": results,
              "scheduled": [start.isoformat(), end.isoformat()], "app_log": tail.lines}
    write_private_text(args.out / "report.json", json.dumps(report, indent=2))
    print(f"\n{'PASS' if not failed else 'FAIL'} · evidence in {args.out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
