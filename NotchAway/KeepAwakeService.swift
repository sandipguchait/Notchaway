import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var endDate: Date?

    var onEvent: ((String) -> Void)?

    private var assertionID = IOPMAssertionID(0)
    private var expiryTask: Task<Void, Never>?

    var shortRemainingText: String {
        guard let endDate else { return "∞" }
        let minutes = max(0, Int(endDate.timeIntervalSinceNow / 60))
        return minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    var statusText: String {
        guard isActive else { return "Off" }
        guard let endDate else { return "On indefinitely" }
        return "Until \(Format.time(endDate))"
    }

    func toggle() {
        if isActive { deactivate() } else { activate(for: nil) }
    }

    func activate(for duration: TimeInterval?) {
        activate(until: duration.map { Date().addingTimeInterval($0) })
    }

    func activate(until date: Date?) {
        releaseAssertion()
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NotchAway Keep Awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return }

        assertionID = id
        isActive = true
        endDate = date
        onEvent?(date.map { "Keeping awake until \(Format.time($0))" } ?? "Keeping your Mac awake")

        expiryTask?.cancel()
        if let date {
            expiryTask = Task { @MainActor [weak self] in
                let seconds = max(0, date.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.deactivate()
                self?.onEvent?("Keep Awake ended")
            }
        }
    }

    func deactivate() {
        expiryTask?.cancel()
        expiryTask = nil
        releaseAssertion()
        isActive = false
        endDate = nil
    }

    private func releaseAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}
