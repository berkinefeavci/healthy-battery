import Foundation

@main
enum ReadyByPlannerTests {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Dakikada `ratePerMinute` yüzde artan şarj parçası.
    static func run(start: Int, minutes: Int, perMinute: Double, offset: Double = 0, charging: Bool = true) -> [ChargeRateSample] {
        (0...minutes).map { m in
            ChargeRateSample(date: t0.addingTimeInterval(offset + Double(m) * 60),
                             percentage: min(100, start + Int((Double(m) * perMinute).rounded(.down))), isCharging: charging)
        }
    }

    static func main() {
        // Hız: 60 dk'da 60% → 60 %/sa
        let rate = ReadyByPlanner.chargeRatePercentPerHour(run(start: 20, minutes: 60, perMinute: 1))!
        precondition(abs(rate - 60) < 1, "\(rate)")
        precondition(ReadyByPlanner.chargeRatePercentPerHour([]) == nil)
        precondition(ReadyByPlanner.chargeRatePercentPerHour(run(start: 20, minutes: 5, perMinute: 1)) == nil, "10 dk altı yok")
        precondition(ReadyByPlanner.chargeRatePercentPerHour(run(start: 50, minutes: 60, perMinute: 0.01)) == nil, "%3 altı yok")
        precondition(ReadyByPlanner.chargeRatePercentPerHour(run(start: 20, minutes: 60, perMinute: 1, charging: false)) == nil)
        precondition(ReadyByPlanner.chargeRatePercentPerHour(run(start: 92, minutes: 30, perMinute: 0.2)) == nil, "%90 üstü başlayan parça yok sayılır")
        // Ortanca: 60 %/sa ve 30 %/sa ve 90 %/sa parçaları
        let mixed = run(start: 20, minutes: 40, perMinute: 1)
            + run(start: 20, minutes: 40, perMinute: 0.5, offset: 5 * 3600)
            + run(start: 20, minutes: 40, perMinute: 1.5, offset: 10 * 3600)
        precondition(abs(ReadyByPlanner.chargeRatePercentPerHour(mixed)! - 60) < 2)
        // Çıkarılıp takılan şarj iki parça sayılır
        let split = run(start: 20, minutes: 30, perMinute: 1)
            + run(start: 50, minutes: 30, perMinute: 1, offset: 3 * 3600)
        precondition(abs(ReadyByPlanner.chargeRatePercentPerHour(split)! - 60) < 2)

        // Başlama süresi
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: nil) == 2 * 3600, "varsayılan 2 saat")
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: 0) == 2 * 3600)
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: .nan) == 2 * 3600)
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: 60) == 6000, "80/60*1.25 sa = 100 dk")
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: 1000) == ReadyByPlanner.minimumLead)
        precondition(ReadyByPlanner.leadTime(ratePercentPerHour: 5) == ReadyByPlanner.maximumLead)

        // Görev: tek seferlik, kapalı, Top Up, başlangıç = hazır - süre
        let ready = calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 8, minute: 0))!
        let task = ReadyByPlanner.task(readyAt: ready, lead: 2 * 3600, now: t0, calendar: calendar)
        precondition(task.action == .topUp && task.recurrence == .once && !task.enabled && task.target == nil)
        precondition(task.next(after: t0) == calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 6, minute: 0)))
        precondition(task.validationError(capabilities: .init(chargeLimits: [80, 100], topUpAvailable: true, powerModes: [])) == nil)
        var enabled = task; enabled.enabled = true
        precondition(enabled.validationError(capabilities: .unavailable) != nil, "Top Up desteği yoksa etkinleştirilemez")
        // Gün sınırı: 01:00 hazır, 2 saat önce → önceki gün 23:00
        let early = calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 1, minute: 0))!
        let overnight = ReadyByPlanner.task(readyAt: early, lead: 2 * 3600, now: t0, calendar: calendar)
        precondition(overnight.next(after: t0) == calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 23, minute: 0)))

        // Sonraki 08:00
        let next = ReadyByPlanner.nextOccurrence(hour: 8, minute: 0, after: t0, calendar: calendar) // 22:13 → ertesi gün
        precondition(next == calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 8, minute: 0)))

        // Optimize Şarj ipucu
        var state = OptimizedChargingHintState()
        func hint(_ seconds: Double, percent: Int? = 70, plugged: Bool = true, charging: Bool = false,
                  full: Bool = false, temp: Double? = 30, limit: Int? = 100) -> Bool {
            let r = OptimizedChargingHint.step(state, percentage: percent, externalConnected: plugged, isCharging: charging,
                                               fullyCharged: full, temperatureC: temp, nativeLimit: limit,
                                               now: t0.addingTimeInterval(seconds))
            state = r.state
            return r.likelyHolding
        }
        precondition(!hint(0), "ilk gözlemde ipucu yok")
        precondition(!hint(599))
        precondition(hint(600), "10 dk sürekli bekleme")
        precondition(!hint(700, charging: true), "şarj olunca biter")
        precondition(!hint(800) && !hint(800 + 599), "sayaç yeniden başlar")
        state = .init()
        precondition(!hint(0, plugged: false) && state.holdingSince == nil)
        precondition(!hint(0, percent: 99, limit: 100) && state.holdingSince == nil, "sınıra yakınsa sınır tutuyordur")
        precondition(!hint(0, percent: 70, limit: 70) && state.holdingSince == nil)
        precondition(!hint(0, temp: 40) && state.holdingSince == nil, "sıcaklık nedeni varsa ipucu yok")
        precondition(!hint(0, full: true) && state.holdingSince == nil)
        precondition(!hint(0, percent: 40) && state.holdingSince == nil)
        precondition(!hint(0, percent: nil) && !hint(0, limit: nil))
        precondition(OptimizedChargingHint.explanation(percentage: 70, nativeLimit: 100).contains("Optimize"))
        print("ReadyByPlanner/OptimizedChargingHint: all assertions passed")
    }
}
