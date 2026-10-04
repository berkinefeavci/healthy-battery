import Combine
import Foundation
import IOKit.pwr_mgt

enum SleepBehaviorPreferences {
    static let preventIdleSleepUntilTarget = "preventIdleSleepUntilChargeTarget"
}

struct SleepInhibitionInput {
    let enabled: Bool
    let batteryAvailable: Bool
    let externalConnected: Bool
    let percentage: Double?
    let target: Int?
    let startedAt: Date?
    let now: Date
}

enum SleepInhibitionStatus: Equatable {
    case disabled
    case waitingForPower
    case waitingForBattery
    case waitingForTarget
    case active(current: Int, target: Int)
    case targetReached(Int)
    case timedOut
    case failed(String)

    var requiresAssertion: Bool {
        if case .active = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .disabled: return String(localized: "Kapalı")
        case .waitingForPower: return String(localized: "Adaptör bekleniyor")
        case .waitingForBattery: return String(localized: "Pil verisi bekleniyor")
        case .waitingForTarget: return String(localized: "Kayıtlı hedef bekleniyor")
        case .active(let current, let target): return String(localized: "Aktif · %\(current) / %\(target)")
        case .targetReached(let target): return String(localized: "Hedefe ulaşıldı · %\(target)")
        case .timedOut: return String(localized: "8 saatlik güvenlik süresi doldu")
        case .failed(let message): return message
        }
    }
}

enum SleepInhibitionPolicy {
    static let maximumDuration: TimeInterval = 8 * 60 * 60

    static func status(for input: SleepInhibitionInput) -> SleepInhibitionStatus {
        guard input.enabled else { return .disabled }
        guard input.batteryAvailable, let percentage = input.percentage, percentage.isFinite else {
            return .waitingForBattery
        }
        guard input.externalConnected else { return .waitingForPower }
        guard let target = input.target, (1...100).contains(target) else { return .waitingForTarget }
        guard percentage < Double(target) else { return .targetReached(target) }
        if let startedAt = input.startedAt,
           input.now.timeIntervalSince(startedAt) >= maximumDuration { return .timedOut }
        return .active(current: Int(percentage.rounded()), target: target)
    }
}

enum SleepAssertionError: LocalizedError, Equatable {
    case creationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let code): return String(localized: "Uyku engeli oluşturulamadı (\(code)).")
        }
    }
}

enum SleepAssertionBackend {
    static func acquire() throws -> UInt32 {
        var identifier = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            String(localized: "Healthy Battery hedef doluluğa kadar şarjı izliyor") as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess else { throw SleepAssertionError.creationFailed(result) }
        return identifier
    }

    static func release(_ identifier: UInt32) {
        _ = IOPMAssertionRelease(IOPMAssertionID(identifier))
    }
}

final class SleepInhibitionController: ObservableObject {
    static let shared = SleepInhibitionController()

    typealias Acquire = () throws -> UInt32
    typealias Release = (UInt32) -> Void
    typealias ScheduleTimeout = (TimeInterval, @escaping () -> Void) -> () -> Void

    @Published private(set) var status = SleepInhibitionStatus.disabled
    var isActive: Bool { assertionID != nil }

    private let acquire: Acquire
    private let release: Release
    private let scheduleTimeout: ScheduleTimeout
    private var assertionID: UInt32?
    private var startedAt: Date?
    private var blockedStatus: SleepInhibitionStatus?
    private var cancelTimeout: (() -> Void)?

    init(acquire: @escaping Acquire = SleepAssertionBackend.acquire,
         release: @escaping Release = SleepAssertionBackend.release,
         scheduleTimeout: @escaping ScheduleTimeout = { delay, action in
             let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() }
             return { timer.invalidate() }
         }) {
        self.acquire = acquire
        self.release = release
        self.scheduleTimeout = scheduleTimeout
    }

    func update(_ input: SleepInhibitionInput) {
        precondition(Thread.isMainThread)
        let baseline = SleepInhibitionPolicy.status(for: .init(
            enabled: input.enabled,
            batteryAvailable: input.batteryAvailable,
            externalConnected: input.externalConnected,
            percentage: input.percentage,
            target: input.target,
            startedAt: nil,
            now: input.now
        ))
        if !baseline.requiresAssertion {
            blockedStatus = nil
        } else if let blockedStatus {
            status = blockedStatus
            return
        }
        let current = SleepInhibitionInput(
            enabled: input.enabled,
            batteryAvailable: input.batteryAvailable,
            externalConnected: input.externalConnected,
            percentage: input.percentage,
            target: input.target,
            startedAt: startedAt ?? input.startedAt,
            now: input.now
        )
        let next = SleepInhibitionPolicy.status(for: current)
        if next == .timedOut {
            releaseAssertion()
            blockedStatus = next
            status = next
            return
        }
        if next.requiresAssertion {
            if assertionID == nil {
                do {
                    assertionID = try acquire()
                    startedAt = input.now
                    cancelTimeout = scheduleTimeout(SleepInhibitionPolicy.maximumDuration) { [weak self] in
                        self?.timeoutReached()
                    }
                } catch {
                    releaseAssertion()
                    let failure = SleepInhibitionStatus.failed(error.localizedDescription)
                    blockedStatus = failure
                    status = failure
                    return
                }
            }
        } else {
            releaseAssertion()
        }
        status = next
    }

    func stop() {
        precondition(Thread.isMainThread)
        releaseAssertion()
        blockedStatus = nil
        status = .disabled
    }

    private func releaseAssertion() {
        cancelTimeout?()
        cancelTimeout = nil
        if let assertionID { release(assertionID) }
        assertionID = nil
        startedAt = nil
    }

    private func timeoutReached() {
        precondition(Thread.isMainThread)
        guard assertionID != nil else { return }
        blockedStatus = .timedOut
        releaseAssertion()
        status = .timedOut
    }
}
