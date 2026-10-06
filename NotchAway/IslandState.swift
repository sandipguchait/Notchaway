import SwiftUI

struct IslandGeometry: Equatable {
    var notchSize: CGSize
    var hasNotch: Bool
}

@MainActor
final class IslandState: ObservableObject {
    @Published var isExpanded = false
    /// 0 is the full dashboard. 1 is minimized into the notch.
    @Published var genieProgress: CGFloat = 0
    /// Skips the layout spring for the single frame where the panel snaps between sizes.
    @Published var prefersInstantLayout = false
    @Published var selectedTab: IslandTab = .home
    @Published var isPinned = false
    @Published var isDropTargeted = false
    @Published var geometry = IslandGeometry(notchSize: CGSize(width: 185, height: 32), hasNotch: true)
    @Published private(set) var hud: HUDService.Event?
    @Published private(set) var toast: String?

    private var hudTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    func showHUD(_ event: HUDService.Event) {
        hud = event
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

@MainActor
enum IslandSizing {
    static let expanded = CGSize(width: 620, height: 294)
    static let closedEar: CGFloat = 8
    static let expandedEar: CGFloat = 14
    static let toastHeight: CGFloat = 28

    static func sideWidth(state: IslandState,
                          nowPlaying: NowPlayingService,
                          timer: FocusTimerService,
                          keepAwake: KeepAwakeService) -> CGFloat {
        let height = state.geometry.notchSize.height
        if state.hud != nil { return 76 }
        if timer.isActive { return max(height + 10, 60) }
        if nowPlaying.isPlaying || keepAwake.isActive { return height + 8 }
        return 0
    }

    static func size(state: IslandState,
                     nowPlaying: NowPlayingService,
                     timer: FocusTimerService,
                     keepAwake: KeepAwakeService) -> CGSize {
        if state.isExpanded { return expanded }
        return closedSize(state: state, nowPlaying: nowPlaying, timer: timer, keepAwake: keepAwake)
    }

    static func closedSize(state: IslandState,
                           nowPlaying: NowPlayingService,
                           timer: FocusTimerService,
                           keepAwake: KeepAwakeService) -> CGSize {
        let geometry = state.geometry
        let ear = geometry.hasNotch ? closedEar : 0
        let side = sideWidth(state: state, nowPlaying: nowPlaying, timer: timer, keepAwake: keepAwake)
        var width = geometry.notchSize.width + side * 2 + ear * 2
        var height = geometry.notchSize.height
        if state.toast != nil {
            width = max(width, 320)
            height += toastHeight
        }
        return CGSize(width: width, height: height)
    }
}

/// Notch silhouette: concave "ears" at the top corners that blend into the screen edge, rounded bottom corners.
struct IslandShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set {
            earRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = min(earRadius, rect.width / 4, rect.height / 2)
        let bottom = max(0, min(bottomRadius, (rect.width - ear * 2) / 2, rect.height - ear))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                          control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
