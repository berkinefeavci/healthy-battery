import Foundation

@main
enum FullChargeDwellTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    static func step(_ state: FullChargeDwellState, _ percent: Int?, _ hours: Double, plugged: Bool = true,
                     enabled: Bool = true, suggest: Bool = true) -> (state: FullChargeDwellState, notify: Bool) {
        FullChargeDwell.step(state, percentage: percent, externalConnected: plugged, enabled: enabled,
                             canSuggestLimit: suggest, now: at(hours))
    }

    static func main() {
        var s = FullChargeDwellState()
        var r = step(s, 100, 0); s = r.state
        precondition(!r.notify && s.aboveSince == at(0))
        r = step(s, 100, 3); s = r.state
        precondition(!r.notify, "tam 3 saat: 'uzun' gerekir")
        r = step(s, 100, 3.01); s = r.state
        precondition(r.notify && s.notified)
        r = step(s, 100, 5); s = r.state
        precondition(!r.notify, "tek bildirim")
        // 90–94 arası yeniden silahlanmaz, süre sayacı sıfırlanır
        r = step(s, 92, 6); s = r.state
        precondition(s.notified && s.aboveSince == nil)
        r = step(s, 100, 7); s = r.state
        precondition(!r.notify)
        r = step(s, 100, 11); s = r.state
        precondition(!r.notify, "silahlanmadan tekrar yok")
        // 90 altı yeniden silahlar
        r = step(s, 89, 12); s = r.state
        precondition(s == FullChargeDwellState())
        r = step(s, 97, 13); s = r.state
        r = step(s, 97, 16.5); s = r.state
        precondition(r.notify, "yeniden silahlanan uyarı")
        // Adaptör çıkınca sıfırlanır
        r = step(s, 97, 17, plugged: false); s = r.state
        precondition(s == FullChargeDwellState() && !r.notify)
        // 95 altına düşüş sürekliliği bozar
        s = FullChargeDwellState()
        s = step(s, 99, 0).state
        s = step(s, 94, 2).state
        precondition(s.aboveSince == nil)
        r = step(s, 99, 4); s = r.state
        r = step(s, 99, 6); s = r.state
        precondition(!r.notify, "kesintiden sonra 3 saat yeniden sayılır")
        r = step(s, 99, 7.1)
        precondition(r.notify)
        // Kapalı tercih / öneri anlamsızsa bildirim yok, bildirildi işaretlenmez
        s = step(FullChargeDwellState(), 100, 0).state
        r = step(s, 100, 4, enabled: false)
        precondition(!r.notify && !r.state.notified)
        r = step(s, 100, 4, suggest: false)
        precondition(!r.notify && !r.state.notified)
        r = step(r.state, 100, 4.1)
        precondition(r.notify, "tercih açılınca geç de olsa uyarır")
        // Okunamayan yüzde durumu korur
        r = step(s, nil, 2)
        precondition(r.state == s && !r.notify)
        precondition(FullChargeDwell.notificationTitle.contains("3 saat"))
        print("FullChargeDwell: all assertions passed")
    }
}
