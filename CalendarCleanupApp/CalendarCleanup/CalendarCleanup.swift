// Calendar Cleanup: finds duplicate events by title, start, end and all-day status,
// shows them for review, and removes only what you confirm.
//
// Only single occurrences are removed, never a whole repeating series.
// Events with attendees are never removed, because that can notify other people.

import EventKit
import Sparkle
import SwiftUI

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
    let isAllDay: Bool
    let calendarTitle: String
    let reason: String
    let events: [EKEvent]
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

    private let store = EKEventStore()
    private var lastRequest: ScanRequest?

    var selectedEventCount: Int {
        findings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.events.count }
    }

    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : .denied
        if granted {
            calendars = store.calendars(for: .event).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
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

    func removeSelected() async {
        guard let request = lastRequest else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        try? await Task.sleep(for: .milliseconds(50))

        var removed = 0
        do {
            for finding in findings where selected.contains(finding.id) {
                for event in finding.events {
                    try store.remove(event, span: .thisEvent, commit: false)
                    removed += 1
                }
            }
            try store.commit()
        } catch {
            // Nothing was saved, so drop the pending changes.
            store.reset()
            errorMessage = "Nothing was removed: \(error.localizedDescription) Scan again and retry."
            isBusy = false
            return
        }
        statusMessage = "Removed \(removed) \(removed == 1 ? "event" : "events")."
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
    @State private var newKeyword = ""

    private var selectedIDs: Set<String> { Set(calendarIDsText.split(separator: "\n").map(String.init)) }
    private var keywords: [String] { keywordsText.split(separator: "\n").map(String.init) }

    private var problem: String? {
        if selectedIDs.isEmpty { return "Choose at least one calendar." }
        if daysBack < 0 || daysAhead < 0 || daysBack + daysAhead == 0 { return "Choose a date range." }
        if daysBack + daysAhead > 1460 { return "The date range can't be longer than 1,460 days." }
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
                    Stepper(value: $daysBack, in: 0...1460, step: 30) {
                        LabeledContent("Days back") {
                            TextField("Days back", value: $daysBack, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                        }
                    }
                    Stepper(value: $daysAhead, in: 0...1460, step: 30) {
                        LabeledContent("Days ahead") {
                            TextField("Days ahead", value: $daysAhead, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                        }
                    }
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

struct ResultsPane: View {
    @EnvironmentObject private var cleaner: Cleaner
    @State private var isConfirming = false

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
            ToolbarItem(placement: .primaryAction) {
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
            Text("This can't be undone. Changes sync to everyone who uses these calendars.")
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

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { cleaner.selected.contains(id) },
            set: { isOn in
                if isOn { cleaner.selected.insert(id) } else { cleaner.selected.remove(id) }
            }
        )
    }
}
