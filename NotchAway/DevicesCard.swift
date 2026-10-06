import AppKit
import SwiftUI

struct DevicesCard: View {
    @EnvironmentObject private var batteries: DeviceBatteryService

    var body: some View {
        Group {
            if let buds = batteries.devices.first(where: { $0.kind == .earbuds }) {
                AirPodsBatteryCard(device: buds)
            } else {
                LiveCard(glow: LuminousCardTheme.violet) {
                    VStack(alignment: .leading, spacing: 6) {
                        CardHeader(title: "Devices", symbol: "battery.75", tint: .green)
                        if batteries.devices.isEmpty {
                            Text(batteries.hasLoaded
                                 ? "Connect AirPods, a Magic Mouse, Keyboard or Trackpad to see battery levels."
                                 : "Checking connected devices…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxHeight: .infinity)
                        } else {
                            HStack {
                                ForEach(batteries.devices.prefix(4)) { device in
                                    let level = device.lowestLevel ?? 0
                                    RingGauge(progress: Double(level) / 100, tint: level < 20 ? .red : .green,
                                              symbol: device.symbol, label: "\(level)%", size: 42)
                                        .help(device.name)
                                    if device.id != batteries.devices.prefix(4).last?.id { Spacer(minLength: 0) }
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear { batteries.beginMonitoring() }
        .onDisappear { batteries.endMonitoring() }
    }
}

/// Earbuds laid out like a headset + controllers card: a curved gauge hugging each side for the
/// left and right buds, and the case in the middle with its gauge curving underneath.
struct AirPodsBatteryCard: View {
    let device: DeviceBatteryService.Device

    @EnvironmentObject private var player: NowPlayingService

    private var isPro: Bool { device.name.localizedCaseInsensitiveContains("pro") }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                BudColumn(level: device.left,
                          symbol: Self.symbol(isPro ? "airpodpro.left" : "airpod.left", fallback: "airpodpro.left"),
                          side: .leading)
                Spacer(minLength: 0)
                CaseColumn(level: device.caseLevel,
                           symbol: Self.symbol(isPro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill",
                                               fallback: "airpodspro"))
                Spacer(minLength: 0)
                BudColumn(level: device.right,
                          symbol: Self.symbol(isPro ? "airpodpro.right" : "airpod.right", fallback: "airpodpro.right"),
                          side: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.top, 30)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let track = player.track {
                    Text(track.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .onTapGesture { player.playPause() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(
            ZStack {
                LuminousCardSurface(shape: shape, accent: AirPodsPalette.glow)
            }
        )
        .clipShape(shape)
    }

    static func symbol(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }
}

enum AirPodsPalette {
    static let fill = LuminousCardTheme.azure
    static let glow = LuminousCardTheme.azure
    static let track = Color.white.opacity(0.1)
    static let product = Color.white.opacity(0.92)
}

private struct PercentLabel: View {
    let level: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(level.map(String.init) ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
            if level != nil {
                Text("%")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// A segment of a circle drawn with `trim`, filled from `from` toward `to` by `level`.
private struct ArcGauge: View {
    let from: Double
    let to: Double
    let level: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .trim(from: from, to: to)
                .stroke(AirPodsPalette.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: from, to: from + (to - from) * min(max(level, 0), 1))
                .stroke(AirPodsPalette.fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: level)
        }
    }
}

private struct BudColumn: View {
    enum Side { case leading, trailing }

    let level: Int?
    let symbol: String
    let side: Side

    var body: some View {
        ZStack(alignment: side == .leading ? .leading : .trailing) {
            GeometryReader { proxy in
                // Fit the full gauge inside both axes. The inset protects rounded stroke caps from clipping.
                let inset: CGFloat = 5
                let diameter = max(0, min(proxy.size.width - inset * 2,
                                          proxy.size.height - inset * 2))
                ArcGauge(from: 0.36, to: 0.64, level: Double(level ?? 0) / 100)
                    .scaleEffect(x: side == .leading ? 1 : -1)
                    .frame(width: diameter, height: diameter)
                    .position(x: side == .leading
                              ? inset + diameter / 2
                              : proxy.size.width - inset - diameter / 2,
                              y: proxy.size.height / 2)
            }

            VStack(spacing: 2) {
                PercentLabel(level: level)
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(AirPodsPalette.product)
            }
            .padding(side == .leading ? .leading : .trailing, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
        .clipped()
    }
}

private struct CaseColumn: View {
    let level: Int?
    let symbol: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(AirPodsPalette.product)
                .frame(height: 38)
            PercentLabel(level: level)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottom) {
            GeometryReader { proxy in
                // Size from the smaller axis and lift the circle above the bottom edge so the arc is always visible.
                let inset: CGFloat = 6
                let diameter = max(0, min(proxy.size.width - inset * 2,
                                          proxy.size.height - inset * 2))
                ArcGauge(from: 0.14, to: 0.36, level: Double(level ?? 0) / 100)
                    .scaleEffect(x: -1)
                    .frame(width: diameter, height: diameter)
                    .position(x: proxy.size.width / 2,
                              y: proxy.size.height - inset - diameter / 2)
            }
        }
        .clipped()
    }
}
