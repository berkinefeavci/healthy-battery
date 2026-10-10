import Foundation

/// Sağlık kartı için son günlerin şarj alışkanlıkları. Ayrıntılı geçmiş yalnızca 24 saat tutulduğu
/// için burada küçük, kendi günlük kovaları (en fazla `keepDays` gün) tutulur. Saf hesaplama; dosya
/// yazma `ChargeHabitsStore`da.
struct ChargeHabitsDay: Codable, Equatable {
    var day: String
    /// Adaptör takılıyken %95 ve üstünde geçen süre (sn).
    var secondsAtOrAbove95Plugged = 0.0
    /// Şarj olurken pil sıcaklığı 35 °C üstündeyken geçen süre (sn).
    var secondsChargingAbove35 = 0.0
    /// Gözlenen toplam süre (sn).
    var observedSeconds = 0.0
}

struct DischargeEpisode: Codable, Equatable {
    var endDay: String
    /// Pilden çalışırken başlangıç yüzdesi - en düşük yüzde.
    var depth: Int
}

struct ChargeHabitsData: Codable, Equatable {
    var schemaVersion = 1
    var days: [ChargeHabitsDay] = []
    var episodes: [DischargeEpisode] = []
    var lastSampleAt: Date?
    var lastPercentage: Int?
    var lastExternal: Bool?
    var lastCharging: Bool?
    var lastTemperatureC: Double?
    var episodeStartPercentage: Int?
    var episodeMinPercentage: Int?
}

struct ChargeHabitsSample {
    var date: Date
    var percentage: Int?
    var externalConnected: Bool
    var isCharging: Bool
    var temperatureC: Double?
}

struct ChargeHabitsSummary: Equatable {
    var daysObserved: Int
    var observedHours: Double
    var hoursAtOrAbove95Plugged: Double
    var hoursChargingAbove35: Double
    var averageDischargeDepth: Double?
    var episodeCount: Int
}

enum ChargeAdvice: Equatable {
    case notEnoughData, hot, stayingFull, deepDischarges, good

    var text: String {
        switch self {
        case .notEnoughData: return String(localized: "Henüz yeterli veri yok; Healthy Battery açık kaldıkça burada öneri görünür.")
        case .hot: return String(localized: "Pil sıcakken şarj oldu. Sıcaklık korumasını açın ve şarj ederken ağır işlerden kaçının.")
        case .stayingFull: return String(localized: "Pil çoğunlukla %95 üstünde bekliyor. Şarj sınırını %80'e çekmek ömrünü uzatır.")
        case .deepDischarges: return String(localized: "Pil sık sık çok derin boşalıyor. %20'nin altına inmeden şarja takmak daha iyi.")
        case .good: return String(localized: "Şarj alışkanlıklarınız pil için iyi görünüyor.")
        }
    }
}

enum ChargeHabits {
    /// Bundan uzun aralıklar gözlenen süre sayılmaz (uygulama kapalı, Mac uykuda).
    static let maxGap: TimeInterval = 5 * 60
    static let keepDays = 30
    static let keepEpisodes = 100
    static let minimumObservedHours = 6.0

    static func record(_ sample: ChargeHabitsSample, into source: ChargeHabitsData, calendar: Calendar) -> ChargeHabitsData {
        var data = source
        let key = LongTermHistory.dayKey(sample.date, calendar: calendar)
        if let last = data.lastSampleAt {
            let gap = sample.date.timeIntervalSince(last)
            if gap > 0, gap <= maxGap {
                let lastKey = LongTermHistory.dayKey(last, calendar: calendar)
                var day = data.days.first { $0.day == lastKey } ?? ChargeHabitsDay(day: lastKey)
                day.observedSeconds += gap
                if data.lastExternal == true, (data.lastPercentage ?? -1) >= 95 { day.secondsAtOrAbove95Plugged += gap }
                if data.lastExternal == true, data.lastCharging == true,
                   (data.lastTemperatureC ?? -100) > HeatProtection.engageAbove { day.secondsChargingAbove35 += gap }
                data.days.removeAll { $0.day == lastKey }
                data.days.append(day)
            } else if gap <= 0 {
                return data
            }
        }
        // Pilden çalışma dönemi: başlangıç ve en düşük yüzde; adaptör takılınca kapanır.
        if let percentage = sample.percentage {
            if !sample.externalConnected {
                if data.episodeStartPercentage == nil { data.episodeStartPercentage = percentage }
                data.episodeMinPercentage = min(data.episodeMinPercentage ?? percentage, percentage)
            } else if let start = data.episodeStartPercentage, let low = data.episodeMinPercentage {
                if start - low >= 1 { data.episodes.append(DischargeEpisode(endDay: key, depth: start - low)) }
                data.episodeStartPercentage = nil
                data.episodeMinPercentage = nil
            }
        }
        data.lastSampleAt = sample.date
        data.lastPercentage = sample.percentage
        data.lastExternal = sample.externalConnected
        data.lastCharging = sample.isCharging
        data.lastTemperatureC = sample.temperatureC
        data.days.sort { $0.day < $1.day }
        if data.days.count > keepDays { data.days.removeFirst(data.days.count - keepDays) }
        if let oldest = data.days.first?.day { data.episodes.removeAll { $0.endDay < oldest } }
        if data.episodes.count > keepEpisodes { data.episodes.removeFirst(data.episodes.count - keepEpisodes) }
        return data
    }

    static func summary(_ data: ChargeHabitsData, lastDays: Int = 7, endingOn day: String,
                        calendar: Calendar) -> ChargeHabitsSummary {
        guard let end = LongTermHistory.date(of: day, calendar: calendar),
              let start = calendar.date(byAdding: .day, value: -(lastDays - 1), to: end) else {
            return ChargeHabitsSummary(daysObserved: 0, observedHours: 0, hoursAtOrAbove95Plugged: 0,
                                       hoursChargingAbove35: 0, averageDischargeDepth: nil, episodeCount: 0)
        }
        let startKey = LongTermHistory.dayKey(start, calendar: calendar)
        let window = data.days.filter { $0.day >= startKey && $0.day <= day }
        let episodes = data.episodes.filter { $0.endDay >= startKey && $0.endDay <= day }
        return ChargeHabitsSummary(
            daysObserved: window.filter { $0.observedSeconds > 0 }.count,
            observedHours: window.reduce(0) { $0 + $1.observedSeconds } / 3600,
            hoursAtOrAbove95Plugged: window.reduce(0) { $0 + $1.secondsAtOrAbove95Plugged } / 3600,
            hoursChargingAbove35: window.reduce(0) { $0 + $1.secondsChargingAbove35 } / 3600,
            averageDischargeDepth: episodes.isEmpty ? nil
                : Double(episodes.reduce(0) { $0 + $1.depth }) / Double(episodes.count),
            episodeCount: episodes.count)
    }

    static func advice(_ summary: ChargeHabitsSummary) -> ChargeAdvice {
        guard summary.observedHours >= minimumObservedHours else { return .notEnoughData }
        if summary.hoursChargingAbove35 >= 0.5 { return .hot }
        if summary.hoursAtOrAbove95Plugged >= 24 || summary.hoursAtOrAbove95Plugged / summary.observedHours >= 0.5 {
            return .stayingFull
        }
        if let depth = summary.averageDischargeDepth, depth >= 70 { return .deepDischarges }
        return .good
    }
}

struct ChargeHabitsStore {
    let url: URL

    func load() -> ChargeHabitsData {
        guard let data = try? Data(contentsOf: url) else { return ChargeHabitsData() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(ChargeHabitsData.self, from: data), value.schemaVersion == 1 else {
            return ChargeHabitsData()
        }
        return value
    }

    func save(_ value: ChargeHabitsData) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
