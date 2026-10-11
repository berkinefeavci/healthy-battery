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

        // The page offers system / always off / scheduled. A value an older build stored ("status", never
        // reachable) or any future one reads back as the safe default instead of failing.
        expect(MagSafeLEDPolicy.allCases == [.system, .alwaysOff, .scheduled])
        for stored in ["status", "future-policy", ""] {
            defaults.set(stored, forKey: MagSafeLEDPolicy.storageKey)
            expect((MagSafeLEDPolicy(rawValue: defaults.string(forKey: MagSafeLEDPolicy.storageKey) ?? "") ?? .system) == .system)
        }
        for policy in MagSafeLEDPolicy.allCases {
            defaults.set(policy.rawValue, forKey: MagSafeLEDPolicy.storageKey)
            expect(MagSafeLEDPolicy(rawValue: defaults.string(forKey: MagSafeLEDPolicy.storageKey) ?? "") == policy)
        }
        expect(MagSafeLEDOutput.allCases == [.system, .off, .green, .orange])

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
