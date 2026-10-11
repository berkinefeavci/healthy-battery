import AppKit
import SwiftUI

final class AppDelegate {
    static var shared: AppDelegate? { nil }
    func showSettings(page: SettingsPage = .dashboard) {}
    func closePanel() {}
}

@main
enum UIRefinementPreview {
    static func main() throws {
        guard CommandLine.arguments.count == 7 else {
            fatalError("Provide 85% popover, 95% popover, sleep, energy, MagSafe and menubar PNG paths")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-ui-refinement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.chargemate.ui-refinement-preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "appReduceTransparency")
        defaults.set(true, forKey: "includeBackgroundEnergyProcesses")
        defaults.set(85.0, forKey: "chargeLimit")
        defaults.set("scheduled", forKey: MagSafeLEDPolicy.storageKey)

        var snapshot = BatterySnapshot()
        snapshot.sampledAt = Date()
        snapshot.available = true
        snapshot.percentage = 90
        snapshot.externalConnected = true // Injected fixture; never probes live SMC.
        snapshot.voltage = 12.66
        snapshot.amperage = 0
        snapshot.wattage = 0
        snapshot.batteryPowerAvailable = true
        snapshot.nominalChargeCapacity = 8583
        snapshot.designCapacity = 8579
        snapshot.adapterRatedWatts = 140
        snapshot.temperatureSource = "SMC TB1T (flt)"
        snapshot.sources[.percentage] = "fixture"

        let stateJSON = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":90,"availableLimits":[80,85,90,95,100],"enabledRaw":1,"currentLimit":100}}"#.utf8)
        let backend = NativeChargeBackend(version: "preview", timeout: 0.1) { arguments, _ in
            guard arguments == ["read"] else { fatalError("Preview must never write hardware") }
            return NativeChargeProcessResult(status: 0, output: stateJSON)
        }
        let coordinator = ChargeControlCoordinator(journal: root.appendingPathComponent("control.json"),
            backend: backend, rival: { false })
        let monitor = BatteryMonitor(defaults: defaults, coordinator: coordinator,
            historyURL: root.appendingPathComponent("history.json"), batteryReader: { snapshot },
            nativeReader: { try? backend.readState() }, controllerRunning: { false },
            energyReader: { .success([EnergyApp(pid: 1, name: "WindowServer", power: 45, cpu: 18, isApplication: false)]) },
            connectedDeviceReader: {
                [ConnectedDevice(id: "phone", name: "iPhone", vendor: "Apple", kind: .phone),
                 ConnectedDevice(id: "ssd", name: "Portable SSD", vendor: "Samsung", kind: .storage, diskIdentifier: "disk4")]
            },
            powerModeReader: { .init(battery: .lowPower, adapter: .turbo) },
            powerModeWriter: { _, _ in fatalError("Preview must never write power mode") })
        monitor.snapshot = snapshot
        monitor.settingsVisible = true
        monitor.refresh()
        let deadline = Date().addingTimeInterval(3)
        while monitor.nativeLimit != 90 && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(monitor.nativeLimits.count == 5)

        try render(PopoverView(showLimitEditor: true).environmentObject(monitor)
            .defaultAppStorage(defaults).preferredColorScheme(.dark),
            size: NSSize(width: 400, height: 640), path: CommandLine.arguments[1])
        monitor.chargeLimit = 95 // Same @Published draft that the preset buttons write.
        try render(PopoverView(showLimitEditor: true).environmentObject(monitor)
            .defaultAppStorage(defaults).preferredColorScheme(.dark),
            size: NSSize(width: 400, height: 640), path: CommandLine.arguments[2])
        for (page, path) in zip([SettingsPage.sleep, .energy, .magsafeLED, .menubar], CommandLine.arguments[3...]) {
            try render(SettingsView(selection: page, scheduleStorageDirectory: root).environmentObject(monitor)
                .defaultAppStorage(defaults).preferredColorScheme(.dark),
                size: NSSize(width: 1080, height: 740), path: path)
        }
        print("Six offscreen UI previews written; no window shown and no hardware write.")
    }

    private static func render<V: View>(_ root: V, size: NSSize, path: String) throws {
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("Offscreen preview could not render")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Offscreen preview could not encode")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
