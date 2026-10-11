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
        // Old builds saved heat/sailing/max-temperature preferences that nothing reads any more; the monitor must
        // neither fail on them nor wipe them.
        check(defaults.bool(forKey: "heatProtection") && defaults.bool(forKey: "sailingEnabled")
              && defaults.double(forKey: "maxTemp") == 42 && monitor.chargeLimit == 80,
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
        check(defaults.integer(forKey: "preferencesSchemaVersion") == 2 && defaults.bool(forKey: "heatProtection")
              && defaults.double(forKey: "maxTemp") == 42, "second startup preserves migration")
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
        check(monitor.actionMessage == nil && monitor.limitFailureMessage == nil, "a working Top Up shows no failure")
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
        // A refused Top Up start says why (it used to be overwritten by a generic "verified" line and never shown).
        providedSnapshot.externalConnected = false
        providedSnapshot.sampledAt = Date()
        monitor.refresh()
        until { !monitor.snapshot.externalConnected }
        monitor.startTopUp()
        until { !monitor.applyingLimit }
        check(!monitor.topUpActive && native.writeCount == writesAfterRestore && monitor.actionMessage != nil
              && monitor.actionMessage != String(localized: "Top Up durumu doğrulandı."),
              "refused Top Up start keeps its real reason in actionMessage")
        monitor.dismissFailureMessages()
        check(monitor.actionMessage == nil, "closing the panel dismisses failure lines")
        providedSnapshot.externalConnected = true
        providedSnapshot.sampledAt = Date()
        monitor.refresh()
        until { monitor.snapshot.externalConnected }
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
        // A limit write that macOS refuses is shown as a failure line (the popover has room for failures only);
        // a verified write is not. Clean, separate environments: the one above ends in recovery scenarios.
        func isolatedMonitor(_ name: String, fake: FakeNative) throws -> BatteryMonitor {
            let isolatedRoot = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
            let isolatedDefaults = UserDefaults(suiteName: suite + "." + name)!
            isolatedDefaults.removePersistentDomain(forName: suite + "." + name)
            let backend = fake.backend()
            let coordinator = ChargeControlCoordinator(journal: isolatedRoot.appendingPathComponent("control-session.json"),
                                                       backend: backend, rival: { false })
            let controller = ChargePolicyController(
                backend: backend, coordinator: coordinator,
                policyStore: ChargePolicyStore(url: isolatedRoot.appendingPathComponent("charge-policy.json")),
                sessionStore: TopUpSessionStore(url: isolatedRoot.appendingPathComponent("charge-session.json")),
                rival: { false })
            return BatteryMonitor(defaults: isolatedDefaults, policyController: controller,
                historyURL: isolatedRoot.appendingPathComponent("history.json"),
                batteryReader: { providedSnapshot }, nativeReader: { fake.read() },
                controllerRunning: { false }, energyReader: { .success([]) })
        }
        do {
            let fake = FakeNative()
            let failing = try isolatedMonitor("failure-lines", fake: fake)
            failing.start()
            defer { failing.stop() }
            until { failing.nativeLimit == 90 }
            fake.reject = true
            failing.chargeLimit = 95
            failing.applyNativeLimit()
            until { !failing.applyingLimit }
            check(failing.limitFailureMessage != nil && failing.limitMessage == failing.limitFailureMessage,
                  "a limit write macOS refuses is a failure line")
            failing.dismissFailureMessages()
            check(failing.limitFailureMessage == nil && failing.limitMessage == nil, "closing the panel dismisses the limit failure")
        }
        do {
            let fake = FakeNative()
            let working = try isolatedMonitor("success-lines", fake: fake)
            working.start()
            defer { working.stop() }
            until { working.nativeLimit == 90 }
            working.chargeLimit = 95
            working.applyNativeLimit()
            until { !working.applyingLimit && working.nativeLimit == 95 }
            check(working.limitMessage != nil && working.limitFailureMessage == nil,
                  "a verified limit write is a message, not a failure line")
        }
        // Automations (heat protection) write the power mode through an already installed helper only: they never
        // reach the interactive writer, which would raise an administrator prompt out of the blue.
        do {
            var interactiveWrites = 0, automationWrites = 0
            let fake = FakeNative()
            let isolatedRoot = root.appendingPathComponent("automation-power")
            try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
            let backend = fake.backend()
            let coordinator = ChargeControlCoordinator(journal: isolatedRoot.appendingPathComponent("control-session.json"), backend: backend, rival: { false })
            let controller = ChargePolicyController(backend: backend, coordinator: coordinator,
                policyStore: ChargePolicyStore(url: isolatedRoot.appendingPathComponent("charge-policy.json")),
                sessionStore: TopUpSessionStore(url: isolatedRoot.appendingPathComponent("charge-session.json")), rival: { false })
            let counting = BatteryMonitor(defaults: UserDefaults(suiteName: suite + ".automation")!, policyController: controller,
                historyURL: isolatedRoot.appendingPathComponent("history.json"),
                batteryReader: { BatterySnapshot() }, nativeReader: { fake.read() }, controllerRunning: { false },
                energyReader: { .success([]) },
                powerModeWriter: { mode, _ in interactiveWrites += 1; return .success(mode) },
                automationPowerModeWriter: { _, _ in automationWrites += 1; return .failure(.helperMissing) })
            counting.applyPowerMode(.automatic, source: .adapter, interactive: false)
            until { !counting.applyingPowerMode }
            check(automationWrites == 1 && interactiveWrites == 0, "an automation never uses the prompting writer")
            check(counting.powerModeMessage == nil, "a missing helper stays quiet for an automation")
            counting.applyPowerMode(.lowPower, source: .adapter)
            until { !counting.applyingPowerMode }
            check(interactiveWrites == 1 && automationWrites == 1, "a user's choice still goes through the interactive writer")
        }
        // Publish only on change: with unchanged hardware, a refresh wakes SwiftUI once (the snapshot carries a
        // fresh timestamp and must be published), not once per property it re-assigned.
        do {
            let fake = FakeNative()
            let quiet = try isolatedMonitor("publish-counts", fake: fake)
            providedSnapshot.available = true
            providedSnapshot.sampledAt = Date()
            quiet.start()
            defer { quiet.stop() }
            until { quiet.nativeLimit == 90 }
            var settled = 0
            let settleWatch = quiet.$snapshot.sink { _ in settled += 1 }
            for _ in 0..<3 { let before = settled; quiet.refresh(); until { settled > before } }
            settleWatch.cancel()
            var emissions = 0
            let watch = quiet.objectWillChange.sink { emissions += 1 }
            let rounds = 4
            for _ in 0..<rounds {
                let before = emissions
                quiet.refresh()
                until { emissions > before }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            watch.cancel()
            check(emissions <= rounds, "an unchanged refresh wakes the views once, not once per re-assigned property (\(emissions) in \(rounds))")
        }
        // History file: encoded points are reused, the JSON stays the same object JSONEncoder writes, and the
        // decode-before-replace guard still protects a file this session did not write.
        do {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            var snapshot = BatterySnapshot(); snapshot.available = true; snapshot.percentage = 71; snapshot.sampledAt = base
            let points = (0..<40).map { BatteryMonitor.historyPoint(snapshot, now: base.addingTimeInterval(Double($0) * 30)) }
            let archive = HistoryArchive(schemaVersion: 2, measurements: points, limitEvents: [LimitEvent(date: base, value: 80)])
            let cache = HistoryEncodingCache()
            func object(_ data: Data) throws -> NSDictionary { try JSONSerialization.jsonObject(with: data) as! NSDictionary }
            check(try object(cache.encode(archive)) == object(JSONEncoder().encode(archive)),
                  "cached encoding is the same JSON object as JSONEncoder's")
            let grown = HistoryArchive(schemaVersion: 2, measurements: points + [BatteryMonitor.historyPoint(snapshot, now: base.addingTimeInterval(1_200))],
                                       limitEvents: [])
            check(try object(cache.encode(grown)) == object(JSONEncoder().encode(grown)), "second write with one new point is identical")
            let trimmed = HistoryArchive(schemaVersion: 2, measurements: Array(points.suffix(5)), limitEvents: [])
            check(try object(cache.encode(trimmed)) == object(JSONEncoder().encode(trimmed)), "points that left the window are dropped")
            check(try object(cache.encode(HistoryArchive(schemaVersion: 2, measurements: [], limitEvents: [])))
                  == object(JSONEncoder().encode(HistoryArchive(schemaVersion: 2, measurements: [], limitEvents: []))), "empty archive")
            let decoded = try JSONDecoder().decode(HistoryArchive.self, from: cache.encode(archive))
            check(decoded.measurements.count == 40 && decoded.limitEvents == archive.limitEvents, "cached JSON decodes back")

            let writeRoot = root.appendingPathComponent("history-write")
            try FileManager.default.createDirectory(at: writeRoot, withIntermediateDirectories: true)
            let file = writeRoot.appendingPathComponent("history.json")
            try Data("not json".utf8).write(to: file)
            var refused = false
            do { try archive.write(file) } catch { refused = true }
            let untouched = try Data(contentsOf: file) == Data("not json".utf8)
            check(refused && untouched, "an unreadable file this session did not write is never overwritten")
            try archive.write(file, verifyPrior: false, encodingCache: cache)
            check(try HistoryArchive.read(file, now: base.addingTimeInterval(1_200)).measurements.count == 40, "session-owned file is rewritten without the guard")
        }
        // Persistence is throttled (MonitorCadence.historySaveInterval) but the first point of a session is saved at
        // once, a quiet monitor leaves the file alone on stop, and stop() writes points still only in memory.
        check(MonitorCadence.historySaveInterval == 120, "history is saved at most every two minutes")
        do {
            let fake = FakeNative()
            let saving = try isolatedMonitor("history-saving", fake: fake)
            let file = root.appendingPathComponent("history-saving").appendingPathComponent("history.json")
            providedSnapshot.available = true
            providedSnapshot.percentage = 64
            providedSnapshot.sampledAt = Date()
            saving.start()
            until { FileManager.default.fileExists(atPath: file.path) }
            let first = try HistoryArchive.read(file)
            check(first.measurements.count == 1 && first.measurements[0].percentage == 64, "first point of a session is saved at once")
            let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            saving.stop()
            let afterStop = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            check(afterStop == modified, "stop() does not rewrite a file with nothing new in it")
        }
        // The long-term summary file failing to save is shown too (it used to be dropped with `try?`).
        do {
            let fake = FakeNative()
            let stuck = try isolatedMonitor("summary-failure", fake: fake)
            let blockedSummary = root.appendingPathComponent("summary-failure").appendingPathComponent("daily-summary.json")
            try FileManager.default.createDirectory(at: blockedSummary, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: blockedSummary.appendingPathComponent("occupied"))
            providedSnapshot.available = true
            providedSnapshot.percentage = 70
            providedSnapshot.sampledAt = Date()
            stuck.start()
            defer { stuck.stop() }
            until { stuck.historyError != nil }
            check(stuck.historyError?.hasPrefix(String(localized: "Geçmiş kaydedilemiyor: ").prefix(10)) == true,
                  "a failing long-term summary write surfaces in the history message area")
        }
        print("BatteryMonitor production integration: \(assertions) assertions passed; isolated defaults/history and fake hardware.")
    }
}
