import AppKit
import SwiftUI

// Marketing image renderer. Renders the app's REAL SwiftUI views offscreen with curated demo data
// (see Tools/render-marketing.sh). It never touches hardware: the native backend is a read-only
// fake that traps on every write, the power-mode writer traps, and all state lives in temp
// directories plus the renderer's own bundle-id defaults domain (the script also points HOME at a
// temp dir so singletons that use Application Support can never see the real user's files).

final class AppDelegate {
    static var shared: AppDelegate? { nil }
    func showSettings(page: SettingsPage = .dashboard) {}
    func closePanel() {}
}

private let scale: CGFloat = 3

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main
enum MarketingRender {
    static var outDir = URL(fileURLWithPath: "")
    static var manifest: [[String: Any]] = []
    static var temp = URL(fileURLWithPath: "")
    static let defaults = UserDefaults.standard

    // MARK: Demo data

    static func demoSnapshot() -> BatterySnapshot {
        var s = BatterySnapshot()
        s.sampledAt = Date()
        s.available = true
        s.percentage = 78
        s.hardwarePercentage = 79
        s.externalConnected = true
        s.isCharging = true
        s.timeRemainingMinutes = 14
        s.temperatureC = 31
        s.temperatureSource = "SMC TB1T (flt)"
        s.voltage = 12.7
        s.amperage = 3300           // mA into the battery
        s.wattage = 42              // W into the battery
        s.batteryPowerAvailable = true
        s.cycleCount = 12
        s.nominalChargeCapacity = 8740
        s.designCapacity = 8579
        s.remainingCapacity = 6817
        s.healthPercent = 100
        s.adapterRatedWatts = 140
        s.adapterWatts = 57
        s.adapterVoltage = 20
        s.adapterAmperage = 2.85
        s.systemWatts = 15
        s.processorWatts = 7.2
        s.displayWatts = 4.1
        for field in BatteryField.allCases { s.sources[field] = "demo" }
        return s
    }

    /// 24 h of smooth, plausible history ending now: night hold at 80 %, a working day on battery,
    /// then a fast top-up from 38 % to 78 % in the last hour.
    static func demoHistory(now: Date) -> [BatteryHistoryPoint] {
        var points: [BatteryHistoryPoint] = []
        let step: TimeInterval = 300
        var t = now.addingTimeInterval(-86400 + step)
        func smooth(_ x: Double, _ phase: Double) -> Double { sin(x * 0.9 + phase) * 0.6 + sin(x * 2.3 + phase * 1.7) * 0.4 }
        while t <= now {
            let h = now.timeIntervalSince(t) / 3600          // hours before now
            let k = (86400 - now.timeIntervalSince(t)) / 3600
            let pct: Double, watts: Double, system: Double
            if h > 22.5 {            // topping up overnight 62 -> 80
                let f = (24 - h) / 1.5
                pct = 62 + 18 * f; watts = 28 - 20 * f; system = 11 + smooth(k, 1)
            } else if h > 9 {        // plugged in, held at the 80 % limit
                pct = 80; watts = 0; system = 9 + 2.5 * smooth(k, 2)
            } else if h > 1.1 {      // unplugged workday 80 -> 38
                let f = (9 - h) / 7.9
                pct = 80 - 42 * (f * 0.92 + 0.08 * f * f) + 0.5 * smooth(k, 3)
                system = 7.5 + 4 * smooth(k, 4) * (0.6 + 0.4 * f); watts = -system
            } else {                 // plugged in, fast charge 38 -> 78
                let f = (1.1 - h) / 1.1
                pct = 38 + 40 * f; watts = 42 - 8 * f * f * f; system = 14 + smooth(k, 5)
            }
            let temp = 28.5 + (watts > 20 ? 2.4 : 0.4) + 0.6 * smooth(k, 6)
            points.append(BatteryHistoryPoint(
                date: t, percentage: Int(pct.rounded()), wattage: watts, temperatureC: temp, systemWatts: max(4, system),
                healthPercent: 99.55 + 0.45 * min(1, k / 10) + 0.04 * smooth(k, 7), cycleCount: 12))
            t = t.addingTimeInterval(step)
        }
        return points
    }

    static func demoApps() -> [EnergyApp] {
        [EnergyApp(pid: 101, name: "Safari", power: 38, cpu: 14, isApplication: true, iconPath: "/Applications/Safari.app"),
         EnergyApp(pid: 102, name: "Xcode", power: 31, cpu: 11, isApplication: true, iconPath: "/Applications/Xcode.app"),
         EnergyApp(pid: 103, name: "Music", power: 17, cpu: 5, isApplication: true, iconPath: "/System/Applications/Music.app"),
         EnergyApp(pid: 104, name: "Slack", power: 12, cpu: 4, isApplication: true, iconPath: "/Applications/Slack.app")]
    }

    /// 7 healthy days: little time at 95 %+, nothing hot, shallow discharges.
    static func writeHabits(to directory: URL) throws {
        var data = ChargeHabitsData()
        let calendar = Calendar.current
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
            var entry = ChargeHabitsDay(day: LongTermHistory.dayKey(day, calendar: calendar))
            entry.observedSeconds = (12.5 + Double((offset * 5) % 4) * 0.5) * 3600
            entry.secondsAtOrAbove95Plugged = [0.0, 0.1, 0.05, 0.2, 0.0, 0.1, 0.05][offset] * 3600
            entry.secondsChargingAbove35 = 0
            data.days.append(entry)
            data.episodes.append(DischargeEpisode(endDay: entry.day, depth: [31, 24, 38, 27, 33, 22, 29][offset]))
        }
        data.days.sort { $0.day < $1.day }
        try ChargeHabitsStore(url: directory.appendingPathComponent("charge-habits.json")).save(data)
    }

    static func makeMonitor(name: String, conflict: Bool) throws -> BatteryMonitor {
        let root = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if conflict {
            // The app wants 100 % while macOS reports 80 % -> real PolicyConflictBanner state.
            try Data(#"{"schemaVersion":1,"desiredLimit":100,"enabled":true}"#.utf8)
                .write(to: root.appendingPathComponent("charge-policy.json"))
        }
        let stateJSON = Data(#"{"schemaVersion":1,"ok":true,"state":{"manualLimit":80,"availableLimits":[80,85,90,95,100],"enabledRaw":1,"currentLimit":80}}"#.utf8)
        let backend = NativeChargeBackend(version: "marketing", timeout: 0.1) { arguments, _ in
            guard arguments == ["read"] else { fatalError("Marketing renderer must never write hardware") }
            return NativeChargeProcessResult(status: 0, output: stateJSON)
        }
        let coordinator = ChargeControlCoordinator(journal: root.appendingPathComponent("control.json"),
                                                   backend: backend, rival: { false })
        let apps = demoApps()
        let monitor = BatteryMonitor(
            defaults: defaults, coordinator: coordinator, historyURL: root.appendingPathComponent("history.json"),
            batteryReader: { var s = demoSnapshot(); s.sampledAt = Date(); return s },
            nativeReader: { try? backend.readState() }, controllerRunning: { false },
            energyReader: { .success(apps) }, connectedDeviceReader: { [] },
            powerModeReader: { .init(battery: .automatic, adapter: .automatic) },
            powerModeWriter: { _, _ in fatalError("Marketing renderer must never write power mode") })
        monitor.snapshot = demoSnapshot()
        monitor.history = demoHistory(now: Date())
        monitor.settingsVisible = true
        monitor.refresh()
        let deadline = Date().addingTimeInterval(5)
        func ready() -> Bool {
            monitor.nativeLimit == 80 && !monitor.energyApps.isEmpty && (!conflict || monitor.policyConflict != nil)
        }
        while !ready() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(ready(), "Demo monitor did not settle (limit \(String(describing: monitor.nativeLimit)))")
        return monitor
    }

    /// Keep readings fresh (10 s staleness rule) right before each capture.
    static func freshen(_ monitor: BatteryMonitor) {
        monitor.snapshot = demoSnapshot()
        monitor.history = demoHistory(now: Date())
    }

    // MARK: Rendering

    static func render<V: View>(_ root: V, name: String, dark: Bool, width: CGFloat, height: CGFloat? = nil,
                                radius: CGFloat? = nil, monitor: BatteryMonitor? = nil) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        defaults.set(dark ? "dark" : "light", forKey: "appearance")
        if let monitor { freshen(monitor) }
        var content: AnyView = AnyView(root.preferredColorScheme(dark ? .dark : .light).environment(\.controlActiveState, .key).tint(Color.accentColor))
        var width = width, height = height
        if let radius { content = AnyView(content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))) }
        else {   // breathing room so strokes at the shape edge are never cropped
            content = AnyView(content.frame(width: width, height: height).padding(4))
            width += 8; height = height.map { $0 + 8 }
        }
        let view = NSHostingView(rootView: AnyView(content.frame(width: width, height: height)))
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? 800),
                               styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.appearance = appearance
        // Active (colored) controls need a key window; park it far off-screen so nothing is visible.
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        view.appearance = appearance
        view.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 800)
        view.layoutSubtreeIfNeeded()
        var size = NSSize(width: width, height: height ?? view.fittingSize.height.rounded(.up))
        view.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        if let monitor { freshen(monitor) }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        size = view.bounds.size
        try writePNG(view: view, size: size, name: name)
    }

    static func writePNG(view: NSView, size: NSSize, name: String) throws {
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("Could not allocate bitmap")
        }
        rep.size = size    // points; pixel density becomes 3x
        view.cacheDisplay(in: view.bounds, to: rep)
        try save(rep, name: name)
    }

    static func save(_ rep: NSBitmapImageRep, name: String) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
        try png.write(to: outDir.appendingPathComponent(name))
        manifest.append(["file": name, "width": rep.pixelsWide, "height": rep.pixelsHigh])
        print("  \(name)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    // MARK: Main

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
            : "/Users/berkinefeavci/Depo/30-39_Aktif_Isler/healthy-battery-marketing/assets/ui/")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("hb-marketing-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        precondition(Bundle.main.bundleIdentifier == "local.marketing.render",
                     "Run through Tools/render-marketing.sh so the isolated bundle id and HOME are in place")
        defer { defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!) }
        precondition(NSHomeDirectory().contains("hb-marketing-home"), "HOME must point at the temp sandbox")

        // The shared health singleton reads habits from <HOME>/Library/Application Support/Cellkeep.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep")
        precondition(support.path.contains("hb-marketing-home"), "Application Support is not sandboxed: \(support.path)")
        try writeHabits(to: support)

        defaults.set(true, forKey: "appReduceTransparency")
        defaults.set(true, forKey: HealthAutomation.Keys.heatProtectionV1)
        defaults.set(true, forKey: HealthAutomation.Keys.fullChargeDwell)
        defaults.set(80.0, forKey: "chargeLimit")
        defaults.set(true, forKey: "includeBackgroundEnergyProcesses")
        defaults.set(PanelSizeMode.normal.rawValue, forKey: PanelSizeMode.storageKey)
        let layout: [PlacedWidget] = [
            PlacedWidget(.statusExplanation), PlacedWidget(.powerFlow),
            PlacedWidget(.chartLevel, size: .square), PlacedWidget(.chartPower, size: .square),
            PlacedWidget(.significantEnergy, size: .square), PlacedWidget(.specifications, size: .square),
        ]
        defaults.set(try PopoverLayout.encode(layout), forKey: "popoverLayout")

        let monitor = try makeMonitor(name: "normal", conflict: false)
        let conflict = try makeMonitor(name: "conflict", conflict: true)
        print("Rendering to \(outDir.path)")

        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            if dark || true {
                try render(PopoverView().environmentObject(monitor), name: "panel-\(suffix).png", dark: dark,
                           width: 400, height: 1010, radius: 22, monitor: monitor)
            }
            try render(PowerFlowView(snapshot: demoSnapshot()).chargeCard().padding(0).environmentObject(monitor),
                       name: "powerflow-\(suffix).png", dark: dark, width: 372, monitor: monitor)
            try render(ReminderToastView(text: "Battery at 40% — plug in if you can."),
                       name: "toast-\(suffix).png", dark: dark, width: ToastGeometry.size.width, height: ToastGeometry.size.height,
                       monitor: monitor)
        }

        try render(PopoverView().environmentObject(conflict), name: "panel-conflict-dark.png", dark: true,
                   width: 400, height: 1090, radius: 22, monitor: conflict)
        try render(MetricChartView(metric: .health).environmentObject(monitor), name: "health-chart-dark.png",
                   dark: true, width: 372, monitor: monitor)
        try render(ChargeLimitBar().environmentObject(monitor), name: "chargebar-dark.png", dark: true,
                   width: 368, monitor: monitor)
        try render(HealthSettingsCards().automationCard.environmentObject(monitor), name: "heat-dark.png",
                   dark: true, width: 560, monitor: monitor)
        try render(ReadyBySheet(rateSamples: [], onCreate: { _ in }, onCancel: {})
                    .background(Color(nsColor: .windowBackgroundColor)),
                   name: "readyby-dark.png", dark: true, width: 420, radius: 20, monitor: monitor)
        try render(HealthSettingsCards().healthCard.environmentObject(monitor), name: "habits-dark.png",
                   dark: true, width: 560, monitor: monitor)
        try render(SettingsView(selection: .charge, scheduleStorageDirectory: temp).environmentObject(monitor),
                   name: "settings-charge-dark.png", dark: true, width: SettingsLayout.windowIdealWidth,
                   height: SettingsLayout.windowIdealHeight + 240, radius: 26, monitor: monitor)

        try renderMenubarGlyph()
        try renderAppIcon()

        let data = try JSONSerialization.data(withJSONObject: ["scale": 3, "files": manifest.sorted { ($0["file"] as! String) < ($1["file"] as! String) }],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("manifest.json"))
        print("Done: \(manifest.count) images, no hardware write.")
    }

    // MARK: Icons

    /// The real status-item renderer (battery glyph drawn by MenubarRenderer's vector fallback, charging
    /// state with the bolt cut-out), white on transparent at 3x.
    static func renderMenubarGlyph() throws {
        var prefs = MenubarPreferences()
        prefs.style = .chargeStatus
        prefs.metrics = []
        let model = MenubarPresentation(preferences: prefs, snapshot: demoSnapshot(), lowPower: false)
        let result = MenubarRenderer.render(model, maxWidth: 100, bundle: Bundle(for: BundleToken.self))
        let source = result.image
        let size = NSSize(width: 24, height: 16)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            // The status image is 22 pt tall with the 24x16 glyph at y = 3; template tint -> white.
            let tinted = NSImage(size: NSSize(width: source.size.width, height: source.size.height), flipped: false) { rect in
                source.draw(in: rect)
                NSColor.white.setFill(); rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                        from: NSRect(x: 0, y: 3, width: size.width, height: size.height), operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        try save(rep, name: "menubar-icon.png")
    }

    final class BundleToken {}

    /// Icon compiled by actool from Packaging/AppIcon.icon (the script passes the resulting .icns path).
    static func renderAppIcon() throws {
        guard CommandLine.arguments.count > 2, let icon = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
            print("  (app-icon-1024.png skipped: no .icns path given)"); return
        }
        let size = NSSize(width: 1024, height: 1024)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try save(rep, name: "app-icon-1024.png")
    }
}
