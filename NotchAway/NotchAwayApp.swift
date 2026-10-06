import SwiftUI

@main
struct NotchAwayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppServices.shared.notch

    var body: some Scene {
        MenuBarExtra("NotchAway", systemImage: controller.isEnabled ? "rectangle.topthird.inset.filled" : "rectangle") {
            NotchMenuView()
                .islandEnvironment(AppServices.shared)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .islandEnvironment(AppServices.shared)
                .frame(width: 560, height: 520)
        }
    }
}
