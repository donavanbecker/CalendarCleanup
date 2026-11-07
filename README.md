# Calendar Cleanup

A Mac app that finds duplicate calendar events and removes the ones you confirm.

## Download

Get the latest version from the [Releases page](https://github.com/donavanbecker/calendar-cleanup/releases/latest). Unzip it, move **Calendar Cleanup** to your Applications folder and open it. It needs macOS 14 or later, and it asks for calendar access the first time.

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

This requires a Developer ID Application certificate and a saved notarization login:

```bash
xcrun notarytool store-credentials calendar-cleanup
```

Update `MARKETING_VERSION` in the Xcode project, then run:

```bash
./scripts/release.sh
```

## Command-line tool

`CalendarDedupe/` holds an earlier command-line version with the same matching rules. Run it with no options to see how to use it.
