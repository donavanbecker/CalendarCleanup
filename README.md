# Calendar Cleanup

A Mac app that finds duplicate calendar events and removes the ones you confirm.

## Download

Get the latest version from the [Releases page](https://github.com/donavanbecker/calendar-cleanup/releases/latest). Unzip it, move **Calendar Cleanup** to your Applications folder and open it. It needs macOS 14 or later, and it asks for calendar access the first time.

The app checks for new versions on its own and installs them when you quit. You can also choose **Calendar Cleanup > Check for Updates…**.

## How it works

1. Add keywords if you want to check only some events, such as "Birthday". With no keywords, every event is checked.
2. Choose the calendars to clean and how far back and ahead to look.
3. Choose the rules: remove duplicates on the same calendar, keep shared events on one calendar, or both.
4. Click **Find Duplicates** and uncheck anything you want to keep.
5. Click **Remove … Events** and confirm.

Events count as duplicates when their title, start, end and all-day setting all match.

**Removals are permanent and sync to everyone who uses those calendars.**

- Events with attendees are never removed, because that can notify other people.
- For a repeating event, only the matching date is removed, not the whole series.
- Read-only calendars can't be changed, so they aren't listed.

Your calendar data stays on your Mac. The app doesn't collect or send any of it.

## Build from source

Open `CalendarCleanupApp/CalendarCleanup.xcodeproj` in Xcode, choose your team under **Signing & Capabilities** and run it.

## Publish a release

Pushing a tag like `v1.2.0` builds, signs and notarizes the app, then publishes it as a GitHub release with the signed `appcast.xml` that [Sparkle](https://sparkle-project.org) reads to offer the update:

```bash
git tag v1.2.0
git push origin v1.2.0
```

### Required repository secrets

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | Your Developer ID Application certificate, exported as `.p12` and base64-encoded |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_KEY_P8` | An App Store Connect API key (`.p8`), base64-encoded |
| `NOTARY_KEY_ID` | That API key's ID |
| `NOTARY_ISSUER_ID` | Your App Store Connect issuer ID |
| `SPARKLE_PRIVATE_KEY` | The private update signing key. It's in the login Keychain under the Sparkle account `calendar-cleanup`, and `generate_keys --account calendar-cleanup -x <file>` exports it |

Keep a safe backup of that key. Without it, you can't sign updates that existing copies of the app will accept.

## Command-line tool

`CalendarDedupe/` holds an earlier command-line version with the same matching rules. Run it with no options to see how to use it.
