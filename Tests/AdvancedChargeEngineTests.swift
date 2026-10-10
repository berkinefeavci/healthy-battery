import Foundation

private final class FakeBackend: ChargeInhibitBackend {
    var caps = ChargeInhibitCapabilities(canInhibitCharging: true, canForceDischarge: true, reason: nil)
    var state = ChargeInhibitState.released
    var applies: [ChargeInhibitState] = []
    var heartbeats = 0
    var failApply = false
    struct Failure: Error {}
    func capabilities() -> ChargeInhibitCapabilities { caps }
    func readState() throws -> ChargeInhibitState { state }
    func apply(_ s: ChargeInhibitState) throws -> ChargeInhibitState {
        if failApply { throw Failure() }
        applies.append(s); state = s; return s
    }
    func heartbeat() throws { heartbeats += 1 }
}

@main enum AdvancedChargeEngineTests {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError(label) }
            count += 1
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let full = ChargeInhibitCapabilities(canInhibitCharging: true, canForceDischarge: true, reason: nil)
        let chargeOnly = ChargeInhibitCapabilities(canInhibitCharging: true, canForceDischarge: false, reason: nil)
        let hold = ChargeInhibitState(chargingInhibited: true, adapterInhibited: false)
        let cut = ChargeInhibitState(chargingInhibited: false, adapterInhibited: true)

        func input(_ pct: Int, temp: Double? = 25, external: Bool = true, now: Date = t0,
                   settings: AdvancedChargeSettings = AdvancedChargeSettings(), caps: ChargeInhibitCapabilities = full,
                   sleep: SleepState = .awake, topUp: Bool = false,
                   memory: AdvancedChargeMemory = AdvancedChargeMemory()) -> AdvancedChargeInput {
            AdvancedChargeInput(percentage: pct, temperatureC: temp, externalConnected: external, isCharging: true,
                                sleep: sleep, now: now, settings: settings, capabilities: caps,
                                current: .released, topUpActive: topUp, memory: memory)
        }
        func run(_ i: AdvancedChargeInput) -> AdvancedChargeOutput { AdvancedChargeEngine.evaluate(i) }
        var s80 = AdvancedChargeSettings(); s80.targetLimit = 80
        var sail = s80; sail.sailingEnabled = true; sail.sailingDelta = 5
        var heat = s80; heat.heatProtectionEnabled = true

        // Capability / safety gates
        let unsupported = run(input(95, caps: .unsupported))
        check(unsupported.desired == .released && unsupported.display == .unavailable, "unsupported releases")
        check(run(input(95, settings: s80, caps: .unsupported)).memory == AdvancedChargeMemory(), "unsupported keeps memory")
        check(run(input(9, settings: s80)).desired == .released && run(input(9, settings: s80)).display == .criticalLow, "critical never inhibits")
        var dis = AdvancedChargeMemory(); dis.discharge = DischargeRequest(requestedAt: t0)
        check(run(input(5, memory: dis)).desired == .released && run(input(5, memory: dis)).memory.discharge == nil, "critical clears discharge")
        var hot = heat; hot.targetLimit = 100
        check(run(input(5, temp: 60, settings: hot)).desired == .released, "critical beats heat")
        check(run(input(90, external: false, settings: s80)).desired == .released, "unplug releases")
        check(run(input(90, external: false, settings: s80)).display == .onBattery, "unplug display")
        check(run(input(90, settings: s80, topUp: true)).desired == .released && run(input(90, settings: s80, topUp: true)).display == .topUp, "top up releases")

        // Limit without sailing
        check(run(input(79, settings: s80)).desired == .released, "below limit charges")
        check(run(input(80, settings: s80)).desired == hold, "limit inhibits at target")
        check(run(input(85, settings: s80)).desired == hold, "above limit inhibits")
        var m = run(input(80, settings: s80)).memory
        check(run(input(80, settings: s80, memory: m)).desired == hold, "stays at target")
        check(run(input(79, settings: s80, memory: m)).desired == .released, "no sailing resumes at target-1")
        m = run(input(79, settings: s80, memory: m)).memory
        check(!m.limitLatched, "latch cleared")
        var s100 = s80; s100.targetLimit = 100
        check(run(input(100, settings: s100)).desired == .released, "100 never inhibits")
        var s83 = s80; s83.targetLimit = 83
        check(run(input(80, settings: s83)).desired == .released && run(input(85, settings: s83)).desired == hold, "target normalizes to 85")
        var s15 = s80; s15.targetLimit = 15
        check(run(input(19, settings: s15)).desired == .released && run(input(20, settings: s15)).desired == hold, "target min 20")
        check(AdvancedChargeLimits.normalizedTarget(250) == 100 && AdvancedChargeLimits.normalizedTarget(0) == 20, "normalize bounds")
        check(AdvancedChargeLimits.clampedDelta(0) == 2 && AdvancedChargeLimits.clampedDelta(99) == 15, "delta bounds")

        // Sailing hysteresis
        var sm = run(input(80, settings: sail)).memory
        for pct in [79, 78, 77, 76] {
            let o = run(input(pct, settings: sail, memory: sm)); sm = o.memory
            check(o.desired == hold && o.display == .sailing, "sailing stays inhibited at \(pct)")
        }
        let resume = run(input(75, settings: sail, memory: sm))
        check(resume.desired == .released && !resume.memory.limitLatched, "sailing resumes at target-delta")
        sm = resume.memory
        check(run(input(78, settings: sail, memory: sm)).desired == .released, "charging continues between band")
        check(run(input(80, settings: sail, memory: sm)).desired == hold, "re-inhibits at target")
        var sail20 = sail; sail20.targetLimit = 20; sail20.sailingDelta = 15
        var m20 = run(input(20, settings: sail20)).memory
        check(run(input(11, settings: sail20, memory: m20)).desired == hold, "sailing above critical keeps hold")
        m20 = run(input(9, settings: sail20, memory: m20)).memory
        check(run(input(12, settings: sail20, memory: m20)).desired == .released, "after critical latch is reset")

        // Heat v2
        check(run(input(50, temp: 35.0, settings: heat)).desired == .released, "35 exactly is not above")
        let h1 = run(input(50, temp: 36, settings: heat))
        check(h1.desired == hold && h1.display == .heatPaused, "heat inhibits above 35")
        check(!h1.desired.adapterInhibited, "heat never discharges")
        check(run(input(50, temp: 33, settings: heat, memory: h1.memory)).desired == hold, "heat hysteresis keeps pause at 33")
        check(run(input(50, temp: 31.9, settings: heat, memory: h1.memory)).desired == .released, "heat resumes below 32")
        check(run(input(50, temp: nil, settings: heat, memory: h1.memory)).desired == .released, "missing sensor drops heat latch")
        check(run(input(50, temp: 40, settings: s80)).desired == .released, "heat off ignores temperature")
        check(run(input(70, temp: 36, settings: heat)).desired == hold, "heat overrides below limit")
        check(run(input(95, temp: 20, settings: heat)).desired == hold, "limit still applies when cool")

        // Discharge
        var s80d = s80
        let dMem = AdvancedChargeMemory(limitLatched: false, heatLatched: false, discharge: DischargeRequest(requestedAt: t0), calibration: nil)
        let d1 = run(input(90, settings: s80d, memory: dMem))
        check(d1.desired == cut && d1.display == .discharging && d1.memory.discharge != nil, "discharge cuts adapter above target")
        let d2 = run(input(80, settings: s80d, memory: dMem))
        check(d2.desired == hold && d2.memory.discharge == nil, "discharge ends at target and limit holds")
        check(run(input(85, settings: s80d, caps: chargeOnly, memory: dMem)).desired == hold, "discharge unsupported without force capability")
        check(run(input(85, settings: s80d, caps: chargeOnly, memory: dMem)).memory.discharge == nil, "discharge request dropped without capability")
        check(run(input(90, now: t0.addingTimeInterval(6 * 3600 + 1), settings: s80d, memory: dMem)).memory.discharge == nil, "discharge hard timeout")
        check(run(input(90, now: t0.addingTimeInterval(6 * 3600 - 1), settings: s80d, memory: dMem)).desired == cut, "discharge before timeout")
        check(run(input(90, external: false, settings: s80d, memory: dMem)).memory.discharge == nil, "unplug clears discharge")
        check(run(input(90, settings: s80d, topUp: true, memory: dMem)).desired == .released, "top up beats discharge")
        s80d.targetLimit = 100
        check(run(input(100, settings: s80d, memory: dMem)).memory.discharge == nil, "discharge at 100 target no-op")

        // Sleep
        let sleepOut = run(input(85, settings: s80, sleep: .aboutToSleep))
        check(sleepOut.desired == hold && sleepOut.sleepMayOvershoot, "about to sleep above target notes overshoot")
        check(!run(input(85, settings: s80, sleep: .awake)).sleepMayOvershoot, "awake no overshoot note")
        check(!run(input(70, settings: s80, sleep: .asleep)).sleepMayOvershoot, "below target no overshoot note")

        // Calibration
        func cal(_ phase: CalibrationPhase, started: Date = t0, holdStart: Date? = nil) -> AdvancedChargeMemory {
            AdvancedChargeMemory(limitLatched: false, heatLatched: false, discharge: nil,
                                 calibration: CalibrationSession(startedAt: started, phase: phase, holdStartedAt: holdStart))
        }
        let c1 = run(input(60, settings: s80, memory: cal(.chargeToFull)))
        check(c1.desired == .released && c1.display == .calibrating(.chargeToFull), "calibration charges past user limit")
        check(run(input(95, settings: s80, memory: cal(.chargeToFull))).desired == .released, "calibration ignores limit")
        let c2 = run(input(100, settings: s80, memory: cal(.chargeToFull)))
        check(c2.memory.calibration?.phase == .hold && c2.memory.calibration?.holdStartedAt == t0, "full starts hold")
        let c3 = run(input(100, now: t0.addingTimeInterval(3599), settings: s80, memory: c2.memory))
        check(c3.memory.calibration?.phase == .hold && c3.desired == .released, "hold lasts one hour")
        let c4 = run(input(100, now: t0.addingTimeInterval(3600), settings: s80, memory: c2.memory))
        check(c4.memory.calibration?.phase == .dischargeToLow && c4.desired == cut, "hold ends into discharge")
        let c5 = run(input(40, now: t0.addingTimeInterval(4000), settings: s80, memory: c4.memory))
        check(c5.desired == cut, "discharging continues")
        let c6 = run(input(15, now: t0.addingTimeInterval(9000), settings: s80, memory: c4.memory))
        check(c6.memory.calibration?.phase == .rechargeToFull && c6.desired == .released, "low ends discharge, recharges")
        let c7 = run(input(99, now: t0.addingTimeInterval(20000), settings: s80, memory: c6.memory))
        check(c7.memory.calibration?.phase == .rechargeToFull, "recharge continues")
        let c8 = run(input(100, now: t0.addingTimeInterval(21000), settings: s80, memory: c6.memory))
        check(c8.memory.calibration == nil && c8.desired == hold, "calibration done restores user limit")
        // Resume after restart: persisted memory survives JSON round trip.
        let data = try! JSONEncoder().encode(c4.memory)
        let restored = try! JSONDecoder().decode(AdvancedChargeMemory.self, from: data)
        check(restored.calibration == c4.memory.calibration, "calibration memory round trips")
        check(run(input(50, now: t0.addingTimeInterval(5000), settings: s80, memory: restored)).desired == cut, "resumes discharge after restart")
        check(run(input(100, now: t0.addingTimeInterval(7200), settings: s80, memory: cal(.hold, holdStart: t0))).memory.calibration?.phase == .dischargeToLow, "hold elapsed during downtime advances")
        // Safety interactions
        check(run(input(50, external: false, settings: s80, memory: cal(.dischargeToLow))).desired == .released, "calibration unplug releases")
        check(run(input(50, external: false, settings: s80, memory: cal(.dischargeToLow))).memory.calibration != nil, "calibration survives unplug")
        check(run(input(9, settings: s80, memory: cal(.dischargeToLow))).desired == .released, "calibration respects critical")
        check(run(input(50, settings: s80, topUp: true, memory: cal(.dischargeToLow))).desired == .released, "top up beats calibration")
        let expired = run(input(85, now: t0.addingTimeInterval(24 * 3600 + 1), settings: s80, memory: cal(.dischargeToLow)))
        check(expired.memory.calibration == nil && expired.desired == hold, "calibration 24h timeout")
        check(run(input(50, now: t0.addingTimeInterval(24 * 3600 - 1), settings: s80, memory: cal(.dischargeToLow))).desired == cut, "calibration before timeout")
        check(run(input(50, settings: s80, caps: chargeOnly, memory: cal(.dischargeToLow))).memory.calibration == nil, "calibration cancelled without discharge capability")
        check(run(input(50, temp: 40, settings: heat, memory: cal(.rechargeToFull))).display == .heatPaused, "heat pauses calibration charging")
        check(run(input(50, temp: 40, settings: heat, memory: cal(.dischargeToLow))).desired == cut, "heat does not stop calibration discharge")

        // Adapter mode (no charge inhibit, adapter cut only)
        let adapterCaps = ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: true, reason: nil)
        var ad = AdvancedChargeSettings(); ad.targetLimit = 80; ad.adapterModeEnabled = true
        func arun(_ pct: Int, _ settings: AdvancedChargeSettings = ad, memory: AdvancedChargeMemory = AdvancedChargeMemory(),
                  external: Bool = true, sleep: SleepState = .awake, topUp: Bool = false, temp: Double? = 25,
                  now: Date = t0) -> AdvancedChargeOutput {
            run(input(pct, temp: temp, external: external, now: now, settings: settings, caps: adapterCaps,
                      sleep: sleep, topUp: topUp, memory: memory))
        }
        var plain = ad; plain.adapterModeEnabled = false
        check(arun(95, plain).desired == .released && arun(95, plain).display == .unavailable, "adapter mode off stays unavailable")
        check(run(input(95, settings: ad, caps: .unsupported)).desired == .released, "adapter mode needs force-discharge capability")
        check(arun(79).desired == .released && arun(79).display == .idle, "adapter below target charges")
        let a1 = arun(80)
        check(a1.desired == cut && a1.display == .adapterCut && a1.memory.adapterLatched, "adapter cut at target")
        check(arun(90).desired == cut, "adapter cut above target")
        // hysteresis: stays cut down to target-5 exclusive, releases at 75
        var am = a1.memory
        for pct in [79, 78, 77, 76] { let o = arun(pct, memory: am); am = o.memory; check(o.desired == cut, "adapter holds cut at \(pct)") }
        let a2 = arun(75, memory: am)
        check(a2.desired == .released && !a2.memory.adapterLatched, "adapter released at target-5")
        am = a2.memory
        check(arun(78, memory: am).desired == .released, "no re-cut inside band after release")
        check(arun(79, memory: am).desired == .released, "no re-cut at 79")
        check(arun(80, memory: am).desired == cut, "re-cut at target")
        // band minimum is 5 even with a small sailing delta, larger delta widens it
        var smallDelta = ad; smallDelta.sailingDelta = 2
        check(AdvancedChargeEngine.adapterResumeAt(target: 80, sailingDelta: 2) == 75, "min band 5")
        let sm2 = arun(80, smallDelta).memory
        check(arun(76, smallDelta, memory: sm2).desired == cut && arun(75, smallDelta, memory: sm2).desired == .released, "small delta uses band 5")
        var bigDelta = ad; bigDelta.sailingDelta = 10
        let bm = arun(80, bigDelta).memory
        check(arun(71, bigDelta, memory: bm).desired == cut && arun(70, bigDelta, memory: bm).desired == .released, "big delta widens band")
        check(AdvancedChargeEngine.adapterResumeAt(target: 80, sailingDelta: 15) == 65, "delta 15")
        // target 100 never cuts
        var ad100 = ad; ad100.targetLimit = 100
        check(arun(100, ad100).desired == .released, "adapter mode target 100 no cut")
        // sleep / unplug / critical / top up
        check(arun(85, sleep: .aboutToSleep).desired == .released && arun(85, sleep: .asleep).desired == .released, "adapter restored for sleep")
        check(arun(85, memory: am, sleep: .asleep).memory.adapterLatched == am.adapterLatched, "sleep keeps latch state")
        let latched = AdvancedChargeMemory(adapterLatched: true)
        check(arun(78, memory: latched, sleep: .asleep).memory.adapterLatched, "latch survives sleep")
        check(arun(78, memory: latched).desired == cut, "re-cut after wake inside band")
        check(arun(90, external: false).desired == .released && arun(90, external: false).display == .onBattery, "adapter mode unplug releases")
        check(!arun(90, memory: latched, external: false).memory.adapterLatched, "unplug clears latch")
        check(arun(9, memory: latched).desired == .released && arun(9, memory: latched).display == .criticalLow, "adapter critical releases")
        check(!arun(9, memory: latched).memory.adapterLatched, "critical clears latch")
        check(arun(90, topUp: true).desired == .released && arun(90, topUp: true).display == .topUp, "adapter top up releases")
        check(!arun(90, memory: latched, topUp: true).memory.adapterLatched, "top up clears latch")
        // heat: no adapter action
        var adHeat = ad; adHeat.heatProtectionEnabled = true
        check(arun(50, adHeat, temp: 45).desired == .released && arun(50, adHeat, temp: 45).display == .idle, "adapter mode ignores heat")
        check(arun(85, adHeat, temp: 45).desired == cut, "limit still cuts when hot")
        // discharge and calibration keep priority
        let adDis = AdvancedChargeMemory(discharge: DischargeRequest(requestedAt: t0))
        check(arun(90, memory: adDis).desired == cut && arun(90, memory: adDis).display == .discharging, "adapter discharge request")
        let adDis2 = arun(80, memory: adDis)
        check(adDis2.memory.discharge == nil && adDis2.desired == cut && adDis2.display == .adapterCut, "discharge ends into hold")
        let adCal = AdvancedChargeMemory(calibration: CalibrationSession(startedAt: t0, phase: .chargeToFull, holdStartedAt: nil))
        check(arun(85, memory: adCal).desired == .released && arun(85, memory: adCal).display == .calibrating(.chargeToFull), "calibration beats adapter hold")
        let adCal2 = AdvancedChargeMemory(calibration: CalibrationSession(startedAt: t0, phase: .dischargeToLow, holdStartedAt: nil), adapterLatched: true)
        check(arun(50, memory: adCal2).desired == cut && arun(50, memory: adCal2).display == .calibrating(.dischargeToLow), "calibration discharge cuts")
        check(arun(50, memory: adCal2, sleep: .asleep).desired == .released, "sleep releases calibration discharge in adapter mode")
        check(arun(80, memory: adDis, topUp: true).desired == .released, "top up beats adapter discharge")
        // charge-inhibit capable hardware ignores adapter setting
        let both = run(input(85, settings: ad, caps: full))
        check(both.desired == hold && !both.memory.adapterLatched, "inhibit-capable keeps old behaviour")
        // old persisted data decodes
        let oldSettings = try! JSONDecoder().decode(AdvancedChargeSettings.self, from: Data("{\"targetLimit\":70}".utf8))
        check(oldSettings.targetLimit == 70 && !oldSettings.adapterModeEnabled, "old settings decode")
        let oldMem = try! JSONDecoder().decode(AdvancedChargeMemory.self, from: Data("{\"limitLatched\":true,\"heatLatched\":false}".utf8))
        check(oldMem.limitLatched && !oldMem.adapterLatched, "old memory decodes")

        // Runner in adapter mode
        let adFake = FakeBackend(); adFake.caps = adapterCaps
        let adRunner = AdvancedChargeRunner(backend: adFake, defaults: UserDefaults(suiteName: "adapter-runner-\(UUID())")!)
        adRunner.settings = ad
        adRunner.update(percentage: 82, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0)
        check(adFake.state == cut && adRunner.adapterStatusText?.contains("75") == true, "runner cuts adapter and reports status")
        adRunner.setSleepState(.asleep, now: t0.addingTimeInterval(10))
        check(adFake.state == .released, "runner restores adapter before sleep")
        adRunner.setSleepState(.awake, now: t0.addingTimeInterval(20))
        check(adFake.state == cut, "runner re-cuts after wake")
        adRunner.update(percentage: 74, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0.addingTimeInterval(30))
        check(adFake.state == .released && adRunner.adapterStatusText == nil, "runner restores adapter at resume level")

        // Runner
        let defaults = UserDefaults(suiteName: "advanced-charge-tests-\(UUID())")!
        let fake = FakeBackend()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("adv-\(UUID())/memory.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let runner = AdvancedChargeRunner(backend: fake, store: AdvancedChargeMemoryStore(url: tmp), defaults: defaults)
        runner.settings = s80
        runner.update(percentage: 70, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0)
        check(fake.applies.isEmpty, "runner applies nothing when desired equals current")
        runner.update(percentage: 80, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0)
        check(fake.applies == [hold], "runner applies on change")
        runner.update(percentage: 80, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0.addingTimeInterval(5))
        check(fake.applies.count == 1 && fake.heartbeats == 0, "runner does not repeat apply or heartbeat early")
        runner.update(percentage: 80, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0.addingTimeInterval(21))
        check(fake.heartbeats == 1, "runner heartbeats while inhibited")
        runner.setSleepState(.aboutToSleep, now: t0.addingTimeInterval(30))
        check(runner.sleepMayOvershoot, "runner reports sleep overshoot")
        fake.state = .released // helper released on sleep
        runner.setSleepState(.awake, now: t0.addingTimeInterval(500))
        check(fake.applies.count == 2 && fake.state == hold, "runner reapplies after wake")
        runner.update(percentage: 80, temperatureC: 25, externalConnected: false, isCharging: false, topUpActive: false, now: t0.addingTimeInterval(600))
        check(fake.state == .released, "runner releases on unplug")
        let beats = fake.heartbeats
        runner.heartbeatIfDue(now: t0.addingTimeInterval(700))
        check(fake.heartbeats == beats, "no heartbeat when released")
        runner.update(percentage: 80, temperatureC: 25, externalConnected: true, isCharging: true, topUpActive: false, now: t0.addingTimeInterval(800))
        runner.releaseAll()
        check(fake.state == .released && runner.applied == .released, "release on quit")
        // Discharge request + persistence + resume
        runner.update(percentage: 90, temperatureC: 25, externalConnected: true, isCharging: false, topUpActive: false, now: t0.addingTimeInterval(900))
        runner.requestDischarge(now: t0.addingTimeInterval(901))
        check(fake.state == cut && FileManager.default.fileExists(atPath: tmp.path), "runner discharges and persists request")
        runner.cancelDischarge(now: t0.addingTimeInterval(902))
        check(fake.state == hold && !FileManager.default.fileExists(atPath: tmp.path), "cancel discharge clears persistence")
        runner.startCalibration(now: t0.addingTimeInterval(1000))
        let resumed = AdvancedChargeRunner(backend: fake, store: AdvancedChargeMemoryStore(url: tmp), defaults: defaults)
        check(resumed.memory.calibration?.phase == .chargeToFull, "runner resumes calibration after restart")
        check(resumed.settings == s80, "settings persisted")
        runner.cancelCalibration(now: t0.addingTimeInterval(1100))
        check(!FileManager.default.fileExists(atPath: tmp.path), "cancel calibration clears persistence")
        fake.failApply = true
        runner.update(percentage: 70, temperatureC: 25, externalConnected: true, isCharging: false, topUpActive: false, now: t0.addingTimeInterval(1200))
        check(runner.lastError != nil, "apply failure surfaces")
        // Default runner is inert
        let inert = AdvancedChargeRunner(defaults: UserDefaults(suiteName: "advanced-inert-\(UUID())")!)
        inert.update(percentage: 99, temperatureC: 50, externalConnected: true, isCharging: true, topUpActive: false, now: t0)
        inert.requestDischarge(now: t0); inert.startCalibration(now: t0)
        check(inert.applied == .released && inert.display == .unavailable && inert.memory.calibration == nil && inert.memory.discharge == nil, "default runner unsupported is inert")

        print("advanced-charge-engine-tests: \(count) checks passed")
    }
}
