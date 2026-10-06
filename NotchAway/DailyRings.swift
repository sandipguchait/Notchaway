import CoreGraphics
import SwiftUI

/// Daily wellness counters shown as Activity-style rings: water, Mac screen time, plus focus and
/// break counts that come from the focus timer.
@MainActor
final class WellnessService: ObservableObject {
    @Published private(set) var glasses = 0
    @Published private(set) var activeMinutes = 0
    @Published private(set) var waterHistory: [String: Int]
    @Published var waterGoal: Int { didSet { UserDefaults.standard.set(waterGoal, forKey: Key.waterGoal) } }
    @Published var focusGoal: Int { didSet { UserDefaults.standard.set(focusGoal, forKey: Key.focusGoal) } }

    private enum Key {
        static let day = "wellness.day"
        static let glasses = "wellness.glasses"
        static let active = "wellness.activeMinutes"
        static let waterGoal = "wellness.waterGoal"
        static let focusGoal = "wellness.focusGoal"
        static let waterHistory = "wellness.waterHistory"
    }

    static let glassLiters = 0.25
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        waterGoal = defaults.object(forKey: Key.waterGoal) as? Int ?? 8
        focusGoal = defaults.object(forKey: Key.focusGoal) as? Int ?? 4
        waterHistory = defaults.dictionary(forKey: Key.waterHistory) as? [String: Int] ?? [:]
        if defaults.string(forKey: Key.day) == Self.today {
            glasses = defaults.integer(forKey: Key.glasses)
            activeMinutes = defaults.integer(forKey: Key.active)
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleActivity() }
        }
    }

    func addGlass() {
        rollOverIfNeeded()
        glasses += 1
        save()
    }

    func removeGlass() {
        rollOverIfNeeded()
        glasses = max(0, glasses - 1)
        save()
    }

    var waterLiters: Double { Double(glasses) * Self.glassLiters }
    var screenHours: Double { Double(activeMinutes) / 60 }
    var waterStreak: Int { streak(in: waterHistory, goal: waterGoal) }

    private func sampleActivity() {
        rollOverIfNeeded()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < 60 {
            activeMinutes += 1
            save()
        }
    }

    private func rollOverIfNeeded() {
        guard UserDefaults.standard.string(forKey: Key.day) != Self.today else { return }
        glasses = 0
        activeMinutes = 0
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(Self.today, forKey: Key.day)
        defaults.set(glasses, forKey: Key.glasses)
        defaults.set(activeMinutes, forKey: Key.active)
        waterHistory[Self.today] = glasses
        defaults.set(waterHistory, forKey: Key.waterHistory)
    }

    private func streak(in history: [String: Int], goal: Int) -> Int {
        let calendar = Calendar.current
        var day = Date()
        if history[Self.dayKey(day), default: 0] < max(1, goal) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var count = 0
        while history[Self.dayKey(day), default: 0] >= max(1, goal) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    private static var today: String {
        dayKey(Date())
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

struct RingsCard: View {
    @EnvironmentObject private var wellness: WellnessService
    @EnvironmentObject private var timer: FocusTimerService

    var body: some View {
        LiveCard(glow: LuminousCardTheme.emerald) {
            HStack(alignment: .center) {
                let focus = timer.todayCount
                streakRing(streak: timer.focusStreak(goal: wellness.focusGoal)) {
                    RingGauge(progress: Double(focus) / Double(max(wellness.focusGoal, 1)), tint: .orange,
                              symbol: "brain.head.profile",
                              label: focus >= wellness.focusGoal ? "DONE" : "\(focus)/\(wellness.focusGoal)",
                              size: 29, lineWidth: 4)
                }
                Spacer(minLength: 0)
                streakRing(streak: wellness.waterStreak) {
                    RingGauge(progress: Double(wellness.glasses) / Double(max(wellness.waterGoal, 1)), tint: .blue,
                              symbol: "drop.fill", label: String(format: "%.2gL", wellness.waterLiters),
                              size: 29, lineWidth: 4)
                        .onTapGesture { wellness.addGlass() }
                        .contextMenu {
                            Button("Add a Glass") { wellness.addGlass() }
                            Button("Remove a Glass") { wellness.removeGlass() }
                        }
                        .help("Click to log a glass of water")
                }
                Spacer(minLength: 0)
                streakRing(streak: timer.breakStreak(goal: wellness.focusGoal)) {
                    RingGauge(progress: Double(timer.breaksToday) / Double(max(wellness.focusGoal, 1)), tint: .green,
                              symbol: "figure.walk",
                              label: timer.breaksToday >= wellness.focusGoal ? "DONE" : "\(timer.breaksToday) BRK",
                              size: 29, lineWidth: 4)
                }
                Spacer(minLength: 0)
                RingGauge(progress: wellness.screenHours / 8, tint: .pink,
                          symbol: "desktopcomputer",
                          label: String(format: "%.1fh", wellness.screenHours),
                          size: 29, lineWidth: 4)
            }
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
        }
    }

    private func streakRing<Content: View>(streak: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 1) {
            Text("🔥\(streak)")
                .font(.system(size: 8, weight: .bold).monospacedDigit())
                .foregroundStyle(streak > 0 ? Color.orange : Color.secondary)
            content()
        }
    }
}
