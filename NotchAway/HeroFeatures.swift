import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreImage
import CoreWLAN
import Darwin
import IOKit.ps
import Network
import ScreenCaptureKit
import Security
import SwiftUI
import UserNotifications

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Adaptive productivity services

@MainActor
final class HeroFeaturesService: ObservableObject {
    enum ContextKind: String {
        case xcode, browser, meeting, creative, general

        var title: String {
            switch self {
            case .xcode: return "Developer Context"
            case .browser: return "Browser Context"
            case .meeting: return "Meeting Context"
            case .creative: return "Creative Context"
            case .general: return "App Context"
            }
        }

        var symbol: String {
            switch self {
            case .xcode: return "hammer.fill"
            case .browser: return "globe"
            case .meeting: return "video.fill"
            case .creative: return "paintbrush.fill"
            case .general: return "app.fill"
            }
        }
    }

    struct BrowserTab: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let url: URL
    }

    struct PowerDrain: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let cpu: Double
    }

    struct MediaApp: Identifiable, Equatable {
        enum Control: Equatable {
            case music, spotify, chrome, safari, unavailable
        }

        let id: String
        let name: String
        let symbol: String
        let control: Control
        var volume: Double

        var isControllable: Bool { control != .unavailable }
    }

    @Published private(set) var frontmostName = "Desktop"
    @Published private(set) var frontmostBundleID = ""
    @Published private(set) var contextKind: ContextKind = .general
    @Published private(set) var browserTabs: [BrowserTab] = []
    @Published private(set) var gitSummary = "Choose a project folder to enable Git status"
    @Published private(set) var developerActionStatus: String?

    @Published var focusShieldEnabled: Bool {
        didSet { defaults.set(focusShieldEnabled, forKey: Key.focusShield); updateFocusShield() }
    }
    @Published var distractingApps: String {
        didSet { defaults.set(distractingApps, forKey: Key.distractingApps) }
    }
    @Published private(set) var pausedByShield = false

    @Published var meetingAttendees: Int {
        didSet { defaults.set(meetingAttendees, forKey: Key.meetingAttendees) }
    }
    @Published var meetingHourlyRate: Double {
        didSet { defaults.set(meetingHourlyRate, forKey: Key.meetingRate) }
    }
    @Published var meetingAutoDetect: Bool {
        didSet { defaults.set(meetingAutoDetect, forKey: Key.meetingAutoDetect) }
    }
    @Published private(set) var meetingStart: Date?

    @Published var batteryLimit: Int {
        didSet { defaults.set(batteryLimit, forKey: Key.batteryLimit); batteryAlertSent = false }
    }
    @Published var batteryGuardianEnabled: Bool {
        didSet { defaults.set(batteryGuardianEnabled, forKey: Key.batteryGuardian) }
    }
    @Published private(set) var batteryLevel = 0
    @Published private(set) var batteryIsCharging = false
    @Published private(set) var batteryTimeText = "Checking…"
    @Published private(set) var powerDrains: [PowerDrain] = []

    @Published private(set) var isDictating = false
    @Published private(set) var wifiName = "No Wi-Fi"
    @Published var wifiPassword = ""
    @Published private(set) var phoneShareURL: URL?
    @Published private(set) var isScreenRecording = false
    @Published private(set) var screenRecordingStatus = "Ready to record"
    @Published private(set) var lastScreenRecordingURL: URL?

    @Published var callAwareDNDEnabled: Bool {
        didSet { defaults.set(callAwareDNDEnabled, forKey: Key.callAwareDND) }
    }
    @Published var dndShortcutName: String {
        didSet { defaults.set(dndShortcutName, forKey: Key.dndShortcut) }
    }
    @Published private(set) var mediaApps: [MediaApp] = []
    @Published var aiInput = ""
    @Published private(set) var aiOutput = ""
    @Published private(set) var aiIsWorking = false
    @Published private(set) var aiCanRun = false
    @Published private(set) var aiAvailabilityTitle = "CHECKING"
    @Published private(set) var aiAvailabilityMessage = "Checking Apple Intelligence availability…"

    var onEvent: ((String) -> Void)?

    private let timer: FocusTimerService
    private let notes: NotesService
    private let captions: LiveCaptionService
    private let shelf: ShelfService
    private let defaults = UserDefaults.standard
    private let shield = FocusShieldOverlayController()
    private var workspaceObserver: NSObjectProtocol?
    private var runtimeTimer: Timer?
    private var mediaTimer: Timer?
    private var nativeScreenRecorder: AnyObject?
    private var phoneServer: LocalFileShareServer?
    private var batteryAlertSent = false
    private var lastCallAppActive = false
    private var cancellables = Set<AnyCancellable>()

    private enum Key {
        static let focusShield = "hero.focusShield"
        static let distractingApps = "hero.distractingApps"
        static let meetingAttendees = "hero.meetingAttendees"
        static let meetingRate = "hero.meetingRate"
        static let meetingAutoDetect = "hero.meetingAutoDetect"
        static let batteryLimit = "hero.batteryLimit"
        static let batteryGuardian = "hero.batteryGuardian"
        static let developerFolder = "hero.developerFolder"
        static let callAwareDND = "hero.callAwareDND"
        static let dndShortcut = "hero.dndShortcut"
    }

    init(timer: FocusTimerService,
         notes: NotesService,
         captions: LiveCaptionService,
         shelf: ShelfService) {
        self.timer = timer
        self.notes = notes
        self.captions = captions
        self.shelf = shelf
        focusShieldEnabled = defaults.bool(forKey: Key.focusShield)
        distractingApps = defaults.string(forKey: Key.distractingApps) ?? "Discord, Reddit, Steam, X, Instagram, TikTok"
        meetingAttendees = max(1, defaults.object(forKey: Key.meetingAttendees) as? Int ?? 6)
        meetingHourlyRate = max(0, defaults.object(forKey: Key.meetingRate) as? Double ?? 75)
        meetingAutoDetect = defaults.bool(forKey: Key.meetingAutoDetect)
        batteryLimit = min(max(defaults.object(forKey: Key.batteryLimit) as? Int ?? 80, 50), 100)
        batteryGuardianEnabled = defaults.object(forKey: Key.batteryGuardian) as? Bool ?? true
        callAwareDNDEnabled = defaults.bool(forKey: Key.callAwareDND)
        dndShortcutName = defaults.string(forKey: Key.dndShortcut) ?? ""
    }

    func start() {
        refreshFrontmostApp()
        refreshBattery()
        refreshMediaApps()
        refreshPowerDrains()
        refreshAIAvailability()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFrontmostApp() }
        }

        timer.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.updateFocusShield()
                }
            }
            .store(in: &cancellables)

        runtimeTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBattery()
                self?.updateFocusShield()
                self?.refreshAIAvailability()
            }
        }
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMediaApps() }
        }
    }

    // MARK: Context Island

    func refreshFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        frontmostName = app.localizedName ?? "App"
        frontmostBundleID = app.bundleIdentifier ?? ""
        contextKind = Self.kind(for: frontmostBundleID, name: frontmostName)

        if contextKind == .xcode { refreshGitStatus() }
        if contextKind == .browser { refreshBrowserTabs() }

        handleFocusDrift()

        let callApp = contextKind == .meeting
        if callApp, meetingAutoDetect, meetingStart == nil { startMeeting() }
        if callApp, !lastCallAppActive, callAwareDNDEnabled, !dndShortcutName.isEmpty {
            ShortcutsRunner.run(dndShortcutName)
            onEvent?("Call detected — running \(dndShortcutName)")
        }
        lastCallAppActive = callApp
    }

    var developerFolder: URL? {
        guard let path = defaults.string(forKey: Key.developerFolder), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    func chooseDeveloperFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: Key.developerFolder)
        refreshGitStatus()
    }

    func refreshGitStatus() {
        guard let folder = developerFolder else {
            gitSummary = "Choose a project folder to enable Git status"
            return
        }
        gitSummary = "Refreshing Git status…"
        Task {
            let output = await Self.runProcess("/usr/bin/git", ["-C", folder.path, "status", "--short", "--branch"])
            let lines = output.split(separator: "\n")
            let branch = lines.first.map(String.init) ?? "Not a Git repository"
            let changes = max(0, lines.count - 1)
            gitSummary = changes == 0 ? "\(branch) · clean" : "\(branch) · \(changes) changed"
        }
    }

    func buildDeveloperProject() {
        guard let folder = developerFolder else { chooseDeveloperFolder(); return }
        developerActionStatus = "Building…"
        Task {
            let projects = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let project = projects.first(where: { $0.pathExtension == "xcodeproj" }) else {
                developerActionStatus = "No .xcodeproj found"
                return
            }
            let scheme = project.deletingPathExtension().lastPathComponent
            let output = await Self.runProcess("/usr/bin/xcodebuild", ["-project", project.path, "-scheme", scheme,
                                                                      "CODE_SIGNING_ALLOWED=NO", "build"])
            developerActionStatus = output.contains("BUILD SUCCEEDED") ? "Build succeeded" : "Build failed"
            onEvent?(developerActionStatus ?? "Build finished")
        }
    }

    func refreshBrowserTabs() {
        let browser = frontmostBundleID
        guard browser == "com.apple.Safari" || browser == "com.google.Chrome" else {
            browserTabs = []
            return
        }
        Task {
            let script: String
            if browser == "com.apple.Safari" {
                script = """
                tell application "Safari"
                    set output to ""
                    repeat with w in windows
                        repeat with t in tabs of w
                            set output to output & (name of t) & "|||" & (URL of t) & linefeed
                        end repeat
                    end repeat
                    return output
                end tell
                """
            } else {
                script = """
                tell application "Google Chrome"
                    set output to ""
                    repeat with w in windows
                        repeat with t in tabs of w
                            set output to output & (title of t) & "|||" & (URL of t) & linefeed
                        end repeat
                    end repeat
                    return output
                end tell
                """
            }
            let output = await Self.runProcess("/usr/bin/osascript", ["-e", script])
            browserTabs = output.split(separator: "\n").compactMap { line in
                let pieces = line.components(separatedBy: "|||")
                guard pieces.count == 2, let url = URL(string: pieces[1]) else { return nil }
                return BrowserTab(title: pieces[0], url: url)
            }
        }
    }

    // MARK: Focus Shield

    private func handleFocusDrift() {
        guard focusShieldEnabled, timer.mode == .focus else {
            pausedByShield = false
            updateFocusShield()
            return
        }
        let haystack = "\(frontmostName) \(frontmostBundleID)".lowercased()
        let isDistracting = distractingApps
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .contains { haystack.contains($0) }

        if isDistracting, timer.isRunning {
            timer.pause()
            pausedByShield = true
            onEvent?("Focus paused — \(frontmostName) is on your distraction list")
        } else if !isDistracting, pausedByShield, !timer.isRunning {
            pausedByShield = false
            timer.resume()
            onEvent?("Welcome back — focus resumed")
        }
        updateFocusShield()
    }

    private func updateFocusShield() {
        let active = focusShieldEnabled && timer.mode == .focus && timer.isRunning
        shield.setActive(active, excludingPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    // MARK: Meeting Cost

    func startMeeting() {
        guard meetingStart == nil else { return }
        meetingStart = Date()
    }

    func stopMeeting() {
        meetingStart = nil
    }

    func meetingCost(at date: Date) -> Double {
        guard let meetingStart else { return 0 }
        return max(0, date.timeIntervalSince(meetingStart)) / 3600 * meetingHourlyRate * Double(meetingAttendees)
    }

    // MARK: Battery Guardian

    func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            batteryTimeText = "Battery unavailable"
            return
        }

        let current = info[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let maximum = max(1, info[kIOPSMaxCapacityKey as String] as? Int ?? 100)
        batteryLevel = Int((Double(current) / Double(maximum) * 100).rounded())
        batteryIsCharging = info[kIOPSIsChargingKey as String] as? Bool ?? false
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0 {
            let minutes = Int(estimate / 60)
            batteryTimeText = batteryIsCharging ? "\(minutes)m to full" : "\(minutes / 60)h \(minutes % 60)m remaining"
        } else {
            batteryTimeText = batteryIsCharging ? "Charging" : "On battery"
        }

        if batteryGuardianEnabled, batteryIsCharging, batteryLevel >= batteryLimit, !batteryAlertSent {
            batteryAlertSent = true
            notify(title: "Battery Guardian", body: "Battery reached \(batteryLevel)%. Consider unplugging your Mac.")
            onEvent?("Battery reached \(batteryLevel)% — time to unplug")
        }
        if batteryLevel < batteryLimit - 3 { batteryAlertSent = false }
        refreshPowerDrains()
    }

    private func refreshPowerDrains() {
        // NSWorkspace can briefly return more than one terminated application with
        // processIdentifier == -1. Dictionary(uniqueKeysWithValues:) traps on those
        // duplicate keys, so collect only live PIDs and tolerate duplicate snapshots.
        var names: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0, let name = app.localizedName, !name.isEmpty else { continue }
            names[pid] = name
        }
        Task {
            let output = await Self.runProcess("/bin/ps", ["-axo", "pid=,%cpu="])
            let values: [PowerDrain] = output.split(separator: "\n").compactMap { line in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, let pid = Int32(parts[0]), let cpu = Double(parts[1]), cpu > 0.1,
                      let name = names[pid] else { return nil }
                return PowerDrain(name: name, cpu: cpu)
            }
            powerDrains = Array(values.sorted { $0.cpu > $1.cpu }.prefix(3))
        }
    }

    // MARK: Media mixer

    func refreshMediaApps() {
        let activeProcesses = Self.activeOutputProcesses()
        let runningApps = NSWorkspace.shared.runningApplications
        var discovered: [String: MediaApp] = [:]

        for process in activeProcesses {
            guard process.pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let running = runningApps.first(where: { $0.processIdentifier == process.pid }) ??
                runningApps
                    .filter { candidate in
                        guard let id = candidate.bundleIdentifier, !id.isEmpty else { return false }
                        return process.bundleID == id || process.bundleID.hasPrefix(id + ".")
                    }
                    .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            let name = running?.localizedName ?? process.bundleID.split(separator: ".").last.map(String.init) ?? "Audio"
            let identity = Self.mediaIdentity(bundleID: process.bundleID, name: name)
            guard identity.id != Bundle.main.bundleIdentifier else { continue }
            let previous = mediaApps.first(where: { $0.id == identity.id })
            let stored = defaults.object(forKey: "hero.mediaVolume.\(identity.id)") as? Double
            let volume = previous?.volume ?? stored ?? 1
            discovered[identity.id] = MediaApp(id: identity.id, name: identity.name, symbol: identity.symbol,
                                               control: identity.control, volume: volume)
        }

        // Process objects arrived in macOS 14.2. Preserve the original discovery
        // behavior on older systems so Music and Spotify remain usable there.
        if #unavailable(macOS 14.2) {
            let legacy: [(String, String, String, MediaApp.Control)] = [
                ("com.apple.Music", "Music", "music.note", .music),
                ("com.spotify.client", "Spotify", "waveform", .spotify)
            ]
            for target in legacy where runningApps.contains(where: { $0.bundleIdentifier == target.0 }) {
                let previous = mediaApps.first(where: { $0.id == target.0 })
                discovered[target.0] = MediaApp(id: target.0, name: target.1, symbol: target.2,
                                                 control: target.3, volume: previous?.volume ?? 1)
            }
        }

        let oldIDs = Set(mediaApps.map(\.id))
        mediaApps = discovered.values.sorted {
            if $0.isControllable != $1.isControllable { return $0.isControllable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        for app in mediaApps where !oldIDs.contains(app.id) && (app.control == .music || app.control == .spotify) {
            readMediaVolume(for: app)
        }
    }

    func setMediaVolume(_ volume: Double, for bundleID: String) {
        guard let index = mediaApps.firstIndex(where: { $0.id == bundleID }) else { return }
        mediaApps[index].volume = min(max(volume, 0), 1)
        let value = Int((mediaApps[index].volume * 100).rounded())
        defaults.set(mediaApps[index].volume, forKey: "hero.mediaVolume.\(bundleID)")
        let control = mediaApps[index].control
        Task {
            let script: String
            switch control {
            case .music:
                script = "tell application \"Music\" to set sound volume to \(value)"
            case .spotify:
                script = "tell application \"Spotify\" to set sound volume to \(value)"
            case .chrome:
                script = Self.browserVolumeScript(application: "Google Chrome", volume: mediaApps[index].volume)
            case .safari:
                script = Self.browserVolumeScript(application: "Safari", volume: mediaApps[index].volume)
            case .unavailable:
                return
            }
            let result = await Self.runProcess("/usr/bin/osascript", ["-e", script])
            if result.localizedCaseInsensitiveContains("error") || result.localizedCaseInsensitiveContains("not allowed") {
                if control == .chrome {
                    onEvent?("In Chrome, enable View › Developer › Allow JavaScript from Apple Events")
                } else if control == .safari {
                    onEvent?("In Safari, enable Develop › Allow JavaScript from Apple Events")
                }
            }
        }
    }

    private func readMediaVolume(for app: MediaApp) {
        let appName = app.control == .music ? "Music" : "Spotify"
        Task {
            let value = await Self.runProcess("/usr/bin/osascript", ["-e", "tell application \"\(appName)\" to get sound volume"])
            guard let volume = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let index = mediaApps.firstIndex(where: { $0.id == app.id }) else { return }
            mediaApps[index].volume = min(max(volume / 100, 0), 1)
        }
    }

    // MARK: Dictation, Wi-Fi and phone transfer

    func toggleDictation() {
        if isDictating {
            captions.stop()
            isDictating = false
            let text = captions.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                notes.add(text: "Dictation · \(Date().formatted(date: .abbreviated, time: .shortened))\n\n\(text)")
                onEvent?("Dictation saved to Notes")
            }
        } else {
            // Dictation is microphone-only. Live Translation may have left the shared
            // caption service on call-audio capture, which would incorrectly request
            // Screen & System Audio Recording permission when Dictate is pressed.
            if captions.isRunning { captions.stop() }
            captions.clear()
            captions.setAudioSource(.microphone)
            captions.setTranslationEnabled(false)
            captions.start()
            isDictating = true
        }
    }

    func refreshWiFi() {
        wifiName = CWWiFiClient.shared().interface()?.ssid() ?? "No Wi-Fi"
    }

    var wifiQRCode: NSImage? {
        guard wifiName != "No Wi-Fi" else { return nil }
        let payload = "WIFI:T:WPA;S:\(Self.escapeWiFi(wifiName));P:\(Self.escapeWiFi(wifiPassword));;"
        return Self.qrImage(for: payload)
    }

    func togglePhoneShare() {
        if phoneServer != nil {
            phoneServer?.stop()
            phoneServer = nil
            phoneShareURL = nil
            return
        }
        let files = shelf.items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            onEvent?("Add files to the Shelf first")
            return
        }
        do {
            let server = try LocalFileShareServer(files: files)
            phoneServer = server
            server.start { [weak self] url in
                Task { @MainActor in
                    self?.phoneShareURL = url
                    if url != nil { self?.onEvent?("Phone share is ready") }
                }
            }
        } catch {
            onEvent?("Could not start phone sharing")
        }
    }

    var phoneQRCode: NSImage? {
        phoneShareURL.flatMap { Self.qrImage(for: $0.absoluteString) }
    }

    // MARK: Quick screen recording

    func toggleScreenRecording() {
        isScreenRecording ? stopScreenRecording() : startScreenRecording()
    }

    func revealLastScreenRecording() {
        guard let url = lastScreenRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startScreenRecording() {
        guard nativeScreenRecorder == nil else { return }

        guard CGPreflightScreenCaptureAccess() else {
            // This call is what registers the current, signed NotchAway build in
            // Privacy & Security. macOS requires the app to restart after access
            // is granted; never begin a capture using the stale process identity.
            let grantedImmediately = CGRequestScreenCaptureAccess()
            if grantedImmediately {
                screenRecordingStatus = "Access granted — quit and reopen NotchAway"
                onEvent?("Restart NotchAway to begin recording")
            } else if Self.isAdHocSigned {
                screenRecordingStatus = "Grant access, then sign with your Personal Team"
                onEvent?("Screen Recording access requested for this temporary build")
            } else {
                screenRecordingStatus = "Grant access in System Settings, then restart NotchAway"
                onEvent?("Screen Recording access requested")
            }
            return
        }

        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let folder = movies.appendingPathComponent("NotchAway Recordings", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            screenRecordingStatus = "Could not create the recordings folder"
            onEvent?(screenRecordingStatus)
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let outputURL = folder.appendingPathComponent("Screen Recording \(formatter.string(from: Date())).mov")

        if #available(macOS 15.0, *) {
            let recorder = NativeScreenRecorder(
                outputURL: outputURL,
                onStarted: { [weak self] in
                    guard let self else { return }
                    self.screenRecordingStatus = "Recording screen…"
                    self.onEvent?("Screen recording started")
                },
                onFinished: { [weak self] error in
                    guard let self else { return }
                    self.nativeScreenRecorder = nil
                    self.isScreenRecording = false
                    if let error {
                        try? FileManager.default.removeItem(at: outputURL)
                        self.screenRecordingStatus = "Could not record — quit and reopen NotchAway once"
                        self.onEvent?("Screen recording failed: \(error.localizedDescription)")
                    } else {
                        self.finishScreenRecording(at: outputURL)
                    }
                }
            )
            nativeScreenRecorder = recorder
            lastScreenRecordingURL = nil
            isScreenRecording = true
            screenRecordingStatus = "Preparing recording…"
            Task { await recorder.start() }
        } else {
            screenRecordingStatus = "Quick recording requires macOS 15 or later"
            onEvent?(screenRecordingStatus)
        }
    }

    private func stopScreenRecording() {
        screenRecordingStatus = "Saving recording…"
        if #available(macOS 15.0, *), let recorder = nativeScreenRecorder as? NativeScreenRecorder {
            recorder.stop()
        }
    }

    private func finishScreenRecording(at outputURL: URL) {
        let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 {
            lastScreenRecordingURL = outputURL
            screenRecordingStatus = "Saved to Movies"
            onEvent?("Screen recording saved")
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            screenRecordingStatus = "Recording cancelled"
            onEvent?("Screen recording cancelled")
        }
    }

    private static var isAdHocSigned: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return true }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let flags = information[kSecCodeInfoFlags as String] as? NSNumber else {
            return true
        }
        let adHocSignatureFlag: UInt32 = 0x0002
        return flags.uint32Value & adHocSignatureFlag != 0
    }

    // MARK: Apple Foundation Models

    func refreshAIAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                aiCanRun = true
                aiAvailabilityTitle = "READY"
                aiAvailabilityMessage = "Apple Intelligence is ready. Processing stays on this Mac."
            case .unavailable(.appleIntelligenceNotEnabled):
                aiCanRun = false
                aiAvailabilityTitle = "TURN ON"
                aiAvailabilityMessage = "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then check again."
            case .unavailable(.deviceNotEligible):
                aiCanRun = false
                aiAvailabilityTitle = "UNSUPPORTED"
                aiAvailabilityMessage = "This Mac isn’t eligible for Apple Intelligence. An Apple-silicon Mac with supported language and region settings is required."
            case .unavailable(.modelNotReady):
                aiCanRun = false
                aiAvailabilityTitle = "DOWNLOADING"
                aiAvailabilityMessage = "Apple’s on-device model is not ready yet. Keep the Mac on Wi-Fi and power, then check again after the download finishes."
            case .unavailable:
                aiCanRun = false
                aiAvailabilityTitle = "UNAVAILABLE"
                aiAvailabilityMessage = "Apple Intelligence is not available for the current device, language, or region settings."
            }
        } else {
            aiCanRun = false
            aiAvailabilityTitle = "NEEDS macOS 26"
            aiAvailabilityMessage = "On-device AI requires macOS 26 or later."
        }
        #else
        aiCanRun = false
        aiAvailabilityTitle = "UNAVAILABLE"
        aiAvailabilityMessage = "This Xcode SDK doesn’t include Apple’s Foundation Models framework."
        #endif
    }

    func runAI(action: String) {
        let input = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { aiOutput = "Paste or type some text first."; return }
        refreshAIAvailability()
        guard aiCanRun else { aiOutput = aiAvailabilityMessage; return }
        aiIsWorking = true
        aiOutput = ""
        Task {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    let session = LanguageModelSession(instructions: "Be concise, accurate, and privacy-conscious. Return plain text.")
                    let response = try await session.respond(to: "\(action):\n\n\(input)")
                    aiOutput = response.content
                } catch {
                    refreshAIAvailability()
                    if error.localizedDescription.localizedCaseInsensitiveContains("assets") {
                        aiCanRun = false
                        aiAvailabilityTitle = "DOWNLOADING"
                        aiAvailabilityMessage = "Apple’s model assets are missing or still downloading. Keep the Mac on Wi-Fi and power, then check again later."
                        aiOutput = aiAvailabilityMessage
                    } else {
                        aiOutput = "Apple Intelligence couldn’t complete this request: \(error.localizedDescription)"
                    }
                }
            } else {
                aiOutput = "On-device AI requires macOS 26 or later."
            }
            #else
            aiOutput = "This Xcode SDK doesn't include Foundation Models."
            #endif
            aiIsWorking = false
        }
    }

    // MARK: Helpers

    nonisolated private static func activeOutputProcesses() -> [(pid: pid_t, bundleID: String)] {
        guard #available(macOS 14.2, *) else { return [] }
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }

        var objectIDs = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let listStatus = objectIDs.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil,
                                       &dataSize, buffer.baseAddress!)
        }
        guard listStatus == noErr else { return [] }

        return objectIDs.compactMap { objectID in
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunningOutput: UInt32 = 0
            var outputSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(objectID, &outputAddress, 0, nil, &outputSize, &isRunningOutput) == noErr,
                  isRunningOutput != 0 else { return nil }

            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0 else { return nil }
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            var unmanagedBundleID: Unmanaged<CFString>?
            let bundleStatus = AudioObjectGetPropertyData(objectID, &bundleAddress, 0, nil,
                                                          &bundleSize, &unmanagedBundleID)
            let bundleID = bundleStatus == noErr
                ? (unmanagedBundleID?.takeRetainedValue() as String? ?? "")
                : ""
            return (pid, bundleID)
        }
    }

    nonisolated private static func mediaIdentity(bundleID: String, name: String)
        -> (id: String, name: String, symbol: String, control: MediaApp.Control) {
        let key = "\(bundleID) \(name)".lowercased()
        if key.contains("com.apple.music") || key.contains(" music") {
            return ("com.apple.Music", "Music", "music.note", .music)
        }
        if key.contains("spotify") {
            return ("com.spotify.client", "Spotify", "waveform", .spotify)
        }
        if key.contains("google.chrome") || key.contains("google chrome") {
            return ("com.google.Chrome", "Google Chrome", "globe", .chrome)
        }
        if key.contains("safari") {
            return ("com.apple.Safari", "Safari", "safari", .safari)
        }

        let cleanName = name
            .replacingOccurrences(of: " Helper (Renderer)", with: "")
            .replacingOccurrences(of: " Helper", with: "")
            .replacingOccurrences(of: " Web Content", with: "")
        let id = bundleID.isEmpty ? "audio.\(cleanName.lowercased())" : bundleID
        let browser = key.contains("firefox") || key.contains("edge") || key.contains("brave") ||
            key.contains("browser") || key.contains("opera") || key.contains("webkit")
        let meeting = key.contains("zoom") || key.contains("teams") || key.contains("webex") || key.contains("facetime")
        return (id, cleanName.isEmpty ? "Audio Process" : cleanName,
                meeting ? "video.fill" : (browser ? "globe" : "speaker.wave.2.fill"), .unavailable)
    }

    nonisolated private static func browserVolumeScript(application: String, volume: Double) -> String {
        let level = min(max(volume, 0), 1)
        let muted = level == 0 ? "true" : "false"
        let javascript = "document.querySelectorAll('video,audio').forEach(function(media){media.volume=\(level);media.muted=\(muted);});"
        if application == "Safari" {
            return """
            tell application "Safari"
                set successCount to 0
                set lastFailure to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            do JavaScript "\(javascript)" in t
                            set successCount to successCount + 1
                        on error failureText
                            set lastFailure to failureText
                        end try
                    end repeat
                end repeat
                if successCount is 0 and lastFailure is not "" then return "ERROR: " & lastFailure
                return "OK"
            end tell
            """
        }
        return """
        tell application "Google Chrome"
            set successCount to 0
            set lastFailure to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        execute t javascript "\(javascript)"
                        set successCount to successCount + 1
                    on error failureText
                        set lastFailure to failureText
                    end try
                end repeat
            end repeat
            if successCount is 0 and lastFailure is not "" then return "ERROR: " & lastFailure
            return "OK"
        end tell
        """
    }

    private func notify(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                          content: content, trigger: nil))
        }
    }

    nonisolated private static func kind(for bundleID: String, name: String) -> ContextKind {
        let value = "\(bundleID) \(name)".lowercased()
        if value.contains("xcode") || value.contains("terminal") || value.contains("iterm") { return .xcode }
        if value.contains("safari") || value.contains("chrome") || value.contains("firefox") || value.contains("arc") { return .browser }
        if value.contains("zoom") || value.contains("teams") || value.contains("facetime") || value.contains("webex") { return .meeting }
        if value.contains("figma") || value.contains("photoshop") || value.contains("illustrator") || value.contains("sketch") { return .creative }
        return .general
    }

    nonisolated private static func runProcess(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }

    nonisolated private static func escapeWiFi(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ":", with: "\\:")
    }

    nonisolated static func qrImage(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
    }
}

// MARK: - Focus shield overlay

private final class FocusShieldOverlayController {
    private var panels: [NSPanel] = []

    @MainActor
    func setActive(_ active: Bool, excludingPID: pid_t?) {
        guard active, let pid = excludingPID, let hole = Self.frontWindowFrame(for: pid) else {
            panels.forEach { $0.orderOut(nil) }
            return
        }
        if panels.count != NSScreen.screens.count {
            panels.forEach { $0.close() }
            panels = NSScreen.screens.map { screen in
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.level = .floating
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
                panel.contentView = ShieldCutoutView(frame: NSRect(origin: .zero, size: screen.frame.size))
                return panel
            }
        }
        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = panels[index]
            panel.setFrame(screen.frame, display: false)
            (panel.contentView as? ShieldCutoutView)?.hole = hole.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            panel.orderFrontRegardless()
        }
    }

    private static func frontWindowFrame(for pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let screenTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return list.compactMap { item -> CGRect? in
            guard item[kCGWindowOwnerPID as String] as? pid_t == pid,
                  item[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = dictionary["X"], let y = dictionary["Y"],
                  let width = dictionary["Width"], let height = dictionary["Height"] else { return nil }
            let quartz = CGRect(x: x, y: y, width: width, height: height)
            guard
                  quartz.width > 180, quartz.height > 100 else { return nil }
            return CGRect(x: quartz.minX, y: screenTop - quartz.maxY,
                          width: quartz.width, height: quartz.height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
}

private final class ShieldCutoutView: NSView {
    var hole: CGRect = .zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if !hole.isEmpty { path.appendRoundedRect(hole.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10) }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.40).setFill()
        path.fill()
    }
}

// MARK: - Local phone sharing

private final class LocalFileShareServer {
    private let files: [URL]
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "NotchAway.PhoneShare")

    init(files: [URL]) throws {
        self.files = files
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start(completion: @escaping @Sendable (URL?) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port,
                      let address = Self.localIPv4(),
                      let url = URL(string: "http://\(address):\(port.rawValue)/\(self.token)") else {
                    completion(nil); return
                }
                completion(url)
            case .failed: completion(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\n").first else { connection.cancel(); return }
            let pieces = firstLine.split(separator: " ")
            guard pieces.count >= 2 else { connection.cancel(); return }
            let path = String(pieces[1])
            if path == "/\(self.token)" || path == "/\(self.token)/" {
                let links = self.files.enumerated().map { index, file in
                    "<li><a href='/\(self.token)/file/\(index)'>\(Self.html(file.lastPathComponent))</a></li>"
                }.joined()
                let html = "<html><meta name='viewport' content='width=device-width'><style>body{font-family:-apple-system;padding:28px;background:#111;color:white}a{color:#72a7ff}li{margin:16px 0}</style><h2>NotchAway</h2><p>Tap a file to download it to this device.</p><ul>\(links)</ul></html>"
                self.send(Data(html.utf8), type: "text/html; charset=utf-8", name: nil, on: connection)
            } else if path.hasPrefix("/\(self.token)/file/"),
                      let index = Int(path.components(separatedBy: "/").last ?? ""), self.files.indices.contains(index),
                      let data = try? Data(contentsOf: self.files[index]) {
                self.send(data, type: "application/octet-stream", name: self.files[index].lastPathComponent, on: connection)
            } else {
                self.send(Data("Not found".utf8), type: "text/plain", name: nil, status: "404 Not Found", on: connection)
            }
        }
    }

    private func send(_ data: Data, type: String, name: String?, status: String = "200 OK", on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        if let name { header += "Content-Disposition: attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: ""))\"\r\n" }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard let interfaceAddress = interface.ifa_addr,
                  interfaceAddress.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let interfaceName = String(cString: interface.ifa_name)
            var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = interfaceAddress.pointee
            if getnameinfo(&socketAddress, socklen_t(socketAddress.sa_len), &address, socklen_t(address.count), nil, 0,
                           NI_NUMERICHOST) == 0 {
                let value = String(cString: address)
                if interfaceName == "en0" { return value }
                fallback = fallback ?? value
            }
        }
        return fallback
    }

    private static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// ScreenCaptureKit records inside NotchAway's own process. This avoids the repeated
// privacy prompt caused by launching /usr/sbin/screencapture as a child process.
@available(macOS 15.0, *)
private final class NativeScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let outputURL: URL
    private let onStarted: @MainActor () -> Void
    private let onFinished: @MainActor (Error?) -> Void
    private let completionLock = NSLock()
    private var hasCompleted = false
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    init(outputURL: URL,
         onStarted: @escaping @MainActor () -> Void,
         onFinished: @escaping @MainActor (Error?) -> Void) {
        self.outputURL = outputURL
        self.onStarted = onStarted
        self.onFinished = onFinished
    }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                    ?? content.displays.first else {
                throw NativeScreenRecordingError.noDisplay
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = display.width
            streamConfiguration.height = display.height
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            streamConfiguration.queueDepth = 6
            streamConfiguration.showsCursor = true
            streamConfiguration.showMouseClicks = true
            streamConfiguration.capturesAudio = true
            streamConfiguration.excludesCurrentProcessAudio = false
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2

            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mov
            outputConfiguration.videoCodecType = .h264

            let recordingOutput = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
            try stream.addRecordingOutput(recordingOutput)
            self.recordingOutput = recordingOutput
            self.stream = stream
            try await stream.startCapture()
        } catch {
            finishOnce(error: error)
        }
    }

    func stop() {
        guard let stream else {
            finishOnce(error: NativeScreenRecordingError.cancelledBeforeStart)
            return
        }
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                finishOnce(error: error)
            }
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in onStarted() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        finishOnce(error: error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finishOnce(error: nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finishOnce(error: error)
    }

    private func finishOnce(error: Error?) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        completionLock.unlock()
        Task { @MainActor in onFinished(error) }
    }
}

private enum NativeScreenRecordingError: LocalizedError {
    case noDisplay
    case cancelledBeforeStart

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display is available to record."
        case .cancelledBeforeStart: return "The recording was cancelled before it started."
        }
    }
}

// MARK: - Context workspace UI

private enum HeroSection: String, CaseIterable, Identifiable {
    case context, focus, audio, battery, meeting, tools, intelligence

    var id: String { rawValue }
    var title: String {
        switch self {
        case .context: return "Context"
        case .focus: return "Shield"
        case .audio: return "Mixer"
        case .battery: return "Battery"
        case .meeting: return "Cost"
        case .tools: return "Tools"
        case .intelligence: return "AI"
        }
    }
    var symbol: String {
        switch self {
        case .context: return "app.badge"
        case .focus: return "shield.lefthalf.filled"
        case .audio: return "slider.horizontal.3"
        case .battery: return "battery.75percent"
        case .meeting: return "dollarsign.circle"
        case .tools: return "wand.and.stars"
        case .intelligence: return "apple.intelligence"
        }
    }
}

struct HeroHubView: View {
    @EnvironmentObject private var hero: HeroFeaturesService
    @State private var section: HeroSection = .context

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 3) {
                ForEach(HeroSection.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { section = item }
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(section == item ? Color.white : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(Capsule().fill(section == item ? Color.white.opacity(0.16) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
            .padding(3)
            .background(AppleGlassSurface(shape: Capsule(), role: .control))

            Group {
                switch section {
                case .context: ContextWorkspaceView()
                case .focus: FocusShieldView()
                case .audio: AppMixerView()
                case .battery: BatteryGuardianView()
                case .meeting: MeetingCostView()
                case .tools: HeroToolsView()
                case .intelligence: OnDeviceAIView()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.99)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ContextWorkspaceView: View {
    @EnvironmentObject private var hero: HeroFeaturesService
    @EnvironmentObject private var services: AppServices

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: contextTint) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: hero.contextKind.symbol)
                            .foregroundStyle(contextTint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hero.frontmostName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(hero.contextKind.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                    }
                    Divider().opacity(0.4)
                    contextContent
                }
            }

            VStack(spacing: 8) {
                HeroCompactAction(title: "Command", subtitle: "⌃⌥K", symbol: "command", tint: .blue) {
                    services.palette.show()
                }
                HeroCompactAction(title: "Dictate", subtitle: hero.isDictating ? "Recording" : "To Notes",
                                  symbol: hero.isDictating ? "stop.circle.fill" : "mic.fill", tint: .orange) {
                    hero.toggleDictation()
                }
                HeroCompactAction(title: hero.isScreenRecording ? "Stop Recording" : "Screen Record",
                                  subtitle: hero.isScreenRecording ? "Recording now" : "Quick capture",
                                  symbol: hero.isScreenRecording ? "stop.circle.fill" : "record.circle",
                                  tint: .red) {
                    hero.toggleScreenRecording()
                }
            }
            .frame(width: 155)
        }
    }

    @ViewBuilder
    private var contextContent: some View {
        switch hero.contextKind {
        case .xcode:
            Text(hero.gitSummary)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                PillButton(title: "Project", symbol: "folder") { hero.chooseDeveloperFolder() }
                PillButton(title: "Refresh", symbol: "arrow.clockwise") { hero.refreshGitStatus() }
                PillButton(title: "Build", symbol: "hammer.fill", prominent: true) { hero.buildDeveloperProject() }
            }
            if let status = hero.developerActionStatus {
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .browser:
            if hero.browserTabs.isEmpty {
                Text("Tab search supports Safari and Google Chrome. macOS may ask for Automation access.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Read Tabs", symbol: "rectangle.stack") { hero.refreshBrowserTabs() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(hero.browserTabs.prefix(5)) { tab in
                            Button { NSWorkspace.shared.open(tab.url) } label: {
                                HStack {
                                    Image(systemName: "globe").foregroundStyle(.blue)
                                    Text(tab.title).lineLimit(1)
                                    Spacer()
                                }
                                .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        case .meeting:
            Text("Keep the call focused and make its cost visible.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                PillButton(title: "Translate Call", symbol: "ear", prominent: true) {
                    services.captions.setAudioSource(.callAudio)
                    services.captions.setTranslationEnabled(true)
                    services.openIsland(tab: .live)
                    if !services.captions.isRunning { services.captions.start() }
                }
                if hero.meetingStart == nil {
                    PillButton(title: "Cost Ticker", symbol: "dollarsign.circle") { hero.startMeeting() }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(hero.meetingCost(at: context.date), format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                            .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    PillButton(title: "Stop", symbol: "stop.fill") { hero.stopMeeting() }
                }
            }
        case .creative:
            Text("Creative profile keeps capture, shelf, and quick notes one gesture away.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                PillButton(title: "Shelf", symbol: "tray.full.fill") { services.openIsland(tab: .shelf) }
                PillButton(title: "Notes", symbol: "note.text") { services.openIsland(tab: .notes) }
                PillButton(title: "Capture", symbol: "mic.fill", prominent: true) { hero.toggleDictation() }
            }
        case .general:
            Text("The island follows your frontmost app and keeps the right actions close.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                PillButton(title: "Clipboard", symbol: "doc.on.clipboard") { services.openIsland(tab: .clipboard) }
                PillButton(title: "Timer", symbol: "timer") { services.openIsland(tab: .timer) }
                PillButton(title: "New Note", symbol: "square.and.pencil", prominent: true) {
                    services.notes.add(); services.openIsland(tab: .notes)
                }
            }
        }
    }

    private var contextTint: Color {
        switch hero.contextKind {
        case .xcode: return .blue
        case .browser: return .cyan
        case .meeting: return .green
        case .creative: return .purple
        case .general: return .orange
        }
    }
}

private struct FocusShieldView: View {
    @EnvironmentObject private var hero: HeroFeaturesService
    @EnvironmentObject private var timer: FocusTimerService

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: hero.focusShieldEnabled ? .blue : LuminousCardTheme.violet) {
                VStack(alignment: .leading, spacing: 9) {
                    CardHeader(title: "Presence-aware Focus Shield", symbol: "shield.lefthalf.filled", tint: .blue,
                               trailing: hero.focusShieldEnabled ? "ON" : "OFF")
                    Toggle("Dim everything except the active window", isOn: $hero.focusShieldEnabled)
                        .toggleStyle(.switch).controlSize(.small)
                    TextField("Distracting apps, comma separated", text: $hero.distractingApps)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Text(hero.pausedByShield ? "Focus paused — return to a work app to resume." :
                            "A distracting app pauses the timer automatically.")
                        .font(.system(size: 10)).foregroundStyle(hero.pausedByShield ? .orange : .secondary)
                }
            }
            LiveCard {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: "Session", symbol: timer.symbol, tint: timer.tint)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        BigNumber(text: timer.displayText(at: context.date), size: 25)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if timer.mode == nil {
                            PillButton(title: "Start Focus", symbol: "play.fill", prominent: true) {
                                timer.startFocus()
                            }
                        } else if timer.isRunning {
                            PillButton(title: "Pause", symbol: "pause.fill") { timer.pause() }
                        } else {
                            PillButton(title: "Resume", symbol: "play.fill", prominent: true) { timer.resume() }
                        }

                        Button {
                            timer.resetTimer()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .frame(width: 28, height: 26)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Reset timer")
                    }
                }
            }
            .frame(width: 180)
        }
    }
}

private struct AppMixerView: View {
    @EnvironmentObject private var hero: HeroFeaturesService

    var body: some View {
        LiveCard(glow: LuminousCardTheme.magenta) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "Per-app Volume Mixer", symbol: "slider.horizontal.3", tint: .pink,
                           trailing: hero.mediaApps.isEmpty ? "LISTENING" : "\(hero.mediaApps.count) LIVE")
                if hero.mediaApps.isEmpty {
                    EmptyStateView(symbol: "speaker.wave.2", title: "No controllable media app is playing",
                                   subtitle: "Start audio in a browser or another app. Live sources appear automatically.")
                } else {
                    ScrollView {
                        VStack(spacing: 7) {
                            ForEach(hero.mediaApps) { app in
                                HStack(spacing: 10) {
                                    Image(systemName: app.symbol).foregroundStyle(.pink).frame(width: 20)
                                    Text(app.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 105, alignment: .leading)
                                        .lineLimit(1)
                                    if app.isControllable {
                                        Image(systemName: app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                        Slider(value: Binding(
                                            get: { hero.mediaApps.first(where: { $0.id == app.id })?.volume ?? app.volume },
                                            set: { hero.setMediaVolume($0, for: app.id) }
                                        ), in: 0...1)
                                        Text("\(Int((hero.mediaApps.first(where: { $0.id == app.id })?.volume ?? app.volume) * 100))%")
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(.secondary).frame(width: 34)
                                    } else {
                                        Spacer()
                                        Text("LIVE · VIEW ONLY")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    Spacer()
                    Text("Chrome/Safari control webpage media. Music and Spotify use native app volume; other active sources are identified live.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BatteryGuardianView: View {
    @EnvironmentObject private var hero: HeroFeaturesService

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: hero.batteryIsCharging ? .green : LuminousCardTheme.emerald) {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: "Battery Guardian", symbol: "battery.100percent", tint: .green,
                               trailing: "\(hero.batteryLevel)%")
                    HStack {
                        BigNumber(text: "\(hero.batteryLevel)%", size: 30)
                        Spacer()
                        Image(systemName: hero.batteryIsCharging ? "bolt.fill" : "battery.75percent")
                            .font(.system(size: 23)).foregroundStyle(hero.batteryIsCharging ? .green : .secondary)
                    }
                    Text(hero.batteryTimeText).font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Toggle("Alert", isOn: $hero.batteryGuardianEnabled).toggleStyle(.switch).controlSize(.small)
                        Slider(value: Binding(get: { Double(hero.batteryLimit) }, set: { hero.batteryLimit = Int($0) }),
                               in: 50...100, step: 5)
                        Text("\(hero.batteryLimit)%").font(.system(size: 10).monospacedDigit())
                    }
                }
            }
            LiveCard {
                VStack(alignment: .leading, spacing: 7) {
                    CardHeader(title: "Power Pressure", symbol: "gauge.with.dots.needle.67percent", tint: .orange)
                    if hero.powerDrains.isEmpty {
                        Text("No high-CPU apps right now").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        ForEach(hero.powerDrains) { drain in
                            HStack {
                                Text(drain.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%% CPU", drain.cpu))
                                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.orange)
                            }
                        }
                    }
                    Spacer()
                    Text("macOS doesn’t provide a public API to stop charging; Guardian alerts you at the limit.")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

private struct MeetingCostView: View {
    @EnvironmentObject private var hero: HeroFeaturesService

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: hero.meetingStart == nil ? LuminousCardTheme.violet : .green) {
                VStack(alignment: .leading, spacing: 7) {
                    CardHeader(title: "Meeting Cost", symbol: "dollarsign.circle.fill", tint: .green,
                               trailing: hero.meetingStart == nil ? "READY" : "LIVE")
                    if hero.meetingStart == nil {
                        BigNumber(text: "$0.00", size: 29)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(hero.meetingCost(at: context.date), format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
                                .font(.system(size: 29, weight: .bold, design: .rounded).monospacedDigit())
                        }
                    }
                    Text("\(hero.meetingAttendees) people × \(hero.meetingHourlyRate, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))/hr")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if hero.meetingStart == nil {
                        PillButton(title: "Start Ticker", symbol: "play.fill", prominent: true) { hero.startMeeting() }
                    } else {
                        PillButton(title: "Stop & Reset", symbol: "stop.fill") { hero.stopMeeting() }
                    }
                }
            }
            LiveCard {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Attendees: \(hero.meetingAttendees)", value: $hero.meetingAttendees, in: 1...100)
                    HStack {
                        Text("Hourly cost")
                        Spacer()
                        TextField("Rate", value: $hero.meetingHourlyRate, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    Toggle("Auto-start for call apps", isOn: $hero.meetingAutoDetect)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("Recognizes Zoom, Teams, FaceTime, and Webex.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
            .frame(width: 220)
        }
    }
}

private enum ToolDetail { case none, wifi, phone }

private struct HeroToolsView: View {
    @EnvironmentObject private var hero: HeroFeaturesService
    @State private var detail: ToolDetail = .none

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                tool("Dictate", hero.isDictating ? "stop.circle.fill" : "mic.fill", .orange) { hero.toggleDictation() }
                tool("Phone", "iphone.and.arrow.forward", .blue) {
                    if hero.phoneShareURL == nil { hero.togglePhoneShare() }
                    detail = .phone
                }
                tool("Wi-Fi QR", "qrcode", .cyan) { hero.refreshWiFi(); detail = .wifi }
                tool(hero.isScreenRecording ? "Stop" : "Record",
                     hero.isScreenRecording ? "stop.circle.fill" : "record.circle", .red) {
                    hero.toggleScreenRecording()
                }
            }

            if detail == .wifi {
                HStack(spacing: 10) {
                    if let qr = hero.wifiQRCode { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 76, height: 76) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(hero.wifiName).font(.system(size: 12, weight: .semibold))
                        SecureField("Wi-Fi password", text: $hero.wifiPassword).textFieldStyle(.roundedBorder)
                        Text("Scan with Camera to join").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    IslandIconButton(symbol: "xmark", help: "Close") { detail = .none }
                }
                .padding(8).cardBackground(cornerRadius: 18, tint: LuminousCardTheme.azure)
            } else if detail == .phone {
                HStack(spacing: 10) {
                    if let qr = hero.phoneQRCode { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 76, height: 76) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hero.phoneShareURL == nil ? "Add files to the Shelf" : "Scan on your phone")
                            .font(.system(size: 12, weight: .semibold))
                        Text(hero.phoneShareURL?.absoluteString ?? "Then return here and tap Phone again")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                        if hero.phoneShareURL != nil {
                            PillButton(title: "Stop Sharing", symbol: "stop.fill") { hero.togglePhoneShare(); detail = .none }
                        }
                    }
                    Spacer()
                    IslandIconButton(symbol: "xmark", help: "Close") { detail = .none }
                }
                .padding(8).cardBackground(cornerRadius: 18, tint: LuminousCardTheme.violet)
            } else {
                HStack(spacing: 8) {
                    LiveCard {
                        VStack(alignment: .leading, spacing: 7) {
                            CardHeader(title: "Quick Screen Recording", symbol: "record.circle", tint: .red,
                                       trailing: hero.isScreenRecording ? "LIVE" : "READY")
                            Text(hero.screenRecordingStatus)
                                .font(.system(size: 11, weight: .medium))
                            HStack(spacing: 6) {
                                PillButton(title: hero.isScreenRecording ? "Stop & Save" : "Start Recording",
                                           symbol: hero.isScreenRecording ? "stop.fill" : "record.circle",
                                           prominent: true) {
                                    hero.toggleScreenRecording()
                                }
                                if hero.lastScreenRecordingURL != nil {
                                    PillButton(title: "Show in Finder", symbol: "folder") {
                                        hero.revealLastScreenRecording()
                                    }
                                }
                            }
                            Text("Captures the main display and saves to Movies › NotchAway Recordings.")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    LiveCard {
                        VStack(alignment: .leading, spacing: 6) {
                            CardHeader(title: "Call-aware DND", symbol: "moon.fill", tint: .indigo)
                            Toggle("Run Shortcut for call apps", isOn: $hero.callAwareDNDEnabled)
                                .toggleStyle(.switch).controlSize(.small)
                            TextField("Shortcut name", text: $hero.dndShortcutName).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    private func tool(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(
                LuminousCardSurface(
                    shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                    accent: tint
                )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct OnDeviceAIView: View {
    @EnvironmentObject private var hero: HeroFeaturesService

    var body: some View {
        HStack(spacing: 8) {
            LiveCard(glow: LuminousCardTheme.magenta) {
                VStack(alignment: .leading, spacing: 7) {
                    CardHeader(title: "Private On-device AI", symbol: "apple.intelligence", tint: .purple,
                               trailing: hero.aiAvailabilityTitle)
                    TextEditor(text: $hero.aiInput)
                        .font(.system(size: 11))
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(
                            LuminousCardSurface(
                                shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                accent: LuminousCardTheme.violet
                            )
                        )
                    HStack(spacing: 6) {
                        PillButton(title: "Summarize", symbol: "text.alignleft", prominent: true) { hero.runAI(action: "Summarize") }
                        PillButton(title: "Explain Error", symbol: "exclamationmark.triangle") { hero.runAI(action: "Explain this error and suggest a fix") }
                        if !hero.aiCanRun {
                            IslandIconButton(symbol: "arrow.clockwise", help: "Check Apple Intelligence again") {
                                hero.refreshAIAvailability()
                            }
                        }
                    }
                }
            }
            LiveCard {
                VStack(alignment: .leading, spacing: 6) {
                    CardHeader(title: "Result", symbol: "sparkles", tint: .cyan)
                    if hero.aiIsWorking { ProgressView().controlSize(.small) }
                    ScrollView {
                        Text(hero.aiOutput.isEmpty
                             ? (hero.aiCanRun ? "Results stay on this Mac and appear here." : hero.aiAvailabilityMessage)
                             : hero.aiOutput)
                            .font(.system(size: 11)).foregroundStyle(hero.aiOutput.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct HeroCompactAction: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 9).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LuminousCardSurface(
                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    accent: tint
                )
            )
        }
        .buttonStyle(.plain)
    }
}
