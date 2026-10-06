import SwiftUI

struct NotchMenuView: View {
    @EnvironmentObject private var controller: NotchController
    @EnvironmentObject private var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotchAway")
                        .font(.headline)
                    Text(controller.notchDetected ? "Built-in notch detected" : "Built-in display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $controller.isEnabled)
                    .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(controller.statusMessage)
                    .font(.subheadline)

                if controller.useAutomaticHeight {
                    Text("Top bar: Auto · \(Int(controller.detectedHeight > 0 ? controller.detectedHeight : 38)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Top bar: \(Int(controller.manualBarHeight)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Hide Notch Now") {
                    Task { await controller.apply() }
                }
                .disabled(controller.isBusy)

                Button("Restore Wallpaper") {
                    controller.restore()
                }
                .disabled(controller.isBusy)

                Spacer()
            }

            Divider()

            HStack {
                Button("Open Island") {
                    services.openIsland()
                }
                Button("Command Palette") {
                    services.palette.show()
                }
                Spacer()
                Text("⌃⌥K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Settings…") {
                    services.openSettings()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
    }
}
