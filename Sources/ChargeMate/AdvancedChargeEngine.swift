import Foundation

// Advanced charge engine (Faz 4): a pure decision function on top of the Faz 3 `ChargeInhibitBackend`
// contract. It never touches hardware; `AdvancedChargeRunner` applies its output.
//
// Sleep interaction (safe option, documented decision): the privileged helper always releases charging
// and the adapter when the Mac sleeps (ChargeInhibitSafety). The engine never asks the helper to keep an
// inhibit across sleep. When the Mac is about to sleep at or above the target, the engine still reports
// the desired (inhibited) state and sets `sleepMayOvershoot`; the runner defers re-applying until wake.
// Therefore the battery may charge past the target during sleep. That is accepted for safety.

enum AdvancedChargeLimits {
    static let minTarget = 20
    static let maxTarget = 100
    static let targetStep = 5
    static let minSailingDelta = 2
    static let maxSailingDelta = 15
    static let defaultHeatHigh = 35.0
    static let defaultHeatLow = 32.0
    /// Adapter mode: the adapter is restored this many points (at least) below the target.
    static let adapterMinBand = 5
    static let calibrationLow = 15
    static let calibrationHold: TimeInterval = 3600
    static let calibrationMaxDuration: TimeInterval = 24 * 3600
    static let dischargeMaxDuration: TimeInterval = 6 * 3600

    static func normalizedTarget(_ value: Int) -> Int {
        let stepped = Int((Double(value) / Double(targetStep)).rounded()) * targetStep
        return min(maxTarget, max(minTarget, stepped))
    }
    static func clampedDelta(_ value: Int) -> Int { min(maxSailingDelta, max(minSailingDelta, value)) }
}

struct AdvancedChargeSettings: Codable, Equatable {
    var targetLimit = 80
    var sailingEnabled = false
    var sailingDelta = 5
    var heatProtectionEnabled = false
    var heatPauseAbove = AdvancedChargeLimits.defaultHeatHigh
    var heatResumeBelow = AdvancedChargeLimits.defaultHeatLow
    var sleepBehaviorEnabled = false
    /// Opt-in adapter mode: cut wall power at the target, restore it below the band. Only used when the
    /// hardware cannot stop charging (`canInhibitCharging == false`) but can cut the adapter.
    var adapterModeEnabled = false
}

extension AdvancedChargeSettings {
    /// Older saved settings lack newer keys; missing keys fall back to defaults instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = AdvancedChargeSettings()
        d.targetLimit = try c.decodeIfPresent(Int.self, forKey: .targetLimit) ?? d.targetLimit
        d.sailingEnabled = try c.decodeIfPresent(Bool.self, forKey: .sailingEnabled) ?? d.sailingEnabled
        d.sailingDelta = try c.decodeIfPresent(Int.self, forKey: .sailingDelta) ?? d.sailingDelta
        d.heatProtectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .heatProtectionEnabled) ?? d.heatProtectionEnabled
        d.heatPauseAbove = try c.decodeIfPresent(Double.self, forKey: .heatPauseAbove) ?? d.heatPauseAbove
        d.heatResumeBelow = try c.decodeIfPresent(Double.self, forKey: .heatResumeBelow) ?? d.heatResumeBelow
        d.sleepBehaviorEnabled = try c.decodeIfPresent(Bool.self, forKey: .sleepBehaviorEnabled) ?? d.sleepBehaviorEnabled
        d.adapterModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .adapterModeEnabled) ?? d.adapterModeEnabled
        self = d
    }
}

enum CalibrationPhase: String, Codable, Equatable {
    case chargeToFull, hold, dischargeToLow, rechargeToFull
}

struct CalibrationSession: Codable, Equatable {
    var startedAt: Date
    var phase: CalibrationPhase
    var holdStartedAt: Date?
}

struct DischargeRequest: Codable, Equatable {
    var requestedAt: Date
}

/// State carried between evaluations. Only `discharge` and `calibration` are worth persisting; the
/// latches are rebuilt safely (charging simply resumes) after a restart.
struct AdvancedChargeMemory: Codable, Equatable {
    var limitLatched = false
    var heatLatched = false
    var discharge: DischargeRequest?
    var calibration: CalibrationSession?
    /// Adapter mode hysteresis latch (not persisted: after a restart the adapter simply comes back).
    var adapterLatched = false

    var needsPersistence: Bool { discharge != nil || calibration != nil }
}

extension AdvancedChargeMemory {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(limitLatched: try c.decodeIfPresent(Bool.self, forKey: .limitLatched) ?? false,
                  heatLatched: try c.decodeIfPresent(Bool.self, forKey: .heatLatched) ?? false,
                  discharge: try c.decodeIfPresent(DischargeRequest.self, forKey: .discharge),
                  calibration: try c.decodeIfPresent(CalibrationSession.self, forKey: .calibration),
                  adapterLatched: try c.decodeIfPresent(Bool.self, forKey: .adapterLatched) ?? false)
    }
}

enum SleepState: Equatable { case awake, aboutToSleep, asleep }

struct AdvancedChargeInput {
    var percentage: Int
    var temperatureC: Double?
    var externalConnected: Bool
    var isCharging: Bool
    var sleep: SleepState = .awake
    var now: Date
    var settings: AdvancedChargeSettings
    var capabilities: ChargeInhibitCapabilities
    var current: ChargeInhibitState
    var topUpActive = false
    var memory = AdvancedChargeMemory()
}

enum AdvancedChargeDisplay: Equatable {
    case unavailable, idle, criticalLow, onBattery, topUp
    case holdingAtLimit, sailing, heatPaused, discharging
    /// Adapter mode: wall power is cut, the Mac runs from the battery until the resume level.
    case adapterCut
    case calibrating(CalibrationPhase)
}

struct AdvancedChargeOutput: Equatable {
    var desired: ChargeInhibitState
    var display: AdvancedChargeDisplay
    var reason: String
    var memory: AdvancedChargeMemory
    /// True when the battery may exceed the target while asleep because the helper releases on sleep.
    var sleepMayOvershoot = false
}

enum AdvancedChargeEngine {
    static func evaluate(_ input: AdvancedChargeInput) -> AdvancedChargeOutput {
        var memory = input.memory
        let settings = input.settings
        let target = AdvancedChargeLimits.normalizedTarget(settings.targetLimit)
        let released = ChargeInhibitState.released

        func out(_ desired: ChargeInhibitState, _ display: AdvancedChargeDisplay, _ reason: String,
                 sleepNote: Bool = false) -> AdvancedChargeOutput {
            AdvancedChargeOutput(desired: desired, display: display, reason: reason, memory: memory,
                                 sleepMayOvershoot: sleepNote)
        }

        let adapterMode = !input.capabilities.canInhibitCharging && input.capabilities.canForceDischarge
            && settings.adapterModeEnabled
        guard input.capabilities.canInhibitCharging || adapterMode else {
            return out(released, .unavailable, input.capabilities.reason ?? "Charge control is not available.")
        }
        let cutAdapter = ChargeInhibitState(chargingInhibited: false, adapterInhibited: true)

        // Timeouts first: a stale request can never keep the adapter cut.
        if let d = memory.discharge, input.now.timeIntervalSince(d.requestedAt) > AdvancedChargeLimits.dischargeMaxDuration {
            memory.discharge = nil
        }
        if let c = memory.calibration, input.now.timeIntervalSince(c.startedAt) > AdvancedChargeLimits.calibrationMaxDuration {
            memory.calibration = nil
        }
        if !input.capabilities.canForceDischarge {
            memory.discharge = nil
            memory.calibration = nil
        }

        if input.percentage < ChargeInhibitSafety.criticalPercent {
            memory.limitLatched = false
            memory.heatLatched = false
            memory.adapterLatched = false
            memory.discharge = nil
            return out(released, .criticalLow, "Battery is below the critical level; charging is always allowed.")
        }
        if !input.externalConnected {
            memory.limitLatched = false
            memory.heatLatched = false
            memory.adapterLatched = false
            memory.discharge = nil
            return out(released, .onBattery, "Adapter is not connected.")
        }
        if input.topUpActive {
            memory.limitLatched = false
            memory.heatLatched = false
            memory.adapterLatched = false
            return out(released, .topUp, "Top Up is active; charge inhibit is released.")
        }

        if adapterMode && input.sleep != .awake {
            // The adapter must be back before the Mac sleeps; the latch survives so it re-cuts on wake.
            return out(released, .idle, "Adapter mode: adapter restored while the Mac sleeps.")
        }

        // Heat latch (hysteresis). Missing sensor drops the latch rather than blocking charging forever.
        // Adapter mode has no heat action: native heat protection (Faz 2) handles it.
        if settings.heatProtectionEnabled, !adapterMode, let t = input.temperatureC {
            if t > settings.heatPauseAbove { memory.heatLatched = true }
            else if t < settings.heatResumeBelow { memory.heatLatched = false }
        } else {
            memory.heatLatched = false
        }
        let heat = memory.heatLatched

        // Calibration (takes precedence over the user limit and discharge request).
        if let session = memory.calibration {
            memory.calibration = advance(session, percentage: input.percentage, now: input.now)
            if let cal = memory.calibration {
                if cal.phase == .dischargeToLow {
                    return out(ChargeInhibitState(chargingInhibited: false, adapterInhibited: true),
                               .calibrating(cal.phase), "Calibration: discharging to \(AdvancedChargeLimits.calibrationLow)%.")
                }
                if heat {
                    return out(ChargeInhibitState(chargingInhibited: true, adapterInhibited: false),
                               .heatPaused, "Calibration paused: battery is too warm.")
                }
                return out(released, .calibrating(cal.phase), "Calibration: \(cal.phase.rawValue).")
            }
            // Calibration finished: fall through and restore the user limit.
        }

        // One-shot discharge down to the target.
        if memory.discharge != nil {
            if input.percentage > target {
                return out(ChargeInhibitState(chargingInhibited: false, adapterInhibited: true), .discharging,
                           "Discharging to \(target)%.")
            }
            memory.discharge = nil
        }

        if heat {
            return out(ChargeInhibitState(chargingInhibited: true, adapterInhibited: false), .heatPaused,
                       "Charging paused: battery is warmer than \(Int(settings.heatPauseAbove)) °C.")
        }

        if adapterMode {
            guard target < 100 else {
                memory.adapterLatched = false
                return out(released, .idle, "No limit set.")
            }
            let resumeAt = adapterResumeAt(target: target, sailingDelta: settings.sailingDelta)
            if input.percentage >= target { memory.adapterLatched = true }
            else if memory.adapterLatched && input.percentage <= resumeAt { memory.adapterLatched = false }
            if memory.adapterLatched {
                return out(cutAdapter, .adapterCut, "Adapter cut at \(target)%: running on battery until \(resumeAt)%.")
            }
            return out(released, .idle, "Charging toward \(target)%.")
        }

        // Limit with optional sailing hysteresis.
        guard target < 100 else {
            memory.limitLatched = false
            return out(released, .idle, "No limit set.")
        }
        let delta = AdvancedChargeLimits.clampedDelta(settings.sailingDelta)
        let resumeAt = settings.sailingEnabled ? target - delta : target - 1
        if input.percentage >= target { memory.limitLatched = true }
        else if memory.limitLatched && input.percentage <= resumeAt { memory.limitLatched = false }

        if memory.limitLatched {
            let sleeping = input.sleep != .awake
            let note = sleeping && input.percentage >= target
            let display: AdvancedChargeDisplay = (settings.sailingEnabled && input.percentage < target) ? .sailing : .holdingAtLimit
            return out(ChargeInhibitState(chargingInhibited: true, adapterInhibited: false), display,
                       display == .sailing ? "Sailing: waiting to drop to \(resumeAt)%." : "Holding at \(target)%.",
                       sleepNote: note)
        }
        return out(released, .idle, "Charging toward \(target)%.")
    }

    /// Level at which adapter mode restores wall power: `target - max(5, sailingDelta)`.
    static func adapterResumeAt(target: Int, sailingDelta: Int) -> Int {
        target - max(AdvancedChargeLimits.adapterMinBand, AdvancedChargeLimits.clampedDelta(sailingDelta))
    }

    /// Moves a calibration session through its phases; nil when the final recharge reached 100%.
    static func advance(_ session: CalibrationSession, percentage: Int, now: Date) -> CalibrationSession? {
        var cal = session
        while true {
            switch cal.phase {
            case .chargeToFull:
                guard percentage >= 100 else { return cal }
                cal.phase = .hold; cal.holdStartedAt = now
            case .hold:
                let start = cal.holdStartedAt ?? now
                cal.holdStartedAt = start
                guard now.timeIntervalSince(start) >= AdvancedChargeLimits.calibrationHold else { return cal }
                cal.phase = .dischargeToLow
            case .dischargeToLow:
                guard percentage <= AdvancedChargeLimits.calibrationLow else { return cal }
                cal.phase = .rechargeToFull
            case .rechargeToFull:
                return percentage >= 100 ? nil : cal
            }
        }
    }
}
