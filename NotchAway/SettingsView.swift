import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            IslandSettingsPane()
                .tabItem { Label("Island", systemImage: "capsule.fill") }
            FeatureSettingsPane()
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
            NotchHidingSettingsPane()
                .tabItem { Label("Notch Hiding", systemImage: "rectangle.topthird.inset.filled") }
        }
        .frame(minWidth: 540, minHeight: 500)
    }
}

private struct IslandSettingsPane: View {
    @EnvironmentObject private var settings: IslandSettings
    @EnvironmentObject private var controller: NotchController

    var body: some View {
        Form {
            Section("Dynamic Island") {
                Toggle("Show the island around the notch", isOn: $settings.islandEnabled)
                Toggle("Open on hover", isOn: $settings.hoverToOpen)
                Toggle("Show a pill on displays without a notch", isOn: $settings.showPillWithoutNotch)
                Toggle("Hide the island from screenshots and screen sharing", isOn: $settings.hideFromScreenCapture)
            }

            Section("Glass Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Transparency", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Text("\(Int(settings.glassTransparency * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.glassTransparency, in: 0...1, step: 0.05)
                    GlassAppearancePreview()
                        .padding(.top, 4)
                }

                Text("Controls how much of the desktop shows through the island. macOS Reduce Transparency is always respected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                Toggle("Command palette hotkey (⌃⌥K)", isOn: $settings.paletteHotkeyEnabled)
                Text("While the island is open: ⌘1–⌘9 switch tabs, Esc closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System HUD") {
                Toggle("Show volume and brightness changes in the island", isOn: $settings.hudEnabled)
                Text("macOS still shows its own overlay; hiding it would require Accessibility access to intercept the media keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch NotchAway at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlassAppearancePreview: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            LuminousCardTheme.canvas

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Glass")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Live preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(AppleGlassSurface(shape: shape, role: .control))
            .padding(10)
        }
        .frame(height: 72)
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }
}

private struct FeatureSettingsPane: View {
    @EnvironmentObject private var settings: IslandSettings
    @EnvironmentObject private var hero: HeroFeaturesService
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var scores: LiveScoresService
    @EnvironmentObject private var wellness: WellnessService
    @EnvironmentObject private var captions: LiveCaptionService
    @EnvironmentObject private var replay: DayReplayService
    @State private var cityDraft = ""
    @State private var teamDraft = ""

    var body: some View {
        Form {
            Section("Weather & UV") {
                HStack {
                    TextField("City (leave empty to use your location)", text: $cityDraft)
                        .onSubmit { weather.manualCity = cityDraft }
                    Button("Save") { weather.manualCity = cityDraft }
                }
                Toggle("Use Fahrenheit", isOn: $weather.useFahrenheit)
                Text("Forecasts from Open-Meteo. Your location is only used to look up local weather.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live Scores") {
                Picker("League", selection: $scores.leagueID) {
                    ForEach(LiveScoresService.leagues) { league in
                        Text(league.name).tag(league.id)
                    }
                }
                HStack {
                    TextField("Favorite team (e.g. ARS or Lakers)", text: $teamDraft)
                        .onSubmit { scores.favoriteTeam = teamDraft }
                    Button("Save") { scores.favoriteTeam = teamDraft }
                }
            }

            Section("Daily Rings") {
                Stepper("Water goal: \(wellness.waterGoal) glasses (\(String(format: "%.1f", Double(wellness.waterGoal) * WellnessService.glassLiters)) L)",
                        value: $wellness.waterGoal, in: 2...20)
                Stepper("Focus goal: \(wellness.focusGoal) sessions", value: $wellness.focusGoal, in: 1...12)
                Text("Click the water ring on the Home tab to log a glass. Screen time counts minutes you're actively using this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live Translation") {
                Toggle("Translate live captions on device", isOn: Binding(
                    get: { captions.translationEnabled },
                    set: { captions.setTranslationEnabled($0) }
                ))
                Picker("Listen to", selection: Binding(
                    get: { captions.sourceLanguageCode },
                    set: { captions.setSourceLanguage($0) }
                )) {
                    ForEach(LiveCaptionService.supportedLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Picker("Translate to", selection: Binding(
                    get: { captions.targetLanguageCode },
                    set: { captions.setTargetLanguage($0) }
                )) {
                    ForEach(LiveCaptionService.supportedLanguages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text("Call Audio uses macOS Screen & System Audio Recording permission. Translation models run on device and may download on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Day Replay") {
                Stepper("Offer replay at (replay.offerHour):00", value: $replay.offerHour, in: 15...23)
                Text("Only active frontmost-app durations are stored, locally. Window titles, documents, keystrokes, and idle time are never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tabs") {
                ForEach(IslandTab.allCases.filter { $0 != .home }) { tab in
                    Toggle(isOn: Binding(
                        get: { settings.isTabEnabled(tab) },
                        set: { settings.setTab(tab, enabled: $0) }
                    )) {
                        Label(tab.title, systemImage: tab.symbol)
                    }
                }
            }

            Section("Focus Timer") {
                Stepper("Focus length: \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Break length: \(settings.breakMinutes) min", value: $settings.breakMinutes, in: 1...60)
                Toggle("Automatically chain focus and break sessions", isOn: $settings.autoChainSessions)
            }

            Section("Context & Automation") {
                Toggle("Presence-aware Focus Shield", isOn: $hero.focusShieldEnabled)
                TextField("Distracting apps (comma separated)", text: $hero.distractingApps)
                Toggle("Auto-start meeting cost in call apps", isOn: $hero.meetingAutoDetect)
                Toggle("Run a Shortcut when a call app becomes active", isOn: $hero.callAwareDNDEnabled)
                TextField("DND Shortcut name", text: $hero.dndShortcutName)
                Stepper("Battery alert: \(hero.batteryLimit)%", value: $hero.batteryLimit, in: 50...100, step: 5)
                Text("Quick screen recordings are saved to Movies › NotchAway Recordings. macOS will request Screen Recording permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Clipboard") {
                Stepper("Keep \(settings.clipboardLimit) recent items (pins are always kept)",
                        value: $settings.clipboardLimit, in: 10...500, step: 10)
                Text("Items marked as passwords or transient by other apps are never saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cityDraft = weather.manualCity
            teamDraft = scores.favoriteTeam
        }
    }
}

private struct NotchHidingSettingsPane: View {
    @EnvironmentObject private var controller: NotchController

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Hide the MacBook notch", isOn: $controller.isEnabled)
                Picker("Top-bar color", selection: $controller.barStyle) {
                    ForEach(TopBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Automatically detect top-bar height", isOn: $controller.useAutomaticHeight)

                if !controller.useAutomaticHeight {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Top-bar height")
                            Spacer()
                            Text("\(Int(controller.manualBarHeight)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $controller.manualBarHeight, in: 24...100, step: 1) { editing in
                            if !editing && controller.isEnabled {
                                Task { await controller.apply() }
                            }
                        }
                    }
                }
            }

            Section("Display") {
                LabeledContent("Notch") {
                    Text(controller.notchDetected ? "Detected" : "Not reported by macOS")
                }
                LabeledContent("Detected safe area") {
                    Text("\(Int(controller.detectedHeight)) pt")
                }
            }

            Section {
                HStack {
                    Button("Apply Now") {
                        Task { await controller.apply() }
                    }
                    .disabled(controller.isBusy)
                    Button("Restore Original Wallpaper") {
                        controller.restore()
                    }
                    .disabled(controller.isBusy)
                }
            } footer: {
                Text("NotchAway visually hides the physical notch by filling the top portion of your wallpaper with black or with colors taken from the wallpaper. It does not modify the display hardware.")
            }
        }
        .formStyle(.grouped)
    }
}
