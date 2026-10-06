import AppKit
import EventKit
import SwiftUI

@MainActor
final class CalendarService: ObservableObject {
    enum Access {
        case unknown, granted, denied
    }

    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: NSColor?

        var timeDescription: String {
            let calendar = Calendar.current
            let day: String
            if calendar.isDateInToday(start) {
                day = "Today"
            } else if calendar.isDateInTomorrow(start) {
                day = "Tomorrow"
            } else {
                day = start.formatted(.dateTime.weekday(.wide))
            }
            if isAllDay { return "\(day) · All day" }
            if start <= Date(), end > Date() { return "Now · until \(Format.time(end))" }
            return "\(day) · \(Format.time(start)) – \(Format.time(end))"
        }
    }

    struct Reminder: Identifiable, Sendable {
        let id: String
        let title: String
        let due: Date?
    }

    @Published private(set) var eventAccess: Access = .unknown
    @Published private(set) var reminderAccess: Access = .unknown
    @Published private(set) var events: [Event] = []
    @Published private(set) var reminders: [Reminder] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var nextEvent: Event? {
        events.first { $0.end > Date() }
    }

    func requestAccess() {
        let completion: @Sendable (Bool, Error?) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: completion)
            store.requestFullAccessToReminders(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
            store.requestAccess(to: .reminder, completion: completion)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        eventAccess = Self.access(for: .event)
        reminderAccess = Self.access(for: .reminder)

        if eventAccess == .granted {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .filter { $0.endDate > Date() }
                .sorted { $0.startDate < $1.startDate }
                .prefix(20)
                .map { event in
                    Event(id: "\(event.eventIdentifier ?? UUID().uuidString)-\(event.startDate.timeIntervalSince1970)",
                          title: event.title ?? "Untitled",
                          start: event.startDate,
                          end: event.endDate,
                          isAllDay: event.isAllDay,
                          color: event.calendar?.color)
                }
        } else {
            events = []
        }

        if reminderAccess == .granted {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] result in
                let items = (result ?? [])
                    .map { reminder in
                        Reminder(id: reminder.calendarItemIdentifier,
                                 title: reminder.title ?? "",
                                 due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                    }
                    .sorted { lhs, rhs in
                        switch (lhs.due, rhs.due) {
                        case let (l?, r?): return l < r
                        case (_?, nil): return true
                        default: return false
                        }
                    }
                let limited = Array(items.prefix(30))
                Task { @MainActor in self?.reminders = limited }
            }
        } else {
            reminders = []
        }
    }

    func addReminder(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, reminderAccess == .granted,
              let calendar = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = calendar
        try? store.save(reminder, commit: true)
        refresh()
    }

    func complete(_ reminder: Reminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }

    private static func access(for type: EKEntityType) -> Access {
        let status = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return .granted }
        } else if status == .authorized {
            return .granted
        }
        return status == .notDetermined ? .unknown : .denied
    }
}

struct CalendarTabView: View {
    @EnvironmentObject private var calendar: CalendarService
    @State private var newReminder = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Upcoming", symbol: "calendar")
                if calendar.eventAccess == .granted {
                    if calendar.events.isEmpty {
                        EmptyStateView(symbol: "calendar.badge.checkmark", title: "Nothing in the next 7 days")
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(calendar.events) { event in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color(nsColor: event.color ?? .systemBlue))
                                            .frame(width: 3, height: 30)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(event.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(event.timeDescription)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(6)
                                    .background(
                                        LuminousCardSurface(
                                            shape: RoundedRectangle(cornerRadius: 11, style: .continuous),
                                            accent: Color(nsColor: event.color ?? .systemBlue)
                                        )
                                    )
                                }
                            }
                        }
                    }
                } else {
                    accessPrompt(for: calendar.eventAccess, what: "calendar events")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.azure)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Reminders", symbol: "checklist")
                if calendar.reminderAccess == .granted {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                        TextField("New reminder", text: $newReminder)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                calendar.addReminder(newReminder)
                                newReminder = ""
                            }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(LuminousCardSurface(shape: Capsule(), accent: LuminousCardTheme.magenta))

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(calendar.reminders) { reminder in
                                HStack(spacing: 8) {
                                    Button {
                                        calendar.complete(reminder)
                                    } label: {
                                        Image(systemName: "circle")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(reminder.title)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        if let due = reminder.due {
                                            Text(due.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 10))
                                                .foregroundStyle(due < Date() ? .red : .secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(6)
                            }
                        }
                    }
                } else {
                    accessPrompt(for: calendar.reminderAccess, what: "reminders")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.violet)
        }
        .onAppear { calendar.refresh() }
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
    }

    @ViewBuilder
    private func accessPrompt(for access: CalendarService.Access, what: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(access == .denied
                 ? "NotchAway doesn't have access to your \(what). Turn it on in System Settings → Privacy & Security."
                 : "Show your \(what) in the notch.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if access == .denied {
                PillButton(title: "Open Privacy Settings", symbol: "lock") { calendar.openPrivacySettings() }
            } else {
                PillButton(title: "Grant Access", symbol: "checkmark", prominent: true) { calendar.requestAccess() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
