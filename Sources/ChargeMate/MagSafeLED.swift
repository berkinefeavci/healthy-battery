import Foundation

enum MagSafeLEDPolicy: String, CaseIterable, Codable, Identifiable {
    case system
    case status
    case alwaysOff
    case scheduled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "Sistem yönetsin")
        case .status: return String(localized: "Duruma göre")
        case .alwaysOff: return String(localized: "Her zaman kapalı")
        case .scheduled: return String(localized: "Saat aralığında kapalı")
        }
    }
}

enum MagSafeLEDCompletionBehavior: String, CaseIterable, Codable, Identifiable {
    case green
    case off

    var id: String { rawValue }
    var title: String { self == .green ? String(localized: "Yeşil") : String(localized: "Kapalı") }
}

enum MagSafeLEDOutput: String, CaseIterable, Codable, Hashable {
    case system
    case off
    case green
    case orange
    case blinkingOrange
}

enum MagSafeConnectionKind: String, Codable {
    case none
    case magsafe2
    case magsafe3
    case usbC
    case unknownAdapter
}

enum MagSafeLEDPhase: Equatable {
    case charging
    case confirmedTargetReached
    case heatPaused
    case topUpCharging
    case calibrationComplete
    case discharging
    case unknown
}

/// What the root LED service is doing, parsed from its policy file ("mode start end").
/// Mode 3 means a manual test paused the automatic policy until it is resumed.
enum MagSafeLEDHelperState: Equatable {
    case policy(MagSafeLEDPolicy, start: Int, end: Int)
    case pausedByTest

    static func parse(_ text: String) -> Self? {
        let values = text.split(whereSeparator: { $0.isWhitespace }).map { Int($0) }
        guard values.count == 3, let mode = values[0], let start = values[1], let end = values[2],
              (0..<1440).contains(start), (0..<1440).contains(end) else { return nil }
        switch mode {
        case 0: return .policy(.system, start: start, end: end)
        case 1: return .policy(.alwaysOff, start: start, end: end)
        case 2: return .policy(.scheduled, start: start, end: end)
        case 3: return .pausedByTest
        default: return nil
        }
    }
}

enum MagSafeLEDTimeWindow {
    static let defaultStart = 1320, defaultEnd = 480
    static let startKey = "magSafeLEDStartMinute", endKey = "magSafeLEDEndMinute"

    /// Times the page should show. Only a scheduled policy carries real times: "System" and
    /// "Always off" store 0 0, and copying those once turned a saved night window into 00:00–00:00.
    static func repaired(policy: MagSafeLEDPolicy, start: Int, end: Int) -> (start: Int, end: Int) {
        guard policy != .scheduled, start == end else { return (start, end) }
        return (defaultStart, defaultEnd)
    }
}

struct MagSafeLEDPreferences: Equatable {
    static let policyKey = "magSafeLEDPolicy"
    static let completionKey = "magSafeLEDCompletionBehavior"
    static let blinkKey = "magSafeLEDBlinkWhileDischarging"

    var policy: MagSafeLEDPolicy
    var completionBehavior: MagSafeLEDCompletionBehavior
    var blinkWhileDischarging: Bool

    static let defaults = Self(policy: .system, completionBehavior: .green, blinkWhileDischarging: false)

    static func load(from defaults: UserDefaults) -> Self {
        Self(
            policy: MagSafeLEDPolicy(rawValue: defaults.string(forKey: policyKey) ?? "") ?? .system,
            completionBehavior: MagSafeLEDCompletionBehavior(rawValue: defaults.string(forKey: completionKey) ?? "") ?? .green,
            blinkWhileDischarging: defaults.bool(forKey: blinkKey)
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(policy.rawValue, forKey: Self.policyKey)
        defaults.set(completionBehavior.rawValue, forKey: Self.completionKey)
        defaults.set(blinkWhileDischarging, forKey: Self.blinkKey)
    }
}

struct MagSafeLEDCapability: Equatable {
    enum ProbeState: Equatable {
        case checking
        case noAdapter
        case candidateKeyFound(type: String, byteCount: Int)
        case candidateKeyUnavailable
        case malformedCandidate
    }

    let connection: MagSafeConnectionKind
    let probeState: ProbeState
    let writerReady: Bool
    let supportedOutputs: Set<MagSafeLEDOutput>

    /// This build deliberately has no SMC writer. A readable candidate key is evidence for
    /// the next physical test, not permission to claim that LED control is available.
    static func liveProbe(externalConnected: Bool, reader: SMCReader = .shared) -> Self {
        guard externalConnected else {
            return Self(connection: .none, probeState: .noAdapter, writerReady: false, supportedOutputs: [])
        }
        do {
            let value = try reader.read("ACLC")
            guard value.bytes.count == 1 else {
                return Self(connection: .unknownAdapter, probeState: .malformedCandidate,
                            writerReady: false, supportedOutputs: [])
            }
            return Self(connection: .unknownAdapter,
                        probeState: .candidateKeyFound(type: value.type, byteCount: value.bytes.count),
                        writerReady: false, supportedOutputs: [])
        } catch {
            return Self(connection: .unknownAdapter, probeState: .candidateKeyUnavailable,
                        writerReady: false, supportedOutputs: [])
        }
    }
}

enum MagSafeLEDBlockReason: Equatable {
    case writerUnavailable
    case noAdapter
    case unsupportedConnection
    case unknownConnection
    case staleOrUnknownState
    case unsupportedOutput(MagSafeLEDOutput)
}

enum MagSafeLEDDecision: Equatable {
    case write(MagSafeLEDOutput)
    case noWrite(MagSafeLEDBlockReason)
}

enum MagSafeLEDPolicyEngine {
    static func decision(preferences: MagSafeLEDPreferences,
                         connection: MagSafeConnectionKind,
                         phase: MagSafeLEDPhase,
                         telemetryFresh: Bool,
                         writerReady: Bool,
                         supportedOutputs: Set<MagSafeLEDOutput>) -> MagSafeLEDDecision {
        guard writerReady else { return .noWrite(.writerUnavailable) }
        guard connection != .none else { return .noWrite(.noAdapter) }
        guard connection != .usbC else { return .noWrite(.unsupportedConnection) }
        guard connection == .magsafe2 || connection == .magsafe3 else { return .noWrite(.unknownConnection) }

        let output: MagSafeLEDOutput
        switch preferences.policy {
        case .system:
            output = .system
        case .alwaysOff:
            output = .off
        case .scheduled:
            // The privileged time-window service evaluates local wall-clock time.
            return .noWrite(.staleOrUnknownState)
        case .status:
            guard telemetryFresh else { return .noWrite(.staleOrUnknownState) }
            switch phase {
            case .charging, .heatPaused, .topUpCharging:
                output = .orange
            case .confirmedTargetReached, .calibrationComplete:
                output = preferences.completionBehavior == .green ? .green : .off
            case .discharging:
                output = preferences.blinkWhileDischarging && connection == .magsafe3 ? .blinkingOrange : .orange
            case .unknown:
                return .noWrite(.staleOrUnknownState)
            }
        }
        guard supportedOutputs.contains(output) else { return .noWrite(.unsupportedOutput(output)) }
        return .write(output)
    }
}
