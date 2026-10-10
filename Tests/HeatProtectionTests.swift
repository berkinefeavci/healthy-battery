import Foundation

@main
enum HeatProtectionTests {
    static func input(_ change: (inout HeatProtectionInput) -> Void = { _ in }) -> HeatProtectionInput {
        var value = HeatProtectionInput(enabled: true, temperatureC: 36, externalConnected: true, isCharging: true,
                                        nativeLimit: 100, availableLimits: [80, 85, 90, 95, 100], adapterMode: .automatic,
                                        topUpActive: false, controlBlocked: false, override: nil)
        change(&value)
        return value
    }
    static let override = HeatProtectionOverride(previousLimit: 100, previousAdapterModeRawValue: nil, startedAt: Date())

    static func main() {
        // Devreye girme
        precondition(HeatProtection.decide(input()) == .engage(previousLimit: 100, limit: 80, switchAdapterModeFrom: nil))
        precondition(HeatProtection.decide(input { $0.adapterMode = .turbo })
            == .engage(previousLimit: 100, limit: 80, switchAdapterModeFrom: .turbo))
        precondition(HeatProtection.decide(input { $0.adapterMode = .lowPower })
            == .engage(previousLimit: 100, limit: 80, switchAdapterModeFrom: nil))
        precondition(HeatProtection.decide(input { $0.temperatureC = 35 }) == .none, "35 tam eşik: yalnızca üstü")
        precondition(HeatProtection.decide(input { $0.temperatureC = nil }) == .none)
        precondition(HeatProtection.decide(input { $0.temperatureC = .nan }) == .none)
        precondition(HeatProtection.decide(input { $0.enabled = false }) == .none)
        precondition(HeatProtection.decide(input { $0.externalConnected = false }) == .none)
        precondition(HeatProtection.decide(input { $0.isCharging = false }) == .none)
        precondition(HeatProtection.decide(input { $0.nativeLimit = 80 }) == .none)
        precondition(HeatProtection.decide(input { $0.nativeLimit = 75 }) == .none)
        precondition(HeatProtection.decide(input { $0.availableLimits = [85, 90, 100] }) == .none)
        precondition(HeatProtection.decide(input { $0.topUpActive = true }) == .none, "Top Up'a karışma")
        precondition(HeatProtection.decide(input { $0.controlBlocked = true }) == .none, "çakışma/kurtarmada yazma")
        precondition(HeatProtection.decide(input { $0.nativeLimit = nil }) == .none)

        // Geri yükleme: histerezis
        func restoring(_ change: (inout HeatProtectionInput) -> Void = { _ in }) -> HeatProtectionAction {
            HeatProtection.decide(input { $0.nativeLimit = 80; $0.override = override; $0.temperatureC = 33; change(&$0) })
        }
        precondition(restoring() == .none, "32–35 arası bekle")
        precondition(restoring { $0.temperatureC = 31.9 } == .restore(limit: 100, restoreAdapterMode: nil))
        precondition(restoring { $0.temperatureC = 32 } == .none, "32 tam eşik: altı gerekir")
        precondition(restoring { $0.temperatureC = 40; $0.externalConnected = false }
            == .restore(limit: 100, restoreAdapterMode: nil), "adaptör çıkınca sıcak olsa da geri ver")
        precondition(restoring { $0.temperatureC = nil; $0.externalConnected = false }
            == .restore(limit: 100, restoreAdapterMode: nil))
        precondition(restoring { $0.temperatureC = nil } == .none, "sıcaklık okunamıyorsa bekle")
        precondition(restoring { $0.temperatureC = 40; $0.enabled = false }
            == .restore(limit: 100, restoreAdapterMode: nil), "özellik kapatılınca geri ver")
        precondition(restoring { $0.temperatureC = 30; $0.topUpActive = true } == .none, "Top Up sürerken bekle")
        precondition(restoring { $0.temperatureC = 30; $0.controlBlocked = true } == .none)
        precondition(restoring { $0.temperatureC = 30; $0.nativeLimit = 90 } == .forgetOverride,
                     "kullanıcı değiştirdiyse üzerine yazma")
        precondition(restoring { $0.temperatureC = 30; $0.nativeLimit = 100 } == .forgetOverride)
        precondition(restoring { $0.temperatureC = 30; $0.nativeLimit = nil } == .none)
        // Aşırı sıcakta bile mevcut geçersiz kılma varken ikinci kez devreye girmez
        precondition(restoring { $0.temperatureC = 45 } == .none)

        // Güç modu geri verme yalnızca bizim bıraktığımız (Otomatik) haldeyse
        let turboOverride = HeatProtectionOverride(previousLimit: 95, previousAdapterModeRawValue: SystemPowerMode.turbo.rawValue,
                                                   startedAt: Date())
        func turboRestore(_ mode: SystemPowerMode) -> HeatProtectionAction {
            HeatProtection.decide(input { $0.nativeLimit = 80; $0.override = turboOverride; $0.temperatureC = 30
                $0.adapterMode = mode })
        }
        precondition(turboRestore(.automatic) == .restore(limit: 95, restoreAdapterMode: .turbo))
        precondition(turboRestore(.lowPower) == .restore(limit: 95, restoreAdapterMode: nil))
        precondition(turboRestore(.turbo) == .restore(limit: 95, restoreAdapterMode: nil))

        // Kalıcı kayıt: çökme/yeniden başlatma
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heat-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HeatOverrideStore(url: directory.appendingPathComponent("heat-override.json"))
        precondition(store.load() == nil)
        let saved = HeatProtectionOverride(previousLimit: 90, previousAdapterModeRawValue: 2,
                                           startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try! store.save(saved)
        precondition(HeatOverrideStore(url: store.url).load() == saved, "yeni örnek aynı kaydı okur")
        try! store.clear()
        precondition(store.load() == nil)
        try! store.clear()
        try! Data("{bozuk".utf8).write(to: store.url)
        precondition(store.load() == nil, "bozuk kayıt yok sayılır")
        try! Data(#"{"schemaVersion":1,"previousLimit":5,"startedAt":"2023-11-14T22:13:20Z"}"#.utf8).write(to: store.url)
        precondition(store.load() == nil, "geçersiz önceki sınır reddedilir")

        precondition(HeatProtection.notificationBody(temperatureC: 36.4, modeChanged: true).contains("Turbo"))
        precondition(!HeatProtection.notificationBody(temperatureC: 36.4, modeChanged: false).contains("Turbo"))
        print("HeatProtection: all assertions passed (no hardware access)")
    }
}
