import Foundation

/// Contract between the privileged SMC charge-inhibit helper (Faz 3) and the
/// advanced charge engine (Faz 4). Both sides code against this file only.
///
/// Safety invariants every implementation must keep:
/// - The helper re-enables charging and the adapter when the app stops sending
///   heartbeats (watchdog), on sleep/shutdown, and when the cable is removed.
/// - Below `ChargeInhibitSafety.criticalPercent` charging is always allowed.
/// - Every write is verified by reading the key back.
struct ChargeInhibitCapabilities: Equatable {
    var canInhibitCharging: Bool
    var canForceDischarge: Bool
    var reason: String?

    static let unsupported = ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                                       reason: nil)
}

struct ChargeInhibitState: Codable, Equatable {
    /// Charging stopped while the adapter keeps powering the Mac.
    var chargingInhibited: Bool
    /// Adapter disconnected logically; the Mac runs from the battery (discharge).
    var adapterInhibited: Bool

    static let released = ChargeInhibitState(chargingInhibited: false, adapterInhibited: false)
}

enum ChargeInhibitSafety {
    static let criticalPercent = 10
    static let heartbeatInterval: TimeInterval = 20
    /// Helper releases everything if no heartbeat arrives within this window.
    static let watchdogTimeout: TimeInterval = 60
}

protocol ChargeInhibitBackend {
    func capabilities() -> ChargeInhibitCapabilities
    func readState() throws -> ChargeInhibitState
    func apply(_ state: ChargeInhibitState) throws -> ChargeInhibitState
    func heartbeat() throws
}

/// Default when the helper is not installed or the hardware is not verified.
struct UnsupportedChargeInhibitBackend: ChargeInhibitBackend {
    func capabilities() -> ChargeInhibitCapabilities { .unsupported }
    func readState() throws -> ChargeInhibitState { .released }
    func apply(_ state: ChargeInhibitState) throws -> ChargeInhibitState { .released }
    func heartbeat() throws {}
}
