import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import SwiftUI

#if canImport(Translation)
import Translation
#endif

/// Live speech-to-text and on-device translation from either the microphone or Mac call audio.
@MainActor
final class LiveCaptionService: ObservableObject {
    enum AudioSource: String, CaseIterable, Identifiable {
        case callAudio
        case microphone

        var id: String { rawValue }
        var title: String { self == .callAudio ? "Call audio" : "Microphone" }
        var symbol: String { self == .callAudio ? "speaker.wave.2.fill" : "mic.fill" }
    }

    struct LanguageOption: Identifiable {
        let code: String
        let shortCode: String
        let name: String
        var id: String { code }
    }

    static let supportedLanguages: [LanguageOption] = [
        .init(code: "en-US", shortCode: "EN", name: "English"),
        .init(code: "es-ES", shortCode: "ES", name: "Spanish"),
        .init(code: "fr-FR", shortCode: "FR", name: "French"),
        .init(code: "de-DE", shortCode: "DE", name: "German"),
        .init(code: "hi-IN", shortCode: "HI", name: "Hindi"),
        .init(code: "it-IT", shortCode: "IT", name: "Italian"),
        .init(code: "ja-JP", shortCode: "JA", name: "Japanese"),
        .init(code: "ko-KR", shortCode: "KO", name: "Korean"),
        .init(code: "pt-BR", shortCode: "PT", name: "Portuguese"),
        .init(code: "zh-CN", shortCode: "ZH", name: "Chinese (Simplified)")
    ]

    @Published private(set) var isRunning = false
    @Published private(set) var transcript = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var message: String?
    @Published private(set) var translationMessage: String?
    @Published private(set) var audioSource: AudioSource
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var sourceLanguageCode: String
    @Published private(set) var targetLanguageCode: String
    @Published private(set) var translationSourceText = ""
    @Published private(set) var translationRequestID = 0

    private enum Key {
        static let audioSource = "captions.audioSource"
        static let translationEnabled = "captions.translationEnabled"
        static let sourceLanguage = "captions.sourceLanguage"
        static let targetLanguage = "captions.targetLanguage"
    }

    private let engine = AVAudioEngine()
    private let defaults = UserDefaults.standard
    private let systemAudioQueue = DispatchQueue(label: "NotchAway.LiveTranslationAudio", qos: .userInitiated)
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var committed = ""
    private var microphoneTapInstalled = false
    private var systemStream: SCStream?
    private var systemOutput: SystemAudioStreamOutput?
    private var translationDebounce: Task<Void, Never>?
    private var levelDecay: Task<Void, Never>?

    init() {
        let storedSource = defaults.string(forKey: Key.audioSource).flatMap(AudioSource.init(rawValue:))
        audioSource = storedSource ?? .callAudio
        translationEnabled = defaults.object(forKey: Key.translationEnabled) as? Bool ?? false
        sourceLanguageCode = defaults.string(forKey: Key.sourceLanguage) ?? "es-ES"
        targetLanguageCode = defaults.string(forKey: Key.targetLanguage) ?? "en-US"
    }

    var recentText: String { String(transcript.suffix(220)) }
    var recentTranslation: String { String(translatedText.suffix(220)) }

    var sourceShortCode: String {
        Self.supportedLanguages.first(where: { $0.code == sourceLanguageCode })?.shortCode ?? "SRC"
    }

    var targetShortCode: String {
        Self.supportedLanguages.first(where: { $0.code == targetLanguageCode })?.shortCode ?? "DST"
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func setAudioSource(_ source: AudioSource) {
        guard source != audioSource else { return }
        let shouldRestart = isRunning
        if shouldRestart { stop() }
        audioSource = source
        defaults.set(source.rawValue, forKey: Key.audioSource)
        if shouldRestart { start() }
    }

    func setTranslationEnabled(_ enabled: Bool) {
        translationEnabled = enabled
        defaults.set(enabled, forKey: Key.translationEnabled)
        translationMessage = nil
        if enabled {
            if #unavailable(macOS 15.0) {
                translationMessage = "On-device translation requires macOS 15 or later."
            }
            scheduleTranslation()
        } else {
            translatedText = ""
            translationDebounce?.cancel()
        }
    }

    func setSourceLanguage(_ code: String) {
        guard code != sourceLanguageCode else { return }
        let shouldRestart = isRunning
        if shouldRestart { stop() }
        sourceLanguageCode = code
        defaults.set(code, forKey: Key.sourceLanguage)
        translatedText = ""
        scheduleTranslation()
        if shouldRestart { start() }
    }

    func setTargetLanguage(_ code: String) {
        guard code != targetLanguageCode else { return }
        targetLanguageCode = code
        defaults.set(code, forKey: Key.targetLanguage)
        translatedText = ""
        scheduleTranslation()
    }

    func start() {
        message = nil
        translationMessage = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.message = "Allow Speech Recognition in System Settings → Privacy & Security"
                    return
                }
                if self.audioSource == .microphone {
                    AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                        Task { @MainActor in
                            guard micGranted else {
                                self.message = "Allow Microphone access in System Settings → Privacy & Security"
                                return
                            }
                            self.begin()
                        }
                    }
                } else {
                    self.begin()
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if engine.isRunning { engine.stop() }
        if microphoneTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        if let stream = systemStream {
            Task { try? await stream.stopCapture() }
        }
        systemStream = nil
        systemOutput = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        committed = transcript
    }

    func clear() {
        transcript = ""
        translatedText = ""
        translationSourceText = ""
        committed = ""
        translationMessage = nil
    }

    func copy() {
        let value = translationEnabled && !translatedText.isEmpty ? translatedText : transcript
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func acceptTranslation(_ text: String, requestID: Int) {
        guard requestID == translationRequestID, translationEnabled else { return }
        translatedText = text
        translationMessage = nil
    }

    func translationFailed(_ error: Error, requestID: Int) {
        guard requestID == translationRequestID, translationEnabled else { return }
        translationMessage = "Translation unavailable: \(error.localizedDescription)"
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: sourceLanguageCode)),
              recognizer.isAvailable else {
            message = "Speech recognition isn't available for the selected language right now"
            return
        }
        committed = transcript
        isRunning = true
        startSegment(using: recognizer)

        if audioSource == .microphone {
            startMicrophoneEngine()
        } else {
            Task { await startSystemAudioCapture() }
        }
    }

    private func startMicrophoneEngine() {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            message = "Couldn't start the microphone"
            stop()
        }
    }

    private func startSystemAudioCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw LiveTranslationError.noDisplay
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.queueDepth = 1
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let output = SystemAudioStreamOutput { [weak self] sampleBuffer in
                guard sampleBuffer.isValid else { return }
                Task { @MainActor in
                    guard let self, self.isRunning, self.audioSource == .callAudio else { return }
                    self.request?.appendAudioSampleBuffer(sampleBuffer)
                    self.pulseSystemAudioLevel()
                }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemAudioQueue)
            systemOutput = output
            systemStream = stream
            try await stream.startCapture()
        } catch {
            message = "Allow Screen & System Audio Recording for NotchAway, then restart the app."
            stop()
        }
    }

    /// Recognition tasks end after a pause or time limit, so each finished segment is committed and a new one starts.
    private func startSegment(using recognizer: SFSpeechRecognizer? = nil) {
        guard isRunning,
              let recognizer = recognizer ?? SFSpeechRecognizer(locale: Locale(identifier: sourceLanguageCode))
        else { return }
        task?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        if audioSource == .microphone {
            let input = engine.inputNode
            if microphoneTapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.rms(buffer)
                Task { @MainActor in self?.level = level }
            }
            microphoneTapInstalled = true
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isRunning else { return }
        if let text, !text.isEmpty {
            transcript = committed.isEmpty ? text : committed + " " + text
            scheduleTranslation()
        }
        if isFinal || failed {
            committed = transcript
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: failed ? 500_000_000 : 50_000_000)
                self?.startSegment()
            }
        }
    }

    private func scheduleTranslation() {
        guard translationEnabled, !recentText.isEmpty else { return }
        let snapshot = recentText
        if sourceLanguageCode == targetLanguageCode {
            translatedText = snapshot
            translationSourceText = snapshot
            return
        }
        translationDebounce?.cancel()
        translationDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self else { return }
            self.translationSourceText = snapshot
            self.translationRequestID += 1
        }
    }

    private func pulseSystemAudioLevel() {
        level = min(1, max(0.22, level + 0.16))
        levelDecay?.cancel()
        levelDecay = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            self?.level = 0.08
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}

private enum LiveTranslationError: Error {
    case noDisplay
}

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        handler(sampleBuffer)
    }
}

struct CaptionsCard: View {
    @EnvironmentObject private var captions: LiveCaptionService

    var body: some View {
        Group {
            #if canImport(Translation)
            if #available(macOS 15.0, *) {
                card.modifier(LiveTranslationTaskModifier(captions: captions))
            } else {
                card
            }
            #else
            card
            #endif
        }
    }

    private var card: some View {
        LiveCard(glow: captions.isRunning ? .orange : LuminousCardTheme.magenta) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    CardHeader(title: captions.translationEnabled ? "Live Translation Ear" : "Live Captions",
                               symbol: captions.translationEnabled ? "ear" : "captions.bubble.fill",
                               tint: .orange,
                               trailing: captions.translationEnabled
                               ? "\(captions.sourceShortCode) → \(captions.targetShortCode)"
                               : nil)
                    AudioLevelBars(level: captions.isRunning ? captions.level : 0)
                        .frame(width: 22, height: 12)
                }

                VStack(alignment: .leading, spacing: 3) {
                    let status = captions.translationMessage ?? captions.message
                    Text(status ?? primaryText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(status != nil || primaryTextIsPlaceholder ? .secondary : .primary)
                        .lineLimit(captions.translationEnabled && !captions.recentText.isEmpty ? 2 : 3)
                    if captions.translationEnabled,
                       !captions.recentText.isEmpty,
                       !captions.recentTranslation.isEmpty {
                        Text(captions.recentText)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 5) {
                    audioSourceMenu
                    translationToggle
                    if captions.translationEnabled { languageMenu }
                    Spacer(minLength: 0)
                    if !captions.transcript.isEmpty {
                        IslandIconButton(symbol: "doc.on.doc", help: "Copy transcript") { captions.copy() }
                        IslandIconButton(symbol: "trash", help: "Clear transcript") { captions.clear() }
                    }
                    Button { captions.toggle() } label: {
                        Image(systemName: captions.isRunning ? "stop.fill" : captions.audioSource.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                    .help(captions.isRunning ? "Stop listening" : "Start listening")
                }
            }
        }
    }

    private var primaryText: String {
        if captions.translationEnabled, !captions.recentTranslation.isEmpty { return captions.recentTranslation }
        if !captions.recentText.isEmpty { return captions.recentText }
        return captions.isRunning ? "Listening…" : "Start to translate speech from a call or your microphone"
    }

    private var primaryTextIsPlaceholder: Bool {
        captions.recentText.isEmpty && captions.recentTranslation.isEmpty
    }

    private var audioSourceMenu: some View {
        Menu {
            ForEach(LiveCaptionService.AudioSource.allCases) { source in
                Button { captions.setAudioSource(source) } label: {
                    Label(source.title, systemImage: source.symbol)
                }
            }
        } label: {
            Label(captions.audioSource.title, systemImage: captions.audioSource.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var translationToggle: some View {
        Button { captions.setTranslationEnabled(!captions.translationEnabled) } label: {
            Label("Translate", systemImage: "character.bubble.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(captions.translationEnabled ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(captions.translationEnabled
                                           ? Color.orange.opacity(0.75)
                                           : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    private var languageMenu: some View {
        Menu {
            Section("Listen to") {
                ForEach(LiveCaptionService.supportedLanguages) { language in
                    Button { captions.setSourceLanguage(language.code) } label: {
                        Text(language.name + (captions.sourceLanguageCode == language.code ? " ✓" : ""))
                    }
                }
            }
            Section("Translate to") {
                ForEach(LiveCaptionService.supportedLanguages) { language in
                    Button { captions.setTargetLanguage(language.code) } label: {
                        Text(language.name + (captions.targetLanguageCode == language.code ? " ✓" : ""))
                    }
                }
            }
        } label: {
            Text("\(captions.sourceShortCode)→\(captions.targetShortCode)")
                .font(.system(size: 9.5, weight: .bold).monospaced())
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct LiveTranslationTaskModifier: ViewModifier {
    @ObservedObject var captions: LiveCaptionService
    @State private var configuration: TranslationSession.Configuration?
    @State private var configuredPair = ""

    func body(content: Content) -> some View {
        content
            .onAppear { triggerTranslation() }
            .onChange(of: captions.translationRequestID) { _ in triggerTranslation() }
            .onChange(of: captions.translationEnabled) { _ in triggerTranslation() }
            .onChange(of: captions.sourceLanguageCode) { _ in triggerTranslation(forceNewPair: true) }
            .onChange(of: captions.targetLanguageCode) { _ in triggerTranslation(forceNewPair: true) }
            .translationTask(configuration) { session in
                let requestID = captions.translationRequestID
                let source = captions.translationSourceText
                guard captions.translationEnabled, !source.isEmpty else { return }
                do {
                    let response = try await session.translate(source)
                    captions.acceptTranslation(response.targetText, requestID: requestID)
                } catch {
                    captions.translationFailed(error, requestID: requestID)
                }
            }
    }

    private func triggerTranslation(forceNewPair: Bool = false) {
        guard captions.translationEnabled, !captions.translationSourceText.isEmpty else {
            configuration = nil
            return
        }
        let pair = "\(captions.sourceLanguageCode)|\(captions.targetLanguageCode)"
        if configuration == nil || configuredPair != pair || forceNewPair {
            configuredPair = pair
            configuration = .init(
                source: Locale.Language(identifier: captions.sourceLanguageCode),
                target: Locale.Language(identifier: captions.targetLanguageCode)
            )
        } else {
            configuration?.invalidate()
        }
    }
}
#endif

private struct AudioLevelBars: View {
    let level: Float

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let weight: [Float] = [0.5, 0.8, 1, 0.8, 0.5]
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 2.5, height: 3 + CGFloat(level * weight[index]) * 9)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
