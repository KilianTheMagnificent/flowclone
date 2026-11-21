# Google sign-in for meeting notes — 2026-11-08

**Sign in with Google** (Meetings page) opens Google's sign-in in a browser window. You pick the account and allow read-only calendar access. FlowClone then reads your calendars and events directly from the Google Calendar API, so you no longer need macOS Internet Accounts. **Use macOS Calendar accounts instead** keeps the old route through EventKit.

## How it works

- OAuth 2.0 for native apps (RFC 8252), shown with `ASWebAuthenticationSession`. It uses PKCE and an **iOS-type** Google client ID, whose redirect is the reversed client ID (`com.googleusercontent.apps.<id>:/oauth2redirect`). No client secret ships in the app.
- Scopes: `openid email https://www.googleapis.com/auth/calendar.readonly`. FlowClone never writes events. If the Calendar box is unticked on Google's consent screen, sign-in stops with a message that says so.
- The refresh token and the account email are kept in the login Keychain (`com.andre.flowclone.google-calendar`, this device only, never read with a prompt). Access tokens are kept in memory only. **Sign out of Google** revokes the token at Google and deletes the Keychain item.
- Sync uses `calendarList` and `events?singleEvents=true` for the selected calendars every 15 s, with a 15 s request timeout. The primary calendar is selected automatically after sign-in. Recurring instances keep their own IDs. Working-location, out-of-office and focus blocks are ignored. A Meet `hangoutLink` or a video conference entry (Zoom/Teams add-ons) counts as a join link, and goes through the same host allowlist as before.
- If the network drops, the last calendar is kept for up to 5 minutes, so one failed request doesn't cancel a countdown. An access error (for example a revoked token) clears it at once and asks you to sign in again.
- Logs record only lifecycle events (`meeting calendar: Google sign-in completed`, sync counts), never tokens, titles or addresses.

## FlowClone's Google project (created 2026-11-08)

- Project **FlowClone** (`flowclone`) on the maintainer's Google account; Google Calendar API enabled.
- Google Auth Platform: External, **Testing**, with the maintainer as the only test user. Google expires a Testing app's sign-in after 7 days, so FlowClone will ask you to sign in with Google again weekly. To publish (and stop that), the Branding page needs a public home page, a privacy-policy link and their authorized domain. Publishing was blocked on those.
- Client **FlowClone Mac**, type iOS, bundle ID `com.andre.flowclone`: `814659710502-6fa8vjp6o4n1mqjote86m619qhqeshc9.apps.googleusercontent.com` (in `app/Info.plist`). Google sends the reversed-ID redirect to its sign-in page and rejects other redirects with `redirect_uri_mismatch` (checked with curl).

## One-time Google Cloud setup (owner)

A Google client ID identifies the app to Google; it is not a secret.

1. <https://console.cloud.google.com/projectcreate>: create a project, e.g. "FlowClone".
2. APIs & Services → Library → **Google Calendar API** → Enable.
3. Google Auth Platform → Get started: app name FlowClone, your support email, Audience **External**, your contact email.
4. Audience: add yourself as a test user (Testing: Google expires the sign-in every 7 days). Publishing removes that limit, but needs a public home page, privacy-policy link and authorized domain on the Branding page first; then Google shows a one-time "Google hasn't verified this app" screen (Advanced → Go to FlowClone).
5. Clients → Create client → Application type **iOS**, name FlowClone, Bundle ID `com.andre.flowclone` → Create. Copy the Client ID (`….apps.googleusercontent.com`).
6. Put it in `app/Info.plist` → `FlowCloneGoogleClientID` and rebuild. To try it without rebuilding, run `defaults write com.andre.flowclone meetingGoogleClientID '<client id>'` and press Sign in with Google again.

## Tests

`GoogleCalendarTests` (fake HTTP; no network, browser or Keychain):
- the RFC 7636 PKCE vector and the reversed-ID redirect;
- the code exchange carries the verifier and no secret, and only the refresh token is kept;
- a forged `state`, a cancellation and an unticked Calendar box are all rejected;
- refresh works, and a revoked grant signs out;
- 401 retry and pagination;
- real event shapes: Meet with no guests, a Zoom add-on, a declined self, rooms, cancelled, all-day, working location and a lookalike link.

`MeetingTests` adds: a network blip keeps the countdown, an access loss clears the calendar, and sign-in selects the primary calendar while sign-out forgets it. The hidden app shows the new card. Pressing Sign in without a client ID shows the setup message, and the test session never opens a browser.

Not established yet: a real sign-in with the owner's account and a real calendar sync; both need the owner at the Mac.
