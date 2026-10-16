import Combine
import Foundation

/// Persists the resumable part of the engine memory (discharge request, calibration session).
/// Nothing is written while both are empty, so an unsupported backend never creates a file.
struct AdvancedChargeMemoryStore {
    let url: URL

    func load() -> AdvancedChargeMemory {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AdvancedChargeMemory.self, from: data) else { return AdvancedChargeMemory() }
        return AdvancedChargeMemory(limitLatched: false, heatLatched: false,
                                    discharge: value.discharge, calibration: value.calibration)
    }

    func save(_ memory: AdvancedChargeMemory) {
        if !memory.needsPersistence { try? FileManager.default.removeItem(at: url); return }
        let kept = AdvancedChargeMemory(limitLatched: false, heatLatched: false,
                                        discharge: memory.discharge, calibration: memory.calibration)
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Owns a `ChargeInhibitBackend`, feeds telemetry to `AdvancedChargeEngine` and applies the result.
/// Main-thread only. With the default `UnsupportedChargeInhibitBackend` it never changes anything.
final class AdvancedChargeRunner: ObservableObject {
    /// Writes only while a discharge request or calibration exists, so it is inert with the default backend.
    static let shared = AdvancedChargeRunner(store: AdvancedChargeMemoryStore(
        url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep").appendingPathComponent("advanced-charge.json")))

    @Published var settings: AdvancedChargeSettings { didSet { persistSettings(); reevaluate(now: Date()) } }
    @Published private(set) var display = AdvancedChargeDisplay.unavailable
    @Published private(set) var reason = ""
    @Published private(set) var capabilities = ChargeInhibitCapabilities.unsupported
    @Published private(set) var sleepMayOvershoot = false
    @Published private(set) var memory: AdvancedChargeMemory
    @Published private(set) var lastError: String?

    private(set) var applied = ChargeInhibitState.released
    private var backend: ChargeInhibitBackend
    private let store: AdvancedChargeMemoryStore?
    private let defaults: UserDefaults
    private var sleep = SleepState.awake
    private var lastHeartbeat = Date.distantPast
    private var lastInput: AdvancedChargeInput?
    private var timer: Timer?
    private var lastSaved = AdvancedChargeMemory()

    init(backend: ChargeInhibitBackend = UnsupportedChargeInhibitBackend(),
         store: AdvancedChargeMemoryStore? = nil, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.store = store
        self.defaults = defaults
        let loaded = store?.load() ?? AdvancedChargeMemory()
        self.memory = loaded
        self.lastSaved = loaded
        if let data = defaults.data(forKey: "advancedChargeSettings"),
           let value = try? JSONDecoder().decode(AdvancedChargeSettings.self, from: data) {
            settings = value
        } else {
            settings = AdvancedChargeSettings()
        }
        capabilities = backend.capabilities()
    }

    /// Injects a supported backend (Faz 3 helper). Releases whatever the previous one held.
    func replaceBackend(_ newBackend: ChargeInhibitBackend) {
        releaseAll()
        backend = newBackend
        capabilities = newBackend.capabilities()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: ChargeInhibitSafety.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.heartbeatIfDue(now: Date())
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        releaseAll()
    }

    // MARK: Requests

    func requestDischarge(now: Date = Date()) {
        guard capabilities.canForceDischarge else { return }
        memory.discharge = DischargeRequest(requestedAt: now)
        reevaluate(now: now)
    }
    func cancelDischarge(now: Date = Date()) { memory.discharge = nil; reevaluate(now: now) }
    func startCalibration(now: Date = Date()) {
        guard capabilities.canForceDischarge else { return }
        memory.calibration = CalibrationSession(startedAt: now, phase: .chargeToFull, holdStartedAt: nil)
        reevaluate(now: now)
    }
    func cancelCalibration(now: Date = Date()) { memory.calibration = nil; reevaluate(now: now) }

    func setSleepState(_ state: SleepState, now: Date = Date()) {
        sleep = state
        // Adapter mode: restore wall power before the Mac sleeps rather than relying on the helper alone.
        if state != .awake, applied.adapterInhibited { releaseAll() }
        if state == .awake { resyncFromBackend(); reevaluate(now: now) } else { sleepMayOvershootUpdate(now: now) }
    }

    // MARK: Telemetry

    func update(percentage: Int, temperatureC: Double?, externalConnected: Bool, isCharging: Bool,
                topUpActive: Bool, now: Date = Date()) {
        capabilities = backend.capabilities()
        lastInput = AdvancedChargeInput(percentage: percentage, temperatureC: temperatureC,
                                        externalConnected: externalConnected, isCharging: isCharging,
                                        sleep: sleep, now: now, settings: settings, capabilities: capabilities,
                                        current: applied, topUpActive: topUpActive, memory: memory)
        reevaluate(now: now)
    }

    private func reevaluate(now: Date) {
        guard var input = lastInput else { return }
        input.now = now; input.sleep = sleep; input.settings = settings
        input.capabilities = capabilities; input.current = applied; input.memory = memory
        let output = AdvancedChargeEngine.evaluate(input)
        memory = output.memory
        display = output.display
        reason = output.reason
        sleepMayOvershoot = output.sleepMayOvershoot
        if memory.discharge != lastSaved.discharge || memory.calibration != lastSaved.calibration {
            store?.save(memory)
            lastSaved = memory
        }
        lastInput?.memory = memory
        // The helper releases everything on sleep, so never fight it while the Mac sleeps.
        guard sleep == .awake else { return }
        if output.desired != applied { apply(output.desired, now: now) }
        else { heartbeatIfDue(now: now) }
    }

    /// Popover status line while adapter mode holds the adapter cut; nil otherwise.
    var adapterStatusText: String? {
        guard display == .adapterCut else { return nil }
        let target = AdvancedChargeLimits.normalizedTarget(settings.targetLimit)
        let resume = AdvancedChargeEngine.adapterResumeAt(target: target, sailingDelta: settings.sailingDelta)
        return String(localized: "Adaptör kesildi — pilden çalışıyor, %\(resume) seviyesine inince açılır")
    }

    private func sleepMayOvershootUpdate(now: Date) {
        guard var input = lastInput else { return }
        input.sleep = sleep; input.now = now; input.memory = memory
        sleepMayOvershoot = AdvancedChargeEngine.evaluate(input).sleepMayOvershoot
    }

    private func apply(_ desired: ChargeInhibitState, now: Date) {
        do {
            applied = try backend.apply(desired)
            lastError = nil
            lastHeartbeat = now
        } catch {
            lastError = error.localizedDescription
            applied = (try? backend.readState()) ?? .released
        }
    }

    func heartbeatIfDue(now: Date) {
        guard applied != .released, now.timeIntervalSince(lastHeartbeat) >= ChargeInhibitSafety.heartbeatInterval else { return }
        do { try backend.heartbeat(); lastHeartbeat = now; lastError = nil }
        catch { lastError = error.localizedDescription }
    }

    /// Called on quit, backend replacement and `stop()`.
    func releaseAll() {
        guard applied != .released else { return }
        _ = try? backend.apply(.released)
        applied = .released
    }

    /// The helper released on its own (sleep, unplug, watchdog): wake handling re-reads the truth.
    func resyncFromBackend() {
        applied = (try? backend.readState()) ?? .released
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "advancedChargeSettings") }
    }
}
