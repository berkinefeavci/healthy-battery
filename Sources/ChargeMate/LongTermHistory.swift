import Foundation

/// One local calendar day of battery readings, condensed. The detailed history keeps 24 hours;
/// these summaries keep months, so slow changes such as capacity loss become visible. A value is
/// only present when real readings for it exist that day — nothing is interpolated.
struct DailySummary: Codable, Equatable {
    /// Local calendar day, "yyyy-MM-dd".
    var day: String
    var samples: Int
    var minPercent: Int?
    var maxPercent: Int?
    var averagePercent: Double?
    /// Observed minutes (gaps of at most `LongTermHistory.maxGap` between readings).
    var observedMinutes: Double
    /// Observed minutes spent at or above 90%.
    var minutesAtOrAbove90: Double
    var healthPercent: Double?
    var fullCapacityMAh: Int?
    var cycleCount: Int?
    var maxTemperatureC: Double?
}

enum LongTermHistory {
    struct Sample {
        var date: Date
        var percentage: Int?
        var healthPercent: Double?
        var fullCapacityMAh: Int?
        var cycleCount: Int?
        var temperatureC: Double?
    }

    struct Stats: Equatable {
        var days: Int
        var averagePercent: Double?
        /// Share of observed time at or above 90%, 0…1.
        var shareAtOrAbove90: Double?
        var cyclesAdded: Int?
        var healthChange: Double?
        var peakTemperatureC: Double?
    }

    /// Readings further apart than this do not count as observed time (app closed, Mac asleep).
    static let maxGap: TimeInterval = 5 * 60
    static let keepDays = 400

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func summarize(_ samples: [Sample], calendar: Calendar) -> [DailySummary] {
        let sorted = samples.sorted { $0.date < $1.date }
        var byDay: [String: [(sample: Sample, weight: TimeInterval)]] = [:]
        var order: [String] = []
        for (index, sample) in sorted.enumerated() {
            let key = dayKey(sample.date, calendar: calendar)
            // Time until the next reading on the same day counts for this reading, if the gap is short.
            var weight: TimeInterval = 0
            if index + 1 < sorted.count {
                let next = sorted[index + 1].date
                let gap = next.timeIntervalSince(sample.date)
                if gap > 0, gap <= maxGap, dayKey(next, calendar: calendar) == key { weight = gap }
            }
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append((sample, weight))
        }
        return order.map { key in
            let entries = byDay[key]!
            let percents = entries.compactMap { $0.sample.percentage }.filter { (0...100).contains($0) }
            let observed = entries.reduce(0) { $0 + $1.weight }
            let high = entries.filter { ($0.sample.percentage ?? -1) >= 90 }.reduce(0) { $0 + $1.weight }
            let temperatures = entries.compactMap { $0.sample.temperatureC }.filter { $0.isFinite && (-40...120).contains($0) }
            return DailySummary(
                day: key, samples: entries.count,
                minPercent: percents.min(), maxPercent: percents.max(),
                averagePercent: percents.isEmpty ? nil : Double(percents.reduce(0, +)) / Double(percents.count),
                observedMinutes: observed / 60, minutesAtOrAbove90: high / 60,
                healthPercent: median(entries.compactMap { $0.sample.healthPercent }.filter { $0.isFinite && (0...150).contains($0) }),
                fullCapacityMAh: median(entries.compactMap { $0.sample.fullCapacityMAh }.filter { $0 > 0 }.map(Double.init)).map { Int($0.rounded()) },
                cycleCount: entries.compactMap { $0.sample.cycleCount }.filter { $0 >= 0 }.max(),
                maxTemperatureC: temperatures.max())
        }
    }

    /// Combines stored days with days recomputed from the 24-hour history. A day recomputed from a
    /// shorter window (older readings already dropped) never replaces a fuller stored summary.
    static func merge(stored: [DailySummary], fresh: [DailySummary], newestDay: String) -> [DailySummary] {
        var byDay = Dictionary(stored.map { ($0.day, $0) }, uniquingKeysWith: { first, second in first.samples >= second.samples ? first : second })
        for summary in fresh where summary.day <= newestDay {
            if let existing = byDay[summary.day], existing.samples > summary.samples { continue }
            byDay[summary.day] = summary
        }
        return Array(byDay.values.filter { $0.day <= newestDay }.sorted { $0.day < $1.day }.suffix(keepDays))
    }

    static func stats(_ summaries: [DailySummary], lastDays: Int, endingOn day: String, calendar: Calendar) -> Stats? {
        guard lastDays > 0, let end = date(of: day, calendar: calendar),
              let start = calendar.date(byAdding: .day, value: -(lastDays - 1), to: end) else { return nil }
        let startKey = dayKey(start, calendar: calendar)
        let window = summaries.filter { $0.day >= startKey && $0.day <= day }.sorted { $0.day < $1.day }
        guard !window.isEmpty else { return nil }
        let weighted = window.filter { $0.averagePercent != nil && $0.samples > 0 }
        let totalSamples = weighted.reduce(0) { $0 + $1.samples }
        let average = totalSamples == 0 ? nil
            : weighted.reduce(0.0) { $0 + $1.averagePercent! * Double($1.samples) } / Double(totalSamples)
        let observed = window.reduce(0.0) { $0 + $1.observedMinutes }
        let high = window.reduce(0.0) { $0 + $1.minutesAtOrAbove90 }
        let cycles = window.compactMap(\.cycleCount)
        let health = window.compactMap(\.healthPercent)
        return Stats(days: window.count,
                     averagePercent: average,
                     shareAtOrAbove90: observed > 0 ? high / observed : nil,
                     cyclesAdded: cycles.count >= 2 ? max(0, cycles.last! - cycles.first!) : nil,
                     healthChange: health.count >= 2 ? health.last! - health.first! : nil,
                     peakTemperatureC: window.compactMap(\.maxTemperatureC).max())
    }

    static func date(of day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Storage

    private struct Archive: Codable {
        var schemaVersion: Int
        var days: [DailySummary]
    }

    /// Reads the stored summaries. A missing file is an empty history; an unreadable one is kept
    /// aside as `<name>.corrupt-<timestamp>` so a bug never silently destroys months of data.
    static func read(_ url: URL, now: Date = Date()) -> [DailySummary] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.schemaVersion == 1 {
            return archive.days
        }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupt-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    static func write(_ days: [DailySummary], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Archive(schemaVersion: 1, days: days)).write(to: url, options: .atomic)
    }
}
