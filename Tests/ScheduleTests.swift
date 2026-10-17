import Foundation

@main
enum ScheduleTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); assertions += 1
        }
        let iso = ISO8601DateFormatter()
        func date(_ value: String) -> Date { iso.date(from: value)! }
        func task(_ recurrence: ScheduleRecurrence, zone: String, start: DateComponents) -> ScheduleTask {
            ScheduleTask(name: "Test", action: .pauseCharging, target: nil, recurrence: recurrence,
                         startLocalComponents: start, timezoneID: zone, createdAt: .distantPast, modifiedAt: .distantPast)
        }
        func components(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> DateComponents {
            var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute; return c
        }

        check(ScheduleAction.allCases.count == 8 && ScheduleRecurrence.allCases.count == 7, "eight actions and seven recurrences")
        let daily = task(.daily, zone: "Europe/Istanbul", start: components(2026, 9, 1, 9))
        check(daily.next(after: date("2026-09-14T05:59:59Z")) == date("2026-09-14T06:00:00Z"), "Istanbul daily")
        let weekdays = task(.weekdays, zone: "Europe/Istanbul", start: components(2026, 9, 18, 9))
        check(weekdays.next(after: date("2026-09-18T06:00:00Z")) == date("2026-09-21T06:00:00Z"), "weekdays skip weekend")
        let weekly = task(.weekly, zone: "Europe/Istanbul", start: components(2026, 9, 14, 9))
        check(weekly.next(after: date("2026-09-14T06:00:00Z")) == date("2026-09-21T06:00:00Z"), "weekly anchor")
        let biweekly = task(.biweekly, zone: "Europe/Istanbul", start: components(2026, 9, 14, 9))
        check(biweekly.next(after: date("2026-09-14T06:00:00Z")) == date("2026-09-28T06:00:00Z"), "biweekly anchor")
        let monthly = task(.monthly, zone: "Europe/Istanbul", start: components(2026, 1, 31, 9))
        check(monthly.next(after: date("2026-01-31T06:00:00Z")) == date("2026-03-31T06:00:00Z"), "monthly skips missing day")
        let yearly = task(.yearly, zone: "Europe/Istanbul", start: components(2024, 2, 29, 9))
        check(yearly.next(after: date("2024-02-29T06:00:00Z")) == date("2028-02-29T06:00:00Z"), "yearly leap day")
        let dstGap = task(.daily, zone: "America/New_York", start: components(2026, 3, 1, 2, 30))
        check(dstGap.next(after: date("2026-03-08T06:59:59Z")) == date("2026-03-08T07:00:00Z"), "DST gap advances to next valid time")
        let repeated = task(.daily, zone: "America/New_York", start: components(2026, 10, 25, 1, 30))
        check(repeated.next(after: date("2026-11-01T04:00:00Z")) == date("2026-11-01T05:30:00Z"), "DST repeated hour uses first occurrence")
        check(repeated.next(after: date("2026-11-01T05:30:00Z")) == date("2026-11-02T06:30:00Z"), "DST second occurrence is not repeated")

        let now = date("2026-09-20T10:00:00Z")
        let fresh = ScheduleTask.new(now: now)
        check(!fresh.enabled && fresh.action == .topUp && fresh.action.isImplemented && fresh.recurrence == .daily, "new task safe defaults")
        var enabledOriginal = fresh; enabledOriginal.enabled = true; enabledOriginal.activationStart = .distantPast; enabledOriginal.lastEvaluatedAt = .distantPast
        let copy = enabledOriginal.duplicated(now: now)
        check(copy.id != enabledOriginal.id && !copy.enabled && copy.name.hasSuffix(" kopyası"), "duplicate has safe identity and name")
        check(copy.createdAt == now && copy.activationStart == nil && copy.lastEvaluatedAt == nil, "duplicate resets runtime state")
        for template in ScheduleTemplate.allCases {
            check(!template.task(now: now).enabled, "template disabled")
            check(template.task(now: now).action.isImplemented, "template uses an action this app can run")
        }
        var target = fresh; target.action = .setChargeLimit; target.target = 85
        let capabilities = ScheduleCapabilities(chargeLimits: [80, 85, 90, 95, 100], topUpAvailable: true,
                                                powerModes: [.automatic, .lowPower, .turbo], adapterCut: true)
        check(target.validationError(capabilities: capabilities) == nil, "supported target validates")
        target.target = 83
        check(target.validationError(capabilities: capabilities) != nil, "unsupported target rejected")
        target.action = .topUp; target.target = 80
        check(target.validationError() != nil, "target forbidden for parameterless action")
        target.target = nil; target.enabled = true
        check(target.validationError(capabilities: capabilities) == nil, "Top Up enables when 100 capability exists")
        check(ScheduleAction.enableLowPower.availability(in: capabilities) == nil, "low power capability enables action")
        check(ScheduleAction.enableHighPower.availability(in: capabilities) == nil, "high power capability enables action")
        let limited = ScheduleCapabilities(chargeLimits: [80, 85], topUpAvailable: false, powerModes: [.automatic])
        check(ScheduleAction.topUp.availability(in: limited) != nil, "Top Up needs 100 capability")
        check(ScheduleAction.enableLowPower.availability(in: limited) != nil, "low power needs capability")
        check(ScheduleAction.enableHighPower.availability(in: limited) != nil, "high power needs capability")
        check(ScheduleAction.pauseCharging.availability(in: capabilities) != nil, "pause charging stays unavailable")
        for action in [ScheduleAction.startCalibration, .dischargeTo] {
            check(action.availability(in: capabilities) == nil, "adapter cut enables \(action.rawValue)")
            check(action.availability(in: limited) != nil, "\(action.rawValue) needs the verified adapter cut")
        }
        var discharge = fresh; discharge.action = .dischargeTo; discharge.target = 50
        check(discharge.validationError(capabilities: capabilities) == nil, "discharge target 50 validates")
        discharge.target = nil
        check(discharge.validationError(capabilities: capabilities) != nil, "discharge needs a target")
        for action in ScheduleAction.allCases {
            check(action.isImplemented == (action.availability(in: capabilities) == nil), "isImplemented matches availability with full capabilities")
        }
        check(ScheduleAction.offered(keeping: .topUp) == ScheduleAction.allCases.filter(\.isImplemented), "picker hides actions that cannot run")
        check(ScheduleAction.offered(keeping: .pauseCharging).contains(.pauseCharging), "picker keeps the action of an existing task")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-schedule-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduleStore(url: root.appendingPathComponent("schedules.json"))
        try store.save([fresh, target])
        let loaded = store.load()
        check(loaded.warning == nil && loaded.tasks == [fresh, target], "store round trip")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        var rows = raw["tasks"] as! [Any]; rows.append(["schemaVersion": 999, "name": "broken"])
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "tasks": rows]).write(to: store.url)
        let repaired = store.load()
        check(repaired.tasks.count == 2 && repaired.warning != nil, "valid tasks survive corrupt row")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        check(files.contains { $0.lastPathComponent.contains("corrupt") }, "corrupt source backed up")

        print("Schedule: \(assertions) assertions passed; fake clock and isolated store only.")
    }
}
