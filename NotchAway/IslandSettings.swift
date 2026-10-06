import Foundation

enum IslandTab: String, CaseIterable, Identifiable, Codable {
    case home, context, live, replay, clipboard, shelf, timer, notes, calendar, stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .context: return "Context"
        case .live: return "Live"
        case .replay: return "Replay"
        case .clipboard: return "Clipboard"
        case .shelf: return "Shelf"
        case .timer: return "Timer"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .stats: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .context: return "sparkles.rectangle.stack.fill"
        case .live: return "square.grid.2x2.fill"
        case .replay: return "clock.arrow.circlepath"
        case .clipboard: return "doc.on.clipboard.fill"
        case .shelf: return "tray.full.fill"
        case .timer: return "timer"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .stats: return "cpu"
        }
    }
}

@MainActor
final class IslandSettings: ObservableObject {
    private enum Key {
        static let islandEnabled = "island.enabled"
        static let hoverToOpen = "island.hoverToOpen"
        static let hudEnabled = "island.hudEnabled"
        static let hideFromCapture = "island.hideFromCapture"
        static let pillWithoutNotch = "island.pillWithoutNotch"
        static let enabledTabs = "island.enabledTabs"
        static let focusMinutes = "timer.focusMinutes"
        static let breakMinutes = "timer.breakMinutes"
        static let autoChain = "timer.autoChain"
        static let clipboardLimit = "clipboard.limit"
        static let paletteHotkey = "palette.hotkeyEnabled"
        static let liveTabSeen = "island.liveTabSeen"
        static let contextTabSeen = "island.contextTabSeen"
        static let replayTabSeen = "island.replayTabSeen"
        static let glassTransparency = "island.glassTransparency"
    }

    private let defaults = UserDefaults.standard

    @Published var islandEnabled: Bool { didSet { defaults.set(islandEnabled, forKey: Key.islandEnabled) } }
    @Published var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: Key.hoverToOpen) } }
    @Published var hudEnabled: Bool { didSet { defaults.set(hudEnabled, forKey: Key.hudEnabled) } }
    @Published var hideFromScreenCapture: Bool { didSet { defaults.set(hideFromScreenCapture, forKey: Key.hideFromCapture) } }
    @Published var showPillWithoutNotch: Bool { didSet { defaults.set(showPillWithoutNotch, forKey: Key.pillWithoutNotch) } }
    @Published var enabledTabs: Set<IslandTab> {
        didSet { defaults.set(enabledTabs.map(\.rawValue), forKey: Key.enabledTabs) }
    }
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: Key.focusMinutes) } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: Key.breakMinutes) } }
    @Published var autoChainSessions: Bool { didSet { defaults.set(autoChainSessions, forKey: Key.autoChain) } }
    @Published var clipboardLimit: Int { didSet { defaults.set(clipboardLimit, forKey: Key.clipboardLimit) } }
    @Published var paletteHotkeyEnabled: Bool { didSet { defaults.set(paletteHotkeyEnabled, forKey: Key.paletteHotkey) } }
    /// User-facing amount of background visibility through the glass, from 0...1.
    @Published var glassTransparency: Double {
        didSet { defaults.set(min(max(glassTransparency, 0), 1), forKey: Key.glassTransparency) }
    }

    init() {
        let d = UserDefaults.standard
        islandEnabled = d.object(forKey: Key.islandEnabled) as? Bool ?? true
        hoverToOpen = d.object(forKey: Key.hoverToOpen) as? Bool ?? true
        hudEnabled = d.object(forKey: Key.hudEnabled) as? Bool ?? true
        hideFromScreenCapture = d.object(forKey: Key.hideFromCapture) as? Bool ?? false
        showPillWithoutNotch = d.object(forKey: Key.pillWithoutNotch) as? Bool ?? true
        if let stored = d.stringArray(forKey: Key.enabledTabs) {
            var tabs = Set(stored.compactMap(IslandTab.init(rawValue:)))
            if d.object(forKey: Key.liveTabSeen) == nil { tabs.insert(.live) }
            if d.object(forKey: Key.contextTabSeen) == nil { tabs.insert(.context) }
            if d.object(forKey: Key.replayTabSeen) == nil { tabs.insert(.replay) }
            enabledTabs = tabs
        } else {
            enabledTabs = Set(IslandTab.allCases)
        }
        focusMinutes = d.object(forKey: Key.focusMinutes) as? Int ?? 25
        breakMinutes = d.object(forKey: Key.breakMinutes) as? Int ?? 5
        autoChainSessions = d.object(forKey: Key.autoChain) as? Bool ?? true
        clipboardLimit = d.object(forKey: Key.clipboardLimit) as? Int ?? 60
        paletteHotkeyEnabled = d.object(forKey: Key.paletteHotkey) as? Bool ?? true
        glassTransparency = min(max(d.object(forKey: Key.glassTransparency) as? Double ?? 0.48, 0), 1)
        d.set(true, forKey: Key.liveTabSeen)
        d.set(true, forKey: Key.contextTabSeen)
        d.set(true, forKey: Key.replayTabSeen)
    }

    var visibleTabs: [IslandTab] {
        IslandTab.allCases.filter { $0 == .home || enabledTabs.contains($0) }
    }

    func isTabEnabled(_ tab: IslandTab) -> Bool {
        tab == .home || enabledTabs.contains(tab)
    }

    func setTab(_ tab: IslandTab, enabled: Bool) {
        if enabled { enabledTabs.insert(tab) } else { enabledTabs.remove(tab) }
    }
}
