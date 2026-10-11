import AppKit
import SwiftUI

final class AppDelegate {
    static var shared: AppDelegate? { nil }
    func showSettings(page: SettingsPage = .dashboard) {}
    func closePanel() {}
}

@main
enum SchedulePowerPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Provide popover, schedule and detail PNG paths") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-schedule-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "local.chargemate.schedule-preview.\(UUID())")!
        defaults.set(true, forKey: "appReduceTransparency")
        defaults.set(false, forKey: "showPowerFlow")
        defaults.set(false, forKey: "showBatteryChart")
        defaults.set(false, forKey: "showQuickStats")
        let coordinator = ChargeControlCoordinator(journal: root.appendingPathComponent("journal.json"),
            read: { [:] }, write: { _ in fatalError("Preview must not write hardware") }, rival: { false })
        let monitor = BatteryMonitor(defaults: defaults, coordinator: coordinator,
            historyURL: root.appendingPathComponent("history.json"), batteryReader: { BatterySnapshot() },
            nativeReader: { [:] }, controllerRunning: { false }, energyReader: { .success([]) })
        var snapshot = BatterySnapshot()
        snapshot.sampledAt = Date(); snapshot.available = true; snapshot.percentage = 80
        snapshot.externalConnected = true; snapshot.batteryPowerAvailable = true; snapshot.wattage = 0
        snapshot.adapterWatts = 30; snapshot.systemWatts = 30
        monitor.snapshot = snapshot

        let task = ScheduleTask(name: "Pazartesi tam dolum", action: .topUp, target: nil,
            recurrence: .weekly, startLocalComponents: ScheduleTask.localComponents(Date(), calendar: .current),
            timezoneID: "Europe/Istanbul", createdAt: Date(), modifiedAt: Date())
        try ScheduleStore(url: root.appendingPathComponent("schedules.json")).save([task])
        let statuses: [(ScheduleExecutionStatus, ScheduleAction, String?)] = [
            (.completed, .setChargeLimit, nil),
            (.failed, .setChargeLimit, "Okuma doğrulaması başarısız."),
            (.skippedConflict, .topUp, "Aynı zamandaki daha öncelikli görev çalıştırıldı."),
            (.recoveryRequired, .startCalibration, "Önceki çalışmanın sonucu doğrulanamadı."),
            (.unsupported, .enableLowPower, "Doğrulanmış public yazma API’si bulunmuyor.")
        ]
        let history = statuses.enumerated().map { index, fixture in
            ScheduleExecutionRecord(executionID: UUID(), taskID: index < 3 ? task.id : UUID(),
                plannedAt: Date().addingTimeInterval(TimeInterval(-index * 3_600)),
                startedAt: Date().addingTimeInterval(TimeInterval(-index * 3_600 + 2)),
                finishedAt: Date().addingTimeInterval(TimeInterval(-index * 3_600 + 4)),
                actionSnapshot: fixture.1, requestedValue: fixture.1 == .setChargeLimit ? 80 : nil,
                timezoneIDSnapshot: "Europe/Istanbul", observedResult: fixture.0 == .completed ? "Fake readback: %80" : nil,
                status: fixture.0, failureReason: fixture.2, operationID: nil)
        }
        try ScheduleExecutionStore(url: root.appendingPathComponent("schedule-executions.json")).save(history, now: Date())

        try render(PopoverView().environmentObject(monitor).defaultAppStorage(defaults).preferredColorScheme(.dark),
                   size: NSSize(width: 400, height: 700), path: CommandLine.arguments[1])
        try render(SettingsView(selection: .schedule, scheduleStorageDirectory: root).environmentObject(monitor).defaultAppStorage(defaults).preferredColorScheme(.dark),
                   size: NSSize(width: 1080, height: 740), path: CommandLine.arguments[2])
        try render(ScheduleExecutionDetailView(record: history[1], taskName: task.name, retryAllowed: true, onRetry: { _ in "Yeni çalışma güvenli biçimde kaydedildi." })
                .preferredColorScheme(.dark),
                   size: NSSize(width: 590, height: 430), path: CommandLine.arguments[3])
        print("Offscreen power/schedule previews written; windows were never shown.")
    }

    private static func render<V: View>(_ root: V, size: NSSize, path: String) throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view; window.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25)); view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
