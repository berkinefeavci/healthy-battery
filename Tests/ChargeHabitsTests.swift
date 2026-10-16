import Foundation

@main
enum ChargeHabitsTests {
    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    static let start = Date(timeIntervalSince1970: 1_699_948_800) // 2023-11-14 08:00:00 UTC

    static func feed(_ data: ChargeHabitsData, from: Date, seconds: Int, step: Int = 60, percent: Int?,
                     plugged: Bool, charging: Bool = false, temp: Double? = 30) -> ChargeHabitsData {
        var data = data
        var t = 0
        while t <= seconds {
            data = ChargeHabits.record(.init(date: from.addingTimeInterval(Double(t)), percentage: percent,
                                             externalConnected: plugged, isCharging: charging, temperatureC: temp),
                                       into: data, calendar: calendar)
            t += step
        }
        return data
    }

    static func main() {
        let key = LongTermHistory.dayKey(start, calendar: calendar)
        // 2 saat takılı %100: 2 saat %95+ ve gözlenen
        var d = feed(ChargeHabitsData(), from: start, seconds: 7200, percent: 100, plugged: true)
        var s = ChargeHabits.summary(d, endingOn: key, calendar: calendar)
        precondition(abs(s.hoursAtOrAbove95Plugged - 2) < 0.001 && abs(s.observedHours - 2) < 0.001, "\(s)")
        precondition(s.hoursChargingAbove35 == 0 && s.averageDischargeDepth == nil && s.daysObserved == 1)

        // 94% takılı: sayılmaz; pilden %100 de sayılmaz
        d = feed(ChargeHabitsData(), from: start, seconds: 3600, percent: 94, plugged: true)
        precondition(ChargeHabits.summary(d, endingOn: key, calendar: calendar).hoursAtOrAbove95Plugged == 0)
        d = feed(ChargeHabitsData(), from: start, seconds: 3600, percent: 100, plugged: false)
        precondition(ChargeHabits.summary(d, endingOn: key, calendar: calendar).hoursAtOrAbove95Plugged == 0)

        // Sıcakta şarj: yalnızca şarj olurken ve >35
        d = feed(ChargeHabitsData(), from: start, seconds: 1800, percent: 50, plugged: true, charging: true, temp: 37)
        s = ChargeHabits.summary(d, endingOn: key, calendar: calendar)
        precondition(abs(s.hoursChargingAbove35 - 0.5) < 0.001)
        d = feed(ChargeHabitsData(), from: start, seconds: 1800, percent: 50, plugged: true, charging: false, temp: 37)
        precondition(ChargeHabits.summary(d, endingOn: key, calendar: calendar).hoursChargingAbove35 == 0)
        d = feed(ChargeHabitsData(), from: start, seconds: 1800, percent: 50, plugged: true, charging: true, temp: 35)
        precondition(ChargeHabits.summary(d, endingOn: key, calendar: calendar).hoursChargingAbove35 == 0)

        // Uzun boşluk (uyku) gözlenen süre sayılmaz
        d = feed(ChargeHabitsData(), from: start, seconds: 60, percent: 100, plugged: true)
        d = feed(d, from: start.addingTimeInterval(3 * 3600), seconds: 60, percent: 100, plugged: true)
        s = ChargeHabits.summary(d, endingOn: key, calendar: calendar)
        precondition(abs(s.observedHours - 2.0 / 60) < 0.001, "\(s.observedHours)")
        // Aynı/geri zamanlı örnek yok sayılır
        let before = d
        d = ChargeHabits.record(.init(date: start, percentage: 100, externalConnected: true, isCharging: false, temperatureC: 30),
                                into: d, calendar: calendar)
        precondition(d == before)

        // Boşalma derinliği: 90 → 60 pilden, sonra takılınca bölüm kapanır; ikinci 80 → 70
        d = ChargeHabitsData()
        var t = start
        for p in [90, 80, 60, 70] {
            d = feed(d, from: t, seconds: 0, percent: p, plugged: false); t = t.addingTimeInterval(60)
        }
        d = feed(d, from: t, seconds: 0, percent: 70, plugged: true); t = t.addingTimeInterval(60)
        for p in [80, 75, 70] { d = feed(d, from: t, seconds: 0, percent: p, plugged: false); t = t.addingTimeInterval(60) }
        d = feed(d, from: t, seconds: 0, percent: 70, plugged: true)
        s = ChargeHabits.summary(d, endingOn: key, calendar: calendar)
        precondition(s.episodeCount == 2 && s.averageDischargeDepth == 20, "\(s)") // (30 + 10) / 2
        // %1'den az düşüş kayıt edilmez
        d = feed(ChargeHabitsData(), from: start, seconds: 120, percent: 80, plugged: false)
        d = feed(d, from: start.addingTimeInterval(300), seconds: 0, percent: 80, plugged: true)
        precondition(ChargeHabits.summary(d, endingOn: key, calendar: calendar).episodeCount == 0)

        // 7 günlük pencere: 8 gün önceki veri dışarıda
        var old = ChargeHabitsData()
        old.days = [ChargeHabitsDay(day: "2023-11-01", secondsAtOrAbove95Plugged: 36000, secondsChargingAbove35: 7200, observedSeconds: 40000),
                    ChargeHabitsDay(day: "2023-11-10", secondsAtOrAbove95Plugged: 3600, secondsChargingAbove35: 0, observedSeconds: 7200)]
        old.episodes = [DischargeEpisode(endDay: "2023-11-01", depth: 90), DischargeEpisode(endDay: "2023-11-12", depth: 40)]
        s = ChargeHabits.summary(old, endingOn: "2023-11-14", calendar: calendar)
        precondition(s.hoursAtOrAbove95Plugged == 1 && s.observedHours == 2 && s.averageDischargeDepth == 40 && s.daysObserved == 1)
        precondition(ChargeHabits.summary(old, endingOn: "2023-11-14", calendar: calendar).episodeCount == 1)

        // Budama: 30 günden eski kovalar ve bölümler silinir
        var big = ChargeHabitsData()
        for i in 0..<40 {
            let date = start.addingTimeInterval(Double(i) * 86400)
            big = feed(big, from: date, seconds: 60, percent: 80, plugged: true)
        }
        precondition(big.days.count == ChargeHabits.keepDays)

        // Öneri öncelik sırası
        func summary(hours: Double, at95: Double = 0, hot: Double = 0, depth: Double? = nil) -> ChargeHabitsSummary {
            .init(daysObserved: 5, observedHours: hours, hoursAtOrAbove95Plugged: at95, hoursChargingAbove35: hot,
                  averageDischargeDepth: depth, episodeCount: depth == nil ? 0 : 3)
        }
        precondition(ChargeHabits.advice(summary(hours: 2, hot: 5)) == .notEnoughData)
        precondition(ChargeHabits.advice(summary(hours: 50, at95: 40, hot: 1)) == .hot)
        precondition(ChargeHabits.advice(summary(hours: 100, at95: 24)) == .stayingFull)
        precondition(ChargeHabits.advice(summary(hours: 20, at95: 10)) == .stayingFull, "yarıdan fazlası dolu")
        precondition(ChargeHabits.advice(summary(hours: 100, at95: 5, depth: 75)) == .deepDischarges)
        precondition(ChargeHabits.advice(summary(hours: 100, at95: 5, depth: 40)) == .good)
        precondition(ChargeHabits.advice(summary(hours: 100, at95: 5)) == .good)
        precondition(!ChargeAdvice.good.text.isEmpty && ChargeAdvice.stayingFull.text.contains("%80"))

        // Depolama gidiş-dönüş ve bozuk dosya
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("habits-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChargeHabitsStore(url: directory.appendingPathComponent("charge-habits.json"))
        precondition(store.load() == ChargeHabitsData())
        let filled = feed(ChargeHabitsData(), from: start, seconds: 600, percent: 99, plugged: true)
        try! store.save(filled)
        precondition(store.load() == filled)
        try! Data("{bozuk".utf8).write(to: store.url)
        precondition(store.load() == ChargeHabitsData())
        print("ChargeHabits: all assertions passed")
    }
}
