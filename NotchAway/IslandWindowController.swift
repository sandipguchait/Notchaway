import AppKit
import Combine
import SwiftUI

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandWindowController {
    let state = IslandState()

    private unowned let services: AppServices
    private var panel: IslandPanel?
    private var screenFrame: CGRect = .zero
    private var monitors: [Any] = []
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var genieTask: Task<Void, Never>?
    private var mouseWasInside = false
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var cancellables = Set<AnyCancellable>()

    private static let panelPadding: CGFloat = 40
    private static let closeDuration: UInt64 = 680_000_000
    private static let closeAnimation = Animation.timingCurve(0.36, 0, 0.20, 1, duration: 0.66)
    private static let openAnimation = Animation.timingCurve(0.16, 1, 0.30, 1, duration: 0.68)

    init(services: AppServices) {
        self.services = services
    }

    func start() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        services.settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        rebuild()
    }

    // MARK: Public control

    func expand(to tab: IslandTab? = nil) {
        guard panel != nil else { return }
        if let tab { state.selectedTab = tab }
        mouseWasInside = currentHotRect().contains(NSEvent.mouseLocation)
        if state.isExpanded {
            guard genieTask != nil else { return }
            genieTask?.cancel()
            genieTask = nil
            withAnimation(Self.openAnimation) {
                state.genieProgress = 0
            }
            return
        }
        setExpanded(true)
    }

    func collapse() {
        guard state.isExpanded, genieTask == nil, state.genieProgress == 0 else { return }
        withAnimation(Self.closeAnimation) {
            state.genieProgress = 1
        }
        genieTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.closeDuration)
            guard let self, !Task.isCancelled, self.state.genieProgress > 0.9 else { return }
            self.finishCollapse()
        }
    }

    // MARK: Window lifecycle

    private func rebuild() {
        let settings = services.settings
        guard settings.islandEnabled, let screen = targetScreen() else {
            panel?.orderOut(nil)
            removeMonitors()
            setExpanded(false)
            return
        }

        screenFrame = screen.frame
        let geometry = Self.geometry(for: screen)
        if state.geometry != geometry { state.geometry = geometry }

        let panel = self.panel ?? makePanel()
        let size = CGSize(width: IslandSizing.expanded.width + Self.panelPadding * 2,
                          height: IslandSizing.expanded.height + Self.panelPadding)
        let frame = CGRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        panel.orderFrontRegardless()

        installMonitors()
        updateMouseState()
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()
        let root = IslandRootView().islandEnvironment(services)
        let hosting = IslandHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in self?.scheduleCollapseIfNeeded() }
            .store(in: &cancellables)
        return panel
    }

    private func targetScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.hasNotch }) { return notched }
        return services.settings.showPillWithoutNotch ? NSScreen.screens.first : nil
    }

    private static func geometry(for screen: NSScreen) -> IslandGeometry {
        if screen.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return IslandGeometry(notchSize: CGSize(width: max(120, width), height: screen.safeAreaInsets.top),
                                  hasNotch: true)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let height = min(max(menuBarHeight, 24), 32)
        return IslandGeometry(notchSize: CGSize(width: 180, height: height), hasNotch: false)
    }

    // MARK: Mouse tracking

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            Task { @MainActor in self?.handleMouse(type, isGlobal: true) }
        }) {
            monitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            Task { @MainActor in self?.handleMouse(type, isGlobal: false) }
            return event
        }) {
            monitors.append(local)
        }

        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKey(event) ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            collapse()
            return true
        }
        if event.modifierFlags.contains(.command),
           let character = event.charactersIgnoringModifiers,
           let number = Int(character), number >= 1 {
            let tabs = services.settings.visibleTabs
            if number <= tabs.count {
                state.selectedTab = tabs[number - 1]
                return true
            }
        }
        return false
    }

    private func handleMouse(_ type: NSEvent.EventType, isGlobal: Bool) {
        switch type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            if isGlobal, state.isExpanded, !state.isPinned,
               !currentHotRect().contains(NSEvent.mouseLocation) {
                collapse()
                return
            }
        case .leftMouseDragged:
            updateMouseState(dragging: true)
            return
        default:
            break
        }
        updateMouseState()
    }

    private func updateMouseState(dragging: Bool = false) {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        var inside = currentHotRect().contains(point)

        if dragging, !state.isExpanded, isDraggingFiles(), dropZone().contains(point) {
            state.selectedTab = .shelf
            setExpanded(true)
            inside = true
        }

        panel.ignoresMouseEvents = !inside

        if inside {
            mouseWasInside = true
            collapseTask?.cancel()
            collapseTask = nil
            if state.isExpanded, genieTask != nil, !dragging {
                // Re-entering while the dashboard is being pulled into the notch
                // reverses the same animation from its current presentation value.
                expand()
            } else if !state.isExpanded, services.settings.hoverToOpen, !dragging, expandTask == nil {
                expandTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 110_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.expandTask = nil
                    if self.currentHotRect().contains(NSEvent.mouseLocation) {
                        self.setExpanded(true)
                    }
                }
            }
        } else {
            expandTask?.cancel()
            expandTask = nil
            if state.isExpanded, mouseWasInside {
                scheduleCollapseIfNeeded()
            }
        }
    }

    private func scheduleCollapseIfNeeded() {
        guard state.isExpanded, collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            if !self.currentHotRect().contains(NSEvent.mouseLocation), self.canAutoCollapse() {
                self.collapse()
            }
        }
    }

    private func canAutoCollapse() -> Bool {
        guard !state.isPinned, !state.isDropTargeted else { return false }
        if let panel, panel.isKeyWindow,
           let textView = panel.firstResponder as? NSTextView, textView.isEditable {
            return false
        }
        return true
    }

    private func finishCollapse() {
        genieTask?.cancel()
        genieTask = nil
        state.prefersInstantLayout = true
        state.genieProgress = 0
        state.isExpanded = false
        mouseWasInside = false
        releaseKeyFocus()
        panel?.ignoresMouseEvents = !currentHotRect().contains(NSEvent.mouseLocation)
        Task { @MainActor [weak self] in
            self?.state.prefersInstantLayout = false
        }
    }

    private func releaseKeyFocus() {
        guard let panel, panel.isKeyWindow else { return }
        // Ordering out hands keyboard focus back to the previously active app.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func setExpanded(_ expanded: Bool) {
        expandTask?.cancel()
        expandTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        if !expanded {
            genieTask?.cancel()
            genieTask = nil
            state.prefersInstantLayout = true
            state.genieProgress = 0
            Task { @MainActor [weak self] in
                self?.state.prefersInstantLayout = false
            }
        }

        if expanded, !state.isExpanded {
            state.prefersInstantLayout = true
            state.isExpanded = true
            state.genieProgress = 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.prefersInstantLayout = false
                withAnimation(Self.openAnimation) {
                    self.state.genieProgress = 0
                }
            }
        } else if state.isExpanded != expanded {
            state.isExpanded = expanded
        }

        guard let panel else { return }
        if !expanded {
            mouseWasInside = false
            releaseKeyFocus()
        }
        panel.ignoresMouseEvents = !(expanded || currentHotRect().contains(NSEvent.mouseLocation))
    }

    private func currentHotRect() -> CGRect {
        let size = IslandSizing.size(state: state,
                                     nowPlaying: services.nowPlaying,
                                     timer: services.timer,
                                     keepAwake: services.keepAwake)
        var rect = CGRect(x: screenFrame.midX - size.width / 2,
                          y: screenFrame.maxY - size.height,
                          width: size.width,
                          height: size.height + 1)
        if !state.isExpanded {
            rect = rect.insetBy(dx: -6, dy: 0)
            rect.origin.y -= 6
            rect.size.height += 6
        }
        return rect
    }

    private func dropZone() -> CGRect {
        currentHotRect().insetBy(dx: -40, dy: -30)
    }

    private func isDraggingFiles() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragChangeCount else { return false }
        return pasteboard.types?.contains(.fileURL) ?? false
    }
}
