import Foundation

/// Per-app energy history behind the "En çok enerji kullananlar" chart. Every energy sample adds
/// macOS POWER × minutes to the owning app's bucket for that day; days older than `retentionDays` are
/// dropped. The unit is macOS's own impact score over time, never watts, so the UI shows shares only.
struct EnergyLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var name: String
        var iconPath: String?
        var score: Double
    }

    enum Period: String, CaseIterable, Identifiable {
        case now, week, month
        var id: String { rawValue }
        var days: Int { self == .week ? 7 : 30 }
    }

    struct Row: Identifiable, Equatable {
        var key: String
        var name: String
        var iconPath: String?
        var score: Double
        /// 0...1 of the period total.
        var share: Double
        var id: String { key }
    }

    static let retentionDays = 35
    /// A gap longer than this (sleep, app closed) only counts this much: no sample means no evidence.
    static let maximumInterval: TimeInterval = 6 * 60

    var days: [String: [String: Entry]] = [:]
    var lastRecordedAt: Date?

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// One row per owner app (helpers folded into their `.app`), else per process name.
    static func grouped(_ apps: [EnergyApp]) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for app in apps where app.power > 0 {
            let key = app.iconPath ?? "process:" + app.name
            let name = app.iconPath.flatMap { EnergyPresentation.ownerAppName(fromExecutablePath: $0) }
                ?? EnergyPresentation.displayName(for: app.name)
            result[key, default: Entry(name: name, iconPath: app.iconPath, score: 0)].score += app.power
        }
        return result
    }

    mutating func record(_ apps: [EnergyApp], at now: Date, calendar: Calendar = .current) {
        defer { lastRecordedAt = now }
        guard let last = lastRecordedAt, now > last else { return }
        let minutes = min(now.timeIntervalSince(last), Self.maximumInterval) / 60
        let day = Self.dayKey(now, calendar: calendar)
        for (key, entry) in Self.grouped(apps) {
            days[day, default: [:]][key, default: Entry(name: entry.name, iconPath: entry.iconPath, score: 0)].score += entry.score * minutes
            days[day]?[key]?.name = entry.name
        }
        let oldest = Self.dayKey(calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) ?? now, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    func rows(for period: Period, current: [EnergyApp], now: Date, limit: Int = 8, calendar: Calendar = .current) -> [Row] {
        var totals: [String: Entry] = [:]
        if period == .now {
            totals = Self.grouped(current)
        } else {
            let first = Self.dayKey(calendar.date(byAdding: .day, value: -(period.days - 1), to: now) ?? now, calendar: calendar)
            for (day, entries) in days where day >= first {
                for (key, entry) in entries {
                    totals[key, default: Entry(name: entry.name, iconPath: entry.iconPath, score: 0)].score += entry.score
                }
            }
        }
        let sum = totals.values.reduce(0) { $0 + $1.score }
        guard sum > 0 else { return [] }
        return totals.map { Row(key: $0.key, name: $0.value.name, iconPath: $0.value.iconPath, score: $0.value.score, share: $0.value.score / sum) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }

    /// Live list with one row per owner app: the busiest process stands in, power and CPU are summed.
    static func mergedByOwner(_ apps: [EnergyApp]) -> [EnergyApp] {
        var order: [String] = [], groups: [String: [EnergyApp]] = [:]
        for app in apps {
            let key = app.iconPath ?? "pid:\(app.pid)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(app)
        }
        return order.compactMap { key -> EnergyApp? in
            guard let members = groups[key], let top = members.max(by: { $0.power < $1.power }) else { return nil }
            guard members.count > 1 else { return top }
            let name = top.iconPath.flatMap { EnergyPresentation.ownerAppName(fromExecutablePath: $0) } ?? top.name
            return EnergyApp(pid: top.pid, name: name, power: members.reduce(0) { $0 + $1.power },
                             cpu: members.reduce(0) { $0 + $1.cpu }, isApplication: members.contains(where: \.isApplication),
                             iconPath: top.iconPath)
        }.sorted { $0.power > $1.power }
    }

    /// Whole days of history held, so the chart can say how much a 30-day view really covers.
    var coveredDays: Int { days.count }
}

/// `~/Library/Application Support/Cellkeep/energy-ledger.json`, written at most once per sample.
final class EnergyLedgerStore: ObservableObject {
    static let shared = EnergyLedgerStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cellkeep").appendingPathComponent("energy-ledger.json"))

    @Published private(set) var ledger: EnergyLedger
    private let url: URL

    init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        ledger = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(EnergyLedger.self, from: $0) } ?? EnergyLedger()
    }

    func record(_ apps: [EnergyApp], at now: Date = Date()) {
        ledger.record(apps, at: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
