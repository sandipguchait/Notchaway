import AppKit
import CoreGraphics
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Builds a private daily activity recap from frontmost-app time. Nothing leaves this Mac.
@MainActor
final class DayReplayService: ObservableObject {
    struct AppUsage: Codable, Identifiable, Equatable {
        var bundleID: String
        var name: String
        var seconds: TimeInterval

        var id: String { bundleID.isEmpty ? name : bundleID }
        var category: Category { Category.classify(bundleID: bundleID, name: name) }
    }

    enum Category: String, CaseIterable, Identifiable {
        case communication = "Communication"
        case development = "Development"
        case browsing = "Browsing"
        case creative = "Creative"
        case productivity = "Productivity"
        case other = "Other"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .communication: return "bubble.left.and.bubble.right.fill"
            case .development: return "hammer.fill"
            case .browsing: return "globe"
            case .creative: return "paintbrush.fill"
            case .productivity: return "checkmark.circle.fill"
            case .other: return "square.grid.2x2.fill"
            }
        }

        var tint: Color {
            switch self {
            case .communication: return .green
            case .development: return .blue
            case .browsing: return .cyan
            case .creative: return .purple
            case .productivity: return .orange
            case .other: return .gray
            }
        }

        static func classify(bundleID: String, name: String) -> Category {
            let value = "\(bundleID) \(name)".lowercased()
            if ["zoom", "teams", "slack", "discord", "facetime", "webex", "whatsapp", "telegram"].contains(where: value.contains) {
                return .communication
            }
            if ["xcode", "terminal", "iterm", "visual studio", "vscode", "cursor", "github", "jetbrains"].contains(where: value.contains) {
                return .development
            }
            if ["safari", "chrome", "firefox", "arc", "edge", "brave"].contains(where: value.contains) {
                return .browsing
            }
            if ["figma", "photoshop", "illustrator", "sketch", "final cut", "logic", "premiere"].contains(where: value.contains) {
                return .creative
            }
            if ["notion", "notes", "calendar", "reminders", "mail", "word", "excel", "pages", "numbers"].contains(where: value.contains) {
                return .productivity
            }
            return .other
        }
    }

    private struct StoredDay: Codable {
        var day: String
        var apps: [AppUsage]
        var summary: String
    }

    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var summary = "Use your Mac for a while and your private day replay will appear here."
    @Published private(set) var isGenerating = false
    @Published private(set) var hasUnseenReplay = false
    @Published private(set) var isSpeaking = false
    @Published var offerHour: Int {
        didSet { defaults.set(offerHour, forKey: Key.offerHour); evaluateEveningOffer() }
    }

    var onOffer: ((String) -> Void)?

    var activeSeconds: TimeInterval { apps.reduce(0) { $0 + $1.seconds } }
    var topApps: [AppUsage] { Array(apps.sorted { $0.seconds > $1.seconds }.prefix(5)) }

    var categoryTotals: [(category: Category, seconds: TimeInterval)] {
        Category.allCases.compactMap { category in
            let seconds = apps.filter { $0.category == category }.reduce(0) { $0 + $1.seconds }
            return seconds > 0 ? (category, seconds) : nil
        }
        .sorted { $0.seconds > $1.seconds }
    }

    private enum Key {
        static let storedDay = "dayReplay.currentDay"
        static let offerHour = "dayReplay.offerHour"
        static let lastOfferedDay = "dayReplay.lastOfferedDay"
        static let unseenDay = "dayReplay.unseenDay"
    }

    private let defaults = UserDefaults.standard
    private let speaker = NSSpeechSynthesizer()
    private var usageByID: [String: AppUsage] = [:]
    private var currentApp: (bundleID: String, name: String)?
    private var lastSampleDate = Date()
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var generatedWithAI = false

    init() {
        offerHour = min(max(UserDefaults.standard.object(forKey: Key.offerHour) as? Int ?? 18, 0), 23)
        loadToday()
        hasUnseenReplay = defaults.string(forKey: Key.unseenDay) == Self.dayKey(Date())
    }

    func start() {
        guard timer == nil else { return }
        updateCurrentApp(NSWorkspace.shared.frontmostApplication)
        lastSampleDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                self.recordElapsed()
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.updateCurrentApp(app)
            }
        }
        sample()
    }

    func refreshReplay() {
        recordElapsed()
        updatePublishedApps()
        summary = deterministicSummary()
        generatedWithAI = false
        persist()
        generateLocalAISummaryIfAvailable()
    }

    func markSeen() {
        hasUnseenReplay = false
        if defaults.string(forKey: Key.unseenDay) == Self.dayKey(Date()) {
            defaults.removeObject(forKey: Key.unseenDay)
        }
    }

    func speakBriefing() {
        if speaker.isSpeaking {
            speaker.stopSpeaking()
            isSpeaking = false
            return
        }
        guard !summary.isEmpty else { return }
        speaker.rate = 205
        speaker.startSpeaking(summary)
        isSpeaking = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self else { return }
            if !self.speaker.isSpeaking { self.isSpeaking = false }
        }
    }

    func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    private func sample() {
        rollOverIfNeeded()
        recordElapsed()
        updatePublishedApps()
        if !generatedWithAI { summary = deterministicSummary() }
        persist()
        evaluateEveningOffer()
    }

    private func recordElapsed() {
        let now = Date()
        let elapsed = min(max(now.timeIntervalSince(lastSampleDate), 0), 60)
        lastSampleDate = now
        guard elapsed > 0,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                      eventType: CGEventType(rawValue: ~0)!) < 120,
              let currentApp,
              currentApp.bundleID != Bundle.main.bundleIdentifier
        else { return }

        let id = currentApp.bundleID.isEmpty ? currentApp.name : currentApp.bundleID
        var usage = usageByID[id] ?? AppUsage(bundleID: currentApp.bundleID, name: currentApp.name, seconds: 0)
        usage.seconds += elapsed
        usageByID[id] = usage
    }

    private func updateCurrentApp(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular else {
            currentApp = nil
            return
        }
        currentApp = (app.bundleIdentifier ?? "", app.localizedName ?? "Unknown App")
    }

    private func updatePublishedApps() {
        apps = usageByID.values.sorted { $0.seconds > $1.seconds }
    }

    private func evaluateEveningOffer() {
        let now = Date()
        let day = Self.dayKey(now)
        guard Calendar.current.component(.hour, from: now) >= offerHour,
              activeSeconds >= 10 * 60,
              defaults.string(forKey: Key.lastOfferedDay) != day
        else { return }

        defaults.set(day, forKey: Key.lastOfferedDay)
        defaults.set(day, forKey: Key.unseenDay)
        hasUnseenReplay = true
        refreshReplay()
        onOffer?("Day Replay is ready — your private briefing is in the notch")
    }

    private func deterministicSummary() -> String {
        guard let first = topApps.first else {
            return "Use your Mac for a while and your private day replay will appear here."
        }
        let second = topApps.dropFirst().first
        let leadCategory = categoryTotals.first?.category.rawValue.lowercased() ?? "active work"
        var text = "You logged \(durationText(activeSeconds)) of active time, led by \(first.name) for \(durationText(first.seconds))."
        if let second { text += " \(second.name) followed at \(durationText(second.seconds))." }
        text += " Most of the day went to \(leadCategory)."
        return text
    }

    private func generateLocalAISummaryIfAvailable() {
        let snapshot = topApps
        guard !snapshot.isEmpty else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            isGenerating = true
            let facts = snapshot.map { "\($0.name): \(durationText($0.seconds)); category: \($0.category.rawValue)" }
                .joined(separator: "\n")
            Task {
                do {
                    let session = LanguageModelSession(instructions: "Summarize only the supplied local activity facts. Never invent activity. Use no more than 35 words and plain text.")
                    let response = try await session.respond(to: "Write a calm 10-second end-of-day briefing:\n\(facts)")
                    let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty {
                        summary = result
                        generatedWithAI = true
                        persist()
                    }
                } catch {
                    // The deterministic local summary remains available when Apple Intelligence isn't ready.
                }
                isGenerating = false
            }
        }
        #endif
    }

    private func rollOverIfNeeded() {
        let day = Self.dayKey(Date())
        guard let stored = loadStoredDay(), stored.day != day else { return }
        usageByID = [:]
        apps = []
        summary = "Use your Mac for a while and your private day replay will appear here."
        generatedWithAI = false
        hasUnseenReplay = false
        defaults.removeObject(forKey: Key.unseenDay)
        persist()
    }

    private func loadToday() {
        guard let stored = loadStoredDay(), stored.day == Self.dayKey(Date()) else { return }
        usageByID = Dictionary(uniqueKeysWithValues: stored.apps.map { ($0.id, $0) })
        apps = stored.apps.sorted { $0.seconds > $1.seconds }
        summary = stored.summary.isEmpty ? deterministicSummary() : stored.summary
    }

    private func loadStoredDay() -> StoredDay? {
        guard let data = defaults.data(forKey: Key.storedDay) else { return nil }
        return try? JSONDecoder().decode(StoredDay.self, from: data)
    }

    private func persist() {
        let stored = StoredDay(day: Self.dayKey(Date()), apps: apps, summary: summary)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Key.storedDay) }
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

struct DayReplayView: View {
    @EnvironmentObject private var replay: DayReplayService

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: LuminousCardTheme.violet) {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: "Day Replay", symbol: "clock.arrow.circlepath", tint: .purple,
                               trailing: replay.isGenerating ? "SUMMARIZING" : "ON DEVICE")
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        BigNumber(text: replay.durationText(replay.activeSeconds), size: 30)
                        Text("active today")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(replay.summary)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    HStack(spacing: 6) {
                        PillButton(title: replay.isSpeaking ? "Stop" : "Play briefing",
                                   symbol: replay.isSpeaking ? "stop.fill" : "speaker.wave.2.fill",
                                   prominent: true) {
                            replay.speakBriefing()
                        }
                        PillButton(title: "Refresh", symbol: "arrow.clockwise") { replay.refreshReplay() }
                    }
                }
            }

            LiveCard {
                VStack(alignment: .leading, spacing: 7) {
                    CardHeader(title: "Where time went", symbol: "chart.bar.fill", tint: .cyan,
                               trailing: replay.topApps.isEmpty ? nil : "TOP \(replay.topApps.count)")
                    if replay.topApps.isEmpty {
                        EmptyStateView(symbol: "hourglass", title: "No activity recorded yet",
                                       subtitle: "Replay counts only active frontmost-app time.")
                    } else {
                        let maximum = max(replay.topApps.first?.seconds ?? 1, 1)
                        ForEach(replay.topApps) { app in
                            HStack(spacing: 8) {
                                Image(systemName: app.category.symbol)
                                    .foregroundStyle(app.category.tint)
                                    .frame(width: 17)
                                Text(app.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                    .frame(width: 95, alignment: .leading)
                                LevelBar(value: app.seconds / maximum, tint: app.category.tint)
                                    .frame(height: 5)
                                Text(replay.durationText(app.seconds))
                                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("Stored locally · idle time is excluded")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            replay.markSeen()
            replay.refreshReplay()
        }
    }
}
