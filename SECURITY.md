# Security Policy

## Scope

FlowClone is a macOS app that holds Microphone, Accessibility and Input Monitoring
permission, and optionally Calendar and Screen & System Audio Recording. It:

- records speech, and with meeting notes on, meeting audio, and transcribes it on the Mac;
- pastes text into the app you are using, and refuses to dictate into password fields;
- keeps secrets only in the macOS Keychain: your own Anthropic API key and, if you sign in
  with Google, a read-only Calendar token;
- sends text to Anthropic only when you have saved your own API key (see "What leaves the
  Mac" in the [README](README.md)), reads Google Calendar if you connect it, and downloads
  its speech model and its own updates;
- updates itself from GitHub Releases, installing only a build signed by the same Apple
  developer team as the running one.

It has no accounts or server of its own.

## Reporting a Vulnerability

Please report a security issue privately through GitHub's
[Private Vulnerability Reporting](https://github.com/KilianTheMagnificent/flowclone/security/advisories/new)
instead of opening a public issue. Examples: an update that installs without a valid
signature, text or audio leaving the Mac when the settings say it stays, a secret written
outside the Keychain, another program driving FlowClone's permissions.

Please include the FlowClone build, your macOS version and steps to reproduce, without real
dictations, meeting notes or keys.

A problem with a published installer, its signature or the update feed can also be reported
at the [release repository](https://github.com/KilianTheMagnificent/flowclone-updates/security/advisories/new).
