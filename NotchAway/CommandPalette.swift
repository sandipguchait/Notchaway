import AppKit
import SwiftUI

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    let run: () -> Void
}

final class PalettePanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class CommandPaletteController: ObservableObject {
    @Published var query = "" {
        didSet { selection = 0 }
    }
    @Published var selection = 0
    @Published private(set) var shortcuts: [String] = []

    private unowned let services: AppServices
    private var panel: PalettePanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(services: AppServices) {
        self.services = services
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        query = ""
        selection = 0
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: CommandPaletteView(controller: self).environment(\.colorScheme, .dark))

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.maxY - panel.frame.height - frame.height * 0.12))
        }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        loadShortcuts()
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func run(_ action: PaletteAction) {
        close()
        action.run()
    }

    func runSelected() {
        let items = results
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    var results: [PaletteAction] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        let all = baseActions + shortcutActions + (tokens.isEmpty ? [] : clipboardActions)
        guard !tokens.isEmpty else { return all }
        return all.filter { action in
            let haystack = (action.title + " " + (action.subtitle ?? "")).lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
        .prefix(40)
        .map { $0 }
    }

    // MARK: Actions

    private var baseActions: [PaletteAction] {
        let s = services
        var actions: [PaletteAction] = s.settings.visibleTabs.enumerated().map { index, tab in
            PaletteAction(id: "tab.\(tab.rawValue)", title: "Open \(tab.title)", subtitle: "Island · ⌘\(index + 1)",
                          symbol: tab.symbol) { s.openIsland(tab: tab) }
        }

        actions += [
            PaletteAction(id: "awake.toggle",
                          title: s.keepAwake.isActive ? "Turn Off Keep Awake" : "Keep Awake",
                          subtitle: s.keepAwake.isActive ? s.keepAwake.statusText : "Prevent sleep until turned off",
                          symbol: "cup.and.saucer.fill") { s.keepAwake.toggle() },
            PaletteAction(id: "awake.1h", title: "Keep Awake for 1 Hour", subtitle: "Caffeine",
                          symbol: "cup.and.saucer") { s.keepAwake.activate(for: 3600) },
            PaletteAction(id: "timer.focus", title: "Start Focus Session",
                          subtitle: "\(s.settings.focusMinutes) minute Pomodoro", symbol: "brain.head.profile") {
                s.timer.startFocus()
            },
            PaletteAction(id: "timer.break", title: "Start Break", subtitle: "\(s.settings.breakMinutes) minutes",
                          symbol: "cup.and.saucer.fill") { s.timer.startBreak() },
            PaletteAction(id: "timer.stopwatch", title: "Start Stopwatch", subtitle: "Timer",
                          symbol: "stopwatch") { s.timer.startStopwatch() },
        ]
        for minutes in [5, 10, 15, 30] {
            actions.append(PaletteAction(id: "timer.\(minutes)", title: "Start \(minutes) Minute Timer", subtitle: "Timer",
                                         symbol: "timer") { s.timer.startTimer(minutes: minutes) })
        }
        if s.timer.isActive {
            actions.append(PaletteAction(id: "timer.stop", title: "Stop Timer", subtitle: s.timer.mode?.title,
                                         symbol: "stop.fill") { s.timer.stop() })
        }

        actions += [
            PaletteAction(id: "note.new", title: "New Note", subtitle: "Quick Notes", symbol: "square.and.pencil") {
                s.notes.add()
                s.openIsland(tab: .notes)
            },
            PaletteAction(id: "media.playpause", title: "Play / Pause", subtitle: "Now Playing",
                          symbol: "playpause.fill") { s.nowPlaying.playPause() },
            PaletteAction(id: "media.next", title: "Next Track", subtitle: "Now Playing",
                          symbol: "forward.fill") { s.nowPlaying.next() },
            PaletteAction(id: "media.previous", title: "Previous Track", subtitle: "Now Playing",
                          symbol: "backward.fill") { s.nowPlaying.previous() },
            PaletteAction(id: "audio.mute", title: s.hud.isMuted ? "Unmute" : "Mute Sound", subtitle: "Audio",
                          symbol: "speaker.slash.fill") { s.hud.toggleMute() },
            PaletteAction(id: "clipboard.clear", title: "Clear Clipboard History", subtitle: "Pinned items are kept",
                          symbol: "trash") { s.clipboard.clearUnpinned() },
            PaletteAction(id: "shelf.clear", title: "Clear File Shelf", subtitle: "Shelf",
                          symbol: "tray") { s.shelf.clear() },
            PaletteAction(id: "calendar.refresh", title: "Refresh Calendar", subtitle: "Calendar",
                          symbol: "arrow.clockwise") { s.calendar.refresh() },
            PaletteAction(id: "notch.toggle",
                          title: s.notch.isEnabled ? "Show the Notch (Restore Wallpaper)" : "Hide the Notch",
                          subtitle: "Wallpaper", symbol: "rectangle.topthird.inset.filled") {
                s.notch.isEnabled.toggle()
            },
            PaletteAction(id: "water.add", title: "Log a Glass of Water", subtitle: "Daily Rings",
                          symbol: "drop.fill") { s.wellness.addGlass() },
            PaletteAction(id: "captions.toggle",
                          title: s.captions.isRunning ? "Stop Live Captions" : "Start Live Captions",
                          subtitle: "Live", symbol: "captions.bubble.fill") {
                s.captions.toggle()
                s.openIsland(tab: .live)
            },
            PaletteAction(id: "weather.refresh", title: "Refresh Weather", subtitle: "Weather & UV",
                          symbol: "cloud.sun.fill") { s.weather.refresh(force: true) },
            PaletteAction(id: "scores.open", title: "Show Live Scores", subtitle: s.scores.league.name,
                          symbol: "sportscourt.fill") { s.openIsland(tab: .live) },
            PaletteAction(id: "hero.dictation",
                          title: s.hero.isDictating ? "Stop Dictation and Save" : "Dictate a Note",
                          subtitle: "On-device speech · Context Island", symbol: "waveform.badge.mic") {
                s.hero.toggleDictation()
                s.openIsland(tab: .context)
            },
            PaletteAction(id: "hero.meeting",
                          title: s.hero.meetingStart == nil ? "Start Meeting Cost Ticker" : "Stop Meeting Cost Ticker",
                          subtitle: "Context Island", symbol: "dollarsign.circle") {
                if s.hero.meetingStart == nil { s.hero.startMeeting() } else { s.hero.stopMeeting() }
                s.openIsland(tab: .context)
            },
            PaletteAction(id: "hero.phone",
                          title: s.hero.phoneShareURL == nil ? "Share Shelf to Phone" : "Stop Phone Share",
                          subtitle: "Private local-network transfer", symbol: "iphone.and.arrow.forward") {
                s.hero.togglePhoneShare()
                s.openIsland(tab: .shelf)
            },
            PaletteAction(id: "hero.screen-recording",
                          title: s.hero.isScreenRecording ? "Stop Screen Recording" : "Start Screen Recording",
                          subtitle: s.hero.screenRecordingStatus,
                          symbol: s.hero.isScreenRecording ? "stop.circle.fill" : "record.circle") {
                s.hero.toggleScreenRecording()
            },
            PaletteAction(id: "app.settings", title: "Settings", subtitle: "NotchAway", symbol: "gearshape") {
                s.openSettings()
            },
            PaletteAction(id: "app.quit", title: "Quit NotchAway", subtitle: "NotchAway", symbol: "power") {
                NSApp.terminate(nil)
            },
        ]
        return actions
    }

    private var shortcutActions: [PaletteAction] {
        shortcuts.map { name in
            PaletteAction(id: "shortcut.\(name)", title: name, subtitle: "Run Shortcut", symbol: "square.stack.3d.up.fill") {
                ShortcutsRunner.run(name)
            }
        }
    }

    private var clipboardActions: [PaletteAction] {
        services.clipboard.items.prefix(100).map { item in
            PaletteAction(id: "clip.\(item.id)", title: String(item.preview.prefix(80)), subtitle: "Copy from clipboard history",
                          symbol: "doc.on.clipboard") { [weak self] in
                self?.services.clipboard.copy(item)
            }
        }
    }

    // MARK: Internals

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        self.panel = panel
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.keyCode {
            case 125:
                self.selection = min(self.selection + 1, max(0, self.results.count - 1))
                return nil
            case 126:
                self.selection = max(self.selection - 1, 0)
                return nil
            case 36, 76:
                self.runSelected()
                return nil
            case 53:
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    private func loadShortcuts() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let names = ShortcutsRunner.list()
            Task { @MainActor in self?.shortcuts = names }
        }
    }
}

enum ShortcutsRunner {
    static func list() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func run(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try? process.run()
    }
}

struct CommandPaletteView: View {
    @ObservedObject var controller: CommandPaletteController
    @FocusState private var focused: Bool

    var body: some View {
        let results = controller.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Type a command, shortcut, or clipboard text…", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                            HStack(spacing: 12) {
                                Image(systemName: action.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 22)
                                    .foregroundStyle(index == controller.selection ? .white : .secondary)
                                Text(action.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                if let subtitle = action.subtitle {
                                    Text(subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(index == controller.selection ? Color.accentColor.opacity(0.35) : Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture { controller.run(action) }
                            .id(index)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: controller.selection) { value in
                    proxy.scrollTo(value)
                }
            }

            if results.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 580, height: 400)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1)))
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}
