import Foundation

/// What Healthy Battery does when macOS's native charge limit is changed from outside the app.
enum ExternalChangeResponse: String, CaseIterable, Identifiable {
    case ask, reapply, adopt
    static let storageKey = "externalChangeResponse"
    var id: String { rawValue }

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .ask }

    var title: String {
        switch self {
        case .ask: return String(localized: "Sor")
        case .reapply: return String(localized: "Hedefimi geri yaz")
        case .adopt: return String(localized: "macOS değerini benimse")
        }
    }
}

/// Loop guard for automatic re-applies. One automatic write per external change; if the same
/// value shows up again within `window`, or the last automatic write failed for that observed
/// value, the engine falls back to asking.
struct ExternalChangeGate: Equatable {
    static let window: TimeInterval = 600
    private(set) var lastAutoReapplyAt: Date?
    private(set) var failedObserved: Int?

    func allowsAutoReapply(observed: Int, now: Date) -> Bool {
        if failedObserved == observed { return false }
        if let last = lastAutoReapplyAt, now.timeIntervalSince(last) < Self.window { return false }
        return true
    }

    mutating func recordAutoReapply(at date: Date) { lastAutoReapplyAt = date }
    mutating func recordFailure(observed: Int) { failedObserved = observed }
}

enum ChargeLimitDisplay {
    /// The limit macOS actually enforces; the saved preference only when macOS cannot be read.
    static func shown(native: Int?, preference: Double) -> Int {
        native ?? Int(preference)
    }

    static func conflictTitle(observed: Int, expected: Int) -> String {
        String(localized: "macOS sınırı %\(observed) — Healthy Battery %\(expected) istiyor")
    }

    /// Turkish dative suffix differs for 90 ("doksan" -> 'a); the other native limits take 'e.
    static func topUpReturnText(limit: Int) -> String {
        limit == 90
            ? String(localized: "Bitince %\(limit)'a dönülecek")
            : String(localized: "Bitince %\(limit)'e dönülecek")
    }
}
