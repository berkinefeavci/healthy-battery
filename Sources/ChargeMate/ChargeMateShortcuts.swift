import Foundation

enum ChargeMateShortcutBatterySource: String, CaseIterable {
    case macOS
    case hardware
}

enum ChargeMateShortcutLimitSource: String, CaseIterable {
    case committed
    case nativeManual
    case nativeCurrent
}

enum ChargeMateShortcutPowerMode: String, CaseIterable {
    case automatic
    case lowPower
    case turbo
}

enum ChargeMateShortcutMagSafeOutput: String, CaseIterable {
    case system
    case green
    case orange
    case off
}

enum ChargeMateShortcutState: String, CaseIterable {
    case monitoring, charging, paused, sailing, discharging, topUp
    case heatProtect, calibration, unavailable, error

    /// `advancedState`: what the adapter-cut engine is doing ("calibrating", "discharging", "heatPaused",
    /// "sailing", "adapterCut"); it wins over the native control state, which cannot see the cut.
    static func resolve(available: Bool, controlState: String, advancedState: String? = nil, policyState: String,
                        isCharging: Bool, externalConnected: Bool) -> Self {
        guard available else { return .unavailable }
        if policyState.hasPrefix("recoveryRequired") || policyState.hasPrefix("pausedByConflict") { return .error }
        switch advancedState {
        case "calibrating": return .calibration
        case "discharging", "adapterCut": return .discharging
        case "heatPaused": return .heatProtect
        case "sailing": return .sailing
        default: break
        }
        switch controlState {
        case "topUp": return .topUp
        case "heatProtect": return .heatProtect
        case "sailing": return .sailing
        case "discharging": return .discharging
        case "pausedAtLimit": return .paused
        case "charging": return .charging
        default:
            if isCharging { return .charging }
            return externalConnected ? .paused : .discharging
        }
    }
}

struct ChargeMateShortcutSnapshot {
    var sampledAt: Date
    var macOSPercentage: Int?
    var hardwarePercentage: Int?
    var temperatureC: Double?
    var committedLimit: Int?
    var nativeManualLimit: Int?
    var nativeCurrentLimit: Int?
    var state: ChargeMateShortcutState
}

enum ChargeMateShortcutError: Error, Equatable, LocalizedError {
    case staleMeasurement
    case measurementUnavailable(String)
    case unsupportedChargeLimit(Int)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .staleMeasurement:
            return String(localized: "Güncel batarya ölçümü 5 saniye içinde alınamadı.")
        case .measurementUnavailable(let name):
            return String(localized: "\(name) bu Mac'te okunamadı.")
        case .unsupportedChargeLimit(let value):
            return String(localized: "%\(value) bu Mac'in desteklediği şarj hedeflerinden biri değil.")
        case .commandFailed(let message):
            return message
        }
    }
}

struct ChargeMateShortcutReader {
    let snapshot: ChargeMateShortcutSnapshot
    let now: Date
    var maximumAge: TimeInterval = 5

    private func requireFresh() throws {
        let age = now.timeIntervalSince(snapshot.sampledAt)
        guard age.isFinite, (0...maximumAge).contains(age) else {
            throw ChargeMateShortcutError.staleMeasurement
        }
    }

    func percentage(_ source: ChargeMateShortcutBatterySource) throws -> Int {
        try requireFresh()
        let value = source == .macOS ? snapshot.macOSPercentage : snapshot.hardwarePercentage
        guard let value, (0...100).contains(value) else {
            throw ChargeMateShortcutError.measurementUnavailable(
                source == .macOS ? String(localized: "macOS pil yüzdesi") : String(localized: "Donanım pil yüzdesi")
            )
        }
        return value
    }

    func temperatureCelsius() throws -> Double {
        try requireFresh()
        guard let value = snapshot.temperatureC, value.isFinite else {
            throw ChargeMateShortcutError.measurementUnavailable(String(localized: "Batarya sıcaklığı"))
        }
        return value
    }

    func limit(_ source: ChargeMateShortcutLimitSource) throws -> Int {
        let value: Int?
        switch source {
        case .committed: value = snapshot.committedLimit
        case .nativeManual: value = snapshot.nativeManualLimit
        case .nativeCurrent: value = snapshot.nativeCurrentLimit
        }
        guard let value, (0...100).contains(value) else {
            throw ChargeMateShortcutError.measurementUnavailable(String(localized: "Şarj limiti"))
        }
        return value
    }

    func state() throws -> ChargeMateShortcutState {
        try requireFresh()
        return snapshot.state
    }
}

enum ChargeMateShortcutCommand: Equatable {
    case setChargeLimit(Int)
    case startTopUp
    case cancelTopUp
    case setPowerMode(ChargeMateShortcutPowerMode)
    case setMagSafe(ChargeMateShortcutMagSafeOutput)
}

struct ChargeMateShortcutCommandRunner {
    let supportedLimits: () -> Set<Int>
    let execute: (ChargeMateShortcutCommand) throws -> String

    func run(_ command: ChargeMateShortcutCommand) throws -> String {
        if case .setChargeLimit(let value) = command, !supportedLimits().contains(value) {
            throw ChargeMateShortcutError.unsupportedChargeLimit(value)
        }
        return try execute(command)
    }
}
