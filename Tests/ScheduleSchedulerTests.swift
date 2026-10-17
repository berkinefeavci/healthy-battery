import Foundation

@main
enum ScheduleSchedulerTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); assertions += 1
        }
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        func components(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> DateComponents {
            var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = 0; return c
        }
        func enabledTask(id: UUID = UUID(), catchUp: Bool, last: Date?) -> ScheduleTask {
            ScheduleTask(id: id, name: "Günlük", enabled: true, action: .pauseCharging, target: nil,
                recurrence: .daily, startLocalComponents: components(2026, 9, 17, 9),
                timezoneID: "Europe/Istanbul", createdAt: date("2026-09-17T05:00:00Z"),
                modifiedAt: date("2026-09-17T05:00:00Z"), activationStart: date("2026-09-17T05:00:00Z"),
                lastEvaluatedAt: last, catchUpEnabled: catchUp)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-scheduler-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = date("2026-09-20T10:00:00Z")
        let prior = date("2026-09-17T06:01:00Z")

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("missed.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in calls += 1; return .unsupported("unexpected") }
            let result = engine.evaluate([enabledTask(catchUp: false, last: prior)], now: now, trigger: .wake)
            check(calls == 0, "catch-up false dispatches nothing")
            check(result.records.count == 1 && result.records[0].status == .skippedMissed, "catch-up false records latest miss")
            check(result.records[0].plannedAt == date("2026-09-20T06:00:00Z"), "only latest missed occurrence recorded")
        }

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("catchup.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, executionID in
                calls += 1
                return .init(status: .completed, observedResult: "fake", failureReason: nil, operationID: executionID)
            }
            var result = engine.evaluate([enabledTask(catchUp: true, last: prior)], now: now, trigger: .wake)
            check(calls == 1 && result.records.count == 1 && result.records[0].status == .completed, "catch-up dispatches latest once")
            result = engine.evaluate(result.tasks, now: now, trigger: .wake)
            result = engine.evaluate(result.tasks, now: now, trigger: .wake)
            check(calls == 1 && result.records.count == 1, "three wake evaluations stay idempotent")
            check(result.records[0].operationID == result.records[0].executionID, "operation correlation is preserved")
        }

        do {
            var calls: [UUID] = []
            let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("conflict.json"))
            let engine = ScheduleEngine(executionStore: store) { task, _, _ in
                calls.append(task.id); return .init(status: .configurationVerified, observedResult: "fake readback", failureReason: nil, operationID: nil)
            }
            let justBefore = date("2026-09-20T05:59:00Z")
            let due = date("2026-09-20T06:00:00Z")
            let result = engine.evaluate([
                enabledTask(id: secondID, catchUp: true, last: justBefore),
                enabledTask(id: firstID, catchUp: true, last: justBefore)
            ], now: due, trigger: .timer)
            check(calls == [firstID], "same-time conflict follows UUID order and dispatches one")
            check(result.records.map(\.status).sorted(by: { $0.rawValue < $1.rawValue }) == [.configurationVerified, .skippedConflict].sorted(by: { $0.rawValue < $1.rawValue }), "conflict is visible")
        }

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("startup.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in calls += 1; return .unsupported("unexpected") }
            let result = engine.evaluate([enabledTask(catchUp: true, last: nil)], now: now, trigger: .startup)
            check(calls == 0 && result.records.isEmpty, "startup does not replay app-closed interval")
            check(result.tasks[0].lastEvaluatedAt == now, "startup establishes evaluation baseline")
        }

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("backward.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in calls += 1; return .unsupported("unexpected") }
            let task = enabledTask(catchUp: true, last: now)
            let result = engine.evaluate([task], now: date("2026-09-19T10:00:00Z"), trigger: .clockChange)
            check(calls == 0 && result.tasks[0].lastEvaluatedAt == now, "clock rollback neither dispatches nor rewinds checkpoint")
        }

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("manual.json"))
            let engine = ScheduleEngine(executionStore: store, manualOperationActive: { true }) { _, _, _ in
                calls += 1; return .unsupported("unexpected")
            }
            let result = engine.evaluate([enabledTask(catchUp: true, last: date("2026-09-20T05:59:00Z"))],
                                         now: date("2026-09-20T06:00:00Z"), trigger: .timer)
            check(calls == 0 && result.records.first?.status == .skippedConflict, "manual operation wins without queueing")
        }

        do {
            let url = root.appendingPathComponent("recovery.json")
            let store = ScheduleExecutionStore(url: url)
            let task = enabledTask(catchUp: true, last: prior)
            let pending = ScheduleExecutionRecord(executionID: UUID(), taskID: task.id,
                plannedAt: date("2026-09-18T06:00:00Z"), startedAt: date("2026-09-18T06:00:01Z"),
                actionSnapshot: task.action, requestedValue: nil, status: .dispatched)
            try store.save([pending], now: now)
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in fatalError("recovery must not dispatch") }
            let recovered = engine.recoverInterrupted(now: now)
            check(recovered.first?.status == .recoveryRequired && recovered.first?.finishedAt == now, "interrupted dispatch becomes recovery required")
            check(store.load().records.first?.status == .recoveryRequired, "recovery survives restart")
        }

        do {
            let recovery = ScheduleExecutionRecord(executionID: UUID(), taskID: UUID(),
                plannedAt: date("2025-01-01T00:00:00Z"), actionSnapshot: .pauseCharging,
                requestedValue: nil, status: .recoveryRequired)
            let old = ScheduleExecutionRecord(executionID: UUID(), taskID: UUID(),
                plannedAt: date("2025-01-02T00:00:00Z"), actionSnapshot: .pauseCharging,
                requestedValue: nil, status: .completed)
            let running = ScheduleExecutionRecord(executionID: UUID(), taskID: UUID(),
                plannedAt: date("2025-01-03T00:00:00Z"), actionSnapshot: .startCalibration,
                requestedValue: nil, status: .running)
            let recent = (0..<1_005).map { index in
                ScheduleExecutionRecord(executionID: UUID(), taskID: UUID(),
                    plannedAt: now.addingTimeInterval(TimeInterval(-index)), actionSnapshot: .pauseCharging,
                    requestedValue: nil, status: .completed)
            }
            let pruned = ScheduleExecutionStore.pruned([recovery, old, running] + recent, now: now)
            check(pruned.count == 1_000 && pruned.contains(recovery), "retention keeps recovery within 1000-row budget")
            check(pruned.contains(running), "retention keeps unfinished long operation")
            check(!pruned.contains(old), "records older than 90 days are removed")
        }

        do {
            let task = enabledTask(catchUp: true, last: now)
            check(ScheduleEngine.nextFireDate(tasks: [task], after: now) == date("2026-09-21T06:00:00Z"), "single timer arms nearest future occurrence")
            var disabled = task; disabled.enabled = false
            check(ScheduleEngine.nextFireDate(tasks: [disabled], after: now) == nil, "disabled tasks do not arm timer")
        }

        do {
            var calls = 0
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("disabled-window.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in calls += 1; return .unsupported("unexpected") }
            var task = enabledTask(catchUp: true, last: prior); task.enabled = false
            var result = engine.evaluate([task], now: now, trigger: .listChange)
            check(result.tasks[0].lastEvaluatedAt == now, "disabled interval advances checkpoint")
            var reenabled = result.tasks
            reenabled[0].enabled = true; reenabled[0].activationStart = now
            result = engine.evaluate(reenabled, now: now, trigger: .listChange)
            check(calls == 0 && result.records.isEmpty, "re-enable does not replay disabled interval")
        }

        do {
            var task = enabledTask(catchUp: false, last: date("2026-09-17T05:59:00Z"))
            task.recurrence = .once
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("once.json"))
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in fatalError("missed once must not dispatch") }
            let result = engine.evaluate([task], now: now, trigger: .wake)
            check(!result.tasks[0].enabled && result.records.first?.status == .skippedMissed, "terminal once result disables task")
        }

        do {
            let blocker = root.appendingPathComponent("blocker")
            FileManager.default.createFile(atPath: blocker.path, contents: Data())
            var calls = 0
            let engine = ScheduleEngine(executionStore: .init(url: blocker.appendingPathComponent("records.json"))) { _, _, _ in
                calls += 1; return .unsupported("unexpected")
            }
            let result = engine.evaluate([enabledTask(catchUp: true, last: date("2026-09-20T05:59:00Z"))],
                                         now: date("2026-09-20T06:00:00Z"), trigger: .timer)
            check(calls == 0 && result.warning != nil, "dispatch is blocked when idempotency journal cannot be written")
        }

        do {
            check(ScheduleHistoryFilter.successful.includes(.completed) && ScheduleHistoryFilter.successful.includes(.configurationVerified), "success filter is explicit")
            check(ScheduleHistoryFilter.error.includes(.failed) && ScheduleHistoryFilter.error.includes(.unsupported) && !ScheduleHistoryFilter.error.includes(.skippedMissed), "error and skip filters stay distinct")
            check(ScheduleHistoryFilter.skipped.includes(.skippedMissed) && ScheduleHistoryFilter.skipped.includes(.skippedConflict), "skip filter includes both skip reasons")
        }

        do {
            // Retry: a real new run through the dispatcher, never a rewrite of the old record.
            let url = root.appendingPathComponent("retry.json")
            let store = ScheduleExecutionStore(url: url)
            let original = ScheduleExecutionRecord(executionID: UUID(), taskID: UUID(),
                plannedAt: date("2026-09-20T06:00:00Z"), startedAt: date("2026-09-20T06:00:01Z"),
                finishedAt: date("2026-09-20T06:00:02Z"), actionSnapshot: .setChargeLimit,
                requestedValue: 85, timezoneIDSnapshot: "Europe/Istanbul", observedResult: nil,
                status: .failed, failureReason: "fake failure", operationID: nil)
            try store.save([original], now: now)
            var task = enabledTask(id: original.taskID, catchUp: true, last: prior)
            task.action = .topUp; task.target = nil // edited since: the retry still repeats the original run
            var dispatched: [(ScheduleAction, Int?)] = []
            var persistedBeforeDispatch: [ScheduleExecutionStatus] = []
            let engine = ScheduleEngine(executionStore: store) { retried, _, executionID in
                dispatched.append((retried.action, retried.target))
                persistedBeforeDispatch = store.load().records.filter { $0.executionID == executionID }.map(\.status)
                return .init(status: .configurationVerified, observedResult: "fake readback", failureReason: nil, operationID: executionID)
            }
            let retry = engine.retry(of: original, task: task, now: now)
            let loaded = store.load().records
            check(dispatched.count == 1 && dispatched[0].0 == .setChargeLimit && dispatched[0].1 == 85, "retry repeats the original action and value")
            check(persistedBeforeDispatch == [.dispatched], "retry persists its idempotency row before the dispatcher runs")
            check(retry?.status == .configurationVerified && retry?.observedResult == "fake readback", "retry reports the real outcome")
            check(retry?.executionID != original.executionID && loaded.count == 2, "retry creates a new execution identity")
            check(loaded.first(where: { $0.executionID == original.executionID })?.status == .failed, "retry never rewrites old failure")
            check(retry?.actionSnapshot == .setChargeLimit && retry?.requestedValue == 85 && retry?.timezoneIDSnapshot == "Europe/Istanbul", "retry preserves immutable snapshots")
            check(retry?.finishedAt == now && retry?.status != .unsupported, "retry is no longer a placeholder row")

            // A manual operation has priority: nothing is dispatched.
            var busyCalls = 0
            let busyEngine = ScheduleEngine(executionStore: store, manualOperationActive: { true }) { _, _, _ in
                busyCalls += 1; return .unsupported("unexpected")
            }
            let blocked = busyEngine.retry(of: original, task: task, now: now.addingTimeInterval(60))
            check(busyCalls == 0 && blocked?.status == .skippedConflict && blocked?.failureReason != nil, "retry yields to a manual operation")

            // A failing writer is recorded as failed, not completed.
            let failing = ScheduleEngine(executionStore: store) { _, _, _ in
                .init(status: .failed, observedResult: nil, failureReason: "fake write failure", operationID: nil)
            }
            let failed = failing.retry(of: original, task: task, now: now.addingTimeInterval(120))
            check(failed?.status == .failed && failed?.failureReason == "fake write failure", "retry surfaces the writer failure")

            // An unwritable store cannot dispatch (the barrier row could not be saved).
            let blockedStore = ScheduleExecutionStore(url: URL(fileURLWithPath: "/dev/null/executions.json"))
            var neverCalled = 0
            let barrier = ScheduleEngine(executionStore: blockedStore) { _, _, _ in neverCalled += 1; return .unsupported("x") }
            check(barrier.retry(of: original, task: task, now: now) == nil && neverCalled == 0, "nothing runs when the idempotency row cannot be saved")

            let scheduleStore = ScheduleStore(url: root.appendingPathComponent("delete-history-schedules.json"))
            try scheduleStore.save([task]); try scheduleStore.save([])
            check(store.load().records.count == 4, "deleting task does not delete execution history")
        }

        do {
            let store = ScheduleExecutionStore(url: root.appendingPathComponent("failed-result.json"))
            var task = enabledTask(catchUp: true, last: date("2026-09-20T05:59:00Z"))
            task.action = .setChargeLimit; task.target = 85
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in
                .init(status: .failed, observedResult: nil, failureReason: "fake write failure", operationID: UUID())
            }
            let result = engine.evaluate([task], now: date("2026-09-20T06:00:00Z"), trigger: .timer)
            task.action = .topUp; task.target = nil
            check(result.records.first?.status == .failed && result.records.first?.status != .completed, "failed write never becomes completed")
            check(result.records.first?.actionSnapshot == .setChargeLimit && result.records.first?.requestedValue == 85, "task edit cannot mutate history snapshot")
        }

        do {
            let operationID = UUID()
            let verified = ChargeControlCoordinator.Result(operationID: operationID,
                status: .configurationVerified, state: nil, message: "verified")
            check(ScheduleRuntime.outcome(verified, running: false).status == .configurationVerified,
                  "verified scheduled limit maps to configuration verified")
            let running = ScheduleRuntime.outcome(verified, running: true)
            check(running.status == .running && running.operationID == operationID,
                  "verified Top Up keeps execution running with operation correlation")
            let recovery = ChargeControlCoordinator.Result(operationID: operationID,
                status: .recoveryRequired, state: nil, message: "ambiguous")
            check(ScheduleRuntime.outcome(recovery, running: false).status == .recoveryRequired,
                  "ambiguous scheduled write maps to recovery")
            check(ScheduleRuntime.outcome(Result<SystemPowerMode, SystemPowerModeService.WriteError>.failure(.helperMissing)).status == .failed,
                  "missing installed helper fails without installer path")
        }

        do {
            let url = root.appendingPathComponent("topup-terminal.json")
            let store = ScheduleExecutionStore(url: url)
            let executionID = UUID()
            let running = ScheduleExecutionRecord(executionID: executionID, taskID: UUID(), plannedAt: now,
                startedAt: now, actionSnapshot: .topUp, requestedValue: nil,
                status: .running, operationID: UUID())
            try store.save([running], now: now)
            let engine = ScheduleEngine(executionStore: store) { _, _, _ in fatalError("terminal update must not dispatch") }
            check(engine.finishRunning(executionID: executionID, status: .completed,
                                       message: "restored", now: now.addingTimeInterval(60)),
                  "terminal Top Up event closes matching running record")
            check(store.load().records.first?.status == .completed,
                  "terminal Top Up completion survives restart")
            check(!engine.finishRunning(executionID: executionID, status: .completed,
                                        message: "duplicate", now: now.addingTimeInterval(61)),
                  "duplicate terminal event is idempotent")
        }

        print("Schedule scheduler: \(assertions) assertions passed; fake clock/dispatcher and isolated stores only.")
    }
}
