import Foundation

private final class ControllerFakeNative {
    private let lock = NSLock()
    var limit: Int
    var rejectNextWrite = false
    var beforeWrite: (() -> Void)?
    private var writes: [Int] = []

    init(limit: Int) { self.limit = limit }
    var writtenLimits: [Int] { lock.lock(); defer { lock.unlock() }; return writes }

    func backend() -> NativeChargeBackend {
        NativeChargeBackend(version: "controller-fake", timeout: 0.1) { arguments, _ in
            self.lock.lock()
            defer { self.lock.unlock() }
            if arguments.count == 2, arguments[0] == "set", let requested = Int(arguments[1]) {
                self.beforeWrite?()
                self.writes.append(requested)
                if self.rejectNextWrite {
                    self.rejectNextWrite = false
                    throw NativeChargeBackendError.rejected("synthetic failure")
                }
                self.limit = requested
            } else if arguments != ["read"] {
                throw NativeChargeBackendError.rejected("unexpected command")
            }
            let state = NativeChargeState(manualLimit: self.limit,
                                          availableLimits: [80, 85, 90, 95, 100],
                                          enabledRaw: self.limit == 100 ? 0 : 1,
                                          currentLimit: self.limit)
            let envelope = Envelope(schemaVersion: 1, ok: true, state: state)
            return NativeChargeProcessResult(status: 0, output: try JSONEncoder().encode(envelope))
        }
    }

    private struct Envelope: Encodable {
        let schemaVersion: Int
        let ok: Bool
        let state: NativeChargeState
    }
}

@main enum ChargePolicyControllerTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-policy-controller-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); assertions += 1
        }
        func telemetry(external: Bool = true, charging: Bool = true, full: Bool = false,
                       percent: Int = 80, at date: Date = now) -> ChargeTelemetry {
            .init(sampledAt: date, percentage: percent, hardwarePercentage: percent,
                  isCharging: charging, externalConnected: external, fullyCharged: full,
                  batteryWatts: charging ? 8 : 0)
        }
        func harness(_ name: String, limit: Int = 80,
                     rival: @escaping () -> Bool = { false }) -> (ControllerFakeNative, ChargePolicyController,
                                                                  ChargePolicyStore, TopUpSessionStore) {
            let directory = root.appendingPathComponent(name)
            let fake = ControllerFakeNative(limit: limit)
            let backend = fake.backend()
            let coordinator = ChargeControlCoordinator(journal: directory.appendingPathComponent("control.json"),
                                                        backend: backend, rival: rival, now: { now })
            let policyStore = ChargePolicyStore(url: directory.appendingPathComponent("charge-policy.json"))
            let sessionStore = TopUpSessionStore(url: directory.appendingPathComponent("charge-session.json"))
            let controller = ChargePolicyController(backend: backend, coordinator: coordinator,
                                                    policyStore: policyStore, sessionStore: sessionStore,
                                                    rival: rival, now: { now })
            return (fake, controller, policyStore, sessionStore)
        }

        do {
            let (fake, controller, policyStore, _) = harness("manual", limit: 90)
            let result = controller.applyManualLimit(85)
            check(result.status == .configurationVerified && fake.writtenLimits == [85],
                  "manual Apply is verified")
            check(policyStore.load().value?.desiredLimit == 85,
                  "manual Apply updates policy only after readback")
            check(controller.state == .maintainingLimit(85), "manual state published")
        }

        do {
            let (fake, controller, policyStore, _) = harness("manual-failure", limit: 90)
            fake.rejectNextWrite = true
            let result = controller.applyManualLimit(85)
            check(result.status == .recoveryRequired, "failed Apply enters recovery")
            check(policyStore.load().value == nil, "failed Apply does not update policy")
        }

        do {
            let (fake, controller, _, sessionStore) = harness("top-up", limit: 80)
            var persistedBeforeWrite = false
            fake.beforeWrite = { persistedBeforeWrite = sessionStore.load().value?.phase == .starting }
            let result = controller.startTopUp(originExecutionID: UUID(), telemetry: telemetry())
            check(result.status == .configurationVerified && fake.writtenLimits == [100], "Top Up writes 100")
            check(persistedBeforeWrite, "Top Up session saved before writer")
            check(sessionStore.load().value?.phase == .charging, "Top Up readback persists charging")
            let event = controller.evaluate(telemetry: telemetry(charging: false, full: true, percent: 100),
                                            trigger: .telemetry)
            check(fake.writtenLimits == [100, 80], "full Top Up restores exact prior limit")
            check(sessionStore.load().value == nil, "successful restore deletes session")
            check(event?.kind == .topUpFinished, "successful restore emits terminal event")
        }

        do {
            let (fake, controller, _, sessionStore) = harness("top-up-already-100", limit: 90)
            let prior = controller.applyManualLimit(100)
            let result = controller.startTopUp(telemetry: telemetry(percent: 95))
            check(fake.writtenLimits == [100], "Top Up already at 100 performs no duplicate write")
            check(result.operationID != prior.operationID && result.message == "Top Up durumu doğrulandı.",
                  "read-only Top Up returns its own current result, not stale Apply result")
            check(sessionStore.load().value?.phase == .charging,
                  "Top Up already at 100 persists charging session")
        }

        do {
            let (fake, controller, _, sessionStore) = harness("restore-failure", limit: 80)
            _ = controller.startTopUp(telemetry: telemetry())
            fake.rejectNextWrite = true
            let event = controller.evaluate(telemetry: telemetry(charging: false, full: true, percent: 100),
                                            trigger: .telemetry)
            check(event?.kind == .topUpFailed, "failed restore emits failure")
            check(sessionStore.load().value?.phase == .recoveryRequired,
                  "failed restore preserves recovery session")
        }

        do {
            let (fake, controller, policyStore, sessionStore) = harness("restart", limit: 100)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            try sessionStore.save(.init(originExecutionID: nil, startedAt: now,
                                        deadline: now.addingTimeInterval(10_800),
                                        previousNativeLimit: 80, restoreLimit: 80, phase: .charging))
            let event = controller.evaluate(telemetry: telemetry(percent: 90), trigger: .startup)
            check(event == nil && fake.writtenLimits.isEmpty && controller.topUpActive,
                  "restart continues charging without duplicate write")
        }

        do {
            let (fake, controller, policyStore, _) = harness("wake-conflict", limit: 90)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            _ = controller.evaluate(telemetry: telemetry(), trigger: .wake)
            check(fake.writtenLimits.isEmpty, "wake normal conflict writes zero")
            check(controller.state == .pausedByConflict(expected: 80, observed: 90),
                  "wake conflict is visible")
        }

        do {
            let (fake, controller, _, _) = harness("unplug", limit: 80)
            _ = controller.startTopUp(telemetry: telemetry(external: true))
            _ = controller.evaluate(telemetry: telemetry(external: true, percent: 90), trigger: .telemetry)
            check(fake.writtenLimits == [100], "ordinary telemetry does not restore")
            _ = controller.evaluate(telemetry: telemetry(external: false, charging: false, percent: 90),
                                    trigger: .powerSourceChange)
            check(fake.writtenLimits == [100, 80], "true to false power transition restores once")
            _ = controller.evaluate(telemetry: telemetry(external: false, charging: false, percent: 90),
                                    trigger: .telemetry)
            check(fake.writtenLimits == [100, 80], "repeated refresh does not duplicate restore")
        }

        do {
            let (fake, controller, policyStore, _) = harness("auto-reapply", limit: 90)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            controller.externalChangeResponse = .reapply
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            check(fake.writtenLimits == [80] && controller.state == .maintainingLimit(80),
                  "auto reapply writes the target once")
            fake.limit = 90
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            check(fake.writtenLimits == [80] && controller.state == .pausedByConflict(expected: 80, observed: 90),
                  "second external change within 10 minutes falls back to asking")
        }

        do {
            let (fake, controller, policyStore, _) = harness("auto-reapply-fail", limit: 90)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            controller.externalChangeResponse = .reapply
            fake.rejectNextWrite = true
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            let attempts = fake.writtenLimits.count
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            check(attempts == 1 && fake.writtenLimits.count == 1, "failed auto reapply is not retried in a loop")
        }

        do {
            let (fake, controller, policyStore, _) = harness("auto-adopt", limit: 90)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            controller.externalChangeResponse = .adopt
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            check(fake.writtenLimits.isEmpty && controller.policy?.desiredLimit == 90
                  && controller.state == .maintainingLimit(90), "auto adopt takes the macOS value without writing")
            check(policyStore.load().value?.desiredLimit == 90, "auto adopt persists the adopted target")
        }

        do {
            let (fake, controller, policyStore, _) = harness("ask-default", limit: 90)
            try policyStore.save(.init(desiredLimit: 80, enabled: true))
            _ = controller.evaluate(telemetry: telemetry(), trigger: .telemetry)
            check(fake.writtenLimits.isEmpty && controller.state == .pausedByConflict(expected: 80, observed: 90),
                  "default response asks and writes nothing")
        }

        do {
            let (_, controller, _, _) = harness("restore-limit", limit: 85)
            _ = controller.startTopUp(telemetry: telemetry())
            check(controller.topUpRestoreLimit == 85, "top up exposes the limit it will return to")
        }

        print("Charge policy controller: \(assertions) assertions passed; fake backend and temporary stores only.")
    }
}
