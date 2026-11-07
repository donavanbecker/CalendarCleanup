// calendar-dedupe: removes duplicate events from one calendar, keeping one copy.
//
// Events are duplicates when title, start, end and all-day status all match.
// Only the single occurrence is ever removed, never a whole recurring series.
// Events with attendees are never removed, because that can notify other people.

import EventKit
import Foundation

let usage = """
Usage:
  calendar-dedupe --list-calendars
  calendar-dedupe --calendar <name> --days <1-1460> [--dry-run]
  calendar-dedupe --calendar-id <id> --days <1-1460> [--dry-run]
  calendar-dedupe --remove-from <name> --also-on <name> --days <1-1460> [--dry-run]
  calendar-dedupe --audit --days <1-1460>
  calendar-dedupe --cleanup --keep-birthdays-on <name> --days <1-1460> [--dry-run]

Add --back <days> to any of these to also look back from today.
The whole range can't be longer than 1460 days.

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func describe(_ calendar: EKCalendar) -> String {
    let access = calendar.allowsContentModifications ? "" : "  [read-only]"
    return "\(calendar.title)  (account: \(calendar.source.title))  id: \(calendar.calendarIdentifier)\(access)"
}

func requestAccess(_ store: EKEventStore) -> Bool {
    let done = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in
        granted = ok
        done.signal()
    }
    done.wait()
    return granted
}

func findCalendar(_ store: EKEventStore, name: String?, id: String?) -> EKCalendar {
    let calendars = store.calendars(for: .event)
    if let id {
        guard let match = calendars.first(where: { $0.calendarIdentifier == id }) else {
            fail("No calendar has the id \(id). Run --list-calendars to see them.")
        }
        return match
    }
    let matches = calendars.filter { $0.title == name }
    if matches.count == 1 { return matches[0] }
    if matches.isEmpty { fail("No calendar is named \"\(name ?? "")\". Run --list-calendars to see them.") }
    let listing = matches.map(describe).joined(separator: "\n  ")
    fail("More than one calendar is named \"\(name ?? "")\". Use --calendar-id with one of:\n  \(listing)")
}

struct EventKey: Hashable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool

    init(_ event: EKEvent) {
        title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
    }
}

// Prefers a recurring event, then the oldest, so repeat runs make the same choice.
func shouldKeepFirst(_ a: EKEvent, _ b: EKEvent) -> Bool {
    if a.hasRecurrenceRules != b.hasRecurrenceRules { return a.hasRecurrenceRules }
    let aCreated = a.creationDate ?? .distantFuture
    let bCreated = b.creationDate ?? .distantFuture
    if aCreated != bCreated { return aCreated < bCreated }
    return a.calendarItemIdentifier < b.calendarItemIdentifier
}

func eventsToRemove(from group: [EKEvent]) -> [EKEvent] {
    let invited = group.filter(\.hasAttendees)
    let plain = group.filter { !$0.hasAttendees }.sorted(by: shouldKeepFirst)
    // An event with attendees is always kept, so it can stand in as the kept copy.
    return invited.isEmpty ? Array(plain.dropFirst()) : plain
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

let store = EKEventStore()
guard requestAccess(store) else {
    fail("Calendar access was denied. Allow it in System Settings > Privacy & Security > Calendars.")
}

if args.contains("--list-calendars") {
    store.calendars(for: .event).map(describe).sorted().forEach { print($0) }
    exit(0)
}

// EventKit will not search a range longer than four years.
guard let days = value(after: "--days", in: args).flatMap({ Int($0) }), (1...1460).contains(days) else {
    fail("--days must be a whole number from 1 to 1460.\n\n" + usage)
}
let dryRun = args.contains("--dry-run")

let backArgument = value(after: "--back", in: args)
let back = backArgument.flatMap { Int($0) } ?? 0
guard (backArgument == nil || Int(backArgument!) != nil), back >= 0, back + days <= 1460 else {
    fail("--back must be a whole number, and --back plus --days can't be more than 1460.")
}

let today = Calendar.current.startOfDay(for: Date())
guard let start = Calendar.current.date(byAdding: .day, value: -back, to: today),
      let end = Calendar.current.date(byAdding: .day, value: days, to: today) else {
    fail("Could not work out the date range.")
}

func fetchEvents(on calendar: EKCalendar) -> [EKEvent] {
    store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
}

func dateText(_ date: Date) -> String {
    DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
}

// Read-only: reports repeats inside each calendar and across each pair of calendars.
if args.contains("--audit") {
    let calendars = store.calendars(for: .event).sorted { $0.title < $1.title }
    var calendarsByEvent: [EventKey: Set<String>] = [:]
    for calendar in calendars {
        let found = fetchEvents(on: calendar)
        let extras = Dictionary(grouping: found, by: EventKey.init).values.reduce(0) { $0 + $1.count - 1 }
        print("WITHIN \(extras) extra copies, \(found.count) events: \(calendar.title)")
        for event in found { calendarsByEvent[EventKey(event), default: []].insert(calendar.title) }
    }
    var pairs: [String: [EventKey]] = [:]
    for (key, titles) in calendarsByEvent where titles.count > 1 {
        let sorted = titles.sorted()
        for (i, first) in sorted.enumerated() {
            for second in sorted[(i + 1)...] { pairs["\(first)  <->  \(second)", default: []].append(key) }
        }
    }
    for (pair, keys) in pairs.sorted(by: { $0.value.count > $1.value.count }) {
        print("ACROSS \(keys.count) shared events: \(pair)")
        for key in keys.sorted(by: { $0.start < $1.start }).prefix(5) {
            print("    \(key.title) at \(dateText(key.start))")
        }
    }
    exit(0)
}

// Removes events from one calendar when an identical event exists on another.
if let fromName = value(after: "--remove-from", in: args) {
    guard let otherName = value(after: "--also-on", in: args) else { fail(usage) }
    let from = findCalendar(store, name: fromName, id: nil)
    let other = findCalendar(store, name: otherName, id: nil)
    guard from.calendarIdentifier != other.calendarIdentifier else { fail("Those are the same calendar.") }
    guard from.allowsContentModifications else { fail("\"\(from.title)\" is read-only, so its events can't be removed.") }

    let otherKeys = Set(fetchEvents(on: other).map(EventKey.init))
    let matches = fetchEvents(on: from).filter { otherKeys.contains(EventKey($0)) }
    let targets = matches.filter { !$0.hasAttendees }.sorted { $0.startDate < $1.startDate }
    for event in targets {
        let kind = event.hasRecurrenceRules ? " [one date of a repeating event]" : ""
        print("\(dryRun ? "Would remove" : "Removing"): \(event.title ?? "(no title)") at \(dateText(event.startDate))\(kind)")
        if !dryRun {
            do {
                try store.remove(event, span: .thisEvent, commit: false)
            } catch {
                fail("Stopped without saving. Could not remove \"\(event.title ?? "")\": \(error.localizedDescription)")
            }
        }
    }
    if !dryRun && !targets.isEmpty {
        do {
            try store.commit()
        } catch {
            fail("Could not save the removals: \(error.localizedDescription)")
        }
    }
    print("\"\(from.title)\": \(matches.count) events also on \"\(other.title)\" over \(days) days, \(dryRun ? "would remove" : "removed") \(targets.count), skipped \(matches.count - targets.count) with attendees.")
    exit(0)
}

// On every editable calendar: removes birthdays that also exist on the keep calendar,
// then removes same-calendar duplicates, leaving one copy of each.
if args.contains("--cleanup") {
    guard let keepName = value(after: "--keep-birthdays-on", in: args) else { fail(usage) }
    let keep = findCalendar(store, name: keepName, id: nil)
    let keepKeys = Set(fetchEvents(on: keep).map(EventKey.init))
    let verb = dryRun ? "Would remove" : "Removing"
    var removeFailed: String?
    var total = 0

    func remove(_ event: EKEvent, reason: String, from calendar: EKCalendar) {
        let kind = event.hasRecurrenceRules ? " [one date of a repeating event]" : ""
        print("\(verb) [\(reason)] [\(calendar.title)]: \(event.title ?? "(no title)") at \(dateText(event.startDate))\(kind)")
        total += 1
        if dryRun || removeFailed != nil { return }
        do {
            try store.remove(event, span: .thisEvent, commit: false)
        } catch {
            removeFailed = "\"\(event.title ?? "")\": \(error.localizedDescription)"
        }
    }

    let calendars = store.calendars(for: .event).filter(\.allowsContentModifications).sorted { $0.title < $1.title }
    for calendar in calendars {
        var remaining = fetchEvents(on: calendar)
        let checked = remaining.count
        var birthdayCount = 0
        var notOnKeep = 0
        if calendar.calendarIdentifier != keep.calendarIdentifier {
            var others: [EKEvent] = []
            for event in remaining {
                let isBirthday = (event.title ?? "").localizedCaseInsensitiveContains("birthday")
                if isBirthday && !keepKeys.contains(EventKey(event)) { notOnKeep += 1 }
                if isBirthday && keepKeys.contains(EventKey(event)) && !event.hasAttendees {
                    remove(event, reason: "birthday", from: calendar)
                    birthdayCount += 1
                } else {
                    others.append(event)
                }
            }
            remaining = others
        }
        var duplicateCount = 0
        for group in Dictionary(grouping: remaining, by: EventKey.init).values where group.count > 1 {
            for event in eventsToRemove(from: group) {
                remove(event, reason: "duplicate", from: calendar)
                duplicateCount += 1
            }
        }
        print("SUMMARY \(calendar.title): checked \(checked), birthdays \(birthdayCount), duplicates \(duplicateCount), birthdays not on keep calendar \(notOnKeep)")
    }
    if let removeFailed { fail("Stopped without saving. Could not remove \(removeFailed)") }
    if !dryRun && total > 0 {
        do {
            try store.commit()
        } catch {
            fail("Could not save the removals: \(error.localizedDescription)")
        }
    }
    print("SUMMARY total \(dryRun ? "would remove" : "removed") \(total), from \(dateText(start)) to \(dateText(end))")
    exit(0)
}

let calendarName = value(after: "--calendar", in: args)
let calendarID = value(after: "--calendar-id", in: args)
guard calendarName != nil || calendarID != nil else { fail(usage) }

let calendar = findCalendar(store, name: calendarName, id: calendarID)
guard calendar.allowsContentModifications else {
    fail("\"\(calendar.title)\" is read-only, so its events can't be removed.")
}

let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
let events = store.events(matching: predicate)
let duplicates = Dictionary(grouping: events, by: EventKey.init).values.filter { $0.count > 1 }

let stamp = ISO8601DateFormatter().string(from: Date())
let shown = DateFormatter()
shown.dateStyle = .medium
shown.timeStyle = .short

var removed = 0
for group in duplicates.sorted(by: { $0[0].startDate < $1[0].startDate }) {
    for event in eventsToRemove(from: group) {
        print("\(dryRun ? "Would remove" : "Removing"): \(event.title ?? "(no title)") at \(shown.string(from: event.startDate))")
        if !dryRun {
            do {
                try store.remove(event, span: .thisEvent, commit: false)
            } catch {
                fail("Stopped without saving. Could not remove \"\(event.title ?? "")\": \(error.localizedDescription)")
            }
        }
        removed += 1
    }
}

if !dryRun && removed > 0 {
    do {
        try store.commit()
    } catch {
        fail("Could not save the removals: \(error.localizedDescription)")
    }
}

print("\(stamp) \"\(calendar.title)\": checked \(events.count) events over \(days) days, \(dryRun ? "would remove" : "removed") \(removed).")
