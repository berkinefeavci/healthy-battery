import Combine
import Foundation

/// The ONE file (besides the helper backend itself) that may reference the charge-inhibit helper.
/// Wires the opt-in adapter mode: backend injection into `AdvancedChargeRunner`, the BatteryMonitor
/// target/ceiling mode, rival detection, and the explicit "install helper" user action.
/// Once the helper is installed and its physical self-test passed, the same adapter cut also serves the
/// on-demand Discharge and Calibration, with adapter mode on or off. Calibration lifts the macOS limit
/// through Top Up for its full-charge phases, and the Mac is kept from idle sleep while either runs
/// (the adapter always comes back before sleep, so sleeping would only pause them).
/// Nothing here installs anything on its own; `installHelperFromUserAction` is only called by a button.
final class AdapterModeController: ObservableObject {
    static let shared = AdapterModeController()
    static let defaultsKey = "adapterModeEnabled"

    private enum Kind { case none, adapter, debug }

    @Published private(set) var enabled: Bool
    @Published private(set) var helperInstalled = false
    @Published private(set) var active = false
    @Published private(set) var installing = false
    @Published private(set) var message: String?
    @Published private(set) var selfTestRunning = false
    @Published private(set) var selfTestReport = AdapterSelfTestStore.load()

    var selfTestPassed: Bool { selfTestReport?.outcome == .passed }

    private let defaults: UserDefaults
    private let runner: AdvancedChargeRunner
    private let battery: BatteryMonitor
    private var kind = Kind.none
    private var cancellables = Set<AnyCancellable>()
    /// Top Up started by calibration, so cancelling calibration also ends it, even after a restart.
    private var calibrationTopUp: Bool {
        get { defaults.bool(forKey: "calibrationStartedTopUp") }
        set { defaults.set(newValue, forKey: "calibrationStartedTopUp") }
    }
    private var lastCalibrationTopUpStart = Date.distantPast
    private var awakeAssertion: UInt32?

    init(defaults: UserDefaults = .standard, runner: AdvancedChargeRunner = .shared, battery: BatteryMonitor = .shared) {
        self.defaults = defaults
        self.runner = runner
        self.battery = battery
        enabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func start() {
        guard cancellables.isEmpty else { return }
        battery.scheduleAdapterCut = { [weak self] in self?.adapterCutAvailable ?? false }
        refreshHelperState()
        runner.$capabilities.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }.store(in: &cancellables)
        battery.$otherControllerRunning.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }.store(in: &cancellables)
        battery.$chargeLimit.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncTarget() }
        }.store(in: &cancellables)
        runner.$applied.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncCutFlag() }
        }.store(in: &cancellables)
        runner.$memory.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.driveRequests() }
        }.store(in: &cancellables)
        battery.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.driveRequests() }
        }.store(in: &cancellables)
        battery.$snapshot.map(\.externalConnected).removeDuplicates().sink { [weak self] plugged in
            if plugged { DispatchQueue.main.async { self?.runPendingSelfTest() } }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncHeat() }
        }.store(in: &cancellables)
        syncHeat()
        reconcile()
        runPendingSelfTest()
    }

    // MARK: On-demand discharge and calibration

    /// The adapter cut is verified on this Mac (helper installed, self-test passed, nothing else in charge).
    var adapterCutAvailable: Bool { kind == .adapter && runner.capabilities.canForceDischarge }

    /// Discharge stops at the adapter target in adapter mode, otherwise at the limit macOS holds.
    var dischargeLimit: Int {
        let limit = battery.adapterModeActive ? Int(battery.chargeLimit) : (battery.nativeLimit ?? Int(battery.chargeLimit))
        return AdvancedChargeLimits.normalizedTarget(limit)
    }

    var dischargeRunning: Bool { runner.memory.discharge != nil }
    var calibrationRunning: Bool { runner.memory.calibration != nil }

    /// Why Discharge cannot start now; nil when it can.
    var dischargeBlockReason: String? { dischargeBlockReason(to: dischargeLimit) }

    func dischargeBlockReason(to level: Int) -> String? {
        if let reason = adapterCutBlockReason { return reason }
        guard let percent = battery.snapshot.percentage, Int(percent) > level else {
            return String(localized: "Pil zaten %\(level) ya da altında")
        }
        return nil
    }

    /// Why the adapter cut cannot be used right now (helper, test, rival app, cable); nil when it can.
    private var adapterCutBlockReason: String? {
        if !helperInstalled { return String(localized: "Deşarj için Ayarlar → Şarj Kontrolü'nden şarj yardımcısını kurun") }
        if !selfTestPassed { return String(localized: "Deşarj, adaptör testi geçince kullanılabilir") }
        if !adapterCutAvailable { return String(localized: "Başka bir şarj uygulaması açık ya da adaptör testi sürüyor") }
        if !battery.snapshot.externalConnected && !battery.adapterCutByApp { return String(localized: "Adaptör bağlı değil") }
        return nil
    }

    func toggleDischarge() {
        if dischargeRunning { runner.cancelDischarge(); return }
        _ = startDischarge()
    }

    func startCalibration() { _ = beginCalibration() }

    /// Panel button, schedule and Shortcuts entry point. `level` nil = the current limit.
    @discardableResult
    func startDischarge(to level: Int? = nil) -> Result<String, ScheduleAdapterRefusal> {
        if dischargeRunning { return .failure(.init(message: String(localized: "Bir deşarj zaten sürüyor."))) }
        if calibrationRunning { return .failure(.init(message: String(localized: "Kalibrasyon sürüyor; deşarj başlatılmadı."))) }
        let target = AdvancedChargeLimits.normalizedTarget(level ?? dischargeLimit)
        if let reason = dischargeBlockReason(to: target) {
            return .failure(.init(message: reason, conflict: helperInstalled && selfTestPassed))
        }
        runner.requestDischarge(to: target)
        return .success(String(localized: "Deşarj başladı: pil %\(target) seviyesine iniyor"))
    }

    @discardableResult
    func beginCalibration() -> Result<String, ScheduleAdapterRefusal> {
        if calibrationRunning { return .failure(.init(message: String(localized: "Kalibrasyon zaten sürüyor."))) }
        if let reason = adapterCutBlockReason {
            return .failure(.init(message: reason, conflict: helperInstalled && selfTestPassed))
        }
        if dischargeRunning { runner.cancelDischarge() } // calibration includes its own discharge
        runner.startCalibration()
        return .success(String(localized: "Kalibrasyon başladı (en fazla 24 saat)."))
    }

    func cancelCalibration() { runner.cancelCalibration() }

    /// Runs on every snapshot and engine memory change: Top Up for calibration's full-charge phases and the
    /// idle-sleep assertion while a discharge or calibration runs.
    private func driveRequests() {
        let busy = dischargeRunning || calibrationRunning
        if busy, awakeAssertion == nil {
            awakeAssertion = try? SleepAssertionBackend.acquire(
                reason: String(localized: "Healthy Battery deşarj ya da kalibrasyon yürütüyor"))
        } else if !busy, let id = awakeAssertion {
            SleepAssertionBackend.release(id)
            awakeAssertion = nil
        }
        guard let calibration = runner.memory.calibration else {
            if calibrationTopUp {
                calibrationTopUp = false
                if battery.topUpActive { battery.stopTopUp() }
            }
            return
        }
        let needsFull = calibration.phase == .chargeToFull || calibration.phase == .rechargeToFull
        if battery.topUpActive || !needsFull { if !battery.topUpActive { calibrationTopUp = false }; return }
        guard let percent = battery.snapshot.percentage, percent < 99,
              battery.topUpControlAvailable,
              Date().timeIntervalSince(lastCalibrationTopUpStart) > 600 else { return }
        lastCalibrationTopUpStart = Date()
        calibrationTopUp = true
        battery.startTopUp()
    }

    /// The one heat switch (Settings > Charge control) also drives adapter mode's heat cut.
    private func syncHeat() {
        let on = defaults.bool(forKey: "heatProtectionV1Enabled")
        if runner.settings.heatProtectionEnabled != on { runner.settings.heatProtectionEnabled = on }
    }

    func refreshHelperState() { helperInstalled = ChargeInhibitHelperService.installed() }

    /// User toggle. Refuses (with a message) when a rival controller runs or the helper is missing.
    func setEnabled(_ on: Bool) {
        message = nil
        refreshHelperState()
        if on {
            let rivals = ChargeControllerDetector.current()
            if !rivals.isEmpty {
                message = String(localized: "Başka bir şarj uygulaması açık (\(rivals.joined(separator: ", "))). Adaptör modu için önce onu kapatın.")
                return
            }
            guard helperInstalled else {
                message = String(localized: "Önce şarj yardımcısını kurun.")
                return
            }
            guard selfTestPassed else {
                message = selfTestRunning ? String(localized: "Adaptör testi sürüyor; bitince açabilirsiniz.")
                    : String(localized: "Adaptör modu, otomatik adaptör testi geçince açılabilir.")
                if !selfTestRunning { runSelfTest() }
                return
            }
        }
        enabled = on
        defaults.set(on, forKey: Self.defaultsKey)
        reconcile()
        if on, !active, message == nil {
            message = runner.capabilities.reason ?? String(localized: "Bu Mac adaptör kesmeyi doğrulamadı.")
            enabled = false
            defaults.set(false, forKey: Self.defaultsKey)
            reconcile()
        }
    }

    /// Runs the one-admin-prompt helper install. Only ever called from a user button.
    func installHelperFromUserAction() {
        guard !installing else { return }
        installing = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: String? = {
                do { try ChargeInhibitHelperService.install(); return nil }
                catch { return error.localizedDescription }
            }()
            DispatchQueue.main.async {
                self.installing = false
                self.message = failure
                self.refreshHelperState()
                if failure == nil {
                    self.selfTestReport = nil // a fresh helper gets a fresh physical test
                    self.runPendingSelfTest()
                }
            }
        }
    }

    /// Physical check of adapter mode (`AdapterSelfTest`): a few minutes, the Mac briefly runs from
    /// the battery. Runs only while nothing else drives the helper, and always ends released.
    func runSelfTest() {
        guard !selfTestRunning else { return }
        message = nil
        refreshHelperState()
        guard helperInstalled else {
            message = String(localized: "Önce şarj yardımcısını kurun.")
            return
        }
        guard !enabled else {
            message = String(localized: "Test için önce adaptör modunu kapatın.")
            return
        }
        guard !dischargeRunning, !calibrationRunning else {
            message = String(localized: "Test için önce süren deşarjı ya da kalibrasyonu durdurun.")
            return
        }
        let rivals = ChargeControllerDetector.current()
        guard rivals.isEmpty else {
            message = String(localized: "Başka bir şarj uygulaması açık (\(rivals.joined(separator: ", "))). Adaptör modu için önce onu kapatın.")
            return
        }
        selfTestRunning = true
        reconcile() // the test drives the helper alone: the runner lets go of it first
        syncCutFlag()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        DispatchQueue.global(qos: .utility).async {
            var report = AdapterSelfTest(request: { try ChargeInhibitHelperService.request($0) },
                                         sample: AdapterSelfTestProbe.live).run()
            report.model = ChargeMateDiagnostics.machineModel()
            report.system = ProcessInfo.processInfo.operatingSystemVersionString
            report.appVersion = version
            AdapterSelfTestStore.save(report)
            DispatchQueue.main.async {
                self.selfTestRunning = false
                self.selfTestReport = report
                self.reconcile()
                self.syncCutFlag()
            }
        }
    }

    // MARK: Internals

    private func reconcile() {
        refreshHelperState()
        let rival = battery.otherControllerRunning
        var wanted = Kind.none
        if (enabled || selfTestPassed), helperInstalled, !rival, !selfTestRunning { wanted = .adapter }
        else if ChargeInhibitUnlock.isUnlocked(), !selfTestRunning { wanted = .debug }
        if enabled, rival, message == nil {
            message = String(localized: "Başka bir şarj uygulaması açık; adaptör modu bekletiliyor.")
        }
        if wanted != kind {
            kind = wanted
            switch wanted {
            case .none: runner.replaceBackend(UnsupportedChargeInhibitBackend())
            case .adapter: runner.replaceBackend(ChargeInhibitHelperBackend(isUnlocked: { true }))
            case .debug: runner.replaceBackend(ChargeInhibitHelperBackend())
            }
        }
        let caps = runner.capabilities
        let nowActive = enabled && kind == .adapter && caps.canForceDischarge && !caps.canInhibitCharging
        if runner.settings.adapterModeEnabled != nowActive { runner.settings.adapterModeEnabled = nowActive }
        if nowActive { syncTarget() }
        if nowActive != active {
            active = nowActive
            battery.setAdapterMode(active: nowActive)
        }
    }

    /// Installing the helper is the go-ahead: the test runs on its own (after install, at launch or when
    /// the adapter is plugged in) until it has a real result. A failed test is only re-run by the user.
    private func runPendingSelfTest() {
        guard !selfTestRunning, selfTestReport == nil || selfTestReport?.outcome == .skipped else { return }
        refreshHelperState()
        guard helperInstalled, !enabled, ChargeControllerDetector.current().isEmpty else { return }
        runSelfTest()
    }

    /// Tells the rest of the app that a missing adapter is our own doing, so it is not treated as an unplug.
    private func syncCutFlag() {
        battery.adapterCutByApp = selfTestRunning || runner.applied.adapterInhibited
    }

    private func syncTarget() {
        guard active else { return }
        let target = AdvancedChargeLimits.normalizedTarget(Int(battery.chargeLimit))
        if runner.settings.targetLimit != target { runner.settings.targetLimit = target }
    }
}
