import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum ScheduleExecutionStatus: String, Codable, CaseIterable {
    case planned, dispatched, configurationVerified, running, completed, failed
    case skippedMissed, skippedConflict, unsupported, cancelled, recoveryRequired

    var isTerminal: Bool { ![.planned, .dispatched, .running].contains(self) }

    var title: String {
        switch self {
        case .planned: return String(localized: "Planlandı")
        case .dispatched: return String(localized: "Gönderildi")
        case .configurationVerified: return String(localized: "Ayar doğrulandı")
        case .running: return String(localized: "Sürüyor")
        case .completed: return String(localized: "Tamamlandı")
        case .failed: return String(localized: "Başarısız")
        case .skippedMissed: return String(localized: "Kaçırıldı")
        case .skippedConflict: return String(localized: "Çakışma nedeniyle atlandı")
        case .unsupported: return String(localized: "Desteklenmiyor")
        case .cancelled: return String(localized: "İptal edildi")
        case .recoveryRequired: return String(localized: "Kontrol gerekli")
        }
    }
}

enum ScheduleHistoryFilter: String, CaseIterable, Identifiable {
    case all, successful, error, skipped
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return String(localized: "Tümü")
        case .successful: return String(localized: "Başarılı")
        case .error: return String(localized: "Hata")
        case .skipped: return String(localized: "Atlanan")
        }
    }
    func includes(_ status: ScheduleExecutionStatus) -> Bool {
        switch self {
        case .all: return true
        case .successful: return status == .configurationVerified || status == .completed
        case .error: return [.failed, .unsupported, .cancelled, .recoveryRequired].contains(status)
        case .skipped: return status == .skippedMissed || status == .skippedConflict
        }
    }
}

struct ScheduleExecutionRecord: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id: UUID { executionID }
    let executionID: UUID
    let taskID: UUID
    let plannedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    let actionSnapshot: ScheduleAction
    let requestedValue: Int?
    var timezoneIDSnapshot: String? = nil
    var observedResult: String?
    var status: ScheduleExecutionStatus
    var failureReason: String?
    var operationID: UUID?

    var idempotencyKey: String { "\(taskID.uuidString)|\(plannedAt.timeIntervalSince1970)" }
}

struct ScheduleExecutionLoadResult {
    let records: [ScheduleExecutionRecord]
    let warning: String?
}

struct ScheduleExecutionStore {
    let url: URL

    func load() -> ScheduleExecutionLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(records: [], warning: nil) }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1,
                  let rows = object["records"] as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var valid: [ScheduleExecutionRecord] = []; var invalid = 0
            for row in rows {
                do {
                    let data = try JSONSerialization.data(withJSONObject: row)
                    let record = try decoder.decode(ScheduleExecutionRecord.self, from: data)
                    guard record.schemaVersion == 1 else { invalid += 1; continue }
                    valid.append(record)
                } catch { invalid += 1 }
            }
            if invalid > 0 { try? backup(data) }
            return .init(records: valid, warning: invalid > 0 ? String(localized: "\(invalid) bozuk çalışma kaydı atlandı; özgün dosya yedeklendi.") : nil)
        } catch {
            if let data = try? Data(contentsOf: url) { try? backup(data) }
            return .init(records: [], warning: String(localized: "Görev geçmişi okunamadı; özgün dosya yedeklendi."))
        }
    }

    func save(_ records: [ScheduleExecutionRecord], now: Date) throws {
        let retained = Self.pruned(records, now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rows = try retained.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func pruned(_ records: [ScheduleExecutionRecord], now: Date) -> [ScheduleExecutionRecord] {
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        // A just-persisted planned/dispatched row is the idempotency barrier. It
        // must never be pruned before the external dispatcher is entered.
        let protected = records.filter { $0.status == .recoveryRequired || !$0.status.isTerminal }
        let eligible = records.filter { $0.status != .recoveryRequired && $0.status.isTerminal && $0.plannedAt >= cutoff }
            .sorted { $0.plannedAt == $1.plannedAt ? $0.executionID.uuidString > $1.executionID.uuidString : $0.plannedAt > $1.plannedAt }
        let slots = max(0, 1_000 - protected.count)
        return (protected + eligible.prefix(slots)).sorted {
            $0.plannedAt == $1.plannedAt ? $0.executionID.uuidString < $1.executionID.uuidString : $0.plannedAt < $1.plannedAt
        }
    }

    private func backup(_ data: Data) throws {
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).backup")
        try data.write(to: backup, options: .atomic)
    }
}

enum ScheduleEvaluationTrigger { case startup, timer, wake, clockChange, timeZoneChange, listChange }

struct ScheduleDispatchOutcome {
    let status: ScheduleExecutionStatus
    let observedResult: String?
    let failureReason: String?
    let operationID: UUID?

    static func unsupported(_ reason: String) -> Self {
        .init(status: .unsupported, observedResult: nil, failureReason: reason, operationID: nil)
    }
}

struct ScheduleEvaluationResult {
    let tasks: [ScheduleTask]
    let records: [ScheduleExecutionRecord]
    let nextFireDate: Date?
    let warning: String?
}

final class ScheduleEngine {
    typealias Dispatcher = (ScheduleTask, Date, UUID) -> ScheduleDispatchOutcome
    private let executionStore: ScheduleExecutionStore
    private let dispatcher: Dispatcher
    private let manualOperationActive: () -> Bool

    init(executionStore: ScheduleExecutionStore,
         manualOperationActive: @escaping () -> Bool = { false },
         dispatcher: @escaping Dispatcher) {
        self.executionStore = executionStore
        self.manualOperationActive = manualOperationActive
        self.dispatcher = dispatcher
    }

    func recoverInterrupted(now: Date) -> [ScheduleExecutionRecord] {
        var records = executionStore.load().records
        var changed = false
        for index in records.indices where !records[index].status.isTerminal {
            records[index].status = .recoveryRequired
            records[index].finishedAt = now
            records[index].failureReason = String(localized: "Uygulama önceki çalışmanın sonucunu doğrulayamadı; otomatik tekrar yapılmadı.")
            changed = true
        }
        if changed { try? executionStore.save(records, now: now) }
        return records
    }

    @discardableResult
    func finishRunning(executionID: UUID, status: ScheduleExecutionStatus,
                       message: String, now: Date) -> Bool {
        var records = executionStore.load().records
        guard let index = records.firstIndex(where: { $0.executionID == executionID && $0.status == .running }) else {
            return false
        }
        records[index].status = status
        records[index].finishedAt = now
        if status == .completed { records[index].observedResult = message }
        else { records[index].failureReason = message }
        do { try executionStore.save(records, now: now); return true }
        catch { return false }
    }

    func evaluate(_ inputTasks: [ScheduleTask], now: Date, trigger: ScheduleEvaluationTrigger) -> ScheduleEvaluationResult {
        var tasks = inputTasks
        var records = executionStore.load().records
        var warning: String?
        struct Candidate { let index: Int; let plannedAt: Date }
        var candidates: [Candidate] = []

        for index in tasks.indices {
            if !tasks[index].enabled {
                if tasks[index].lastEvaluatedAt == nil || tasks[index].lastEvaluatedAt! < now { tasks[index].lastEvaluatedAt = now }
                continue
            }
            guard let previous = tasks[index].lastEvaluatedAt else {
                // First observation establishes a baseline. Time while the app was
                // closed is never silently replayed.
                tasks[index].lastEvaluatedAt = now
                continue
            }
            guard now >= previous else { continue } // Clock moved backwards.
            let activationFloor = tasks[index].activationStart ?? previous
            let lower = max(previous, activationFloor.addingTimeInterval(-0.001))
            if let latest = tasks[index].latestOccurrence(after: lower, through: now),
               !records.contains(where: { $0.taskID == tasks[index].id && $0.plannedAt == latest }) {
                let missed = latest < now && trigger != .timer
                if missed && !tasks[index].catchUpEnabled {
                    var record = makeRecord(task: tasks[index], plannedAt: latest, status: .skippedMissed)
                    record.finishedAt = now
                    record.failureReason = String(localized: "Kaçırılan çalışma için telafi kapalı.")
                    records.append(record)
                    if tasks[index].recurrence == .once { tasks[index].enabled = false }
                } else {
                    candidates.append(.init(index: index, plannedAt: latest))
                }
            }
            if tasks[index].lastEvaluatedAt == nil || tasks[index].lastEvaluatedAt! < now { tasks[index].lastEvaluatedAt = now }
        }

        candidates.sort {
            $0.plannedAt == $1.plannedAt
                ? tasks[$0.index].id.uuidString < tasks[$1.index].id.uuidString
                : $0.plannedAt < $1.plannedAt
        }
        var admittedTimes = Set<Date>()
        for candidate in candidates {
            let task = tasks[candidate.index]
            let manualBusy = manualOperationActive()
            if manualBusy || admittedTimes.contains(candidate.plannedAt) {
                var record = makeRecord(task: task, plannedAt: candidate.plannedAt, status: .skippedConflict)
                record.finishedAt = now
                record.failureReason = manualBusy
                    ? String(localized: "Elle başlatılan işlem öncelikli olduğu için görev atlandı.")
                    : String(localized: "Aynı zamandaki daha öncelikli görev çalıştırıldı.")
                records.append(record)
                if task.recurrence == .once { tasks[candidate.index].enabled = false }
                continue
            }

            let record = makeRecord(task: task, plannedAt: candidate.plannedAt, status: .planned)
            records.append(record)
            do { try executionStore.save(records, now: now) }
            catch { warning = String(localized: "Çalışma kimliği kaydedilemedi; görev gönderilmedi: \(error.localizedDescription)"); continue }
            guard let row = records.firstIndex(where: { $0.executionID == record.executionID }) else { continue }
            records[row].status = .dispatched
            records[row].startedAt = now
            do { try executionStore.save(records, now: now) }
            catch { warning = String(localized: "Dispatch kaydı doğrulanamadı; görev gönderilmedi: \(error.localizedDescription)"); continue }

            admittedTimes.insert(candidate.plannedAt)
            let outcome = dispatcher(task, candidate.plannedAt, record.executionID)
            records[row].status = outcome.status
            records[row].observedResult = outcome.observedResult
            records[row].failureReason = outcome.failureReason
            records[row].operationID = outcome.operationID
            if outcome.status.isTerminal { records[row].finishedAt = now }
            if task.recurrence == .once && outcome.status.isTerminal { tasks[candidate.index].enabled = false }
        }
        do { try executionStore.save(records, now: now) }
        catch { warning = warning ?? String(localized: "Görev sonucu kaydedilemedi: \(error.localizedDescription)") }
        return .init(tasks: tasks, records: records, nextFireDate: Self.nextFireDate(tasks: tasks, after: now), warning: warning)
    }

    static func nextFireDate(tasks: [ScheduleTask], after now: Date) -> Date? {
        tasks.filter(\.enabled).compactMap { task in
            guard let next = task.next(after: now), next >= (task.activationStart ?? .distantPast) else { return nil }
            return next
        }.min()
    }

    private func makeRecord(task: ScheduleTask, plannedAt: Date, status: ScheduleExecutionStatus) -> ScheduleExecutionRecord {
        ScheduleExecutionRecord(executionID: UUID(), taskID: task.id, plannedAt: plannedAt,
            actionSnapshot: task.action, requestedValue: task.target,
            timezoneIDSnapshot: task.timezoneID, status: status)
    }
}

extension Notification.Name {
    static let chargeMateScheduleChanged = Notification.Name("ChargeMateScheduleChanged")
    static let chargeMateScheduleRuntimeUpdated = Notification.Name("ChargeMateScheduleRuntimeUpdated")
}

#if canImport(AppKit)
/// Main-run-loop host. Production currently exposes no scheduled writer: every
/// action is recorded as unsupported until its coordinator-backed capability is
/// separately verified and explicitly enabled by the user.
final class ScheduleRuntime {
    typealias ChargeLimitDispatcher = (Int) -> ChargeControlCoordinator.Result
    typealias TopUpDispatcher = (UUID) -> ChargeControlCoordinator.Result
    typealias PowerDispatcher = (SystemPowerMode) -> Result<SystemPowerMode, SystemPowerModeService.WriteError>
    private let scheduleStore: ScheduleStore
    private let engine: ScheduleEngine
    private let capabilities: () -> ScheduleCapabilities
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(directory: URL,
         manualOperationActive: @escaping () -> Bool = { false },
         capabilities: @escaping () -> ScheduleCapabilities = { .unavailable },
         chargeLimit: @escaping ChargeLimitDispatcher = { _ in
             .init(operationID: UUID(), status: .rejected, state: nil, message: String(localized: "Şarj limiti kullanılamıyor."))
         },
         topUp: @escaping TopUpDispatcher = { _ in
             .init(operationID: UUID(), status: .rejected, state: nil, message: String(localized: "Top Up kullanılamıyor."))
         },
         powerMode: @escaping PowerDispatcher = SystemPowerModeService.applyInstalled) {
        scheduleStore = ScheduleStore(url: directory.appendingPathComponent("schedules.json"))
        let executions = ScheduleExecutionStore(url: directory.appendingPathComponent("schedule-executions.json"))
        self.capabilities = capabilities
        engine = ScheduleEngine(executionStore: executions, manualOperationActive: manualOperationActive) { task, _, executionID in
            if let reason = task.action.availability(in: capabilities()) { return .unsupported(reason) }
            switch task.action {
            case .setChargeLimit:
                guard let target = task.target else { return .unsupported(String(localized: "Şarj hedefi eksik.")) }
                return Self.outcome(chargeLimit(target), running: false)
            case .topUp:
                return Self.outcome(topUp(executionID), running: true)
            case .enableLowPower:
                return Self.outcome(powerMode(.lowPower))
            case .disableLowPower:
                return Self.outcome(powerMode(.automatic))
            case .enableHighPower:
                return Self.outcome(powerMode(.turbo))
            case .pauseCharging, .startCalibration, .dischargeTo:
                return .unsupported(task.action.availability(in: capabilities()) ?? "Desteklenmiyor.")
            }
        }
    }

    func start() {
        guard !started else { return }; started = true
        _ = engine.recoverInterrupted(now: Date())
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .chargeMateScheduleChanged, object: nil, queue: .main) { [weak self] _ in self?.evaluate(.listChange) })
        observers.append(center.addObserver(forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.evaluate(.clockChange) })
        observers.append(center.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.evaluate(.timeZoneChange) })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.evaluate(.wake) })
        observers.append(center.addObserver(forName: .chargeMatePolicyEvent, object: nil, queue: .main) { [weak self] notification in
            guard let self, let event = notification.object as? ChargePolicyEvent,
                  let executionID = event.originExecutionID else { return }
            let status: ScheduleExecutionStatus = event.kind == .topUpFinished ? .completed
                : event.kind == .topUpFailed ? .recoveryRequired : .running
            guard status != .running else { return }
            if self.engine.finishRunning(executionID: executionID, status: status,
                                         message: event.message, now: Date()) {
                NotificationCenter.default.post(name: .chargeMateScheduleRuntimeUpdated, object: nil)
            }
        })
        evaluate(.startup)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll(); started = false
    }

    private func evaluate(_ trigger: ScheduleEvaluationTrigger) {
        timer?.invalidate(); timer = nil
        let loaded = scheduleStore.load()
        let result = engine.evaluate(loaded.tasks, now: Date(), trigger: trigger)
        if result.tasks != loaded.tasks {
            try? scheduleStore.save(result.tasks)
            NotificationCenter.default.post(name: .chargeMateScheduleRuntimeUpdated, object: nil)
        }
        guard let date = result.nextFireDate else { return }
        let newTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in self?.evaluate(.timer) }
        newTimer.tolerance = 0.5
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    static func outcome(_ result: ChargeControlCoordinator.Result,
                        running: Bool) -> ScheduleDispatchOutcome {
        switch result.status {
        case .configurationVerified:
            return .init(status: running ? .running : .configurationVerified,
                         observedResult: result.message, failureReason: nil,
                         operationID: result.operationID)
        case .busy, .rejected, .cancelled:
            return .init(status: .skippedConflict, observedResult: nil,
                         failureReason: result.message, operationID: result.operationID)
        case .recoveryRequired:
            return .init(status: .recoveryRequired, observedResult: nil,
                         failureReason: result.message, operationID: result.operationID)
        case .pending, .reconciled:
            return .init(status: .failed, observedResult: nil,
                         failureReason: result.message, operationID: result.operationID)
        }
    }

    static func outcome(_ result: Result<SystemPowerMode, SystemPowerModeService.WriteError>)
        -> ScheduleDispatchOutcome {
        switch result {
        case .success(let mode):
            return .init(status: .configurationVerified, observedResult: mode.title,
                         failureReason: nil, operationID: nil)
        case .failure(let error):
            return .init(status: .failed, observedResult: nil,
                         failureReason: error.localizedDescription, operationID: nil)
        }
    }
}
#endif
