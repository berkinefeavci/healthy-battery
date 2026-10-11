import Foundation

enum MagSafeLEDPolicy: String, CaseIterable, Codable, Identifiable {
    case system
    case alwaysOff
    case scheduled

    /// UserDefaults key of the selection made on the MagSafe page. An older build also stored "status"
    /// ("by state", never reachable here); that and any unknown value read back as `.system`.
    static let storageKey = "magSafeLEDPolicy"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "Sistem yönetsin")
        case .alwaysOff: return String(localized: "Her zaman kapalı")
        case .scheduled: return String(localized: "Saat aralığında kapalı")
        }
    }
}

enum MagSafeLEDOutput: String, CaseIterable, Codable, Hashable {
    case system
    case off
    case green
    case orange
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

/// Read-only look at the MagSafe LED key. A readable key is evidence for the physical test, nothing more:
/// this type never writes.
struct MagSafeLEDCapability: Equatable {
    enum ProbeState: Equatable {
        case checking
        case noAdapter
        case candidateKeyFound(type: String, byteCount: Int)
        case candidateKeyUnavailable
        case malformedCandidate
    }

    let probeState: ProbeState

    static func liveProbe(externalConnected: Bool, reader: SMCReader = .shared) -> Self {
        guard externalConnected else { return Self(probeState: .noAdapter) }
        do {
            let value = try reader.read("ACLC")
            guard value.bytes.count == 1 else { return Self(probeState: .malformedCandidate) }
            return Self(probeState: .candidateKeyFound(type: value.type, byteCount: value.bytes.count))
        } catch {
            return Self(probeState: .candidateKeyUnavailable)
        }
    }
}
