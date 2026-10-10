import Combine
import Foundation

/// The ONE file (besides the helper backend itself) that may reference the charge-inhibit helper.
/// Wires the opt-in adapter mode: backend injection into `AdvancedChargeRunner`, the BatteryMonitor
/// target/ceiling mode, rival detection, and the explicit "install helper" user action.
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

    init(defaults: UserDefaults = .standard, runner: AdvancedChargeRunner = .shared, battery: BatteryMonitor = .shared) {
        self.defaults = defaults
        self.runner = runner
        self.battery = battery
        enabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func start() {
        guard cancellables.isEmpty else { return }
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
        runner.$display.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncCutFlag() }
        }.store(in: &cancellables)
        battery.$snapshot.map(\.externalConnected).removeDuplicates().sink { [weak self] plugged in
            if plugged { DispatchQueue.main.async { self?.runPendingSelfTest() } }
        }.store(in: &cancellables)
        reconcile()
        runPendingSelfTest()
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
        guard kind == .none else {
            message = String(localized: "Test için önce adaptör modunu kapatın.")
            return
        }
        let rivals = ChargeControllerDetector.current()
        guard rivals.isEmpty else {
            message = String(localized: "Başka bir şarj uygulaması açık (\(rivals.joined(separator: ", "))). Adaptör modu için önce onu kapatın.")
            return
        }
        selfTestRunning = true
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
                self.syncCutFlag()
            }
        }
    }

    // MARK: Internals

    private func reconcile() {
        refreshHelperState()
        let rival = battery.otherControllerRunning
        var wanted = Kind.none
        if enabled, helperInstalled, !rival { wanted = .adapter }
        else if ChargeInhibitUnlock.isUnlocked() { wanted = .debug }
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
        let nowActive = kind == .adapter && caps.canForceDischarge && !caps.canInhibitCharging
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
        guard helperInstalled, kind == .none, ChargeControllerDetector.current().isEmpty else { return }
        runSelfTest()
    }

    /// Tells the rest of the app that a missing adapter is our own doing, so it is not treated as an unplug.
    private func syncCutFlag() {
        let display = runner.display
        battery.adapterCutByApp = selfTestRunning || display == .adapterCut || display == .discharging
            || display == .calibrating(.dischargeToLow)
    }

    private func syncTarget() {
        guard active else { return }
        let target = AdvancedChargeLimits.normalizedTarget(Int(battery.chargeLimit))
        if runner.settings.targetLimit != target { runner.settings.targetLimit = target }
    }
}
