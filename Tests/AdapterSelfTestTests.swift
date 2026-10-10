import Foundation

/// Fake helper + fake battery: the adapter is "cut" between S 0 1 and S 0 0 (or the watchdog).
@main enum AdapterSelfTestTests {
    final class Rig {
        var requests: [String] = []
        var cut = false
        var capabilities = "0 0 1 1 0"
        var batteryFollowsCut = true     // false: the key is written but nothing physical happens
        var watchdogWorks = true
        var plugged = true
        var percent = 80
        var idleAmperage = 0
        var throwOnSet = false
        var clock: TimeInterval = 0
        var cutSince: TimeInterval?
        var lastBeat: TimeInterval = 0
        /// > 0: the gauge republishes only this often (Mac17,8: ~55 s); readings in between are stale.
        var gaugePeriod: TimeInterval = 0
        var gaugeFrozen = false
        private var published: AdapterSelfTestSample?
        private var publishedAt: TimeInterval = -1

        func request(_ line: String) throws -> String {
            requests.append(line)
            switch line {
            case "C\n": return capabilities
            case "H\n": lastBeat = clock; return "0"
            case "R\n":
                if cut, watchdogWorks, clock - lastBeat >= 60 { cut = false }
                return "0 0 \(cut ? 1 : 0)"
            case "S 0 1\n":
                if throwOnSet { throw ChargeInhibitWire.Failure.failed }
                cut = true; lastBeat = clock; return "0 0 1"
            case "S 0 0\n": cut = false; return "0 0 0"
            default: return "2"
            }
        }

        func sample() -> AdapterSelfTestSample? {
            if let published, gaugeFrozen || (gaugePeriod > 0 && clock - publishedAt < gaugePeriod) { return published }
            let draining = cut && batteryFollowsCut
            let reading = AdapterSelfTestSample(externalConnected: plugged && !draining, amperage: draining ? -1800 : idleAmperage,
                                                percent: percent, updateTime: Int(clock) + 1)
            published = reading; publishedAt = clock
            return reading
        }

        var test: AdapterSelfTest {
            AdapterSelfTest(request: request, sample: sample, sleep: { self.clock += $0 }, now: { Date(timeIntervalSince1970: self.clock) })
        }
    }

    static func main() {
        // Happy path: cut → discharge, restore → wall power, watchdog → restored within 75 s.
        let good = Rig()
        let passed = good.test.run()
        precondition(passed.outcome == .passed, "\(passed)")
        precondition(passed.steps.map(\.name) == ["start", "capabilities", "cut", "restore", "watchdog"])
        precondition(passed.steps.allSatisfy(\.ok))
        precondition(good.requests.last == "S 0 0\n" && !good.cut, "always ends released")
        precondition(good.requests.filter { $0 == "S 0 1\n" }.count == 2)
        let watchdogIndex = good.requests.lastIndex(of: "S 0 1\n")!
        precondition(!good.requests[watchdogIndex...].contains("H\n"), "no heartbeat during the watchdog step")

        // Real gauge: values only every 55 s, so the cut shows up late but still inside the window.
        let laggy = Rig(); laggy.gaugePeriod = 55; laggy.idleAmperage = 5600
        let laggyReport = laggy.test.run()
        precondition(laggyReport.outcome == .passed, "\(laggyReport)")

        // A gauge that never republishes: failed as "no fresh reading", not as "adapter mode does not work".
        let frozen = Rig(); frozen.gaugeFrozen = true
        let frozenReport = frozen.test.run()
        precondition(frozenReport.outcome == .failed && frozenReport.summary.contains("yenilenmedi") && !frozen.cut, "\(frozenReport)")

        // macOS gates CHIE: failed, and nothing was ever cut.
        let gated = Rig(); gated.capabilities = "0 0 0 1 2"
        let gatedReport = gated.test.run()
        precondition(gatedReport.outcome == .failed && !gated.requests.contains("S 0 1\n"))
        precondition(gatedReport.summary.contains("izin vermiyor"))

        // Key accepted but the battery never drains: failed, released.
        let inert = Rig(); inert.batteryFollowsCut = false
        let inertReport = inert.test.run()
        precondition(inertReport.outcome == .failed && inertReport.steps.last?.name == "cut" && !inert.cut)
        precondition(inert.requests.last == "S 0 0\n")

        // Watchdog never restores: failed, and the final release still goes out.
        let stuck = Rig(); stuck.watchdogWorks = false
        let stuckReport = stuck.test.run()
        precondition(stuckReport.outcome == .failed && stuckReport.steps.last?.name == "watchdog")
        precondition(stuck.requests.last == "S 0 0\n" && !stuck.cut)

        // Preconditions skip without touching the helper.
        for setup in [{ (r: Rig) in r.plugged = false }, { r in r.percent = 15 }, { r in r.idleAmperage = -900 }] {
            let rig = Rig(); setup(rig)
            let report = rig.test.run()
            precondition(report.outcome == .skipped && rig.requests.isEmpty, "\(report)")
        }

        // A helper error mid-test fails and still releases.
        let broken = Rig(); broken.throwOnSet = true
        let brokenReport = broken.test.run()
        precondition(brokenReport.outcome == .failed && broken.requests.last == "S 0 0\n")

        // Store round-trip.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-self-test-\(UUID().uuidString).json")
        AdapterSelfTestStore.save(passed, to: url)
        precondition(AdapterSelfTestStore.load(from: url)?.outcome == .passed)
        try? FileManager.default.removeItem(at: url)
        print("AdapterSelfTest: all assertions passed (fake helper and battery only)")
    }
}
