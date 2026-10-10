import Combine
import Foundation

/// Faz 2 otomasyonlarının ince bağlantı katmanı. Kararlar saf türlerdedir (HeatProtection,
/// FullChargeDwell, ChargeHabits, OptimizedChargingHint); burası yalnızca BatteryMonitor
/// anlık görüntüsünü bunlara besler ve sonuçları mevcut yazma yolundan uygular.
@MainActor
final class HealthAutomation: ObservableObject {
    enum Keys {
        static let heatProtectionV1 = "heatProtectionV1Enabled"
        static let fullChargeDwell = "fullChargeDwellEnabled"
    }

    static let shared: HealthAutomation = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep")
        return HealthAutomation(battery: .shared, directory: directory, defaults: .standard)
    }()

    @Published private(set) var habitsSummary: ChargeHabitsSummary?
    @Published private(set) var advice: ChargeAdvice = .notEnoughData
    @Published private(set) var heatOverrideActive = false
    @Published private(set) var optimizedChargingNote: String?

    private let battery: BatteryMonitor
    private let defaults: UserDefaults
    private let overrideStore: HeatOverrideStore
    private let habitsStore: ChargeHabitsStore
    private let writeQueue = DispatchQueue(label: "io.github.berkinefeavci.cellkeep.health", qos: .utility)
    private var cancellable: AnyCancellable?
    private var heatOverride: HeatProtectionOverride?
    private var heatBusy = false
    private var lastHeatEvaluation = Date.distantPast
    private var dwell = FullChargeDwellState()
    private var optimizedHint = OptimizedChargingHintState()
    private var habits: ChargeHabitsData
    private var lastHabitsSave = Date.distantPast
    private var lastSummaryUpdate = Date.distantPast

    init(battery: BatteryMonitor, directory: URL, defaults: UserDefaults) {
        self.battery = battery
        self.defaults = defaults
        overrideStore = HeatOverrideStore(url: directory.appendingPathComponent("heat-override.json"))
        habitsStore = ChargeHabitsStore(url: directory.appendingPathComponent("charge-habits.json"))
        habits = habitsStore.load()
        heatOverride = overrideStore.load()
        heatOverrideActive = heatOverride != nil
        updateSummary(now: Date())
    }

    func start() {
        guard cancellable == nil else { return }
        HealthNotifications.shared.registerCategories()
        cancellable = battery.$snapshot.sink { [weak self] snapshot in
            MainActor.assumeIsolated { self?.observe(snapshot) }
        }
    }

    private var heatEnabled: Bool { defaults.bool(forKey: Keys.heatProtectionV1) }
    private var dwellEnabled: Bool { defaults.object(forKey: Keys.fullChargeDwell) as? Bool ?? true }

    private func observe(_ snapshot: BatterySnapshot) {
        guard snapshot.available else { return }
        let now = Date()
        recordHabits(snapshot, now: now)
        updateDwell(snapshot, now: now)
        updateOptimizedHint(snapshot, now: now)
        evaluateHeat(snapshot, now: now)
    }

    // MARK: Sağlık kartı

    private func recordHabits(_ snapshot: BatterySnapshot, now: Date) {
        habits = ChargeHabits.record(.init(date: now, percentage: snapshot.percentage,
                                           externalConnected: snapshot.externalConnected,
                                           isCharging: snapshot.isCharging, temperatureC: snapshot.temperatureC),
                                     into: habits, calendar: .current)
        if now.timeIntervalSince(lastHabitsSave) >= 60 {
            lastHabitsSave = now
            let data = habits, store = habitsStore
            writeQueue.async { try? store.save(data) }
        }
        if now.timeIntervalSince(lastSummaryUpdate) >= 60 { updateSummary(now: now) }
    }

    private func updateSummary(now: Date) {
        lastSummaryUpdate = now
        let summary = ChargeHabits.summary(habits, endingOn: LongTermHistory.dayKey(now, calendar: .current),
                                           calendar: .current)
        habitsSummary = summary
        advice = ChargeHabits.advice(summary)
    }

    // MARK: %100'de bekleme

    private func updateDwell(_ snapshot: BatterySnapshot, now: Date) {
        let canSuggest = battery.nativeLimit.map { $0 > HeatProtection.protectedLimit } ?? false
        let result = FullChargeDwell.step(dwell, percentage: snapshot.percentage,
                                          externalConnected: snapshot.externalConnected,
                                          enabled: dwellEnabled, canSuggestLimit: canSuggest, now: now)
        dwell = result.state
        if result.notify {
            HealthNotifications.shared.post(identifier: HealthNotifications.dwellIdentifier,
                                            title: FullChargeDwell.notificationTitle,
                                            body: FullChargeDwell.notificationBody, offerLimit80: true)
        }
    }

    func setLimit80FromNotification() {
        guard battery.nativeLimits.contains(HeatProtection.protectedLimit) else { return }
        let battery = battery
        writeQueue.async { _ = battery.applyAutomationLimit(HeatProtection.protectedLimit, source: .manual) }
    }

    // MARK: Optimize Şarj ipucu

    private func updateOptimizedHint(_ snapshot: BatterySnapshot, now: Date) {
        let result = OptimizedChargingHint.step(optimizedHint, percentage: snapshot.percentage,
                                                externalConnected: snapshot.externalConnected,
                                                isCharging: snapshot.isCharging, fullyCharged: snapshot.fullyCharged,
                                                temperatureC: snapshot.temperatureC, nativeLimit: battery.nativeLimit,
                                                now: now)
        optimizedHint = result.state
        let note = result.likelyHolding
            ? snapshot.percentage.flatMap { p in battery.nativeLimit.map { OptimizedChargingHint.explanation(percentage: p, nativeLimit: $0) } }
            : nil
        if note != optimizedChargingNote { optimizedChargingNote = note }
    }

    // MARK: Isı koruması v1

    private func evaluateHeat(_ snapshot: BatterySnapshot, now: Date) {
        guard !heatBusy, now.timeIntervalSince(lastHeatEvaluation) >= 15 else { return }
        lastHeatEvaluation = now
        var recovery = false
        if case .recoveryRequired = battery.policyState { recovery = true }
        let blocked = recovery || battery.policyConflict != nil || battery.controlRecoveryRequired
            || battery.otherControllerRunning || battery.applyingLimit
        let input = HeatProtectionInput(enabled: heatEnabled, temperatureC: snapshot.temperatureC,
                                        externalConnected: snapshot.externalConnected, isCharging: snapshot.isCharging,
                                        nativeLimit: battery.nativeLimit, availableLimits: battery.nativeLimits,
                                        adapterMode: battery.adapterPowerMode, topUpActive: battery.topUpActive,
                                        controlBlocked: blocked, override: heatOverride)
        switch HeatProtection.decide(input) {
        case .none: break
        case .forgetOverride:
            try? overrideStore.clear()
            heatOverride = nil
            heatOverrideActive = false
        case .engage(let previous, let limit, let modeFrom):
            engage(previous: previous, limit: limit, modeFrom: modeFrom, temperatureC: snapshot.temperatureC ?? 0, now: now)
        case .restore(let limit, let mode):
            restore(limit: limit, mode: mode)
        }
    }

    private func engage(previous: Int, limit: Int, modeFrom: SystemPowerMode?, temperatureC: Double, now: Date) {
        let record = HeatProtectionOverride(previousLimit: previous,
                                            previousAdapterModeRawValue: modeFrom?.rawValue, startedAt: now)
        // Önce kaydet: yazma sonrası çökme olsa bile açılışta eski sınır geri verilebilir.
        do { try overrideStore.save(record) } catch { return }
        heatBusy = true
        let battery = battery
        writeQueue.async { [weak self] in
            let result = battery.applyAutomationLimit(limit, source: .heatProtection)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.heatBusy = false
                    guard result.status == .configurationVerified else {
                        try? self.overrideStore.clear()
                        self.lastHeatEvaluation = Date().addingTimeInterval(300)
                        return
                    }
                    self.heatOverride = record
                    self.heatOverrideActive = true
                    if modeFrom != nil { battery.applyPowerMode(.automatic, source: .adapter) }
                    HealthNotifications.shared.post(
                        identifier: HealthNotifications.heatIdentifier,
                        title: String(localized: "Pil sıcak: şarj sınırı %80'e çekildi"),
                        body: HeatProtection.notificationBody(temperatureC: temperatureC, modeChanged: modeFrom != nil),
                        offerLimit80: false)
                }
            }
        }
    }

    private func restore(limit: Int, mode: SystemPowerMode?) {
        heatBusy = true
        let battery = battery
        writeQueue.async { [weak self] in
            let result = battery.applyAutomationLimit(limit, source: .heatProtection)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.heatBusy = false
                    // Başarısızsa kayıt kalır; bir sonraki değerlendirme yeniden dener.
                    guard result.status == .configurationVerified else {
                        self.lastHeatEvaluation = Date().addingTimeInterval(300)
                        return
                    }
                    try? self.overrideStore.clear()
                    self.heatOverride = nil
                    self.heatOverrideActive = false
                    if let mode { battery.applyPowerMode(mode, source: .adapter) }
                }
            }
        }
    }
}
