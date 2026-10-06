import AppKit
import Combine
import CoreGraphics
import ServiceManagement

@MainActor
final class NotchController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                Task { await apply() }
            } else {
                restore()
            }
        }
    }

    @Published var useAutomaticHeight: Bool {
        didSet {
            UserDefaults.standard.set(useAutomaticHeight, forKey: Keys.autoHeight)
            if isEnabled { Task { await apply() } }
        }
    }

    @Published var manualBarHeight: Double {
        didSet {
            UserDefaults.standard.set(manualBarHeight, forKey: Keys.manualHeight)
        }
    }

    @Published var barStyle: TopBarStyle {
        didSet {
            UserDefaults.standard.set(barStyle.rawValue, forKey: Keys.barStyle)
            if isEnabled { Task { await apply() } }
        }
    }

    @Published var launchAtLogin = false
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var isBusy = false
    @Published private(set) var notchDetected = false
    @Published private(set) var detectedHeight: CGFloat = 0

    private let processor = WallpaperProcessor()

    private enum Keys {
        static let enabled = "notchAway.enabled"
        static let autoHeight = "notchAway.autoHeight"
        static let manualHeight = "notchAway.manualHeight"
        static let barStyle = "notchAway.barStyle"
    }

    init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        self.useAutomaticHeight = defaults.object(forKey: Keys.autoHeight) as? Bool ?? true
        self.manualBarHeight = defaults.object(forKey: Keys.manualHeight) as? Double ?? 38
        self.barStyle = defaults.string(forKey: Keys.barStyle).flatMap(TopBarStyle.init(rawValue:)) ?? .matchWallpaper

        refreshDisplayInfo()
        refreshLoginItemState()

        if isEnabled {
            Task { await apply() }
        }
    }

    func refreshDisplayInfo() {
        guard let screen = NSScreen.screens.first(where: { $0.isBuiltIn }) ?? NSScreen.main else {
            notchDetected = false
            detectedHeight = 0
            return
        }
        detectedHeight = screen.safeAreaInsets.top
        notchDetected = screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
    }

    func resolvedBarHeight(for screen: NSScreen) -> CGFloat {
        if useAutomaticHeight {
            let safeHeight = screen.safeAreaInsets.top
            // A small fallback helps on OS versions/configurations that do not report the notch inset.
            return safeHeight > 0 ? safeHeight : 38
        }
        return CGFloat(manualBarHeight)
    }

    func apply() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        refreshDisplayInfo()
        do {
            let screens = NSScreen.screens.filter { $0.isBuiltIn }
            guard !screens.isEmpty else {
                statusMessage = "No built-in display found"
                return
            }

            for screen in screens {
                try processor.applyTopBar(to: screen, heightInPoints: resolvedBarHeight(for: screen), style: barStyle)
            }
            statusMessage = "Notch hidden"
        } catch {
            statusMessage = "Could not apply: \(error.localizedDescription)"
        }
    }

    func restore() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try processor.restoreAllBuiltInDisplays()
            statusMessage = "Original wallpaper restored"
        } catch {
            statusMessage = "Could not restore: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLogin = false
            statusMessage = "Launch at Login requires macOS 13 or later"
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            refreshLoginItemState()
            statusMessage = "Login item error: \(error.localizedDescription)"
        }
    }

    func refreshLoginItemState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }
}
