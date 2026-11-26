FlowClone — hold a key, talk, release, cleaned text is pasted where your cursor is.
Speech recognition runs on your Mac. Your voice is never sent anywhere, and the text of
what you say leaves the Mac only through two optional features: your own Claude API key
(then the text of dictations that need more than basic cleanup, Prompt mode dictations,
your dictionary words and meeting transcripts, notes, titles and invitee names go to
Anthropic) and publishing meeting notes to a GitHub repository you connect (then the
notes, and by default the full transcript, go to that repository).

REQUIREMENTS
- Apple Silicon Mac (M1 or newer). Intel Macs are not supported.
- macOS 14 or newer. Text transforms and the built-in model need Apple
  Intelligence (macOS 26 or newer, turned on). Without it, Prompt mode uses
  Claude if you add your own API key and otherwise works like Clean; meeting
  notes list key excerpts instead of a written summary. Settings > This Mac
  shows whether Apple Intelligence is available and why not.
- About 1 GB free disk and an internet connection for the one-time speech
  model download (about 630 MB) from huggingface.co.
- Speech recognition understands English only, whatever language your Mac is set to.

INSTALL
1. Drag FlowClone.app itself (not the outer FlowClone-0.3 folder) into your
   Applications folder. Do not open FlowClone directly from Downloads, or macOS
   runs it from a temporary read-only folder where permissions and updates break.
2. Double-click FlowClone in Applications. macOS will refuse to open it (it is
   not notarized with Apple). Close that dialog, then:
   - macOS 15 or newer: System Settings > Privacy & Security > scroll to the
     bottom > click "Open Anyway" next to FlowClone > Open.
   - macOS 14: right-click FlowClone.app > Open > Open.
   You only do this once.
3. Follow the three steps in the FlowClone window and allow Microphone, Accessibility and
   Input Monitoring when asked. Accessibility is required for the hotkey and for pasting
   the text. If you dismissed a prompt, add FlowClone under
   System Settings > Privacy & Security > Accessibility / Input Monitoring / Microphone
   and relaunch.
4. The first launch downloads the speech model (about 630 MB). The top right of
   the FlowClone window shows progress; wait until it says "Ready to dictate".
   If the download fails, Settings > This Mac says why (offline, a blocked
   network or Wi-Fi sign-in page, or not enough disk space) and has a Retry
   button. FlowClone also retries by itself when the network comes back.
5. Optional — Smart corrections with Claude: FlowClone does not include an API key.
   When Settings opens, paste your own Anthropic API key (from console.anthropic.com,
   stored only in your Mac's Keychain) or click "Use built-in model instead" (on a
   Mac without Apple Intelligence: "Skip, keep everything on this Mac") to run
   100% on your Mac. You can switch later under Settings > Dictation > Model.

USE
- FlowClone appears in the Dock and the menu bar. Right-click its Dock icon and
  choose Options > Keep in Dock to pin it. Closing the window keeps dictation running.
- FlowClone opens at login. Turn that off in Settings > This Mac > Open FlowClone
  at login.
- Click into any text field, hold the fn key (or Ctrl+Option), speak, release.
  Text appears at the cursor.
- The menu bar icon has settings, modes, and Quit.

UPDATES
- FlowClone checks for a new version about a minute after launch and every 6 hours,
  downloads it, verifies it is signed by the same developer, and installs it when
  you are idle (or as soon as you click "Install & Relaunch" or close the window).
  You keep your permissions. If a new version does not start on your Mac, FlowClone
  puts the previous version back by itself.
- Menu bar icon > Updates > "Check for updates" (or Settings > "Check for updates")
  downloads, installs, and relaunches into the latest version right away.
- Settings > Updates & diagnostics > "Check for updates automatically" turns the
  automatic checks off or on.
- The line beside it shows the current build and update state.
- Updates use a public, installer-only feed. No GitHub account or update credential
  is needed. Source code and your dictation data are not part of that feed.
- If an older copy says update access is missing, expired, or HTTP 404, quit it and
  replace FlowClone.app in Applications with this copy once. That repairs access for
  all future updates.
  If your Mac user account cannot write to /Applications, drag FlowClone.app into
  your user's ~/Applications folder instead.

Alternative to step 2 (Terminal): xattr -dr com.apple.quarantine /Applications/FlowClone.app
