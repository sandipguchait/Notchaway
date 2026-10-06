import AppKit
import Carbon.HIToolbox
import SwiftUI

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NotchAway", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func file(_ name: String) -> URL {
        support.appendingPathComponent(name)
    }
}

enum JSONStore {
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: AppPaths.file(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: AppPaths.file(name), options: .atomic)
    }
}

enum Format {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .file) + "/s"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension NSScreen {
    var hasNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil && safeAreaInsets.top > 0
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// System-wide hotkey via Carbon, which needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate static var action: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister()
        HotKey.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E41_5759), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

// MARK: - Shared island styling

enum AppleGlassRole {
    case panel
    case card
    case control

    var material: NSVisualEffectView.Material {
        switch self {
        case .panel: return .hudWindow
        case .card: return .popover
        case .control: return .menu
        }
    }
}

/// A single adaptive glass recipe for the entire island. On the newest macOS
/// it uses Apple's native Liquid Glass renderer; older supported systems retain
/// the same hierarchy with AppKit vibrancy and backdrop blur.
struct AppleGlassSurface<S: Shape>: View {
    let shape: S
    var role: AppleGlassRole = .card

    @EnvironmentObject private var settings: IslandSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            glassMaterial
            shape.fill(surfaceColor.opacity(surfaceOpacity))
            shape.stroke(Color.white.opacity(role == .panel ? 0.08 : 0.055), lineWidth: 0.7)
        }
        .clipShape(shape)
    }

    @ViewBuilder
    private var glassMaterial: some View {
        if reduceTransparency {
            shape.fill(Color(red: 0.055, green: 0.06, blue: 0.07))
        } else if #available(macOS 26.0, *) {
            shape
                .fill(Color.clear)
                .glassEffect(role == .control ? .clear : .regular, in: shape)
        } else {
            VisualEffectBackground(material: role.material)
                .clipShape(shape)
        }
    }

    private var transparency: Double {
        reduceTransparency ? 0 : min(max(settings.glassTransparency, 0), 1)
    }

    private var surfaceColor: Color {
        switch role {
        case .panel: return LuminousCardTheme.canvas
        case .card: return LuminousCardTheme.midnight
        case .control: return LuminousCardTheme.raised
        }
    }

    private var surfaceOpacity: Double {
        switch role {
        case .panel: return 0.96 - transparency * 0.24
        case .card: return 0.96 - transparency * 0.20
        case .control: return 0.92 - transparency * 0.22
        }
    }
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tint: Color = LuminousCardTheme.azure

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(cornerRadius, 16), style: .continuous)
        content
            .background(LuminousCardSurface(shape: shape, accent: tint))
            .clipShape(shape)
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 12, tint: Color = LuminousCardTheme.azure) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

struct IslandIconButton: View {
    let symbol: String
    var isActive = false
    var help: String = ""
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.white.opacity(0.75))
                .frame(width: 26, height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.12 : (isActive ? 0.07 : 0)))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(isHovering ? 0.10 : 0), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .help(help)
    }
}

struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(Color.white)
            .background(
                Capsule().fill(prominent
                               ? LuminousCardTheme.azure
                               : Color.white.opacity(isHovering ? 0.16 : 0.10))
            )
            .scaleEffect(isHovering ? 1.025 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { isHovering = hovering }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
