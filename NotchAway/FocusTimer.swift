import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class FocusTimerService: ObservableObject {
    enum Mode: String {
        case focus, rest, countdown, stopwatch

        var title: String {
            switch self {
            case .focus: return "Focus"
            case .rest: return "Break"
            case .countdown: return "Timer"
            case .stopwatch: return "Stopwatch"
            }
        }
    }

    @Published private(set) var mode: Mode?
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var stopwatchStart: Date?
    @Published private(set) var stopwatchAccumulated: TimeInterval = 0
    @Published private(set) var history: [String: Int]
    @Published private(set) var breakHistory: [String: Int]

    var onEvent: ((String) -> Void)?

    private let settings: IslandSettings
    private var ticker: Timer?
    private var askedForNotifications = false
    private static let historyKey = "timer.focusHistory"
    private static let breakHistoryKey = "timer.breakHistory"

    init(settings: IslandSettings) {
        self.settings = settings
        history = UserDefaults.standard.dictionary(forKey: Self.historyKey) as? [String: Int] ?? [:]
        breakHistory = UserDefaults.standard.dictionary(forKey: Self.breakHistoryKey) as? [String: Int] ?? [:]
    }

    var breaksToday: Int { breakHistory[Self.dayKey(Date())] ?? 0 }

    var isActive: Bool { mode != nil }
    var isRunning: Bool { endDate != nil || stopwatchStart != nil }
    var isPomodoro: Bool { mode == .focus || mode == .rest }
    var todayCount: Int { history[Self.dayKey(Date())] ?? 0 }

    var symbol: String {
        switch mode {
        case .focus: return "brain.head.profile"
        case .rest: return "cup.and.saucer.fill"
        case .stopwatch: return "stopwatch"
        default: return "timer"
        }
    }

    var tint: Color {
        switch mode {
        case .focus: return .orange
        case .rest: return .green
        case .stopwatch: return .cyan
        default: return .yellow
        }
    }

    func remaining(at now: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? 0
    }

    func elapsed(at now: Date) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    func progress(at now: Date) -> Double {
        guard let mode else { return 0 }
        if mode == .stopwatch {
            return elapsed(at: now).truncatingRemainder(dividingBy: 60) / 60
        }
        guard totalDuration > 0 else { return 0 }
        return 1 - remaining(at: now) / totalDuration
    }

    func displayText(at now: Date) -> String {
        guard let mode else { return Format.clock(TimeInterval(settings.focusMinutes * 60)) }
        if mode == .stopwatch { return Format.clock(elapsed(at: now)) }
        return Format.clock(remaining(at: now).rounded(.up))
    }

    func lastSevenDays() -> [(label: String, count: Int)] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return (formatter.string(from: day), history[Self.dayKey(day)] ?? 0)
        }
    }

    func focusStreak(goal: Int) -> Int { Self.streak(in: history, goal: goal) }
    func breakStreak(goal: Int) -> Int { Self.streak(in: breakHistory, goal: goal) }

    // MARK: Controls

    func startFocus() { startCountdown(.focus, minutes: settings.focusMinutes) }
    func startBreak() { startCountdown(.rest, minutes: settings.breakMinutes) }
    func startTimer(minutes: Int) { startCountdown(.countdown, minutes: minutes) }

    func startStopwatch() {
        reset()
        mode = .stopwatch
        stopwatchStart = Date()
    }

    func pause() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            stopTicker()
        } else if let start = stopwatchStart {
            stopwatchAccumulated += Date().timeIntervalSince(start)
            stopwatchStart = nil
        }
    }

    func resume() {
        if let remaining = pausedRemaining {
            endDate = Date().addingTimeInterval(remaining)
            pausedRemaining = nil
            startTicker()
        } else if mode == .stopwatch, stopwatchStart == nil {
            stopwatchStart = Date()
        }
    }

    func stop() { reset() }

    /// Returns the timer to its configured idle duration from any running or paused state.
    func resetTimer() { reset() }

    func skip() { complete(skipped: true) }

    // MARK: Internals

    private func startCountdown(_ newMode: Mode, minutes: Int) {
        reset()
        requestNotificationPermission()
        mode = newMode
        totalDuration = TimeInterval(max(1, minutes) * 60)
        endDate = Date().addingTimeInterval(totalDuration)
        startTicker()
    }

    private func reset() {
        stopTicker()
        mode = nil
        endDate = nil
        pausedRemaining = nil
        totalDuration = 0
        stopwatchStart = nil
        stopwatchAccumulated = 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let endDate, endDate <= Date() else { return }
        complete(skipped: false)
    }

    private func complete(skipped: Bool) {
        let finished = mode
        if finished == .focus, !skipped {
            let key = Self.dayKey(Date())
            history[key, default: 0] += 1
            UserDefaults.standard.set(history, forKey: Self.historyKey)
        }
        if finished == .rest, !skipped {
            breakHistory[Self.dayKey(Date()), default: 0] += 1
            UserDefaults.standard.set(breakHistory, forKey: Self.breakHistoryKey)
        }
        if !skipped { announce(finished) }

        let chain = settings.autoChainSessions || skipped
        switch finished {
        case .focus: chain ? startBreak() : reset()
        case .rest: chain ? startFocus() : reset()
        default: reset()
        }
    }

    private func announce(_ finished: Mode?) {
        let message: String
        switch finished {
        case .focus: message = "Focus session complete — time for a break"
        case .rest: message = "Break over — back to focus"
        default: message = "Timer finished"
        }
        NSSound(named: "Glass")?.play()
        onEvent?(message)

        let content = UNMutableNotificationContent()
        content.title = "NotchAway"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func requestNotificationPermission() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func streak(in history: [String: Int], goal: Int) -> Int {
        let calendar = Calendar.current
        var day = Date()
        if history[dayKey(day), default: 0] < max(1, goal) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var result = 0
        while history[dayKey(day), default: 0] >= max(1, goal) {
            result += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return result
    }
}

struct TimerTabView: View {
    @EnvironmentObject private var timer: FocusTimerService
    @EnvironmentObject private var settings: IslandSettings
    @EnvironmentObject private var keepAwake: KeepAwakeService

    var body: some View {
        HStack(spacing: 22) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: CGFloat(timer.progress(at: context.date)))
                        .stroke(timer.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: timer.progress(at: context.date))
                    VStack(spacing: 2) {
                        Text(timer.displayText(at: context.date))
                            .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(timer.mode?.title ?? "Ready")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 128, height: 128)
            .padding(13)
            .cardBackground(cornerRadius: 20, tint: timer.tint)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if !timer.isActive {
                        PillButton(title: "Start Focus", symbol: "play.fill", prominent: true) { timer.startFocus() }
                    } else {
                        if timer.isRunning {
                            PillButton(title: "Pause", symbol: "pause.fill", prominent: true) { timer.pause() }
                        } else {
                            PillButton(title: "Resume", symbol: "play.fill", prominent: true) { timer.resume() }
                        }
                        if timer.isPomodoro {
                            PillButton(title: "Skip", symbol: "forward.end.fill") { timer.skip() }
                        }
                        PillButton(title: "Stop", symbol: "stop.fill") { timer.stop() }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("PRESETS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        PillButton(title: "Focus \(settings.focusMinutes)m") { timer.startFocus() }
                        PillButton(title: "Break \(settings.breakMinutes)m") { timer.startBreak() }
                        PillButton(title: "Stopwatch", symbol: "stopwatch") { timer.startStopwatch() }
                    }
                    HStack(spacing: 6) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                            PillButton(title: "\(minutes)m") { timer.startTimer(minutes: minutes) }
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(timer.todayCount)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("sessions today")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    WeekChart(days: timer.lastSevenDays())
                        .frame(width: 150, height: 44)
                    Spacer()
                    Menu {
                        Button("Indefinitely") { keepAwake.activate(for: nil) }
                        Button("30 minutes") { keepAwake.activate(for: 30 * 60) }
                        Button("1 hour") { keepAwake.activate(for: 3600) }
                        Button("2 hours") { keepAwake.activate(for: 7200) }
                        Button("4 hours") { keepAwake.activate(for: 14400) }
                        if keepAwake.isActive {
                            Divider()
                            Button("Turn Off") { keepAwake.deactivate() }
                        }
                    } label: {
                        Label(keepAwake.isActive ? keepAwake.statusText : "Keep Awake", systemImage: "cup.and.saucer.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .cardBackground(cornerRadius: 20, tint: LuminousCardTheme.violet)
        }
    }
}

struct WeekChart: View {
    let days: [(label: String, count: Int)]

    var body: some View {
        let maximum = max(1, days.map(\.count).max() ?? 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == days.count - 1 ? Color.orange : Color.white.opacity(0.3))
                        .frame(height: max(3, CGFloat(day.count) / CGFloat(maximum) * 28))
                    Text(day.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
    }
}
