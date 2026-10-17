import Foundation

struct ScheduleCapabilities: Equatable {
    let chargeLimits: [Int]
    let topUpAvailable: Bool
    let powerModes: Set<SystemPowerMode>
    /// The verified adapter cut (charge helper + passed adapter test): discharge and calibration can run.
    var adapterCut = false

    static let unavailable = Self(chargeLimits: [], topUpAvailable: false, powerModes: [])
}

enum ScheduleAction: String, Codable, CaseIterable, Identifiable {
    case topUp, pauseCharging, startCalibration, setChargeLimit, dischargeTo
    case enableLowPower, disableLowPower, enableHighPower
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topUp: return String(localized: "Tam doldur")
        case .pauseCharging: return String(localized: "Şarjı duraklat")
        case .startCalibration: return String(localized: "Kalibrasyon başlat")
        case .setChargeLimit: return String(localized: "Şarj limitini ayarla")
        case .dischargeTo: return String(localized: "Hedefe kadar boşalt")
        case .enableLowPower: return String(localized: "Düşük Güç Modunu aç")
        case .disableLowPower: return String(localized: "Otomatik güç moduna dön")
        case .enableHighPower: return String(localized: "Yüksek Güç Modunu aç")
        }
    }
    var needsTarget: Bool { self == .setChargeLimit || self == .dischargeTo }
    /// True for the actions a task can really run. Pausing charging needs a charge-stop key that macOS 27
    /// locks, so no Mac can; a task saved with it still loads and is shown as unsupported. Discharge and
    /// calibration run through the adapter cut where it is verified (`availability` says when it is not).
    var isRunnable: Bool { self != .pauseCharging }
    /// The actions the editor offers: every runnable one, plus `keeping` so an old task can still be edited.
    static func offered(keeping current: ScheduleAction? = nil) -> [ScheduleAction] {
        allCases.filter { $0.isRunnable || $0 == current }
    }
    func availability(in capabilities: ScheduleCapabilities) -> String? {
        switch self {
        case .topUp:
            return capabilities.topUpAvailable && capabilities.chargeLimits.contains(100)
                ? nil : String(localized: "Top Up için doğrulanmış %100 şarj limiti desteği gerekiyor.")
        case .setChargeLimit:
            return capabilities.chargeLimits.isEmpty ? String(localized: "Bu Mac’te doğrulanmış şarj limiti desteği yok.") : nil
        case .enableLowPower:
            return capabilities.powerModes.contains(.lowPower) ? nil : String(localized: "Bu Mac Düşük Güç Modunu sunmuyor.")
        case .disableLowPower:
            return capabilities.powerModes.contains(.automatic) ? nil : String(localized: "Otomatik güç modu kullanılamıyor.")
        case .enableHighPower:
            return capabilities.powerModes.contains(.turbo) ? nil : String(localized: "Bu Mac Yüksek Güç Modunu sunmuyor.")
        case .startCalibration, .dischargeTo:
            return capabilities.adapterCut ? nil
                : String(localized: "Şarj yardımcısı kurulu olmalı ve adaptör testi geçmiş olmalı (Ayarlar → Şarj Kontrolü).")
        case .pauseCharging:
            return String(localized: "Bu donanım eyleminin fiziksel etkisi henüz doğrulanmadı.")
        }
    }
    var unavailableReason: String { availability(in: .unavailable) ?? "" }
}

enum ScheduleRecurrence: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekdays, weekly, biweekly, monthly, yearly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: return String(localized: "Bir kez")
        case .daily: return String(localized: "Her gün")
        case .weekdays: return String(localized: "Hafta içi")
        case .weekly: return String(localized: "Her hafta")
        case .biweekly: return String(localized: "İki haftada bir")
        case .monthly: return String(localized: "Her ay")
        case .yearly: return String(localized: "Her yıl")
        }
    }
}

struct ScheduleTask: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var enabled = false
    var action: ScheduleAction
    var target: Int?
    var recurrence: ScheduleRecurrence
    var startLocalComponents: DateComponents
    var timezoneID: String
    var createdAt: Date
    var modifiedAt: Date
    var activationStart: Date?
    var lastEvaluatedAt: Date?
    var catchUpEnabled = false

    static func new(now: Date, calendar: Calendar = .current) -> Self {
        let nextHour = calendar.date(bySetting: .minute, value: 0,
            of: calendar.date(byAdding: .hour, value: 1, to: now)!)!
        return Self(name: String(localized: "Yeni görev"), action: .topUp, target: nil, recurrence: .daily,
                    startLocalComponents: localComponents(nextHour, calendar: calendar),
                    timezoneID: calendar.timeZone.identifier, createdAt: now, modifiedAt: now)
    }

    static func localComponents(_ date: Date, calendar: Calendar) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    func duplicated(now: Date) -> Self {
        var copy = self
        copy.id = UUID()
        let suffix = String(localized: " kopyası")
        copy.name = String(name.prefix(max(1, 80 - suffix.count))) + suffix
        copy.enabled = false
        copy.createdAt = now
        copy.modifiedAt = now
        copy.activationStart = nil
        copy.lastEvaluatedAt = nil
        return copy
    }

    func validationError(capabilities: ScheduleCapabilities) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count) else { return String(localized: "Görev adı 1–80 karakter olmalı.") }
        guard TimeZone(identifier: timezoneID) != nil else { return String(localized: "Geçerli bir saat dilimi seçin.") }
        guard startLocalComponents.year != nil, startLocalComponents.month != nil,
              startLocalComponents.day != nil, startLocalComponents.hour != nil,
              startLocalComponents.minute != nil else { return String(localized: "Başlangıç tarihi eksik.") }
        if action.needsTarget {
            guard let target, (20...100).contains(target) else { return String(localized: "Hedef %20–100 arasında olmalı.") }
            if action == .setChargeLimit, !capabilities.chargeLimits.contains(target) {
                return String(localized: "Bu Mac’in sunduğu limitlerden birini seçin.")
            }
        } else if target != nil { return String(localized: "Bu eylem hedef yüzdesi kullanmaz.") }
        if enabled { return action.availability(in: capabilities) }
        return nil
    }

    func validationError(supportedLimits: [Int] = []) -> String? {
        validationError(capabilities: .init(chargeLimits: supportedLimits,
                                            topUpAvailable: supportedLimits.contains(100),
                                            powerModes: []))
    }

    func next(after instant: Date) -> Date? {
        guard let zone = TimeZone(identifier: timezoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let start = calendar.date(from: startLocalComponents) else { return nil }
        if recurrence == .once { return start > instant ? start : nil }
        let startDay = calendar.startOfDay(for: start)
        let afterDay = calendar.startOfDay(for: instant)
        let firstOffset = max(0, calendar.dateComponents([.day], from: startDay, to: afterDay).day ?? 0)
        let hour = startLocalComponents.hour ?? 0
        let minute = startLocalComponents.minute ?? 0
        for offset in firstOffset...(firstOffset + 3662) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay), matches(day, startDay: startDay, calendar: calendar) else { continue }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
            var match = DateComponents(); match.hour = hour; match.minute = minute
            guard let candidate = calendar.nextDate(after: day.addingTimeInterval(-1), matching: match,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward), candidate < dayEnd else { continue }
            if candidate >= start && candidate > instant { return candidate }
        }
        return nil
    }

    /// Returns only the latest occurrence in a closed evaluation window. This
    /// prevents a wake after several days from building an action backlog.
    func latestOccurrence(after lowerBound: Date, through upperBound: Date) -> Date? {
        guard upperBound > lowerBound else { return nil }
        var cursor = lowerBound
        var latest: Date?
        // Ten years of daily occurrences is a defensive bound for damaged data.
        for _ in 0..<3_662 {
            guard let candidate = next(after: cursor), candidate <= upperBound else { break }
            latest = candidate
            cursor = candidate
        }
        return latest
    }

    private func matches(_ day: Date, startDay: Date, calendar: Calendar) -> Bool {
        let days = calendar.dateComponents([.day], from: startDay, to: day).day ?? 0
        switch recurrence {
        case .once: return days == 0
        case .daily: return true
        case .weekdays: return (2...6).contains(calendar.component(.weekday, from: day))
        case .weekly: return days >= 0 && days % 7 == 0
        case .biweekly: return days >= 0 && days % 14 == 0
        case .monthly:
            return calendar.component(.day, from: day) == startLocalComponents.day
        case .yearly:
            return calendar.component(.month, from: day) == startLocalComponents.month &&
                   calendar.component(.day, from: day) == startLocalComponents.day
        }
    }
}

struct ScheduleLoadResult {
    let tasks: [ScheduleTask]
    let warning: String?
}

struct ScheduleStore {
    let url: URL

    func load() -> ScheduleLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return ScheduleLoadResult(tasks: [], warning: nil) }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1,
                  let rawTasks = object["tasks"] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
            var tasks: [ScheduleTask] = []
            var invalid = 0
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for raw in rawTasks {
                do {
                    let item = try JSONSerialization.data(withJSONObject: raw)
                    let task = try decoder.decode(ScheduleTask.self, from: item)
                    guard task.schemaVersion == 1 else { invalid += 1; continue }
                    tasks.append(task)
                } catch { invalid += 1 }
            }
            if invalid > 0 { try? backup(data) }
            return ScheduleLoadResult(tasks: tasks, warning: invalid > 0 ? String(localized: "\(invalid) bozuk görev atlandı; özgün dosya yedeklendi.") : nil)
        } catch {
            if let data = try? Data(contentsOf: url) { try? backup(data) }
            return ScheduleLoadResult(tasks: [], warning: String(localized: "Program dosyası okunamadı; özgün dosya yedeklendi."))
        }
    }

    func save(_ tasks: [ScheduleTask]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let raw = try tasks.map { task -> Any in
            try JSONSerialization.jsonObject(with: encoder.encode(task))
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "tasks": raw], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func backup(_ data: Data) throws {
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).backup")
        try data.write(to: backup, options: .atomic)
    }
}

enum ScheduleTemplate: String, CaseIterable, Identifiable {
    case mondayTopUp, weekendFull
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mondayTopUp: return String(localized: "Pazartesi tam dolum")
        case .weekendFull: return String(localized: "Hafta sonu tam dolum")
        }
    }
    func task(now: Date, calendar: Calendar = .current) -> ScheduleTask {
        let weekday: Int, hour: Int
        switch self {
        case .mondayTopUp: weekday = 2; hour = 7
        case .weekendFull: weekday = 6; hour = 18
        }
        var match = DateComponents(); match.weekday = weekday; match.hour = hour; match.minute = 0
        let start = calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime, repeatedTimePolicy: .first)!
        return ScheduleTask(name: title, action: .topUp, target: nil, recurrence: .weekly,
            startLocalComponents: ScheduleTask.localComponents(start, calendar: calendar),
            timezoneID: calendar.timeZone.identifier, createdAt: now, modifiedAt: now)
    }
}
