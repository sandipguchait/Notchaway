import AppKit
import AudioToolbox
import CoreAudio

/// Watches output volume (CoreAudio listeners) and built-in display brightness (polled), and
/// reports changes so the island can show its own HUD. The stock macOS HUD still appears;
/// suppressing it would require intercepting media keys with Accessibility access.
@MainActor
final class HUDService: ObservableObject {
    enum Kind: Equatable {
        case volume, brightness
    }

    struct Event: Equatable {
        var kind: Kind
        var value: Float
        var muted: Bool

        var symbol: String {
            switch kind {
            case .brightness:
                return value < 0.3 ? "sun.min.fill" : "sun.max.fill"
            case .volume:
                if muted || value <= 0.001 { return "speaker.slash.fill" }
                if value < 0.34 { return "speaker.wave.1.fill" }
                if value < 0.67 { return "speaker.wave.2.fill" }
                return "speaker.wave.3.fill"
            }
        }
    }

    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var brightness: Float = 0

    var onChange: ((Event) -> Void)?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var brightnessTimer: Timer?
    private var running = false

    func start() {
        guard !running else { return }
        running = true

        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.attachToDefaultDevice()
            }
        }
        defaultDeviceListener = defaultListener
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultListener)
        attachToDefaultDevice()

        if let value = Brightness.get() { brightness = value }
        if Brightness.isAvailable {
            brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollBrightness() }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        detachFromDevice()
        if let defaultDeviceListener {
            var address = Self.defaultDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener)
        }
        defaultDeviceListener = nil
        brightnessTimer?.invalidate()
        brightnessTimer = nil
    }

    // MARK: Volume

    func setVolume(_ value: Float) {
        var volume = Float32(min(max(value, 0), 1))
        var address = Self.volumeAddress
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if isMuted, volume > 0 { setMuted(false) }
    }

    func toggleMute() {
        if !running { readVolume(notify: false) }
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.muteAddress
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        readVolume(notify: running)
    }

    private func attachToDefaultDevice() {
        detachFromDevice()
        device = Self.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.readVolume(notify: true) }
        }
        deviceListener = listener
        var volumeAddress = Self.volumeAddress
        AudioObjectAddPropertyListenerBlock(device, &volumeAddress, .main, listener)
        var muteAddress = Self.muteAddress
        AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, listener)
        readVolume(notify: false)
    }

    private func detachFromDevice() {
        guard let deviceListener, device != kAudioObjectUnknown else { return }
        var volumeAddress = Self.volumeAddress
        AudioObjectRemovePropertyListenerBlock(device, &volumeAddress, .main, deviceListener)
        var muteAddress = Self.muteAddress
        AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, deviceListener)
        self.deviceListener = nil
    }

    private func readVolume(notify: Bool) {
        if device == kAudioObjectUnknown { device = Self.defaultOutputDevice() }

        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return }

        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = Self.muteAddress
        let hasMute = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr
        let muted = hasMute && mute != 0

        let changed = abs(value - volume) > 0.001 || muted != isMuted
        volume = value
        isMuted = muted
        if notify && changed {
            onChange?(Event(kind: .volume, value: value, muted: muted))
        }
    }

    // MARK: Brightness

    func setBrightness(_ value: Float) {
        Brightness.set(min(max(value, 0), 1))
        pollBrightness()
    }

    private func pollBrightness() {
        guard let value = Brightness.get(), abs(value - brightness) > 0.004 else { return }
        brightness = value
        onChange?(Event(kind: .brightness, value: value, muted: false))
    }

    // MARK: CoreAudio helpers

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultDeviceAddress
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }
}

/// Built-in display brightness through the private DisplayServices framework, loaded lazily so
/// the app still runs if Apple removes it.
@MainActor
private enum Brightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Getter? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: Getter.self) }
    private static let setter: Setter? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: Setter.self) }

    private static var display: CGDirectDisplayID? {
        NSScreen.screens.first(where: \.isBuiltIn)?.displayID
    }

    static var isAvailable: Bool { getter != nil && display != nil }

    static func get() -> Float? {
        guard let getter, let display else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let setter, let display else { return }
        _ = setter(display, value)
    }
}
