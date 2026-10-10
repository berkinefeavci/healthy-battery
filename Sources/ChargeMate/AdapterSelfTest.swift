import Foundation
import IOKit

/// One battery reading for the adapter self-test.
struct AdapterSelfTestSample: Equatable {
    var externalConnected: Bool
    /// Battery current in mA; negative while the battery powers the Mac.
    var amperage: Int
    var percent: Int
}

struct AdapterSelfTestReport: Codable, Equatable {
    enum Outcome: String, Codable { case passed, failed, skipped }
    struct Step: Codable, Equatable {
        var name: String
        var ok: Bool
        var detail: String
    }

    var outcome: Outcome
    var summary: String
    var startedAt: Date
    var finishedAt: Date
    var steps: [Step]
    var model = ""
    var system = ""
    var appVersion = ""
}

/// Automatic physical check of adapter mode. It does sections A, C and D of
/// `docs/2026-10-06-Faz3-Fiziksel-Test.md` without a terminal: cut the adapter and see the battery
/// discharge, restore it and see wall power return, then cut it once more without heartbeats and wait
/// for the helper's 60 s watchdog to restore it. Every path ends with a release request.
/// Pure: the helper transport, battery reader, sleep and clock are injected.
struct AdapterSelfTest {
    var request: (String) throws -> String
    var sample: () -> AdapterSelfTestSample?
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init

    static let minimumPercent = 20
    /// Below this current (mA) the battery is clearly powering the Mac.
    static let dischargingBelow = -100
    static let observeWindow: TimeInterval = 20
    static let pollInterval: TimeInterval = 2
    static let heartbeatEvery: TimeInterval = 10
    static let watchdogLimit: TimeInterval = 75
    static let watchdogPoll: TimeInterval = 5

    func run() -> AdapterSelfTestReport {
        let start = now()
        var steps: [AdapterSelfTestReport.Step] = []
        var touched = false
        func finish(_ outcome: AdapterSelfTestReport.Outcome, _ summary: String) -> AdapterSelfTestReport {
            if touched { _ = try? request(ChargeInhibitWire.setRequest(.released)) }
            return AdapterSelfTestReport(outcome: outcome, summary: summary, startedAt: start, finishedAt: now(), steps: steps)
        }
        func step(_ name: String, _ ok: Bool, _ detail: String) { steps.append(.init(name: name, ok: ok, detail: detail)) }
        func cut(_ on: Bool) throws -> ChargeInhibitState {
            touched = true
            return try ChargeInhibitWire.state(from: request(ChargeInhibitWire.setRequest(
                ChargeInhibitState(chargingInhibited: false, adapterInhibited: on))))
        }
        /// Polls the battery until `condition` holds; sends a heartbeat every 10 s when asked.
        func observe(heartbeat: Bool, _ condition: (AdapterSelfTestSample) -> Bool) -> (ok: Bool, last: AdapterSelfTestSample?, seconds: Int) {
            var waited: TimeInterval = 0, sinceBeat: TimeInterval = 0, last: AdapterSelfTestSample?
            while waited <= Self.observeWindow {
                if let reading = sample() {
                    last = reading
                    if condition(reading) { return (true, reading, Int(waited)) }
                }
                sleep(Self.pollInterval)
                waited += Self.pollInterval
                sinceBeat += Self.pollInterval
                if heartbeat, sinceBeat >= Self.heartbeatEvery {
                    sinceBeat = 0
                    _ = try? request(ChargeInhibitWire.heartbeatRequest)
                }
            }
            return (false, last, Int(waited))
        }
        func describe(_ s: AdapterSelfTestSample?) -> String {
            guard let s else { return "no reading" }
            return "external=\(s.externalConnected) amperage=\(s.amperage)mA percent=\(s.percent)"
        }
        let discharging = { (s: AdapterSelfTestSample) in s.amperage < Self.dischargingBelow }
        let onWallPower = { (s: AdapterSelfTestSample) in s.externalConnected && s.amperage >= Self.dischargingBelow }

        guard let first = sample() else { return finish(.skipped, String(localized: "Pil okunamadı; test yapılmadı.")) }
        guard first.externalConnected else {
            return finish(.skipped, String(localized: "Adaptör takılı değil; test adaptör takılınca kendiliğinden yapılır."))
        }
        guard first.percent >= Self.minimumPercent else { return finish(.skipped, String(localized: "Pil %20'nin altında; test yapılmadı.")) }
        guard !discharging(first) else {
            return finish(.skipped, String(localized: "Mac adaptördeyken de pilden besleniyor (yük yüksek); test sonra yapılır."))
        }
        step("start", true, describe(first))

        do {
            let caps = try ChargeInhibitWire.capabilities(from: request(ChargeInhibitWire.capabilitiesRequest))
            step("capabilities", caps.adapter, "charging=\(caps.charging) adapter=\(caps.adapter) reasons=\(caps.chargingReason),\(caps.adapterReason)")
            guard caps.adapter else {
                return finish(.failed, caps.adapterReason == 2
                    ? String(localized: "macOS bu Mac'te adaptörü kesmeye izin vermiyor; adaptör modu kullanılamaz.")
                    : String(localized: "Bu Mac'te adaptörü kesen anahtar yok; adaptör modu kullanılamaz."))
            }

            // 1. Cut: the battery must start powering the Mac.
            let applied = try cut(true)
            guard applied.adapterInhibited else {
                step("cut", false, "helper answered \(applied)")
                return finish(.failed, String(localized: "Yardımcı adaptörü kesmedi."))
            }
            let drained = observe(heartbeat: true, discharging)
            step("cut", drained.ok, "\(describe(drained.last)) after \(drained.seconds)s")
            guard drained.ok else {
                return finish(.failed, String(localized: "Adaptör kesildi göründü ama pil boşalmadı; bu Mac'te adaptör modu çalışmıyor."))
            }

            // 2. Restore: wall power must come back.
            let released = try cut(false)
            let back = observe(heartbeat: false, onWallPower)
            step("restore", released == .released && back.ok, "\(describe(back.last)) after \(back.seconds)s")
            guard released == .released, back.ok else {
                return finish(.failed, String(localized: "Adaptör geri açılmadı; kabloyu çıkarıp takın."))
            }

            // 3. Watchdog: cut again, send no heartbeat, the helper must restore on its own.
            guard try cut(true).adapterInhibited else {
                step("watchdog", false, "second cut refused")
                return finish(.failed, String(localized: "Yardımcı adaptörü kesmedi."))
            }
            var waited: TimeInterval = 0, restored = false
            while waited < Self.watchdogLimit {
                sleep(Self.watchdogPoll)
                waited += Self.watchdogPoll
                if let state = try? ChargeInhibitWire.state(from: request(ChargeInhibitWire.readRequest)), state == .released {
                    restored = true
                    break
                }
            }
            let afterWatchdog = restored ? observe(heartbeat: false, onWallPower) : (ok: false, last: sample(), seconds: 0)
            step("watchdog", restored && afterWatchdog.ok, "released after \(Int(waited))s; \(describe(afterWatchdog.last))")
            guard restored, afterWatchdog.ok else {
                return finish(.failed, String(localized: "Uygulama sustuğunda yardımcı adaptörü kendiliğinden geri açmadı."))
            }
        } catch {
            step("helper", false, error.localizedDescription)
            return finish(.failed, String(localized: "Şarj yardımcısıyla konuşulamadı: \(error.localizedDescription)"))
        }
        return finish(.passed, String(localized: "Adaptör testi geçti: kesme, geri açma ve güvenlik zamanlayıcısı çalışıyor."))
    }
}

/// Live battery reading straight from AppleSmartBattery (no BatteryMonitor state involved).
enum AdapterSelfTestProbe {
    static func live() -> AdapterSelfTestSample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func number(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        }
        guard let current = number("CurrentCapacity")?.intValue, let maximum = number("MaxCapacity")?.intValue, maximum > 0,
              let amperage = number("InstantAmperage") ?? number("Amperage") else { return nil }
        return AdapterSelfTestSample(externalConnected: number("ExternalConnected")?.boolValue ?? false,
                                     amperage: Int(amperage.int64Value), // signed two's complement
                                     percent: Int((Double(current) * 100 / Double(maximum)).rounded()))
    }
}

/// `~/Library/Application Support/Cellkeep/adapter-self-test.json`, last report only.
enum AdapterSelfTestStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep").appendingPathComponent("adapter-self-test.json")
    }

    static func load(from url: URL = url) -> AdapterSelfTestReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AdapterSelfTestReport.self, from: data)
    }

    static func save(_ report: AdapterSelfTestReport, to url: URL = url) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
