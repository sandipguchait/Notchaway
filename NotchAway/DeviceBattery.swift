import Foundation
import IOKit
import SwiftUI

@MainActor
final class DeviceBatteryService: ObservableObject {
    struct Device: Identifiable, Equatable, Sendable {
        enum Kind: Sendable {
            case earbuds, headphones, mouse, keyboard, trackpad, other
        }

        let id: String
        let name: String
        let kind: Kind
        var level: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?

        var symbol: String {
            switch kind {
            case .earbuds: return "airpodspro"
            case .headphones: return "headphones"
            case .mouse: return "computermouse.fill"
            case .keyboard: return "keyboard.fill"
            case .trackpad: return "rectangle.and.hand.point.up.left.fill"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }

        var lowestLevel: Int? {
            [level, left, right].compactMap { $0 }.min()
        }
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var hasLoaded = false

    private var timer: Timer?
    private var clients = 0

    func beginMonitoring() {
        clients += 1
        guard clients == 1 else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func endMonitoring() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var merged = Self.readBluetooth()
            for device in Self.readHIDDevices() where !merged.contains(where: { $0.name == device.name }) {
                merged.append(device)
            }
            let result = merged
            Task { @MainActor in
                self?.devices = result
                self?.hasLoaded = true
            }
        }
    }

    /// Magic Mouse / Keyboard / Trackpad report `BatteryPercent` on this IOKit service.
    nonisolated private static func readHIDDevices() -> [Device] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [Device] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if let percent, let name {
                let lower = name.lowercased()
                let kind: Device.Kind = lower.contains("mouse") ? .mouse
                    : lower.contains("keyboard") ? .keyboard
                    : lower.contains("trackpad") ? .trackpad : .other
                devices.append(Device(id: "hid-\(name)", name: name, kind: kind, level: percent))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }

    /// AirPods and other Bluetooth audio report per-bud and case levels through system_profiler.
    nonisolated private static func readBluetooth() -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "-detailLevel", "basic", "SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        func percent(_ value: Any?) -> Int? {
            guard let string = value as? String else { return nil }
            return Int(string.filter(\.isNumber))
        }

        var devices: [Device] = []
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let left = percent(info["device_batteryLevelLeft"])
                    let right = percent(info["device_batteryLevelRight"])
                    let caseLevel = percent(info["device_batteryLevelCase"])
                    let main = percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"])
                    guard left != nil || right != nil || main != nil else { continue }

                    let minor = (info["device_minorType"] as? String ?? "").lowercased()
                    let kind: Device.Kind
                    if left != nil || right != nil {
                        kind = .earbuds
                    } else if minor.contains("headphone") || minor.contains("headset") {
                        kind = .headphones
                    } else if minor.contains("mouse") {
                        kind = .mouse
                    } else if minor.contains("keyboard") {
                        kind = .keyboard
                    } else if minor.contains("trackpad") {
                        kind = .trackpad
                    } else {
                        kind = .other
                    }
                    devices.append(Device(id: "bt-\(name)", name: name, kind: kind,
                                          level: main, left: left, right: right, caseLevel: caseLevel))
                }
            }
        }
        return devices
    }
}
