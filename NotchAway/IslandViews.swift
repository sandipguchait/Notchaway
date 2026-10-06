import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @EnvironmentObject private var state: IslandState
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var timer: FocusTimerService
    @EnvironmentObject private var keepAwake: KeepAwakeService
    @EnvironmentObject private var shelf: ShelfService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)

    var body: some View {
        let size = IslandSizing.size(state: state, nowPlaying: nowPlaying, timer: timer, keepAwake: keepAwake)
        let closedSize = IslandSizing.closedSize(state: state, nowPlaying: nowPlaying, timer: timer, keepAwake: keepAwake)
        let hasNotch = state.geometry.hasNotch
        let motionProgress = min(max(state.genieProgress, 0), 1)
        let expandedEar = IslandSizing.expandedEar -
            (IslandSizing.expandedEar - IslandSizing.closedEar) * motionProgress
        let ear: CGFloat = hasNotch ? (state.isExpanded ? expandedEar : IslandSizing.closedEar) : 0
        let closedBottom: CGFloat = hasNotch ? 10 : state.geometry.notchSize.height / 2
        let bottom: CGFloat = state.isExpanded ? 26 - (26 - closedBottom) * motionProgress : closedBottom
        let shape = IslandShape(earRadius: ear, bottomRadius: bottom)
        let closedShape = IslandShape(
            earRadius: hasNotch ? IslandSizing.closedEar : 0,
            bottomRadius: hasNotch ? 10 : state.geometry.notchSize.height / 2
        )

        ZStack(alignment: .top) {
            if !state.isExpanded || state.genieProgress > 0.46 {
                ClosedIslandView(earInset: hasNotch ? IslandSizing.closedEar : 0)
                    .background(closedShape.fill(Color.black))
                    .clipShape(closedShape)
                    .frame(width: closedSize.width, height: closedSize.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .opacity(state.isExpanded ? closedIslandOpacity : 1)
            }
            if state.isExpanded {
                ExpandedIslandView(
                    earInset: ear,
                    bottomRadius: bottom,
                    minimizeProgress: motionProgress
                )
                    .modifier(NotchGenieEffect(
                        progress: state.genieProgress,
                        collapsedSize: closedSize,
                        reduceMotion: reduceMotion
                    ))
                    .transition(.identity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .overlay {
            if state.isDropTargeted && !state.isExpanded {
                shape.stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $state.isDropTargeted) { providers in
            shelf.add(providers: providers)
            state.selectedTab = .shelf
            return true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(state.prefersInstantLayout ? nil : spring, value: size)
        .environment(\.colorScheme, .dark)
    }

    private var closedIslandOpacity: Double {
        let phase = min(max((state.genieProgress - 0.46) / 0.42, 0), 1)
        return Double(phase * phase * (3 - 2 * phase))
    }

    private var expandedShadowOpacity: Double {
        guard state.isExpanded else { return 0 }
        let phase = min(max(state.genieProgress / 0.42, 0), 1)
        let eased = phase * phase * (3 - 2 * phase)
        return Double(0.45 * (1 - eased))
    }
}

// MARK: - Closed island

struct ClosedIslandView: View {
    let earInset: CGFloat

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: IslandState
    @EnvironmentObject private var nowPlaying: NowPlayingService
    @EnvironmentObject private var timer: FocusTimerService
    @EnvironmentObject private var keepAwake: KeepAwakeService

    var body: some View {
        let side = IslandSizing.sideWidth(state: state, nowPlaying: nowPlaying, timer: timer, keepAwake: keepAwake)
        let notch = state.geometry.notchSize

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if side > 0 {
                    leading(height: notch.height)
                        .frame(width: side, alignment: .leading)
                }
                Color.clear.frame(width: notch.width)
                if side > 0 {
                    trailing
                        .frame(width: side, alignment: .trailing)
                }
            }
            .frame(height: notch.height)

            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: IslandSizing.toastHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, earInset)
        .contentShape(Rectangle())
        .onTapGesture { services.openIsland() }
    }

    @ViewBuilder
    private func leading(height: CGFloat) -> some View {
        if let hud = state.hud {
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 14)
        } else if nowPlaying.isPlaying {
            ArtworkView(image: nowPlaying.artwork, size: max(16, height - 12), cornerRadius: 5)
                .padding(.leading, 8)
        } else if timer.isActive {
            Image(systemName: timer.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(timer.tint)
                .padding(.leading, 12)
        } else if keepAwake.isActive {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.leading, 10)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let hud = state.hud {
            LevelBar(value: hud.muted ? 0 : Double(hud.value))
                .frame(width: 48, height: 5)
                .padding(.trailing, 14)
        } else if timer.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timer.displayText(at: context.date))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.tint)
            }
            .padding(.trailing, 10)
        } else if nowPlaying.isPlaying {
            MusicBars()
                .frame(width: 16, height: 12)
                .padding(.trailing, 10)
        } else if keepAwake.isActive {
            Text(keepAwake.shortRemainingText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.orange)
                .padding(.trailing, 10)
        }
    }
}

/// A top-centred version of the macOS window minimize effect. The upper edge is
/// pulled into the notch just ahead of the lower edge, creating the familiar
/// curved "suction" silhouette without resizing the host NSPanel every frame.
struct NotchGenieEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let collapsedSize: CGSize
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let amount = min(max(progress, 0), 1)

        if reduceMotion {
            content
                .opacity(Double(1 - smoothStep(amount)))
                .allowsHitTesting(amount < 0.02)
        } else {
            content
                .mask {
                    NotchGenieMask(progress: amount, targetWidth: collapsedSize.width)
                }
                .scaleEffect(
                    x: 1,
                    y: 1 - smoothStep(amount) * (1 - collapsedHeightRatio),
                    anchor: .top
                )
                // A hint of motion blur hides sub-pixel shimmer while the curved
                // mask is travelling fastest, but resolves sharp at both ends.
                .blur(radius: sin(amount * .pi) * 0.9)
                .opacity(Double(1 - smoothStep((amount - 0.56) / 0.44)))
                .allowsHitTesting(amount < 0.02)
        }
    }

    private var collapsedHeightRatio: CGFloat {
        min(max(collapsedSize.height / IslandSizing.expanded.height, 0.06), 1)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }
}

/// Curves the two side walls independently so the notch-facing edge leads the
/// motion. At rest this is a full rectangle; at completion it is notch-width.
private struct NotchGenieMask: Shape {
    var progress: CGFloat
    let targetWidth: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let amount = min(max(progress, 0), 1)
        let fullHalfWidth = rect.width / 2
        let targetHalfWidth = min(max(targetWidth / 2, 1), fullHalfWidth)
        let insetRange = fullHalfWidth - targetHalfWidth

        // The top reaches for the notch first; the lower corners follow a beat
        // later. The cubic side walls turn that phase difference into a soft
        // genie-like funnel instead of a trapezoid.
        let topPhase = smoothStep(amount / 0.82)
        let bottomPhase = smoothStep((amount - 0.08) / 0.92)
        let topHalfWidth = fullHalfWidth - insetRange * topPhase
        let bottomHalfWidth = fullHalfWidth - insetRange * bottomPhase
        let centerX = rect.midX

        var path = Path()
        path.move(to: CGPoint(x: centerX - topHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: centerX + topHalfWidth, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: centerX + bottomHalfWidth, y: rect.maxY),
            control1: CGPoint(x: centerX + topHalfWidth, y: rect.minY + rect.height * 0.34),
            control2: CGPoint(x: centerX + bottomHalfWidth, y: rect.minY + rect.height * 0.68)
        )
        path.addLine(to: CGPoint(x: centerX - bottomHalfWidth, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: centerX - topHalfWidth, y: rect.minY),
            control1: CGPoint(x: centerX - bottomHalfWidth, y: rect.minY + rect.height * 0.68),
            control2: CGPoint(x: centerX - topHalfWidth, y: rect.minY + rect.height * 0.34)
        )
        path.closeSubpath()
        return path
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }
}

struct LevelBar: View {
    let value: Double
    var tint: Color = LuminousCardTheme.azure

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: value)
    }
}

struct MusicBars: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let phase = sin(t * (2.3 + Double(index) * 0.9) + Double(index) * 1.7)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 2.5, height: 3 + CGFloat((phase + 1) / 2) * 9)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: t)
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LuminousCardTheme.raised
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Expanded island

struct ExpandedIslandView: View {
    let earInset: CGFloat
    let bottomRadius: CGFloat
    let minimizeProgress: CGFloat

    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var state: IslandState
    @EnvironmentObject private var settings: IslandSettings
    @EnvironmentObject private var keepAwake: KeepAwakeService
    @EnvironmentObject private var replay: DayReplayService

    var body: some View {
        let shape = IslandShape(earRadius: earInset, bottomRadius: bottomRadius)
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                header
                    .frame(height: max(state.geometry.notchSize.height + 2, 34))
                    .opacity(stagedOpacity(start: 0.08, end: 0.68))

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, sideInset)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .opacity(stagedOpacity(start: 0.02, end: 0.64))
                    .offset(y: -4 * minimizeProgress)
            }
            .frame(height: 258)
            .background(AppleGlassSurface(shape: shape, role: .panel))
            .clipShape(shape)
            .overlay {
                if state.isDropTargeted {
                    shape.stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                }
            }

            tabDock
                .opacity(stagedOpacity(start: 0.0, end: 0.48))
                .offset(y: -5 * minimizeProgress)
        }
        .foregroundStyle(.white)
    }

    private func stagedOpacity(start: CGFloat, end: CGFloat) -> Double {
        let phase = min(max((minimizeProgress - start) / (end - start), 0), 1)
        let eased = phase * phase * (3 - 2 * phase)
        return Double(1 - eased)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(state.selectedTab == .home ? "Dashboard" : state.selectedTab.title)
                .font(.system(size: 12, weight: .bold))
            Button {
                keepAwake.toggle()
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(keepAwake.isActive ? Color.yellow : Color.white.opacity(0.65))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(keepAwake.isActive ? "Keep Awake: \(keepAwake.statusText)" : "Keep Awake")

            Spacer(minLength: state.geometry.hasNotch ? state.geometry.notchSize.width + 16 : 16)

            IslandIconButton(symbol: state.isPinned ? "pin.fill" : "pin", isActive: state.isPinned, help: "Keep open") {
                state.isPinned.toggle()
            }
            IslandIconButton(symbol: "command", help: "Command palette (⌃⌥K)") {
                services.palette.show()
            }
            IslandIconButton(symbol: "gearshape.fill", help: "Settings") {
                services.openSettings()
            }
        }
        .padding(.horizontal, sideInset)
    }

    /// The notch shape pulls both side walls in by `earInset`, so padding is measured from that edge.
    private var sideInset: CGFloat { earInset + 14 }

    private var tabDock: some View {
        HStack(spacing: 1) {
            ForEach(settings.visibleTabs) { tab in
                ZStack(alignment: .topTrailing) {
                    IslandIconButton(symbol: tab.symbol, isActive: state.selectedTab == tab, help: tab.title) {
                        state.selectedTab = tab
                    }
                    if tab == .replay, replay.hasUnseenReplay, state.selectedTab != .replay {
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 5, height: 5)
                            .offset(x: -2, y: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(AppleGlassSurface(shape: Capsule(), role: .control))
    }

    @ViewBuilder
    private var content: some View {
        let tab = settings.isTabEnabled(state.selectedTab) ? state.selectedTab : .home
        switch tab {
        case .home: HomeTabView()
        case .context: HeroHubView()
        case .live: LiveTabView()
        case .replay: DayReplayView()
        case .clipboard: ClipboardTabView()
        case .shelf: ShelfTabView()
        case .timer: TimerTabView()
        case .notes: NotesTabView()
        case .calendar: CalendarTabView()
        case .stats: StatsTabView()
        }
    }
}

// MARK: - Home

struct QuickToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(isOn ? tint : Color.white.opacity(0.12)))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct UpNextCard: View {
    @EnvironmentObject private var calendar: CalendarService

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: calendar.nextEvent?.color ?? .systemBlue))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text("UP NEXT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                if calendar.eventAccess != .granted {
                    Button("Connect Calendar") { calendar.requestAccess() }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                } else if let event = calendar.nextEvent {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(event.timeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Nothing scheduled")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Next 7 days are clear")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(height: 64)
        .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.azure)
    }
}
