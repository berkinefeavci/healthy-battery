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

    @Published private(set) var applied = ChargeInhibitState.released
    private var backend: ChargeInhibitBackend
    private let store: AdvancedChargeMemoryStore?
    private let defaults: UserDefaults
    private var sleep = SleepState.awake
    private var lastHeartbeat = Date.distantPast
    private var lastInput: AdvancedChargeInput?
    private var timer: Timer?
    private var lastSaved = AdvancedChargeMemory()
    /// The helper answers a capability query over IPC; telemetry arrives every few seconds, so ask at most
    /// this often (a new backend, sleep/wake and every apply still check right away).
    static let capabilityRefreshInterval: TimeInterval = 30
    private var lastCapabilityCheck = Date.distantPast

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
        lastCapabilityCheck = Date()
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

    /// Runs from the battery down to `target` (default: the advanced target limit), then restores the adapter.
    func requestDischarge(to target: Int? = nil, now: Date = Date()) {
        guard capabilities.canForceDischarge else { return }
        memory.discharge = DischargeRequest(requestedAt: now, target: target)
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
        if state == .awake { capabilities = backend.capabilities(); resyncFromBackend(); reevaluate(now: now) } else { sleepMayOvershootUpdate(now: now) }
    }

    // MARK: Telemetry

    func update(percentage: Int, temperatureC: Double?, externalConnected: Bool, isCharging: Bool,
                topUpActive: Bool, now: Date = Date()) {
        if abs(now.timeIntervalSince(lastCapabilityCheck)) >= Self.capabilityRefreshInterval {
            capabilities = backend.capabilities()
            lastCapabilityCheck = now
        }
        // While we hold the adapter cut macOS reports no external power. The helper checks the cable itself
        // (SMC AC-W) and releases on a real unplug, so a cut it still holds means the cable is in.
        var plugged = externalConnected
        if !plugged, applied.adapterInhibited {
            resyncFromBackend()
            plugged = applied.adapterInhibited
        }
        lastInput = AdvancedChargeInput(percentage: percentage, temperatureC: temperatureC,
                                        externalConnected: plugged, isCharging: isCharging,
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

    /// Popover status line while Healthy Battery holds the adapter cut; nil otherwise.
    var adapterStatusText: String? {
        switch display {
        case .adapterCut:
            let target = AdvancedChargeLimits.normalizedTarget(settings.targetLimit)
            let resume = AdvancedChargeEngine.adapterResumeAt(target: target, settings: settings)
            return String(localized: "Adaptör kesildi — pilden çalışıyor, %\(resume) seviyesine inince açılır")
        case .discharging:
            return String(localized: "Deşarj: adaptör kesildi, pil %\(dischargeTarget) seviyesine inince geri açılır")
        case .calibrating(.dischargeToLow):
            return String(localized: "Kalibrasyon: adaptör kesildi, pil %\(AdvancedChargeLimits.calibrationLow) seviyesine iniyor")
        case .heatPaused where !capabilities.canInhibitCharging:
            return String(localized: "Pil sıcak: adaptör kesildi, pil soğuyunca şarj sürer")
        default:
            return nil
        }
    }

    /// Level the running (or next) discharge stops at.
    var dischargeTarget: Int {
        memory.discharge?.target.map(AdvancedChargeLimits.normalizedTarget)
            ?? AdvancedChargeLimits.normalizedTarget(settings.targetLimit)
    }

    /// Headline for the panel's status card while Healthy Battery itself steers the adapter; nil leaves
    /// the macOS policy title (the native limit) in place.
    var panelTitle: String? {
        guard !capabilities.canInhibitCharging, capabilities.canForceDischarge else { return nil }
        let target = AdvancedChargeLimits.normalizedTarget(settings.targetLimit)
        switch display {
        case .adapterCut: return String(localized: "Adaptör modu: hedef %\(target), pilden çalışıyor")
        case .idle where settings.adapterModeEnabled: return String(localized: "Adaptör modu: hedef %\(target)")
        case .discharging: return String(localized: "Deşarj: %\(dischargeTarget) seviyesine iniyor")
        case .heatPaused: return String(localized: "Isı koruması: adaptör kesildi")
        case .calibrating(let phase): return Self.calibrationTitle(phase)
        default: return nil
        }
    }

    static func calibrationTitle(_ phase: CalibrationPhase) -> String {
        switch phase {
        case .chargeToFull: return String(localized: "Kalibrasyon 1/4: %100'e şarj")
        case .hold: return String(localized: "Kalibrasyon 2/4: %100'de 1 saat bekleme")
        case .dischargeToLow: return String(localized: "Kalibrasyon 3/4: %\(AdvancedChargeLimits.calibrationLow) seviyesine deşarj")
        case .rechargeToFull: return String(localized: "Kalibrasyon 4/4: yeniden %100'e şarj")
        }
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
