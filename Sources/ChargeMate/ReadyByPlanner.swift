import Foundation

/// "Şu saatte %100 hazır olsun": var olan Takvim altyapısını (tek seferlik Top Up görevi) kullanır;
/// yeni eylem türü eklemez. Başlangıç saati son şarj hızından ya da 2 saatlik varsayılandan hesaplanır.
struct ChargeRateSample: Equatable {
    var date: Date
    var percentage: Int
    var isCharging: Bool
}

enum ReadyByPlanner {
    static let defaultLead: TimeInterval = 2 * 3600
    static let minimumLead: TimeInterval = 3600
    static let maximumLead: TimeInterval = 5 * 3600
    /// Görev önceden kurulduğu için pilin ne kadar boşalmış olacağı bilinmez; %20'den hesaplanır.
    static let assumedStartPercent = 20.0
    /// %80 üstünde şarj yavaşlar; hıza pay bırakılır.
    static let safetyFactor = 1.25

    /// Son şarj parçalarının ortanca hızı (%/saat). Yeterli veri yoksa nil.
    static func chargeRatePercentPerHour(_ samples: [ChargeRateSample]) -> Double? {
        let sorted = samples.sorted { $0.date < $1.date }
        var rates: [Double] = []
        var run: [ChargeRateSample] = []
        func close() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            let hours = last.date.timeIntervalSince(first.date) / 3600
            let delta = last.percentage - first.percentage
            // En az 10 dakika ve %3; %90 üstü yavaşlama hızı bozmasın.
            guard hours >= 10.0 / 60, delta >= 3, first.percentage < 90 else { return }
            rates.append(Double(delta) / hours)
        }
        for sample in sorted {
            if sample.isCharging, let previous = run.last, sample.date.timeIntervalSince(previous.date) > 10 * 60 { close() }
            if sample.isCharging { run.append(sample) } else { close() }
        }
        close()
        guard !rates.isEmpty else { return nil }
        let ordered = rates.sorted()
        let middle = ordered.count / 2
        let median = ordered.count.isMultiple(of: 2) ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
        return median > 0 ? median : nil
    }

    static func leadTime(ratePercentPerHour: Double?) -> TimeInterval {
        guard let rate = ratePercentPerHour, rate.isFinite, rate > 0 else { return defaultLead }
        let hours = (100 - assumedStartPercent) / rate * safetyFactor
        return min(maximumLead, max(minimumLead, (hours * 3600).rounded()))
    }

    static func startDate(readyAt: Date, lead: TimeInterval) -> Date { readyAt.addingTimeInterval(-lead) }

    /// Kapalı başlayan, bir kez çalışan Top Up görevi. Kullanıcı düzenleyip etkinleştirir.
    static func task(readyAt: Date, lead: TimeInterval, now: Date, calendar: Calendar = .current) -> ScheduleTask {
        let start = startDate(readyAt: readyAt, lead: lead)
        let time = readyAt.formatted(date: .omitted, time: .shortened)
        var task = ScheduleTask(name: String(localized: "%100 hazır: \(time)"), action: .topUp, target: nil,
                                recurrence: .once,
                                startLocalComponents: ScheduleTask.localComponents(start, calendar: calendar),
                                timezoneID: calendar.timeZone.identifier, createdAt: now, modifiedAt: now)
        task.enabled = false
        return task
    }

    /// Verilen saat bugün henüz geçmediyse bugün, geçtiyse yarın.
    static func nextOccurrence(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var match = DateComponents(); match.hour = hour; match.minute = minute
        return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
    }
}

/// macOS Optimize Şarj'ı doğrudan okuyabilecek güvenilir, salt okunur bir kaynak yok (ayar PowerUI'nin
/// özel durumunda). Bunun yerine gözlenen davranış izlenir: adaptör takılı, pil sınırın belirgin
/// altında, şarj olmuyor ve sıcaklık nedeni yok. Bu bir ipucudur, kesin tespit değil.
struct OptimizedChargingHintState: Equatable {
    var holdingSince: Date?
}

enum OptimizedChargingHint {
    static let sustained: TimeInterval = 10 * 60

    static func step(_ state: OptimizedChargingHintState, percentage: Int?, externalConnected: Bool,
                     isCharging: Bool, fullyCharged: Bool, temperatureC: Double?, nativeLimit: Int?,
                     now: Date) -> (state: OptimizedChargingHintState, likelyHolding: Bool) {
        let holding: Bool
        if let percentage, let nativeLimit {
            holding = externalConnected && !isCharging && !fullyCharged && percentage >= 60
                && percentage < nativeLimit - 1 && (temperatureC ?? 0) <= HeatProtection.engageAbove
        } else { holding = false }
        guard holding else { return (OptimizedChargingHintState(), false) }
        let since = state.holdingSince ?? now
        return (OptimizedChargingHintState(holdingSince: since), now.timeIntervalSince(since) >= sustained)
    }

    static func explanation(percentage: Int, nativeLimit: Int) -> String {
        String(localized: "Pil %\(percentage) seviyesinde bekliyor, sınır %\(nativeLimit). macOS'un Optimize Şarj özelliği şarjı tutuyor olabilir (Sistem Ayarları › Pil › Pil Sağlığı). İki mekanizma birlikte çalışınca pil beklediğinizden geç dolar; ayarı buradan okuyamıyoruz, bu yalnızca gözleme dayalı bir ipucudur.")
    }
}
