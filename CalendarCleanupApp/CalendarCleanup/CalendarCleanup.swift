// Calendar Cleanup: finds duplicate events by title, start, end and all-day status,
// shows them for review, and removes only what you confirm.
//
// Only single occurrences are removed, never a whole repeating series.
// Events with attendees are never removed, because that can notify other people.
// The last removal is saved so it can be undone, and the list can be exported as CSV.

import EventKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

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

struct Finding: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let reason: String
    let events: [EKEvent]
}

/// A removed event, saved so Undo can put it back. A removed date of a repeating
/// event comes back as a single event, because a series can't be re-joined.
struct RemovedEvent: Codable {
    struct Alarm: Codable {
        let offset: TimeInterval
        let date: Date?
    }

    let calendarID: String
    let title: String?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let timeZone: String?
    let location: String?
    let notes: String?
    let url: URL?
    let availability: Int
    let alarms: [Alarm]

    init(_ event: EKEvent) {
        calendarID = event.calendar.calendarIdentifier
        title = event.title
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        timeZone = event.timeZone?.identifier
        location = event.location
        notes = event.notes
        url = event.url
        availability = event.availability.rawValue
        alarms = (event.alarms ?? []).map { Alarm(offset: $0.relativeOffset, date: $0.absoluteDate) }
    }

    func makeEvent(in store: EKEventStore, calendar: EKCalendar) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.isAllDay = isAllDay
        event.timeZone = timeZone.flatMap(TimeZone.init(identifier:))
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.url = url
        event.availability = EKEventAvailability(rawValue: availability) ?? .notSupported
        event.alarms = alarms.map { $0.date.map(EKAlarm.init(absoluteDate:)) ?? EKAlarm(relativeOffset: $0.offset) }
        return event
    }
}

struct ScanRequest {
    let calendarIDs: Set<String>
    let back: Int
    let ahead: Int
    let keywords: [String]
    let removeSameCalendar: Bool
    let keepOnID: String?
}

@MainActor
final class Cleaner: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published var access = Access.unknown
    @Published var calendars: [EKCalendar] = []
    @Published var findings: [Finding] = []
    @Published var selected: Set<UUID> = []
    @Published var skippedWithAttendees = 0
    @Published var scannedCount = 0
    @Published var hasScanned = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    /// The events removed most recently, kept on disk until undone or replaced.
    @Published private(set) var lastRemoval: [RemovedEvent] = []

    private let store = EKEventStore()
    private var lastRequest: ScanRequest?
    private var didAutoClean = false

    private static let undoFile: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("Last Removal.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.undoFile),
           let saved = try? JSONDecoder().decode([RemovedEvent].self, from: data) {
            lastRemoval = saved
        }
    }

    var selectedEventCount: Int {
        findings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.events.count }
    }

    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted {
            calendars = store.calendars(for: .event).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        access = granted ? .granted : .denied
    }

    /// Scans with the saved settings and removes everything found, once per launch.
    func autoClean(_ request: ScanRequest) async {
        guard !didAutoClean else { return }
        didAutoClean = true
        await scan(request)
        if selectedEventCount == 0 {
            statusMessage = "Cleaned up on open: no duplicates found."
        } else {
            await removeSelected(onLaunch: true)
        }
    }

    func skipAutoClean(because problem: String) {
        guard !didAutoClean else { return }
        didAutoClean = true
        statusMessage = "Didn't clean up on open: \(problem)"
    }

    private func saveUndo(_ events: [RemovedEvent]) throws {
        if events.isEmpty {
            try? FileManager.default.removeItem(at: Self.undoFile)
            return
        }
        try FileManager.default.createDirectory(
            at: Self.undoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: Self.undoFile, options: .atomic)
    }

    func undoLastRemoval() async {
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        try? await Task.sleep(for: .milliseconds(50))

        var restored = 0
        var missing = 0
        do {
            for saved in lastRemoval {
                guard let calendar = store.calendar(withIdentifier: saved.calendarID),
                      calendar.allowsContentModifications else {
                    missing += 1
                    continue
                }
                try store.save(saved.makeEvent(in: store, calendar: calendar), span: .thisEvent, commit: false)
                restored += 1
            }
            try store.commit()
        } catch {
            store.reset()
            errorMessage = "Nothing was put back: \(error.localizedDescription)"
            isBusy = false
            return
        }
        lastRemoval = []
        try? saveUndo([])
        var status = "Put back \(restored) \(restored == 1 ? "event" : "events")."
        if missing > 0 {
            status += " \(missing) couldn't be put back because their calendar is gone or read-only."
        }
        statusMessage = status
        if let request = lastRequest {
            await scan(request, keepStatus: true)
        } else {
            isBusy = false
        }
    }

    /// The found duplicates as CSV, one row per event and date.
    func csv() -> String {
        let dateTime = DateFormatter()
        dateTime.dateFormat = "yyyy-MM-dd HH:mm"
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"

        func field(_ text: String) -> String {
            // A leading = + - or @ could run as a formula in a spreadsheet.
            var text = text
            if let first = text.first, "=+-@".contains(first) { text = "'" + text }
            if text.contains(where: { ",\"\n\r".contains($0) }) {
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return text
        }

        var lines = ["Selected,Calendar,Title,Start,End,All Day,Reason,Copies to Remove"]
        for finding in findings {
            let format = finding.isAllDay ? dateOnly : dateTime
            lines.append([
                selected.contains(finding.id) ? "Yes" : "No",
                finding.calendarTitle,
                finding.title,
                format.string(from: finding.start),
                format.string(from: finding.end),
                finding.isAllDay ? "Yes" : "No",
                finding.reason,
                String(finding.events.count),
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func scan(_ request: ScanRequest, keepStatus: Bool = false) async {
        isBusy = true
        errorMessage = nil
        if !keepStatus { statusMessage = nil }
        lastRequest = request
        // Lets the progress indicator appear before the work starts.
        try? await Task.sleep(for: .milliseconds(50))
        defer { isBusy = false }

        store.refreshSourcesIfNecessary()
        let today = Calendar.current.startOfDay(for: Date())
        guard let start = Calendar.current.date(byAdding: .day, value: -request.back, to: today),
              let end = Calendar.current.date(byAdding: .day, value: request.ahead, to: today) else {
            errorMessage = "Could not work out the date range."
            return
        }

        func fetch(_ calendar: EKCalendar) -> [EKEvent] {
            store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
        }
        func matchesKeywords(_ event: EKEvent) -> Bool {
            request.keywords.isEmpty || request.keywords.contains { (event.title ?? "").localizedCaseInsensitiveContains($0) }
        }

        let keepCalendar = request.keepOnID.flatMap { id in calendars.first { $0.calendarIdentifier == id } }
        let keepKeys = keepCalendar.map { Set(fetch($0).map(EventKey.init)) } ?? []

        var found: [Finding] = []
        var scanned = 0
        var skipped = 0

        for calendar in calendars where request.calendarIDs.contains(calendar.calendarIdentifier) && calendar.allowsContentModifications {
            var remaining = fetch(calendar).filter(matchesKeywords)
            scanned += remaining.count

            if let keepCalendar, keepCalendar.calendarIdentifier != calendar.calendarIdentifier {
                let shared = remaining.filter { keepKeys.contains(EventKey($0)) }
                skipped += shared.filter(\.hasAttendees).count
                found += makeFindings(
                    shared.filter { !$0.hasAttendees },
                    calendar: calendar,
                    reason: "Also on \(keepCalendar.title)"
                )
                remaining.removeAll { keepKeys.contains(EventKey($0)) && !$0.hasAttendees }
            }

            if request.removeSameCalendar {
                var duplicates: [EKEvent] = []
                for group in Dictionary(grouping: remaining, by: EventKey.init).values where group.count > 1 {
                    skipped += group.filter(\.hasAttendees).count
                    duplicates += eventsToRemove(from: group)
                }
                found += makeFindings(duplicates, calendar: calendar, reason: "Duplicate on this calendar")
            }
        }

        findings = found.sorted {
            ($0.calendarTitle, $0.start, $0.title) < ($1.calendarTitle, $1.start, $1.title)
        }
        selected = Set(findings.map(\.id))
        scannedCount = scanned
        skippedWithAttendees = skipped
        hasScanned = true
    }

    func removeSelected(onLaunch: Bool = false) async {
        guard let request = lastRequest else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        try? await Task.sleep(for: .milliseconds(50))

        let events = findings.filter { selected.contains($0.id) }.flatMap(\.events)
        let snapshot = events.map(RemovedEvent.init)
        // Save the undo copy first, so nothing is removed that can't be put back.
        do {
            try saveUndo(snapshot)
        } catch {
            errorMessage = "Nothing was removed: the undo copy couldn't be saved. \(error.localizedDescription)"
            isBusy = false
            return
        }

        do {
            for event in events {
                try store.remove(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            // Nothing was saved, so drop the pending changes and keep the earlier undo copy.
            store.reset()
            try? saveUndo(lastRemoval)
            errorMessage = "Nothing was removed: \(error.localizedDescription) Scan again and retry."
            isBusy = false
            return
        }
        lastRemoval = snapshot
        let removed = "removed \(events.count) \(events.count == 1 ? "event" : "events")."
        statusMessage = onLaunch ? "Cleaned up on open: \(removed)" : removed.prefix(1).uppercased() + removed.dropFirst()
        await scan(request, keepStatus: true)
    }

    // Prefers a repeating event, then the oldest, so repeat scans make the same choice.
    private func shouldKeepFirst(_ a: EKEvent, _ b: EKEvent) -> Bool {
        if a.hasRecurrenceRules != b.hasRecurrenceRules { return a.hasRecurrenceRules }
        let aCreated = a.creationDate ?? .distantFuture
        let bCreated = b.creationDate ?? .distantFuture
        if aCreated != bCreated { return aCreated < bCreated }
        return a.calendarItemIdentifier < b.calendarItemIdentifier
    }

    private func eventsToRemove(from group: [EKEvent]) -> [EKEvent] {
        let plain = group.filter { !$0.hasAttendees }.sorted(by: shouldKeepFirst)
        // An event with attendees is always kept, so it can stand in as the kept copy.
        return group.contains(where: \.hasAttendees) ? plain : Array(plain.dropFirst())
    }

    private func makeFindings(_ events: [EKEvent], calendar: EKCalendar, reason: String) -> [Finding] {
        Dictionary(grouping: events, by: EventKey.init).map { key, copies in
            Finding(
                title: key.title.isEmpty ? "(No title)" : key.title,
                start: key.start,
                end: key.end,
                isAllDay: key.isAllDay,
                calendarTitle: calendar.title,
                reason: reason,
                events: copies
            )
        }
    }
}

@MainActor
final class UpdateAvailability: ObservableObject {
    @Published var canCheck = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}

struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @StateObject private var availability: UpdateAvailability

    init(updater: SPUUpdater) {
        self.updater = updater
        _availability = StateObject(wrappedValue: UpdateAvailability(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!availability.canCheck)
    }
}

@main
struct CalendarCleanupApp: App {
    @StateObject private var cleaner = Cleaner()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Calendar Cleanup", id: "main") {
            ContentView()
                .environmentObject(cleaner)
                .frame(minWidth: 860, minHeight: 560)
                .task { await cleaner.requestAccess() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var cleaner: Cleaner

    var body: some View {
        switch cleaner.access {
        case .unknown:
            ProgressView("Requesting calendar access…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            ContentUnavailableView {
                Label("Calendar Access Is Off", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Turn on Calendar Cleanup in Privacy & Security, then reopen the app.")
            } actions: {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .granted:
            NavigationSplitView {
                SettingsPane()
                    .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
            } detail: {
                ResultsPane()
            }
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject private var cleaner: Cleaner

    @AppStorage("calendarIDs") private var calendarIDsText = ""
    @AppStorage("keywords") private var keywordsText = ""
    @AppStorage("daysBack") private var daysBack = 90
    @AppStorage("daysAhead") private var daysAhead = 90
    @AppStorage("removeSameCalendar") private var removeSameCalendar = true
    @AppStorage("useKeepCalendar") private var useKeepCalendar = false
    @AppStorage("keepCalendarID") private var keepCalendarID = ""
    @AppStorage("cleanOnLaunch") private var cleanOnLaunch = false
    @State private var newKeyword = ""

    static let dayRange = 0...1460

    private var selectedIDs: Set<String> { Set(calendarIDsText.split(separator: "\n").map(String.init)) }
    private var keywords: [String] { keywordsText.split(separator: "\n").map(String.init) }

    private var problem: String? {
        if selectedIDs.isEmpty { return "Choose at least one calendar." }
        if daysBack < 0 || daysAhead < 0 || daysBack + daysAhead == 0 { return "Choose a date range." }
        if daysBack + daysAhead > Self.dayRange.upperBound {
            return "Days back and ahead can't add up to more than \(Self.dayRange.upperBound.formatted())."
        }
        if !removeSameCalendar && !useKeepCalendar { return "Turn on at least one rule." }
        if useKeepCalendar && keepCalendarID.isEmpty { return "Choose the calendar to keep events on." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Keywords") {
                    TextField("Add a keyword", text: $newKeyword)
                        .onSubmit { addKeyword(newKeyword) }
                    if !keywords.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading) {
                            ForEach(keywords, id: \.self) { keyword in
                                Button {
                                    keywordsText = keywords.filter { $0 != keyword }.joined(separator: "\n")
                                } label: {
                                    Label(keyword, systemImage: "xmark.circle.fill")
                                        .lineLimit(1)
                                }
                                .help("Remove \(keyword)")
                            }
                        }
                    }
                    HStack {
                        ForEach(["Birthday", "Anniversary"].filter { !keywords.contains($0) }, id: \.self) { suggestion in
                            Button("+ \(suggestion)") { addKeyword(suggestion) }
                        }
                    }
                    Text(keywords.isEmpty
                         ? "No keywords: every event is checked."
                         : "Only events with any of these words in the title are checked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Calendars to clean") {
                    ForEach(cleaner.calendars.filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                        Toggle(calendar.title, isOn: calendarBinding(calendar.calendarIdentifier))
                            .toggleStyle(.checkbox)
                    }
                    Text("Read-only calendars aren't listed because their events can't be removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Dates") {
                    Stepper(value: $daysBack, in: Self.dayRange, step: 30) {
                        LabeledContent("Days back") {
                            DayField(title: "Days back", days: $daysBack, range: Self.dayRange)
                        }
                    }
                    Stepper(value: $daysAhead, in: Self.dayRange, step: 30) {
                        LabeledContent("Days ahead") {
                            DayField(title: "Days ahead", days: $daysAhead, range: Self.dayRange)
                        }
                    }
                    Text("Up to \(Self.dayRange.upperBound.formatted()) days in total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("When the app opens") {
                    Toggle("Clean up automatically", isOn: $cleanOnLaunch)
                    Text("Finds duplicates with these settings and removes them without asking. You can undo the last removal.")
                        .font(.caption)
                        .foregroundStyle(cleanOnLaunch ? Color.orange : Color.secondary)
                }

                Section("Rules") {
                    Toggle("Remove duplicates on the same calendar", isOn: $removeSameCalendar)
                    Toggle("Keep shared events on one calendar", isOn: $useKeepCalendar)
                    if useKeepCalendar {
                        Picker("Keep on", selection: $keepCalendarID) {
                            Text("Choose…").tag("")
                            ForEach(cleaner.calendars, id: \.calendarIdentifier) { calendar in
                                Text(calendar.title).tag(calendar.calendarIdentifier)
                            }
                        }
                        Text(keywords.isEmpty
                             ? "With no keywords, this applies to every event shared with that calendar."
                             : "Matching events are removed from the calendars above when that calendar has an identical one.")
                            .font(.caption)
                            .foregroundStyle(keywords.isEmpty ? Color.orange : Color.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(spacing: 6) {
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    Task { await cleaner.scan(makeRequest()) }
                } label: {
                    Text("Find Duplicates").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(problem != nil || cleaner.isBusy)
            }
            .padding(12)
        }
        .task {
            // Values saved by older versions could be out of range.
            if clampDays(daysBack) != daysBack { daysBack = clampDays(daysBack) }
            if clampDays(daysAhead) != daysAhead { daysAhead = clampDays(daysAhead) }
            guard cleanOnLaunch else { return }
            if let problem {
                cleaner.skipAutoClean(because: problem)
            } else {
                await cleaner.autoClean(makeRequest())
            }
        }
    }

    private func clampDays(_ days: Int) -> Int {
        min(max(days, Self.dayRange.lowerBound), Self.dayRange.upperBound)
    }

    private func makeRequest() -> ScanRequest {
        ScanRequest(
            calendarIDs: selectedIDs,
            back: daysBack,
            ahead: daysAhead,
            keywords: keywords,
            removeSameCalendar: removeSameCalendar,
            keepOnID: useKeepCalendar ? keepCalendarID : nil
        )
    }

    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                var ids = selectedIDs
                if isOn { ids.insert(id) } else { ids.remove(id) }
                calendarIDsText = ids.sorted().joined(separator: "\n")
            }
        )
    }

    private func addKeyword(_ text: String) {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        newKeyword = ""
        guard !keyword.isEmpty,
              !keywords.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) else { return }
        keywordsText = (keywords + [keyword]).joined(separator: "\n")
    }
}

/// A number field that accepts only digits and keeps the value within `range` as you type.
struct DayField: View {
    let title: String
    @Binding var days: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(title, text: $text)
            .labelsHidden()
            .frame(width: 60)
            .focused($isFocused)
            .onAppear { text = String(days) }
            .onChange(of: days) { _, newDays in
                if Int(text) != newDays { text = String(newDays) }
            }
            .onChange(of: text) { _, newText in
                let digits = newText.filter(\.isASCII).filter(\.isNumber)
                guard digits == newText else {
                    text = digits
                    return
                }
                guard let value = Int(digits.prefix(9)) else { return }
                let limited = min(max(value, range.lowerBound), range.upperBound)
                if days != limited { days = limited }
                if limited != value || digits.count > 1 && digits.hasPrefix("0") {
                    text = String(limited)
                }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { text = String(days) }
            }
            .onSubmit { text = String(days) }
    }
}

struct ResultsPane: View {
    @EnvironmentObject private var cleaner: Cleaner
    @State private var isConfirming = false
    @State private var isConfirmingUndo = false

    var body: some View {
        VStack(spacing: 0) {
            messages
            if cleaner.isBusy {
                ProgressView("Working…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !cleaner.hasScanned {
                ContentUnavailableView(
                    "Nothing Checked Yet",
                    systemImage: "calendar",
                    description: Text("Choose your settings, then click Find Duplicates. Nothing is removed until you confirm.")
                )
            } else if cleaner.findings.isEmpty {
                ContentUnavailableView(
                    "No Duplicates Found",
                    systemImage: "checkmark.circle",
                    description: Text("Checked \(cleaner.scannedCount) events.")
                )
            } else {
                results
            }
        }
        .navigationTitle("Calendar Cleanup")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !cleaner.lastRemoval.isEmpty {
                    Button("Undo Last Removal (\(cleaner.lastRemoval.count))…") {
                        isConfirmingUndo = true
                    }
                    .help("Puts back the events removed most recently.")
                    .disabled(cleaner.isBusy)
                    .confirmationDialog(
                        "Put back \(cleaner.lastRemoval.count) removed events?",
                        isPresented: $isConfirmingUndo,
                        titleVisibility: .visible
                    ) {
                        Button("Put Back \(cleaner.lastRemoval.count) Events") {
                            Task { await cleaner.undoLastRemoval() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("They're added back to their calendars and sync to everyone who uses them. A removed date of a repeating event comes back as a single event.")
                    }
                }
                Button("Remove \(cleaner.selectedEventCount) Events…", role: .destructive) {
                    isConfirming = true
                }
                .disabled(cleaner.selectedEventCount == 0 || cleaner.isBusy)
            }
        }
        .confirmationDialog(
            "Remove \(cleaner.selectedEventCount) events?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Remove \(cleaner.selectedEventCount) Events", role: .destructive) {
                Task { await cleaner.removeSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes sync to everyone who uses these calendars. You can put them back with Undo Last Removal until your next removal.")
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = cleaner.errorMessage {
            Text(error)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        if let status = cleaner.statusMessage {
            Text(status)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(cleaner.selectedEventCount) of \(cleaner.findings.reduce(0) { $0 + $1.events.count }) copies selected")
                        .font(.headline)
                    if cleaner.skippedWithAttendees > 0 {
                        Text("\(cleaner.skippedWithAttendees) events with attendees will be kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Export CSV…", action: exportCSV)
                Button("Select All") { cleaner.selected = Set(cleaner.findings.map(\.id)) }
                Button("Select None") { cleaner.selected = [] }
            }
            .padding(12)
            Divider()
            List(cleaner.findings) { finding in
                Toggle(isOn: selectionBinding(finding.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).lineLimit(1)
                            Text("\(finding.calendarTitle) · \(finding.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(finding.start, format: finding.isAllDay
                                 ? .dateTime.month(.abbreviated).day().year()
                                 : .dateTime.month(.abbreviated).day().year().hour().minute())
                                .monospacedDigit()
                            Text("\(finding.events.count) to remove")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Calendar Duplicates \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try cleaner.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            cleaner.errorMessage = "The list couldn't be saved: \(error.localizedDescription)"
        }
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { cleaner.selected.contains(id) },
            set: { isOn in
                if isOn { cleaner.selected.insert(id) } else { cleaner.selected.remove(id) }
            }
        )
    }
}
