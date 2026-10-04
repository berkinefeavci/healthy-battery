import Foundation

@main enum MagSafeLEDTests {
    static func main() {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool) {
            precondition(condition()); assertions += 1
        }
        let suite = "local.chargemate.magsafe-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        expect(MagSafeLEDPreferences.load(from: defaults) == .defaults)
        let saved = MagSafeLEDPreferences(policy: .status, completionBehavior: .off, blinkWhileDischarging: true)
        saved.save(to: defaults)
        expect(MagSafeLEDPreferences.load(from: defaults) == saved)
        defaults.set("future-policy", forKey: MagSafeLEDPreferences.policyKey)
        expect(MagSafeLEDPreferences.load(from: defaults).policy == .system)

        let all = Set(MagSafeLEDOutput.allCases)
        func decide(_ preferences: MagSafeLEDPreferences = saved,
                    _ connection: MagSafeConnectionKind = .magsafe3,
                    _ phase: MagSafeLEDPhase = .charging,
                    fresh: Bool = true, ready: Bool = true,
                    outputs: Set<MagSafeLEDOutput> = all) -> MagSafeLEDDecision {
            MagSafeLEDPolicyEngine.decision(preferences: preferences, connection: connection, phase: phase,
                                            telemetryFresh: fresh, writerReady: ready, supportedOutputs: outputs)
        }

        expect(decide(ready: false) == .noWrite(.writerUnavailable))
        expect(decide(saved, .none) == .noWrite(.noAdapter))
        expect(decide(saved, .usbC) == .noWrite(.unsupportedConnection))
        expect(decide(saved, .unknownAdapter) == .noWrite(.unknownConnection))
        expect(decide(saved, .magsafe3, .unknown) == .noWrite(.staleOrUnknownState))
        expect(decide(saved, .magsafe3, .charging, fresh: false) == .noWrite(.staleOrUnknownState))
        expect(decide(saved, .magsafe3, .charging) == .write(.orange))
        expect(decide(saved, .magsafe3, .confirmedTargetReached) == .write(.off))
        expect(decide(saved, .magsafe3, .calibrationComplete) == .write(.off))
        expect(decide(saved, .magsafe3, .discharging) == .write(.blinkingOrange))
        expect(decide(saved, .magsafe2, .discharging) == .write(.orange))

        let green = MagSafeLEDPreferences(policy: .status, completionBehavior: .green, blinkWhileDischarging: false)
        expect(decide(green, .magsafe2, .confirmedTargetReached) == .write(.green))
        expect(decide(green, .magsafe3, .heatPaused) == .write(.orange))
        expect(decide(green, .magsafe3, .topUpCharging) == .write(.orange))
        let system = MagSafeLEDPreferences(policy: .system, completionBehavior: .green, blinkWhileDischarging: false)
        expect(decide(system, .magsafe3, .unknown, fresh: false) == .write(.system))
        let off = MagSafeLEDPreferences(policy: .alwaysOff, completionBehavior: .green, blinkWhileDischarging: false)
        expect(decide(off, .magsafe3, .unknown, fresh: false) == .write(.off))
        expect(decide(green, .magsafe3, .charging, outputs: [.green]) == .noWrite(.unsupportedOutput(.orange)))

        expect(MagSafeLEDHelperState.parse("2 1380 600\n") == .policy(.scheduled, start: 1380, end: 600))
        expect(MagSafeLEDHelperState.parse("0 0 0") == .policy(.system, start: 0, end: 0))
        expect(MagSafeLEDHelperState.parse("3 0 0") == .pausedByTest)
        expect(MagSafeLEDHelperState.parse("4 0 0") == nil && MagSafeLEDHelperState.parse("2 1440 0") == nil)
        expect(MagSafeLEDHelperState.parse("") == nil && MagSafeLEDHelperState.parse("2 x 0") == nil)
        expect(MagSafeLEDTimeWindow.repaired(policy: .system, start: 0, end: 0) == (1320, 480))
        expect(MagSafeLEDTimeWindow.repaired(policy: .system, start: 1380, end: 600) == (1380, 600))
        expect(MagSafeLEDTimeWindow.repaired(policy: .scheduled, start: 0, end: 0) == (0, 0))

        print("MagSafe LED: \(assertions) assertions passed; preferences and fake capability only, no hardware writes.")
    }
}
