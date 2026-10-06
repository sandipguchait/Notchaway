import SwiftUI

struct HomeTabView: View {
    var body: some View {
        EqualCardGrid {
            NowPlayingLiveCard()
        } topTrailing: {
            RingsCard()
        } bottomLeading: {
            DashboardUtilitiesCard()
        } bottomTrailing: {
            WeatherCard()
        }
    }
}

private enum DashboardUtilityDetail {
    case none, wifi, phone
}

/// A compact launchpad for the high-value utility actions that used to live in the Context tools page.
struct DashboardUtilitiesCard: View {
    @EnvironmentObject private var hero: HeroFeaturesService
    @State private var detail: DashboardUtilityDetail = .none

    var body: some View {
        GeometryReader { proxy in
            LiveCard(padding: 10, glow: LuminousCardTheme.violet) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Utilities", symbol: "wand.and.stars", tint: .white.opacity(0.82),
                               trailing: hero.isScreenRecording ? "RECORDING" : nil)

                    HStack(alignment: .center, spacing: 6) {
                        utility(title: hero.isDictating ? "Stop" : "Dictate",
                                symbol: hero.isDictating ? "stop.circle.fill" : "mic.fill",
                                tint: .orange, isActive: hero.isDictating) {
                            hero.toggleDictation()
                        }
                        utility(title: "Phone", symbol: "iphone.and.arrow.forward", tint: .blue,
                                isActive: hero.phoneShareURL != nil) {
                            if hero.phoneShareURL == nil { hero.togglePhoneShare() }
                            detail = .phone
                        }
                        utility(title: "Wi-Fi QR", symbol: "qrcode", tint: .cyan) {
                            hero.refreshWiFi()
                            detail = .wifi
                        }
                        utility(title: hero.isScreenRecording ? "Stop" : "Record",
                                symbol: hero.isScreenRecording ? "stop.circle.fill" : "record.circle",
                                tint: .red, isActive: hero.isScreenRecording) {
                            hero.toggleScreenRecording()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .popover(isPresented: Binding(
            get: { detail != .none },
            set: { if !$0 { detail = .none } }
        ), arrowEdge: .bottom) {
            utilityDetail
                .environment(\.colorScheme, .dark)
        }
    }

    private func utility(title: String, symbol: String, tint: Color, isActive: Bool = false,
                         action: @escaping () -> Void) -> some View {
        DashboardUtilityButton(title: title, symbol: symbol, tint: tint, isActive: isActive, action: action)
    }

    @ViewBuilder
    private var utilityDetail: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            switch detail {
            case .wifi:
                CardHeader(title: "Wi-Fi Guest QR", symbol: "wifi", tint: .cyan, trailing: hero.wifiName)
                HStack(spacing: 14) {
                    if let qr = hero.wifiQRCode {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 112, height: 112)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Enter the Wi-Fi password")
                            .font(.system(size: 12, weight: .semibold))
                        SecureField("Password", text: $hero.wifiPassword)
                            .textFieldStyle(.roundedBorder)
                        Text("The password stays on this Mac. Scan the QR code with the Camera app to join.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            case .phone:
                CardHeader(title: "Drop to Phone", symbol: "iphone.and.arrow.forward", tint: .blue,
                           trailing: hero.phoneShareURL == nil ? "WAITING" : "LIVE")
                HStack(spacing: 14) {
                    if let qr = hero.phoneQRCode {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 112, height: 112)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 112, height: 112)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.12)))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(hero.phoneShareURL == nil ? "Add files to the Shelf first" : "Scan this code on your phone")
                            .font(.system(size: 12, weight: .semibold))
                        Text(hero.phoneShareURL?.absoluteString ?? "Files are shared only over your local network.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if hero.phoneShareURL != nil {
                            PillButton(title: "Stop Sharing", symbol: "stop.fill") {
                                hero.togglePhoneShare()
                                detail = .none
                            }
                        }
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(AppleGlassSurface(shape: shape, role: .panel))
    }
}

private struct DashboardUtilityButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .center, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .opacity(isActive ? 1 : 0.92)
                    .frame(width: 24, height: 24, alignment: .center)
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive
                          ? tint.opacity(0.22)
                          : Color.white.opacity(isHovering ? 0.12 : 0.075))
            )
            .scaleEffect(isHovering ? 1.025 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .help(title)
    }
}

struct LiveTabView: View {
    var body: some View {
        EqualCardGrid {
            ScoresCard()
        } topTrailing: {
            DevicesCard()
        } bottomLeading: {
            CaptionsCard()
        } bottomTrailing: {
            MindfulCard()
        }
    }
}

/// Two rows and two columns that each take exactly half of the available space.
private struct EqualCardGrid<TL: View, TR: View, BL: View, BR: View>: View {
    @ViewBuilder var topLeading: () -> TL
    @ViewBuilder var topTrailing: () -> TR
    @ViewBuilder var bottomLeading: () -> BL
    @ViewBuilder var bottomTrailing: () -> BR

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let cellWidth = max(0, (proxy.size.width - spacing) / 2)
            let cellHeight = max(0, (proxy.size.height - spacing) / 2)

            VStack(spacing: spacing) {
                row(topLeading(), topTrailing(), width: cellWidth, height: cellHeight)
                row(bottomLeading(), bottomTrailing(), width: cellWidth, height: cellHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func row<L: View, R: View>(_ leading: L, _ trailing: R,
                                      width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            cell(leading, width: width, height: height)
            cell(trailing, width: width, height: height)
        }
        .frame(width: width * 2 + 8, height: height, alignment: .leading)
    }

    private func cell<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) -> some View {
        content
            .frame(width: width, height: height)
            .clipped()
    }
}

/// Book-card style now playing: artwork, title, and a progress bar with elapsed / remaining time.
struct NowPlayingLiveCard: View {
    @EnvironmentObject private var player: NowPlayingService

    var body: some View {
        LiveCard(glow: player.isPlaying ? LuminousCardTheme.magenta : LuminousCardTheme.violet) {
            if let track = player.track {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        ArtworkView(image: player.artwork, size: 36, cornerRadius: 7)
                            .onTapGesture { player.openPlayer() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(track.artist.isEmpty ? track.album : track.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            mediaButton("backward.fill") { player.previous() }
                            mediaButton(player.isPlaying ? "pause.fill" : "play.fill") { player.playPause() }
                            mediaButton("forward.fill") { player.next() }
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let position = player.currentPosition(at: context.date)
                        HStack(spacing: 8) {
                            Text(Format.clock(position))
                            LevelBar(value: track.duration > 0 ? position / track.duration : 0)
                                .frame(height: 4)
                            Text("-" + Format.clock(max(0, track.duration - position)))
                        }
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ArtworkView(image: nil, size: 36, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing playing")
                            .font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 6) {
                            ChipButton(title: "Music") { player.launch(.music) }
                            if player.isInstalled(.spotify) {
                                ChipButton(title: "Spotify") { player.launch(.spotify) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func mediaButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Ride-card style focus timer: green label, big digits, pill controls.
struct FocusLiveCard: View {
    @EnvironmentObject private var timer: FocusTimerService
    @EnvironmentObject private var keepAwake: KeepAwakeService
    @EnvironmentObject private var calendar: CalendarService

    var body: some View {
        LiveCard {
            VStack(alignment: .leading, spacing: 4) {
                CardHeader(title: timer.mode.map { "\($0.title) left" } ?? "Focus",
                           symbol: timer.symbol,
                           tint: timer.isActive ? timer.tint : .green,
                           trailing: "\(timer.todayCount) today",
                           trailingSymbol: "flame.fill",
                           trailingTint: .orange)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BigNumber(text: timer.displayText(at: context.date), size: 22)
                }

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                HStack(spacing: 8) {
                    if !timer.isActive {
                        RoundActionButton(symbol: "play.fill", tint: .green, filled: true) { timer.startFocus() }
                        RoundActionButton(symbol: "cup.and.saucer.fill", tint: .green) { timer.startBreak() }
                    } else {
                        RoundActionButton(symbol: timer.isRunning ? "pause.fill" : "play.fill", tint: .green, filled: true) {
                            if timer.isRunning { timer.pause() } else { timer.resume() }
                        }
                        RoundActionButton(symbol: "stop.fill", tint: .green) { timer.stop() }
                    }
                    RoundActionButton(symbol: "bolt.fill", tint: keepAwake.isActive ? .orange : .green,
                                      filled: keepAwake.isActive) { keepAwake.toggle() }
                        .help(keepAwake.isActive ? "Keep Awake: \(keepAwake.statusText)" : "Keep Awake")
                }
            }
        }
    }

    private var subtitle: String {
        if timer.isActive {
            return timer.isRunning ? "Stay in the zone" : "Paused"
        }
        if let event = calendar.nextEvent {
            return "Next: \(event.title) · \(event.timeDescription)"
        }
        return keepAwake.isActive ? "Keeping your Mac awake · \(keepAwake.statusText)" : "Start a focus session"
    }
}
