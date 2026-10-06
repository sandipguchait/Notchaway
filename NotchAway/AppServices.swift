import AppKit
import Carbon.HIToolbox
import Combine
import Security
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let notch = NotchController()
    let settings = IslandSettings()
    let nowPlaying = NowPlayingService()
    let clipboard = ClipboardService()
    let shelf = ShelfService()
    let timer: FocusTimerService
    let keepAwake = KeepAwakeService()
    let notes = NotesService()
    let calendar = CalendarService()
    let stats = SystemStatsService()
    let hud = HUDService()
    let weather = WeatherService()
    let wellness = WellnessService()
    let batteries = DeviceBatteryService()
    let scores = LiveScoresService()
    let captions = LiveCaptionService()
    let replay = DayReplayService()
    let hero: HeroFeaturesService

    private(set) var island: IslandWindowController!
    private(set) var palette: CommandPaletteController!

    private let hotKey = HotKey()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {
        timer = FocusTimerService(settings: settings)
        hero = HeroFeaturesService(timer: timer, notes: notes, captions: captions, shelf: shelf)
        island = IslandWindowController(services: self)
        palette = CommandPaletteController(services: self)
    }

    func start() {
        guard !started else { return }
        started = true

        replay.onOffer = { [weak self] message in
            self?.island.state.showToast(message)
        }

        nowPlaying.start()
        clipboard.start()
        calendar.refresh()
        weather.start()
        wellness.start()
        replay.start()
        hero.start()
        island.start()
        removeFaceUnlockData()

        timer.onEvent = { [weak self] message in
            self?.island.state.showToast(message)
        }
        keepAwake.onEvent = { [weak self] message in
            self?.island.state.showToast(message)
        }
        hero.onEvent = { [weak self] message in
            self?.island.state.showToast(message)
        }
        hud.onChange = { [weak self] event in
            guard let self, self.settings.hudEnabled else { return }
            self.island.state.showHUD(event)
        }

        settings.$hudEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.hud.start() } else { self?.hud.stop() }
            }
            .store(in: &cancellables)

        settings.$clipboardLimit
            .removeDuplicates()
            .sink { [weak self] limit in self?.clipboard.limit = limit }
            .store(in: &cancellables)

        settings.$paletteHotkeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.hotKey.register(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
                        self?.palette.toggle()
                    }
                } else {
                    self.hotKey.unregister()
                }
            }
            .store(in: &cancellables)
    }

    func openIsland(tab: IslandTab? = nil) {
        island.expand(to: tab)
    }

    /// Face Unlock was removed. Drop the login password and face model it stored in the Keychain.
    private func removeFaceUnlockData() {
        let defaults = UserDefaults.standard
        for key in ["faceUnlock.enabled", "faceUnlock.sensitivity", "faceUnlock.graceMinutes", "faceUnlock.requireBlink"] {
            defaults.removeObject(forKey: key)
        }
        for account in ["login-password", "face-model"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.example.NotchAway.FaceUnlock",
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "NotchAway Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().islandEnvironment(self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.shared.start()
    }
}

extension View {
    func islandEnvironment(_ services: AppServices) -> some View {
        self
            .environmentObject(services)
            .environmentObject(services.island.state)
            .environmentObject(services.settings)
            .environmentObject(services.nowPlaying)
            .environmentObject(services.clipboard)
            .environmentObject(services.shelf)
            .environmentObject(services.timer)
            .environmentObject(services.keepAwake)
            .environmentObject(services.notes)
            .environmentObject(services.calendar)
            .environmentObject(services.stats)
            .environmentObject(services.hud)
            .environmentObject(services.notch)
            .environmentObject(services.weather)
            .environmentObject(services.wellness)
            .environmentObject(services.batteries)
            .environmentObject(services.scores)
            .environmentObject(services.captions)
            .environmentObject(services.replay)
            .environmentObject(services.hero)
    }
}
