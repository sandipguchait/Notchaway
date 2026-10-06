import Darwin
import Foundation
import IOKit.ps
import SwiftUI

@MainActor
final class SystemStatsService: ObservableObject {
    struct Battery: Equatable {
        var level: Double
        var isCharging: Bool
        var onAC: Bool
        var minutesRemaining: Int?

        var symbol: String {
            if isCharging { return "battery.100.bolt" }
            switch level {
            case 0.75...: return "battery.100"
            case 0.5..<0.75: return "battery.75"
            case 0.25..<0.5: return "battery.50"
            case 0.1..<0.25: return "battery.25"
            default: return "battery.0"
            }
        }

        var statusText: String {
            if isCharging { return "Charging" }
            if onAC { return "On power adapter" }
            if let minutes = minutesRemaining, minutes > 0 {
                return "\(minutes / 60)h \(minutes % 60)m left"
            }
            return "On battery"
        }
    }

    @Published private(set) var cpu: Double = 0
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var battery: Battery?
    @Published private(set) var downloadRate: Double = 0
    @Published private(set) var uploadRate: Double = 0
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0

    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

    private var timer: Timer?
    private var clients = 0
    private var lastCPU: (used: UInt64, total: UInt64)?
    private var lastNetwork: (received: UInt64, sent: UInt64, date: Date)?
    private let host = mach_host_self()

    func beginMonitoring() {
        clients += 1
        guard clients == 1 else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func endMonitoring() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refreshBattery() {
        battery = Self.readBattery()
    }

    private func sample() {
        if let ticks = cpuTicks() {
            if let last = lastCPU, ticks.total > last.total {
                cpu = Double(ticks.used - last.used) / Double(ticks.total - last.total)
            }
            lastCPU = ticks
        }

        memoryUsed = readMemoryUsed() ?? memoryUsed
        battery = Self.readBattery()

        if let network = Self.readNetworkBytes() {
            let now = Date()
            if let last = lastNetwork {
                let elapsed = max(0.1, now.timeIntervalSince(last.date))
                downloadRate = network.received >= last.received ? Double(network.received - last.received) / elapsed : 0
                uploadRate = network.sent >= last.sent ? Double(network.sent - last.sent) / elapsed : 0
            }
            lastNetwork = (network.received, network.sent, now)
        }

        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ]) {
            diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(values.volumeTotalCapacity ?? 0)
        }
    }

    private func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    private func readMemoryUsed() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize = vm_size_t(0)
        host_page_size(host, &pageSize)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Double(pages) * Double(pageSize)
    }

    private static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let state = description[kIOPSPowerSourceStateKey] as? String
            let minutes = description[kIOPSTimeToEmptyKey] as? Int
            return Battery(level: Double(current) / Double(maximum),
                           isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                           onAC: state == kIOPSACPowerValue,
                           minutesRemaining: minutes)
        }
        return nil
    }

    private static func readNetworkBytes() -> (received: UInt64, sent: UInt64)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
        }
        return (received, sent)
    }
}

struct StatsTabView: View {
    @EnvironmentObject private var stats: SystemStatsService

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatRing(title: "CPU", value: stats.cpu, detail: "\(Int(stats.cpu * 100))%", tint: .blue)
                StatRing(title: "Memory",
                         value: stats.memoryTotal > 0 ? stats.memoryUsed / stats.memoryTotal : 0,
                         detail: "\(Format.bytes(stats.memoryUsed)) of \(Format.bytes(stats.memoryTotal))",
                         tint: .purple)
                if let battery = stats.battery {
                    StatRing(title: "Battery", value: battery.level,
                             detail: battery.statusText,
                             tint: battery.level < 0.2 && !battery.onAC ? .red : .green)
                }
                StatRing(title: "Disk",
                         value: stats.diskTotal > 0 ? 1 - stats.diskFree / stats.diskTotal : 0,
                         detail: "\(Format.bytes(stats.diskFree)) free",
                         tint: .orange)
            }

            HStack(spacing: 24) {
                Label(Format.rate(stats.downloadRate), systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.cyan)
                Label(Format.rate(stats.uploadRate), systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.pink)
                Spacer()
                Text("Updates every 2 seconds while this tab is open")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.magenta)
        }
        .onAppear { stats.beginMonitoring() }
        .onDisappear { stats.endMonitoring() }
    }
}

private struct StatRing: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text("\(Int(min(max(value, 0), 1) * 100))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 70, height: 70)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .cardBackground(cornerRadius: 18, tint: tint)
    }
}
