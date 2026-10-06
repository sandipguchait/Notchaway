import SwiftUI

enum LuminousCardTheme {
    /// Deep neutral shell that lets the content cards and semantic colors lead.
    static let canvas = Color(red: 0.035, green: 0.063, blue: 0.122)
    static let midnight = Color(red: 0.015, green: 0.045, blue: 0.10)
    static let raised = Color(red: 0.055, green: 0.085, blue: 0.16)
    static let azure = Color(red: 0.22, green: 0.53, blue: 1.00)
    static let cyan = Color(red: 0.25, green: 0.70, blue: 0.96)
    static let violet = Color(red: 0.38, green: 0.42, blue: 0.68)
    static let magenta = Color(red: 1.00, green: 0.20, blue: 0.38)
    static let emerald = Color(red: 0.27, green: 0.82, blue: 0.35)
    static let amber = Color(red: 1.00, green: 0.63, blue: 0.18)
}

/// Minimal midnight surface shared by cards, editors, list rows, and controls.
/// The accent remains in the API for semantic content, but the card itself stays
/// neutral so color is reserved for status and action.
struct LuminousCardSurface<S: Shape>: View {
    let shape: S
    var accent: Color = LuminousCardTheme.azure
    var secondaryAccent: Color = LuminousCardTheme.violet

    var body: some View {
        ZStack {
            AppleGlassSurface(shape: shape, role: .card)
            shape.fill(LuminousCardTheme.midnight.opacity(0.86))
            shape.stroke(Color.white.opacity(0.055), lineWidth: 0.7)
        }
        .clipShape(shape)
    }
}

/// Flat metric tile shared by the dashboard and feature tabs.
struct LiveCard<Content: View>: View {
    var padding: CGFloat
    var glow: Color?
    let content: Content

    init(padding: CGFloat = 10, glow: Color? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.glow = glow
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let accent = glow ?? LuminousCardTheme.azure
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LuminousCardSurface(shape: shape, accent: accent))
            .clipShape(shape)
    }
}

struct CardHeader: View {
    let title: String
    var symbol: String?
    var tint: Color = .green
    var trailing: String?
    var trailingSymbol: String?
    var trailingTint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
            Spacer(minLength: 4)
            if let trailingSymbol { Image(systemName: trailingSymbol).foregroundStyle(trailingTint) }
            if let trailing { Text(trailing).foregroundStyle(trailingTint) }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(1)
    }
}

struct BigNumber: View {
    let text: String
    var size: CGFloat = 30

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Open-bottom ring gauge with an icon inside, like the Activity-style rings.
struct RingGauge: View {
    let progress: Double
    let tint: Color
    let symbol: String
    var label: String?
    var size: CGFloat = 44
    var lineWidth: CGFloat = 5

    var body: some View {
        let value = min(max(progress, 0), 1)
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    .stroke(tint.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.12, to: 0.12 + 0.76 * value)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }
}

struct RoundActionButton: View {
    let symbol: String
    var tint: Color = .green
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(filled ? Color.black : tint)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(filled ? tint : tint.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ChipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
