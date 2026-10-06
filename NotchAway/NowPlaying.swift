import AppKit
import SwiftUI

/// Apple Music and Spotify via AppleScript. Scripts only run while the player is already open,
/// because `tell application` would otherwise launch it.
@MainActor
final class NowPlayingService: ObservableObject {
    enum Player: String, CaseIterable, Sendable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var appName: String { self == .music ? "Music" : "Spotify" }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    private struct Snapshot: Sendable {
        let player: Player
        let isPlaying: Bool
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let position: Double
        let artworkURL: String?
    }

    @Published private(set) var player: Player?
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?

    private var position: Double = 0
    private var positionDate = Date()
    private var artworkKey: String?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "NotchAway.NowPlaying", qos: .userInitiated)

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func currentPosition(at date: Date) -> Double {
        guard let track else { return 0 }
        let value = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, value), max(track.duration, 0))
    }

    func refresh() {
        let running = Player.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty
        }
        guard !running.isEmpty else {
            clear()
            return
        }

        queue.async { [weak self] in
            var best: Snapshot?
            for player in running {
                guard let snapshot = Self.fetch(player) else { continue }
                if snapshot.isPlaying {
                    best = snapshot
                    break
                }
                if best == nil { best = snapshot }
            }
            let result = best
            Task { @MainActor in self?.apply(result) }
        }
    }

    // MARK: Controls

    func playPause() {
        isPlaying.toggle()
        position = currentPosition(at: Date())
        positionDate = Date()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        position = seconds
        positionDate = Date()
        send("set player position to \(seconds)")
    }

    func openPlayer() {
        guard let player,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first else { return }
        app.activate(options: [])
    }

    func launch(_ player: Player) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func isInstalled(_ player: Player) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) != nil
    }

    private func send(_ command: String) {
        guard let player else { return }
        let source = "tell application \"\(player.appName)\" to \(command)"
        queue.async { [weak self] in
            _ = Self.run(source)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.refresh()
            }
        }
    }

    // MARK: State

    private func clear() {
        if player != nil { player = nil }
        if track != nil { track = nil }
        if isPlaying { isPlaying = false }
        if artwork != nil { artwork = nil }
        artworkKey = nil
    }

    private func apply(_ snapshot: Snapshot?) {
        guard let snapshot else {
            clear()
            return
        }
        if player != snapshot.player { player = snapshot.player }
        if isPlaying != snapshot.isPlaying { isPlaying = snapshot.isPlaying }
        let newTrack = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, duration: snapshot.duration)
        if track != newTrack { track = newTrack }
        position = snapshot.position
        positionDate = Date()

        let key = "\(snapshot.player.rawValue)|\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
            loadArtwork(for: snapshot, key: key)
        }
    }

    private func loadArtwork(for snapshot: Snapshot, key: String) {
        switch snapshot.player {
        case .music:
            queue.async { [weak self] in
                let data = Self.run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data
                Task { @MainActor in
                    guard let self, self.artworkKey == key, let data else { return }
                    self.artwork = NSImage(data: data)
                }
            }
        case .spotify:
            guard let string = snapshot.artworkURL, let url = URL(string: string) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                Task { @MainActor in
                    guard let self, self.artworkKey == key, let data else { return }
                    self.artwork = NSImage(data: data)
                }
            }.resume()
        }
    }

    // MARK: AppleScript

    nonisolated private static func fetch(_ player: Player) -> Snapshot? {
        let source: String
        switch player {
        case .music:
            source = """
            tell application "Music"
                if player state is stopped then return "stopped"
                set t to current track
                return {player state as text, name of t, artist of t, album of t, duration of t, player position, ""}
            end tell
            """
        case .spotify:
            source = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set t to current track
                return {player state as text, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t}
            end tell
            """
        }

        guard let result = run(source), result.numberOfItems >= 6 else { return nil }
        func string(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
        func number(_ index: Int) -> Double { result.atIndex(index)?.doubleValue ?? 0 }

        let artwork = string(7)
        return Snapshot(
            player: player,
            isPlaying: string(1) == "playing",
            title: string(2),
            artist: string(3),
            album: string(4),
            duration: number(5),
            position: number(6),
            artworkURL: artwork.isEmpty ? nil : artwork
        )
    }

    nonisolated private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject private var player: NowPlayingService
    @State private var scrubValue: Double?

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(image: player.artwork, size: 104, cornerRadius: 14)
                .onTapGesture { player.openPlayer() }

            VStack(alignment: .leading, spacing: 6) {
                if let track = player.track {
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let position = scrubValue ?? player.currentPosition(at: context.date)
                        VStack(spacing: 2) {
                            Slider(
                                value: Binding(get: { position }, set: { scrubValue = $0 }),
                                in: 0...max(track.duration, 1),
                                onEditingChanged: { editing in
                                    if !editing, let value = scrubValue {
                                        player.seek(to: value)
                                        scrubValue = nil
                                    }
                                }
                            )
                            .controlSize(.mini)
                            .tint(.white)
                            HStack {
                                Text(Format.clock(position))
                                Spacer()
                                Text("-" + Format.clock(max(0, track.duration - position)))
                            }
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 24) {
                        controlButton("backward.fill", size: 16) { player.previous() }
                        controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 22) { player.playPause() }
                        controlButton("forward.fill", size: 16) { player.next() }
                        Spacer()
                        Text(player.player?.appName ?? "")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } else {
                    Text("Nothing playing")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Play something in Apple Music or Spotify")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        PillButton(title: "Music", symbol: "music.note") { player.launch(.music) }
                        if player.isInstalled(.spotify) {
                            PillButton(title: "Spotify", symbol: "dot.radiowaves.left.and.right") { player.launch(.spotify) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .cardBackground(cornerRadius: 20, tint: LuminousCardTheme.magenta)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
