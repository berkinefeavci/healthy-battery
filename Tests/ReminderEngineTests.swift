import CoreGraphics
import Foundation

@main
enum ReminderEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static let all = ReminderSettings(enabled: true, kinds: Set(ReminderKind.allCases))

    static func sample(_ p: Int?, plugged: Bool = false, charging: Bool = false, temp: Double? = nil, limit: Int? = 100)
        -> ReminderSample {
        ReminderSample(percentage: p, externalConnected: plugged, isCharging: charging, temperatureC: temp, limit: limit)
    }

    @discardableResult
    static func feed(_ s: inout ReminderState, _ sample: ReminderSample, _ minutes: Double,
                     settings: ReminderSettings = all) -> [ReminderKind] {
        let r = ReminderEngine.step(s, sample: sample, settings: settings, now: at(minutes))
        s = r.state
        return r.fire
    }

    static func main() {
        // Açılış: mevcut durum için tetik yok (pil %35, pilde)
        var s = ReminderState()
        precondition(feed(&s, sample(35), 0).isEmpty, "açılışta ateşleme yok")
        precondition(feed(&s, sample(34), 1).isEmpty)

        // Kablo çıkarıldı + cooldown 4 saat
        s = ReminderState()
        feed(&s, sample(80, plugged: true), 0)
        precondition(feed(&s, sample(80), 1) == [.cableRemoved])
        feed(&s, sample(80, plugged: true), 2)
        precondition(feed(&s, sample(80), 3).isEmpty, "cooldown içinde yok")
        feed(&s, sample(80, plugged: true), 4)
        precondition(feed(&s, sample(80), 1 + 241) == [.cableRemoved], "4 saat sonra yine")

        // %40 ve %20: eşik civarında dolaşırken tekrar yok, takınca yeniden silahlanır
        s = ReminderState()
        feed(&s, sample(42), 0)
        precondition(feed(&s, sample(40), 1) == [.reached40])
        precondition(feed(&s, sample(41), 2).isEmpty && feed(&s, sample(40), 3).isEmpty, "tekrar yok")
        precondition(feed(&s, sample(21), 4).isEmpty)
        precondition(feed(&s, sample(20), 5) == [.reached20])
        precondition(feed(&s, sample(21), 6).isEmpty && feed(&s, sample(19), 7).isEmpty)
        feed(&s, sample(30, plugged: true, charging: true), 8)
        feed(&s, sample(45, plugged: true, charging: true), 9)
        feed(&s, sample(45), 10) // kablo çıktı (cooldown sayacı ayrı)
        precondition(feed(&s, sample(40), 11) == [.reached40], "takınca yeniden silahlandı")
        // Prize bağlıyken eşik geçişi sayılmaz
        s = ReminderState()
        feed(&s, sample(45, plugged: true), 0)
        precondition(feed(&s, sample(39, plugged: true), 1).isEmpty)
        // 45 -> 18 tek örnekte: yalnızca %20 mesajı
        s = ReminderState()
        feed(&s, sample(45), 0)
        precondition(feed(&s, sample(18), 1) == [.reached20])
        precondition(feed(&s, sample(17), 2).isEmpty, "%40 de tüketildi")

        // Şarjda ısınma: 2 ardışık örnek, cooldown 30 dk
        s = ReminderState()
        feed(&s, sample(60, plugged: true, charging: true, temp: 34), 0)
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 1).isEmpty, "tek örnek yetmez")
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 2) == [.chargingWarm])
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 3).isEmpty, "cooldown")
        feed(&s, sample(60, plugged: true, charging: true, temp: 30), 4)
        feed(&s, sample(60, plugged: true, charging: true, temp: 36), 5)
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 6).isEmpty, "30 dk dolmadı")
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 33) == [.chargingWarm])
        s = ReminderState()
        feed(&s, sample(60, plugged: true, charging: true, temp: 36), 0)
        feed(&s, sample(60, plugged: true, charging: false, temp: 36), 1)
        precondition(feed(&s, sample(60, plugged: true, charging: true, temp: 36), 2).isEmpty, "seri bozulur")

        // Dolu pille takıldı: %95+, limit > 80, cooldown 12 saat
        s = ReminderState()
        feed(&s, sample(97), 0)
        precondition(feed(&s, sample(97, plugged: true, limit: 80), 1).isEmpty, "limit 80 ise yok")
        feed(&s, sample(97), 2)
        precondition(feed(&s, sample(97, plugged: true, limit: 100), 3) == [.pluggedFull])
        feed(&s, sample(97), 4)
        precondition(!feed(&s, sample(97, plugged: true), 5).contains(.pluggedFull), "12 saat cooldown")
        s = ReminderState()
        feed(&s, sample(90), 0)
        precondition(feed(&s, sample(90, plugged: true), 1).isEmpty, "%95 altı yok")

        // Aylık kalibrasyon: varsayılan kapalı; 30 gün sonra pilde bir kez
        precondition(!ReminderSettings.load(UserDefaults(suiteName: "reminder-test-\(UUID())")!).kinds.contains(.calibration))
        let defaultsOn = ReminderSettings()
        s = ReminderState()
        feed(&s, sample(70), 0, settings: defaultsOn)
        precondition(feed(&s, sample(69), 60 * 24 * 29, settings: defaultsOn).isEmpty, "29 gün: erken")
        precondition(feed(&s, sample(69), 60 * 24 * 30, settings: defaultsOn).isEmpty, "kapalıyken ateşlemez")
        precondition(feed(&s, sample(69), 60 * 24 * 30 + 1) == [.calibration])
        precondition(feed(&s, sample(68), 60 * 24 * 30 + 2).isEmpty, "bir kez")
        // Tam döngü tamamlanınca sayaç sıfırlanır
        s = ReminderState()
        feed(&s, sample(99, plugged: true), 0)
        feed(&s, sample(50), 10)
        feed(&s, sample(19), 60 * 24 * 20)
        precondition(feed(&s, sample(60), 60 * 24 * 40).isEmpty, "döngü 20. günde tamamlandı; 40. gün erken")
        precondition(feed(&s, sample(60), 60 * 24 * 51) == [.calibration])

        // Uyku: uyurken ve uyanınca 60 sn susar; uyanış sonrası ilk örnek referanstır
        s = ReminderState()
        feed(&s, sample(80, plugged: true), 0)
        s = ReminderEngine.willSleep(s)
        precondition(feed(&s, sample(80), 1).isEmpty, "uykuda yok")
        s = ReminderEngine.didWake(s, now: at(2))
        precondition(feed(&s, sample(80), 2).isEmpty, "uyanış sonrası referans örnek")
        s = ReminderState()
        feed(&s, sample(80, plugged: true), 0)
        s = ReminderEngine.didWake(s, now: at(10))
        feed(&s, sample(80, plugged: true), 10.1)
        precondition(feed(&s, sample(80), 10.5).isEmpty, "uyanıştan 60 sn içinde yok")
        feed(&s, sample(80, plugged: true), 11.5)
        precondition(feed(&s, sample(80), 12) == [.cableRemoved], "sonra normal")

        // Ana anahtar ve tür anahtarı: kapalıyken ateşlemez ve cooldown tüketmez
        var off = all; off.enabled = false
        s = ReminderState()
        feed(&s, sample(80, plugged: true), 0)
        precondition(feed(&s, sample(80), 1, settings: off).isEmpty && s.lastFired.isEmpty)
        var noCable = all; noCable.kinds.remove(.cableRemoved)
        feed(&s, sample(80, plugged: true), 2)
        precondition(feed(&s, sample(80), 3, settings: noCable).isEmpty && s.lastFired.isEmpty)

        // Durum kalıcılığı: yalnızca cooldown/silah bilgisi; "previous" yazılmaz
        s = ReminderState()
        feed(&s, sample(80, plugged: true), 0)
        feed(&s, sample(80), 1)
        let data = try! JSONEncoder().encode(s)
        let restored = try! JSONDecoder().decode(ReminderState.self, from: data)
        precondition(restored.previous == nil && restored.lastFired == s.lastFired)
        var r = restored
        precondition(feed(&r, sample(30), 2).isEmpty, "yeniden açılışta ilk örnek tetiklemez")

        // Toast kuyruğu: bir gösterilen + en fazla bir bekleyen
        var q = ToastQueue()
        precondition(q.enqueue("a") == .show("a"))
        precondition(q.enqueue("b") == .queued)
        precondition(q.enqueue("c") == .dropped)
        precondition(q.finished() == "b" && q.showing)
        precondition(q.finished() == nil && !q.showing)

        // Yerleşim: sabit 300×44, durum öğesinin altında; yoksa sağ üst; ekran dışına taşmaz
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let f = ToastGeometry.frame(anchor: CGRect(x: 1200, y: 875, width: 40, height: 24), screen: screen)
        precondition(f.size == CGSize(width: 300, height: 44) && f.maxY <= 875 && f.midX == 1220)
        let g = ToastGeometry.frame(anchor: nil, screen: screen)
        precondition(g.maxX <= 1440 && g.maxY <= 875 && g.size == ToastGeometry.size)
        let h = ToastGeometry.frame(anchor: CGRect(x: 1425, y: 875, width: 15, height: 24), screen: screen)
        precondition(h.maxX <= 1440 && h.minX >= 0)
        precondition(ReminderKind.reached40.message.contains("%40") && ReminderKind.reached20.message.contains("%20"))
        print("ReminderEngine: all assertions passed")
    }
}
