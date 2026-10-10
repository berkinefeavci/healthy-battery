import Foundation

@main enum ChargePolicyTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError(label) }
            count += 1
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let native80 = NativeChargeState(manualLimit: 80, availableLimits: [80, 85, 90, 95, 100], enabledRaw: 1, currentLimit: 80)
        let native100 = NativeChargeState(manualLimit: 100, availableLimits: [80, 85, 90, 95, 100], enabledRaw: 0, currentLimit: 100)
        let policy = ChargePolicy(desiredLimit: 80, enabled: true)

        let policyURL = root.appendingPathComponent("charge-policy.json")
        let policyStore = ChargePolicyStore(url: policyURL)
        check(policyStore.load().value == nil && !policyStore.load().blocked, "absent policy is not blocked")
        try policyStore.save(policy)
        check(policyStore.load().value == policy, "policy round trip")
        let policyBytes = try Data(contentsOf: policyURL)
        check(!policyBytes.isEmpty, "policy persisted atomically")

        let corruptURL = root.appendingPathComponent("corrupt-policy.json")
        let corruptBytes = Data("broken".utf8)
        try corruptBytes.write(to: corruptURL)
        let corruptStore = ChargePolicyStore(url: corruptURL)
        check(corruptStore.load().blocked, "corrupt policy blocks")
        do { try corruptStore.save(policy); fatalError("blocked policy overwritten") }
        catch { check(error as? ChargeStoreError == .blocked, "blocked policy refuses save") }
        let corruptBackups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("corrupt-policy.json.invalid-") }
        let corruptPreserved = try corruptBackups.contains { try Data(contentsOf: $0) == corruptBytes }
        check(corruptPreserved, "corrupt policy backed up byte for byte")
        try corruptStore.reconcile(with: policy)
        check(corruptStore.load().value == policy && !corruptStore.load().blocked, "explicit reconcile unblocks policy")

        let futureURL = root.appendingPathComponent("future-session.json")
        let futureBytes = Data(#"{"schemaVersion":9,"id":"00000000-0000-0000-0000-000000000001","originExecutionID":null,"startedAt":0,"deadline":1,"previousNativeLimit":80,"restoreLimit":80,"phase":"charging","nonChargingSamples":0}"#.utf8)
        try futureBytes.write(to: futureURL)
        let futureStore = TopUpSessionStore(url: futureURL)
        check(futureStore.load().blocked, "future session schema blocks")
        let futureBackups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("future-session.json.invalid-") }
        let futurePreserved = try futureBackups.contains { try Data(contentsOf: $0) == futureBytes }
        check(futurePreserved, "future session backed up byte for byte")

        let baseTelemetry = ChargeTelemetry(sampledAt: now, percentage: 75, hardwarePercentage: 74,
                                            isCharging: true, externalConnected: true, fullyCharged: false,
                                            batteryWatts: 12)
        func input(policy selectedPolicy: ChargePolicy? = policy,
                   session: TopUpSession? = nil,
                   native: NativeChargeState? = native80,
                   telemetry: ChargeTelemetry = baseTelemetry,
                   intent: ChargePolicyIntent = .none,
                   rival: Bool = false,
                   recovery: Bool = false,
                   trigger: ChargePolicyTrigger = .telemetry,
                   at date: Date = now) -> ChargePolicyEvaluationInput {
            .init(policy: selectedPolicy, session: session, nativeState: native, telemetry: telemetry,
                  intent: intent, rivalRunning: rival, coordinatorRecovery: recovery, now: date, trigger: trigger)
        }

        var decision = ChargePolicyEngine.evaluate(input())
        check(decision.state == .maintainingLimit(80) && decision.command == .none, "matching policy maintains")
        let native90 = NativeChargeState(manualLimit: 90, availableLimits: native80.availableLimits, enabledRaw: 1, currentLimit: 90)
        decision = ChargePolicyEngine.evaluate(input(native: native90))
        check(decision.state == .pausedByConflict(expected: 80, observed: 90) && decision.command == .none,
              "external change pauses without tug of war")
        decision = ChargePolicyEngine.evaluate(input(native: native90, intent: .adoptNativeLimit))
        check(decision.policy?.desiredLimit == 90 && decision.command == .none, "adopt native changes policy only")
        decision = ChargePolicyEngine.evaluate(input(native: native90, intent: .reapplyPolicy))
        check(decision.command == .write(limit: 80, source: .manual), "explicit reapply writes desired limit")

        let unsupportedPolicy = ChargePolicy(desiredLimit: 75, enabled: true)
        decision = ChargePolicyEngine.evaluate(input(policy: unsupportedPolicy))
        check(decision.command == .none && decision.state.isRecovery, "unsupported desired limit blocks")
        decision = ChargePolicyEngine.evaluate(input(intent: .reapplyPolicy, rival: true))
        check(decision.command == .none, "rival controller blocks explicit write")
        decision = ChargePolicyEngine.evaluate(input(recovery: true))
        check(decision.command == .none && decision.state.isRecovery, "coordinator recovery blocks")
        decision = ChargePolicyEngine.evaluate(input(native: native90, trigger: .wake))
        check(decision.command == .none, "wake normal conflict writes zero")

        decision = ChargePolicyEngine.evaluate(input(intent: .startTopUp(originExecutionID: nil)))
        check(decision.command == .write(limit: 100, source: .topUp), "top up starts at 100")
        check(decision.session?.previousNativeLimit == 80 && decision.session?.restoreLimit == 80,
              "top up captures exact prior limit")
        check(decision.session?.phase == .starting && decision.session?.deadline == now.addingTimeInterval(10_800),
              "top up persists starting phase and deadline")
        let starting = decision.session!
        let native81 = NativeChargeState(manualLimit: 81, availableLimits: native80.availableLimits,
                                         enabledRaw: 1, currentLimit: 100)
        decision = ChargePolicyEngine.evaluate(input(native: native81,
            intent: .startTopUp(originExecutionID: nil)))
        check(decision.command == .none && decision.state.isRecovery,
              "Top Up refuses a prior limit it cannot restore exactly")

        decision = ChargePolicyEngine.evaluate(input(session: starting, native: native100))
        check(decision.session?.phase == .charging && decision.command == .none, "readback advances top up to charging")
        let charging = decision.session!
        decision = ChargePolicyEngine.evaluate(input(session: nil, native: native100,
            intent: .startTopUp(originExecutionID: UUID())))
        check(decision.command == .none && decision.session?.phase == .charging,
              "already at 100 starts without redundant write")

        var full = baseTelemetry
        full.fullyCharged = true
        decision = ChargePolicyEngine.evaluate(input(session: charging, native: native100, telemetry: full))
        check(decision.state == .topUpRestoring(80) && decision.command == .write(limit: 80, source: .restore),
              "fully charged restores prior limit")
        check(decision.session?.phase == .restoring, "session survives until restore readback")

        var stopped = baseTelemetry
        stopped.hardwarePercentage = 99; stopped.percentage = 99; stopped.isCharging = false; stopped.batteryWatts = 0
        decision = ChargePolicyEngine.evaluate(input(session: charging, native: native100, telemetry: stopped))
        check(decision.session?.nonChargingSamples == 1 && decision.command == .none, "first noncharging sample waits")
        decision = ChargePolicyEngine.evaluate(input(session: decision.session, native: native100, telemetry: stopped,
                                                     at: now.addingTimeInterval(2)))
        check(decision.command == .write(limit: 80, source: .restore), "second noncharging sample restores")
        var resumed = stopped; resumed.isCharging = true; resumed.batteryWatts = 4
        decision = ChargePolicyEngine.evaluate(input(session: charging.with(nonChargingSamples: 1), native: native100,
                                                     telemetry: resumed))
        check(decision.session?.nonChargingSamples == 0, "charging sample resets completion count")
        var stale = stopped; stale.sampledAt = now.addingTimeInterval(-10.01)
        decision = ChargePolicyEngine.evaluate(input(session: charging.with(nonChargingSamples: 1), native: native100,
                                                     telemetry: stale))
        check(decision.session?.nonChargingSamples == 0 && decision.command == .none, "stale sample cannot complete")

        decision = ChargePolicyEngine.evaluate(input(session: charging, native: native100, intent: .cancelTopUp))
        check(decision.command == .write(limit: 80, source: .restore), "manual cancel restores")
        var unplugged = baseTelemetry; unplugged.externalConnected = false
        decision = ChargePolicyEngine.evaluate(input(session: charging, native: native100, telemetry: unplugged,
                                                     trigger: .powerSourceChange))
        check(decision.command == .write(limit: 80, source: .restore), "unplug restores")
        decision = ChargePolicyEngine.evaluate(input(session: charging, native: native100,
                                                     at: charging.deadline))
        check(decision.command == .write(limit: 80, source: .restore), "three hour deadline restores")

        let restoring = charging.with(phase: .restoring)
        decision = ChargePolicyEngine.evaluate(input(session: restoring, native: native80, trigger: .startup))
        check(decision.clearSession && decision.command == .none && decision.state == .maintainingLimit(80),
              "restart clears only verified restore")
        decision = ChargePolicyEngine.evaluate(input(session: restoring, native: native100, trigger: .wake))
        check(decision.command == .write(limit: 80, source: .wakeRecovery), "wake resumes valid restore once")
        decision = ChargePolicyEngine.evaluate(input(session: restoring.with(phase: .recoveryRequired), native: native100,
                                                     recovery: true))
        check(!decision.clearSession && decision.state.isRecovery, "restore failure preserves recovery session")

        let sessionURL = root.appendingPathComponent("charge-session.json")
        let sessionStore = TopUpSessionStore(url: sessionURL)
        try sessionStore.save(charging)
        check(sessionStore.load().value == charging, "top up session round trip")
        try sessionStore.clear()
        check(sessionStore.load().value == nil, "verified completion clears session")

        // External-change preference: engine behaviour and loop guard.
        var autoInput = input(native: native90)
        autoInput.externalChangeResponse = .reapply
        decision = ChargePolicyEngine.evaluate(autoInput)
        check(decision.command == .write(limit: 80, source: .manual), "reapply preference writes the target")
        autoInput.autoReapplyAllowed = false
        decision = ChargePolicyEngine.evaluate(autoInput)
        check(decision.command == .none && decision.state == .pausedByConflict(expected: 80, observed: 90),
              "blocked auto reapply falls back to asking")
        autoInput = input(native: native90)
        autoInput.externalChangeResponse = .adopt
        decision = ChargePolicyEngine.evaluate(autoInput)
        check(decision.command == .none && decision.policy?.desiredLimit == 90 && decision.state == .maintainingLimit(90),
              "adopt preference takes the macOS value")
        var gate = ExternalChangeGate()
        check(gate.allowsAutoReapply(observed: 90, now: now), "fresh gate allows one reapply")
        gate.recordAutoReapply(at: now)
        check(!gate.allowsAutoReapply(observed: 90, now: now.addingTimeInterval(599)), "gate blocks within 10 minutes")
        check(gate.allowsAutoReapply(observed: 90, now: now.addingTimeInterval(601)), "gate reopens after 10 minutes")
        gate.recordFailure(observed: 90)
        check(!gate.allowsAutoReapply(observed: 90, now: now.addingTimeInterval(9_999)), "failed value never retried")
        check(gate.allowsAutoReapply(observed: 85, now: now.addingTimeInterval(9_999)), "a different external value is a new change")
        check(ExternalChangeResponse(stored: nil) == .ask && ExternalChangeResponse(stored: "bogus") == .ask
              && ExternalChangeResponse(stored: "adopt") == .adopt, "stored response defaults to ask")
        check(ChargeLimitDisplay.shown(native: 80, preference: 100) == 80
              && ChargeLimitDisplay.shown(native: nil, preference: 100) == 100, "panel shows real native limit")
        check(ChargeLimitDisplay.topUpReturnText(limit: 80).contains("80") , "top up return text mentions the limit")

        print("Charge policy: \(count) assertions passed; pure logic and temporary stores only.")
    }
}

private extension ChargePolicyState {
    var isRecovery: Bool {
        if case .recoveryRequired = self { return true }
        return false
    }
}

private extension TopUpSession {
    func with(phase: Phase? = nil, nonChargingSamples: Int? = nil) -> Self {
        var copy = self
        if let phase { copy.phase = phase }
        if let nonChargingSamples { copy.nonChargingSamples = nonChargingSamples }
        return copy
    }
}
