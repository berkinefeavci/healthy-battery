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
        reconcile()
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

    private func syncTarget() {
        guard active else { return }
        let target = AdvancedChargeLimits.normalizedTarget(Int(battery.chargeLimit))
        if runner.settings.targetLimit != target { runner.settings.targetLimit = target }
    }
}
