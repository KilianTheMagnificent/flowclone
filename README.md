# FlowClone

Dictation for the Mac: hold a key, speak, release, and cleaned-up text is typed where your
cursor is. Speech recognition runs on your Mac (Parakeet Ultra through
[FluidAudio](https://github.com/FluidInference/FluidAudio)). FlowClone can also record a
meeting, transcribe it on the Mac and write the notes.

## Status

A personal project, version 0.3. Its author uses it every day; a few friends use it too.

- Apple Silicon Macs on macOS 14 or newer. Intel Macs are not supported.
- English only.
- Not notarized by Apple. The one-line install below opens without a warning; a copy
  downloaded by hand needs **Open Anyway** once.
- Prompt mode, text transforms and written meeting summaries use Apple Intelligence
  (macOS 26 or newer) or, if you add your own key, Claude. Without either, dictation and
  Clean mode still work and meeting notes list key excerpts.
- No support is promised. Bug reports are welcome as issues; outside code changes are not
  accepted ([CONTRIBUTING](CONTRIBUTING.md)).

## Install

Open Terminal (in Applications > Utilities), paste this line and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/KilianTheMagnificent/flowclone/main/install.sh | bash
```

[The script](install.sh) downloads the latest release, checks its checksum and that it is
signed by the maintainer, puts `FlowClone.app` into Applications and opens it. Then:

1. Follow the three steps in the window: allow Microphone, Accessibility and Input
   Monitoring, then relaunch when asked.
2. The first launch downloads the speech model (about 630 MB, from huggingface.co; keep about
   1 GB free). The top right of the window shows progress until it says **Ready to dictate**.
3. Click into any text field, hold **fn** (or Control+Option), speak, release.

FlowClone then keeps itself up to date ([Releases and updates](#releases-and-updates)).

### Installing by hand

FlowClone is not notarized by Apple (that needs a paid developer account), so macOS refuses
to open a copy downloaded with a browser until you allow it once. The Terminal line above
avoids that; this route does not:

1. Download `FlowClone-<version>-<build>.zip` from the
   [latest release](https://github.com/KilianTheMagnificent/flowclone-updates/releases/latest).
2. Unzip it and drag `FlowClone.app` into Applications. Do not open it from Downloads:
   macOS then runs it from a temporary folder where permissions and updates do not stick.
3. Open FlowClone. macOS refuses the first time. On macOS 15 or newer go to System Settings >
   Privacy & Security, scroll down and click **Open Anyway**; on macOS 14 right-click the app
   and choose Open.
4. Continue with the three steps above. The zip's `README.txt` has them in more detail.

## What leaves the Mac

Without a Claude API key: nothing you say. Speech recognition, cleanup and summaries run on
the Mac; the app only downloads its speech model and its own updates, and reads your
calendar if you connect one.

With your own key saved (Settings > Dictation > Smart corrections), text is sent to
Anthropic over HTTPS: a Clean dictation that needs more than basic cleanup (short, already
clean ones stay local), every Prompt mode dictation, your dictionary words and learned
corrections, and meeting transcripts for the summary. Audio is never sent. Dictation into a
password field, expanded private snippets and rewrites that used on-screen context stay on
the Mac. **Model: Built-in model** keeps all dictation local while leaving the key saved;
Meetings has its own **Summary model** choice.

## Smart corrections

Clean removes abandoned words with rules. When a sentence still looks like a
self-correction, a model takes a second look and may only delete words. By default that is
Apple's on-device model, so nothing leaves the Mac. The **Smart corrections** switch, in
Settings > Dictation and in the menu-bar menu, turns the second look off and on; off keeps
the rules and never waits.

## Meeting notes

Open **Meetings** in the sidebar and choose **Sign in with Google**: Google's sign-in opens in a browser window, you allow read-only calendar access, and your primary calendar is selected (tick others as needed). FlowClone reads events through the Google Calendar API, never writes them, and keeps the sign-in in your Keychain. Google sign-in currently works only for accounts the maintainer has listed as test users, so most people should use the macOS Calendar route; a build of your own needs its own Google OAuth client ID ([one-time setup](docs/meeting-notes/google-sign-in.md)). **Use macOS Calendar accounts instead** keeps the older route through Internet Accounts and macOS Calendar.

Confirm participants have agreed to transcription and turn on **Automatically record scheduled meetings**. From then on nothing needs a click: after a 10-second countdown at an event's start, FlowClone captures microphone and system audio, transcribes locally, and saves the transcript and summary when the meeting ends. A red menu-bar recording icon and a stop command remain available with the window closed. Use headphones; system audio includes other apps' sound.

What is recorded: events on the selected calendars with a call link, guests, or a title that says it is a meeting ("team meeting", "sync", "call", "1:1", "standup", "interview"…). Classes (lectures, discussion sections, reviews), errands and focus blocks are left alone. Each event under **Upcoming** has a **Record automatically** switch to turn any event on or off.

What happens without you:

- **Late start.** If the Mac was asleep, FlowClone was closed or the network was down at the start, recording begins as soon as FlowClone sees the meeting is running.
- **Overlaps.** Of several meetings at once it records the one that started last (then the one with a call link, then the shorter), and picks up a longer one when that ends.
- **Running over.** Past the scheduled end it keeps recording while anyone was heard in the last 45 seconds, for up to 30 minutes, and never into the next scheduled meeting. Maximum 3 hours.
- **Interruptions.** A recording cut off by sleep, a microphone change (AirPods connecting), a crash or a failed start continues in the same note while the meeting is still running. **Stop and summarize**, Skip, Delete, and stopping the capture from the macOS menu bar are your decision and are not undone.
- **Staying awake.** The Mac does not idle-sleep while a meeting is recording.
- **Problems.** The FlowClone waveform gets an alert badge when automatic recording needs your attention. Choose **Reconnect Google Calendar…** from the menu if Google sign-in is required, or **Meeting recording needs attention…** for other setup issues.

Still yours to do: keep FlowClone running (it opens at login) and the Mac awake or woken during the meeting; leave early with **Stop and summarize** if you do not want the rest. While the Google project is in Testing, Google ends the sign-in every 7 days ([details](docs/meeting-notes/google-sign-in.md)); macOS asks about once a month to keep allowing screen and system-audio recording. Local speech recognition is English. Remote speakers share a system-audio label.

The meeting view contains Summary, Transcript and My notes, with local Markdown export, resume, retry and deletion (including audio). Notes and recoverable audio stay in `~/Library/Application Support/FlowClone/Meetings` until deleted. Summaries use an on-device model when available and clearly labeled key excerpts otherwise.

Hands-free mock: start the hidden test app with `tools/handsfree-flowclone.sh --with-model`, then use `meeting-mock` with `{"audio":["/absolute/alex.aiff","/absolute/maya.aiff"],"output":"/absolute/scratch/output"}`. It simulates calendar time and audio hardware, runs the production audio writer, local recognizer, summarizer and storage, and renders the Meetings page. Poll `meeting-result`. It never reads your calendar or microphone.

Run the complete acceptance scenario with `tools/mock-meeting.sh` (requires the existing downloaded Parakeet Ultra model, macOS voices, Swift, and Node). Evidence goes to `work/meeting-mock-<timestamp>/`. No new third-party dependency is needed.

Live test against the installed app, with nothing simulated: after the one-time Meetings setup, create a 3-minute Google Calendar event with a Meet link and no guests, 15+ minutes ahead, then run `python3 tools/live_meeting_test.py --title "<event title>" --speak`. It waits for the app to record the event, plays a dialogue through the speakers, and checks start/stop timing, both audio tracks, the transcript and the summary. `--talk-past-end` and `--max-start-delay` cover a meeting that runs over and a late start. It only reads the app's preferences, notes and log.

## Releases and updates

`./build.sh release` tests, signs and stages the zip; `./build.sh publish` uploads it to the
public feed `KilianTheMagnificent/flowclone-updates` (maintainer only: signing is pinned to his Apple team). Installed
copies check a minute after launch, every 6 hours and after a wake, and install only a build
that is newer, signed by the same Apple team, and runs on that Mac's macOS and processor.

- **A build that does not start is undone.** After an update the previous build is kept for a
  minute; if the new one cannot be opened or is gone within about 20 seconds, the previous
  build is put back and reopened, and that Mac leaves the failed build alone for a week.
- **Pulling a bad release:** `gh release delete b<build> --repo KilianTheMagnificent/flowclone-updates --cleanup-tag`
  makes the previous release the latest again. Copies that already installed it never
  downgrade, so ship a fixed build with a higher number.
- **Do not rename or delete** the feed repository or the GitHub account: the feed address is
  inside every installed copy.
- **Signing.** Builds are signed with an Apple Development certificate (team `36B25Z964W`,
  expires 2027-07-30) and are not notarized, so a copy downloaded with a browser needs
  **Open Anyway** once. A new
  certificate from the same team keeps updates working. A Developer ID certificate and
  notarization (paid Apple Developer Program) would remove the warning; `build.sh` already
  prefers a Developer ID certificate when one is in the Keychain but has no notarization step.

## Building from source

Needs a Swift 6 toolchain (Xcode) on an Apple Silicon Mac. `build.sh` builds in
`~/Library/Caches/flowclone-build` and never touches an installed copy unless told to.

```sh
./build.sh check     # every test, warnings as errors, then a release build
./build.sh package   # an unsigned FlowClone.app in the build cache
python3 -m unittest discover -s tools -p 'test_*.py'   # release-tool tests
```

`sign`, `release` and `publish` are pinned to the maintainer's Apple team and update feed
(`app/Info.plist`), so they only work for him. To run a build of your own, change the bundle
identifier, team and update repository there and sign with your own certificate; macOS ties
the microphone and Accessibility permissions to that signature. That path is untested.

## Hands-free UI testing

A hidden debug copy of the app can be driven from the command line (by a person or a coding agent) without touching your screen, focus, keyboard, clipboard, microphone, preferences or data. Run from the repo root. Never use `test.sh --integration/--menutest/--pilltest/--perf`, `build.sh install/run` or `pkill FlowClone`: they replace or drive the installed app.

```sh
tools/handsfree-flowclone.sh [--with-model] -- -appearanceTheme interface  # build, start hidden and never frontmost
node tools/handsfree.mjs text --target FlowClone                           # accessibility tree of the main window
node tools/handsfree.mjs click Settings --target FlowClone                 # label or #identifier; also type --into, key, wait
node tools/handsfree.mjs shot /private/tmp/fc.png --target FlowClone       # then look at the PNG
node tools/handsfree.mjs action dictate '{"audio":"spikes/say8.wav"}'      # needs --with-model; result lands in Draft and History
node tools/handsfree.mjs focus && node tools/handsfree.mjs logs && node tools/handsfree.mjs stop
```

App actions: `page {name}`, `dictate {audio}`, `pill {phase, level}` (then `shot --target "Recording pill"`), `menu` or `menu {press: title}` (status menu), `transform` (preview window), `windows` (names sheets so `--target` reaches them). Refused in a session, and logged as `handsfree: blocked …`: hotkey tap, microphone, AX and Cmd+V into other apps, notifications, sounds, login item, updater, model download, pop-up menus. Pressing an alert-sheet button reports `does not support press` although it took effect, so check the result. Out of reach: real hotkey, mic and paste, the menu-bar menu, pop-up choices, TCC prompts, on-screen pill placement and Dock following, and vibrancy.

`--with-model` seeds the Ultra cache. For an already-downloaded isolated cache,
set `FLOWCLONE_PARAKEET_MODEL_DIR` to its `parakeet-ultra` directory. The
hidden app still refuses model downloads.

## How this was built

Andre Romero-Carey directs development with AI coding agents (Claude, Codex and Gemini) and
checks the results by running them, rather than writing Swift by hand.

- Every change has to pass the test suite (about 570 tests, warnings as errors) and is then
  seen working in a hidden copy of the app that dictates a recorded sentence.
- Larger features were also run for real on his Mac: meeting recording was tested against
  real calendar events, including a crash and a microphone change in the middle.
- Security and update handling were reviewed by a separate pass before the source was
  published. The updater installs only builds signed by the same Apple team and puts the
  previous build back if a new one does not start.
- It has run on one Mac daily (Apple Silicon, macOS 27) and on a few friends' Macs. Support
  for macOS 14, 15 and 26, multi-input audio interfaces and non-US keyboards comes from
  reading the code and from unit tests, not from those machines.

## Licence

MIT, see [LICENSE](LICENSE). The speech model and FluidAudio have their own licences, bundled
in the app ([notice](app/Parakeet-Ultra-NOTICE.txt)).
