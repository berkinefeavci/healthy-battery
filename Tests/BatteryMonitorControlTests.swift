import Foundation
import Combine

private final class FakeNative {
    private let lock = NSLock()
    var limit = 90
    var reject = false
    private var writes = 0
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func read() -> NativeChargeState {
        lock.lock(); defer { lock.unlock() }
        return NativeChargeState(manualLimit: limit, availableLimits: [80, 85, 90, 95, 100],
                                 enabledRaw: 1, currentLimit: 100)
    }
    func write(_ requested: Int) throws -> NativeChargeState {
        lock.lock(); writes += 1
        if reject { lock.unlock(); throw NativeChargeBackendError.rejected("synthetic failure") }
        limit = requested
        lock.unlock()
        return read()
    }

    func backend() -> NativeChargeBackend {
        NativeChargeBackend(version: "fake-monitor", timeout: 0.1) { arguments, _ in
            let state: NativeChargeState
            if arguments == ["read"] { state = self.read() }
            else if arguments.count == 2, arguments[0] == "set", let value = Int(arguments[1]) {
                state = try self.write(value)
            } else { throw NativeChargeBackendError.rejected("unexpected fake command") }
            let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, ok: true, state: state))
            return NativeChargeProcessResult(status: 0, output: data)
        }
    }

    private struct Envelope: Encodable {
        let schemaVersion: Int
        let ok: Bool
        let state: NativeChargeState
    }
}

@main enum BatteryMonitorControlTests {
    static func main() throws {
        precondition(Thread.isMainThread)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-monitor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "local.chargemate.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        defaults.set(true, forKey: "heatProtection")
        defaults.set(true, forKey: "sailingEnabled")
        defaults.set(42.0, forKey: "maxTemp")
        defaults.set(80.0, forKey: "chargeLimit")
        defaults.set(true, forKey: "automaticControlEnabled")
        let historyURL = root.appendingPathComponent("history.json")
        let oldHistory = Data("[]".utf8)
        try oldHistory.write(to: historyURL)
        let native = FakeNative()
        var rival = false
        var providedSnapshot = BatterySnapshot()
        var powerProfiles = SystemPowerModeProfiles(battery: .lowPower, adapter: .turbo)
        var powerWrites: [(SystemPowerSource, SystemPowerMode)] = []
        let journal = root.appendingPathComponent("control-session.json")
        func makeMonitor() -> BatteryMonitor {
            let backend = native.backend()
            let coordinator = ChargeControlCoordinator(journal: journal, backend: backend, rival: { rival })
            let policyController = ChargePolicyController(
                backend: backend, coordinator: coordinator,
                policyStore: ChargePolicyStore(url: root.appendingPathComponent("charge-policy.json")),
                sessionStore: TopUpSessionStore(url: root.appendingPathComponent("charge-session.json")),
                rival: { rival })
            return BatteryMonitor(defaults: defaults, policyController: policyController, historyURL: historyURL,
                batteryReader: { providedSnapshot }, nativeReader: { native.read() },
                controllerRunning: { rival }, energyReader: { .success([]) },
                connectedDeviceReader: {
                    [ConnectedDevice(id: "phone", name: "iPhone", vendor: "Apple", kind: .phone)]
                },
                powerModeReader: { powerProfiles },
                powerModeWriter: { mode, source in
                    powerWrites.append((source, mode))
                    switch source {
                    case .battery: powerProfiles = .init(battery: mode, adapter: powerProfiles.adapter)
                    case .adapter: powerProfiles = .init(battery: powerProfiles.battery, adapter: mode)
                    case .all: powerProfiles = .init(battery: mode, adapter: mode)
                    }
                    return .success(mode)
                })
        }
        var assertions = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); assertions += 1 }
        func until(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !condition(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "async production callback timed out")
        }
        let monitor = makeMonitor()
        check(MonitorCadence.refreshInterval == 5, "ordinary sensor refresh uses five-second cadence")
        check(!MonitorCadence.shouldEvaluatePolicy(topUpActive: false, trigger: .telemetry, elapsed: 5),
              "idle policy skips ordinary fast refresh")
        check(MonitorCadence.shouldEvaluatePolicy(topUpActive: false, trigger: .telemetry, elapsed: 30),
              "idle policy checks every thirty seconds")
        check(MonitorCadence.shouldEvaluatePolicy(topUpActive: true, trigger: .telemetry, elapsed: 5),
              "active Top Up follows each sensor refresh")
        check(MonitorCadence.shouldEvaluatePolicy(topUpActive: false, trigger: .wake, elapsed: 0),
              "wake forces immediate policy check")
        var deliveries = 0
        let observation = monitor.$snapshot.sink { _ in deliveries += 1 }
        defer { observation.cancel(); monitor.stop() }
        monitor.start()
        until { monitor.nativeLimit == 90 && monitor.batteryPowerMode == .lowPower
            && monitor.adapterPowerMode == .turbo && monitor.connectedDevices.first?.name == "iPhone" }
        check(monitor.connectedDevices.first?.kind == .phone,
              "refresh publishes read-only connected device observations")
        check(monitor.selectedPowerMode == .lowPower,
              "battery source exposes its own native power profile")
        providedSnapshot.externalConnected = true
        let beforeSourceChange = deliveries
        monitor.refresh()
        until { deliveries > beforeSourceChange && monitor.selectedPowerMode == .turbo }
        check(powerWrites.isEmpty,
              "source transition selects stored adapter profile without a write")
        monitor.applyPowerMode(.automatic, source: .adapter)
        until { !monitor.applyingPowerMode }
        check(powerWrites.last?.0 == .adapter && powerWrites.last?.1 == .automatic
              && monitor.adapterPowerMode == .automatic && monitor.selectedPowerMode == .automatic,
              "adapter control writes only adapter profile and refreshes active state")
        providedSnapshot.externalConnected = false
        monitor.stop()
        for _ in 0..<30 {
            let previous = deliveries
            monitor.refresh()
            until { deliveries > previous }
        }
        check(native.writeCount == 0, "startup migration plus 30 real refresh callbacks writer zero")
        check(monitor.heatProtection && monitor.sailingEnabled && monitor.maxTemp == 42 && monitor.chargeLimit == 80,
              "legacy preference values preserved")
        check(!defaults.bool(forKey: "automaticControlEnabled") && defaults.integer(forKey: "preferencesSchemaVersion") == 2,
              "legacy preferences never authorize automatic control")
        check(monitor.committedLimit == nil, "legacy draft must not become confirmed")
        for target in [80.0, 50, 95] { monitor.chargeLimit = target }
        check(native.writeCount == 0, "draft and presets writer zero")
        monitor.cancelDraftLimit()
        check(monitor.chargeLimit == 90 && native.writeCount == 0, "draft cancellation uses observed native value without writing")
        check(try Data(contentsOf: historyURL) == oldHistory, "startup and controls preserve history")
        monitor.chargeLimit = 85
        rival = true
        monitor.applyNativeLimit()
        check(!monitor.applyingLimit && native.writeCount == 0, "direct Apply obeys controller gate")
        rival = false
        monitor.applyNativeLimit()
        until { !monitor.applyingLimit }
        check(monitor.committedLimit == 85 && native.writeCount == 1, "production Apply commits only after readback")
        native.reject = true
        monitor.chargeLimit = 95
        monitor.applyNativeLimit()
        until { !monitor.applyingLimit }
        check(monitor.committedLimit == 85 && monitor.chargeLimit == 95 && monitor.controlRecoveryRequired && native.writeCount == 2,
              "failed production Apply preserves committed and draft, no rollback")
        monitor.reconcileNativeLimit(expectedLimit: 85)
        until { !monitor.applyingLimit }
        check(!monitor.controlRecoveryRequired && native.writeCount == 2 && monitor.committedLimit == 85,
              "production recovery no write or implicit commit")
        let restart = makeMonitor()
        check(restart.chargeLimit == 95 && restart.committedLimit == 85 && native.writeCount == 2,
              "restart restores draft and confirmed separately, writer zero")
        check(defaults.integer(forKey: "preferencesSchemaVersion") == 2 && restart.heatProtection && restart.maxTemp == 42,
              "second startup preserves migration")
        monitor.chargeLimit = .nan
        monitor.applyNativeLimit()
        check(!monitor.applyingLimit && native.writeCount == 2, "invalid direct input rejected without integer conversion trap")
        native.reject = false
        providedSnapshot.available = true
        providedSnapshot.externalConnected = true
        providedSnapshot.isCharging = true
        providedSnapshot.percentage = 85
        providedSnapshot.hardwarePercentage = 85
        providedSnapshot.wattage = 8
        providedSnapshot.sampledAt = Date()
        let beforePluggedRefresh = deliveries
        monitor.refresh()
        until { deliveries > beforePluggedRefresh }
        check(monitor.percentageText == "%85", "percentageText uses Turkish %85 style, not \"85 %\"")
        monitor.startTopUp()
        until { !monitor.applyingLimit }
        check(monitor.topUpActive && native.limit == 100 && native.writeCount == 3,
              "Top Up is functional and persists verified 100")
        providedSnapshot.externalConnected = false
        providedSnapshot.isCharging = false
        providedSnapshot.wattage = 0
        providedSnapshot.sampledAt = Date()
        let beforeUnplugRefresh = deliveries
        monitor.refresh()
        until { deliveries > beforeUnplugRefresh && !monitor.topUpActive }
        check(native.limit == 85 && native.writeCount == 4,
              "active Top Up restores exact prior limit on unplug once")
        let writesAfterRestore = native.writeCount
        monitor.refresh()
        until { !monitor.topUpActive }
        check(native.writeCount == writesAfterRestore, "ordinary refresh does not duplicate restore")
        native.limit = 90
        providedSnapshot.externalConnected = true
        providedSnapshot.sampledAt = Date()
        monitor.handleWake()
        until { monitor.policyConflict != nil }
        check(native.writeCount == writesAfterRestore,
              "wake with normal policy conflict writes zero")

        var shortcutLimitResult: ChargeControlCoordinator.Result?
        Task { @MainActor in
            shortcutLimitResult = await monitor.applyShortcutLimit(80)
        }
        until { shortcutLimitResult != nil }
        check(shortcutLimitResult?.status == .configurationVerified && native.limit == 80,
              "Shortcut limit uses production policy controller")
        let shortcutJournal = try JSONDecoder().decode(ChargeControlCoordinator.Session.self,
                                                       from: Data(contentsOf: journal))
        check(shortcutJournal.source == .shortcut,
              "Shortcut limit records its source in the sole coordinator journal")

        var shortcutTopUpResult: ChargeControlCoordinator.Result?
        Task { @MainActor in
            shortcutTopUpResult = await monitor.startShortcutTopUp()
        }
        until { shortcutTopUpResult != nil }
        check(shortcutTopUpResult?.status == .configurationVerified && monitor.topUpActive && native.limit == 100,
              "Shortcut Top Up starts through production policy controller")

        var shortcutCancelResult: ChargeControlCoordinator.Result?
        Task { @MainActor in
            shortcutCancelResult = await monitor.cancelShortcutTopUp()
        }
        until { shortcutCancelResult != nil }
        check(shortcutCancelResult?.status == .configurationVerified && !monitor.topUpActive && native.limit == 80,
              "Shortcut Top Up cancel restores exact committed limit")

        let coldMonitor = makeMonitor()
        var coldShortcutResult: ChargeControlCoordinator.Result?
        Task { @MainActor in
            coldShortcutResult = await coldMonitor.startShortcutTopUp(snapshot: providedSnapshot)
        }
        until { coldShortcutResult != nil }
        check(coldShortcutResult?.status == .configurationVerified && coldMonitor.topUpActive,
              "Shortcut supplies fresh telemetry before app monitor timer starts")
        var coldCancelResult: ChargeControlCoordinator.Result?
        Task { @MainActor in
            coldCancelResult = await coldMonitor.cancelShortcutTopUp(snapshot: providedSnapshot)
        }
        until { coldCancelResult != nil }
        check(coldCancelResult?.status == .configurationVerified && !coldMonitor.topUpActive && native.limit == 80,
              "cold Shortcut cancel restores committed target")

        // Adapter mode: the main limit is the target (20-100); macOS keeps a sleep ceiling.
        check(BatteryMonitor.adapterCeiling(forTarget: 20) == 80 && BatteryMonitor.adapterCeiling(forTarget: 75) == 80
              && BatteryMonitor.adapterCeiling(forTarget: 80) == 80 && BatteryMonitor.adapterCeiling(forTarget: 81) == 85
              && BatteryMonitor.adapterCeiling(forTarget: 87) == 90 && BatteryMonitor.adapterCeiling(forTarget: 100) == 100,
              "adapter ceiling is max(80, target rounded up to 5)")
        check(monitor.barLimits == [80, 85, 90, 95, 100] && !monitor.adapterModeActive, "bar keeps native limits by default")
        until { !monitor.applyingLimit }
        monitor.chargeLimit = 60
        monitor.setAdapterMode(active: true)
        until { !monitor.applyingLimit && monitor.committedLimit == 80 }
        check(monitor.adapterModeActive && monitor.barLimits.first == 20 && monitor.barLimits.count == 17
              && monitor.shownTarget == 60 && monitor.chargeLimit == 60 && native.limit == 80,
              "adapter mode opens 20-100 bar and holds an 80 ceiling")
        check(monitor.policyConflict == nil, "adapter ceiling is the policy desired value: no conflict")
        monitor.chargeLimit = 87
        monitor.applyNativeLimit()
        until { !monitor.applyingLimit && native.limit == 90 }
        check(monitor.shownTarget == 87 && monitor.committedLimit == 90, "ceiling follows target up to 90")
        let writesBefore = native.writeCount
        monitor.applyNativeLimit()
        check(native.writeCount == writesBefore && !monitor.applyingLimit, "unchanged ceiling is not rewritten")
        monitor.cancelDraftLimit()
        check(monitor.chargeLimit == 87, "draft cancel does not clobber adapter target")
        monitor.setAdapterMode(active: false)
        until { !monitor.applyingLimit && native.limit == 80 }
        check(!monitor.adapterModeActive && monitor.chargeLimit == 80 && monitor.barLimits == [80, 85, 90, 95, 100],
              "leaving adapter mode restores the previous native limit")
        print("BatteryMonitor production integration: \(assertions) assertions passed; isolated defaults/history and fake hardware.")
    }
}
