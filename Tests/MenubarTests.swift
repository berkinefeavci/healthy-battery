import AppKit

@main
enum MenubarTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
        assertions += 1
    }
    static func snapshot(_ mode: PowerFlowMode, at now: Date) -> BatterySnapshot {
        var value = BatterySnapshot()
        value.sampledAt = now
        value.available = mode != .unavailable
        value.percentage = 73
        value.hardwarePercentage = 70
        value.externalConnected = mode != .batteryOnly
        value.isCharging = mode == .charging
        value.batteryPowerAvailable = mode != .unavailable
        value.wattage = mode == .charging ? 12 : (mode == .adapterOnly ? 0 : -8)
        value.temperatureC = 31.5
        return value
    }
    static func main() throws {
        let suite = "local.chargemate.menubar-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(MenubarPreferences.load(from: defaults) == MenubarPreferences(), "fresh defaults")
        defaults.set(false, forKey: "showMenuPercentage")
        defaults.set(true, forKey: "showMenuTemperature")
        defaults.set(true, forKey: "showMenuPower")
        var p = MenubarPreferences.load(from: defaults)
        expect(p.metrics == [.temperatureC, .batteryWatts], "legacy selection and order preserved")
        p.style = .hidden
        p.spacing = 20; p.interval = 2; p.rightClick = .openDashboard
        p.save(to: defaults)
        expect(MenubarPreferences.load(from: defaults) == p, "restart round trip")
        defaults.set(true, forKey: "showMenuPercentage")
        expect(MenubarPreferences.load(from: defaults) == p, "migration runs only before saved config")
        p.toggle(.temperatureC)
        expect(p.metrics == [.batteryWatts], "second click removes")
        p.toggle(.cycleCount); p.toggle(.percentage)
        p.move(.percentage, before: .batteryWatts)
        expect(p.metrics == [.percentage, .batteryWatts, .cycleCount], "drag reorder")
        p.move(.percentage, by: 1)
        expect(p.metrics == [.batteryWatts, .percentage, .cycleCount], "keyboard reorder")
        p.move(.batteryWatts, by: -1)
        expect(p.metrics.first == .batteryWatts, "left edge guarded")
        p.metrics = []; p.save(to: defaults)
        expect(MenubarPreferences.load(from: defaults).metrics.isEmpty, "explicit clear persists")
        expect(p.accessFallback && p.effectiveStyle == .chargeStatus, "hidden empty stays accessible")
        p.metrics = [.macOSCondition]
        expect(p.accessFallback, "unsupported-only list stays accessible")
        p.toggle(.topUp)
        expect(p.metrics.contains(.topUp), "verified Top Up status can be added")
        p.metrics = [.percentage, .percentage]
        p.spacing = 90; p.interval = -1
        expect(p.normalized().metrics == [.percentage], "deduplicated order")
        expect(p.normalized().spacing == 20 && p.normalized().interval == 2, "range clamps")
        expect(!MenubarRightClick.toggleCharging.supported && !MenubarRightClick.toggleLowPower.supported, "writes unavailable")
        expect(MenubarOverflow.visibleCount(widths: [40, 40, 40], iconWidth: 24, spacing: 5, budget: 200, indicatorWidth: { _ in 20 }) == 3, "no overflow")
        expect(MenubarOverflow.visibleCount(widths: [40, 40, 40], iconWidth: 24, spacing: 5, budget: 100, indicatorWidth: { _ in 20 }) == 1, "indicator fits budget")
        expect(MenubarOverflow.visibleCount(widths: [400], iconWidth: 0, spacing: 20, budget: 100, indicatorWidth: { _ in 20 }) == 0, "huge item hidden")

        let now = Date()
        var sample = snapshot(.charging, at: now)
        p = MenubarPreferences(); p.metrics = [.percentage, .hardwarePercentage, .adapterWatts, .sailing]
        let model = MenubarPresentation(preferences: p, snapshot: sample, lowPower: false, now: now)
        expect(model.values.count == 4 && model.values[3].text == "—", "idle control shows a dash")
        expect(model.values[0].text == "%73" && model.values[1].text == "%70", "display and hardware percentage distinct")
        expect(model.values[2].text == "—", "missing adapter is not zero")
        p.metrics = [.topUp]
        let topUpModel = MenubarPresentation(preferences: p, snapshot: sample, lowPower: false,
                                             policyState: .topUpCharging(73), now: now)
        expect(topUpModel.values.first?.text == "Top Up %73", "menu Top Up status is real controller state")
        p.metrics = [.calibration, .sailing, .heatProtection]
        let controlModel = MenubarPresentation(preferences: p, snapshot: sample, lowPower: false,
                                               controlStates: [.calibration: "Kal. 3/4", .sailing: "Yelken %70–%80"], now: now)
        expect(controlModel.values.map(\.text) == ["Kal. 3/4", "Yelken %70–%80", "—"], "control metrics show live states")
        p.metrics = [.percentage, .hardwarePercentage, .adapterWatts, .sailing]
        let stale = MenubarPresentation(preferences: p, snapshot: sample, lowPower: false, now: now.addingTimeInterval(11))
        expect(stale.mode == .unavailable && stale.values.allSatisfy { $0.text == "—" }, "stale status and metrics")
        sample.percentage = 0
        expect(MenubarPresentation(preferences: p, snapshot: sample, lowPower: false, now: now).values[0].text == "%0", "valid zero preserved")
        expect(MenubarRenderer.assetName(style: .macNative, mode: .adapterOnly) == nil, "adapter is not confirmed pause")
        expect(MenubarRenderer.assetName(style: .macNative, mode: .unavailable) == nil, "unknown is not empty battery")

        // Offscreen AppKit drawing only: no application windows or status items are created.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.count > 1, let bundle = Bundle(path: CommandLine.arguments[1]) {
            for name in MenubarRenderer.assetNames {
                expect(MenubarRenderer.asset(name, bundle: bundle) != nil, "missing bundled resource: \(name)")
            }
            let modes: [PowerFlowMode] = [.charging, .adapterOnly, .batteryOnly, .batteryAssist, .unavailable]
            for style in MenubarStyle.allCases {
                for mode in modes {
                    var prefs = MenubarPreferences(); prefs.style = style
                    let output = MenubarRenderer.render(MenubarPresentation(preferences: prefs, snapshot: snapshot(mode, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
                    expect(output.image.size.width <= 200 && output.image.size.width > 0, "style/mode width")
                    expect(output.resourceWarning == nil, "resource lookup warning")
                    expect(output.image.tiffRepresentation != nil, "offscreen render")
                }
            }
            var prefs = MenubarPreferences(); prefs.metrics = [.percentage, .temperatureC, .cycleCount, .adapterWatts]
            let overflow = MenubarRenderer.render(MenubarPresentation(preferences: prefs, snapshot: sample, lowPower: true, now: now), maxWidth: 100, bundle: bundle)
            expect(overflow.hiddenCount > 0 && overflow.image.size.width <= 100, "real measured overflow")
            expect(overflow.description.contains("Adaptör gücü"), "overflow accessible full values")
            expect(!overflow.image.isTemplate, "low power tint preserves color")
            let boldCharge = MenubarRenderer.render(MenubarPresentation(preferences: MenubarPreferences(), snapshot: snapshot(.charging, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            let boldBattery = MenubarRenderer.render(MenubarPresentation(preferences: MenubarPreferences(), snapshot: snapshot(.batteryOnly, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            expect(boldCharge.image.tiffRepresentation != boldBattery.image.tiffRepresentation, "bold glyphs must distinguish power states")
            var ios = MenubarPreferences(); ios.style = .iosBattery
            let iosWithPercent = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: sample, lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            ios.metrics = []
            let iosWithoutExternalPercent = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: sample, lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            expect(iosWithPercent.image.size == iosWithoutExternalPercent.image.size, "iOS percentage is internal and not duplicated")
            let iosCharging = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: snapshot(.charging, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            let iosAdapter = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: snapshot(.adapterOnly, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            let iosBattery = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: snapshot(.batteryOnly, at: now), lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            expect(iosCharging.image.tiffRepresentation == iosAdapter.image.tiffRepresentation, "external power keeps the iOS lightning glyph even when charging is idle")
            expect(iosAdapter.image.tiffRepresentation != iosBattery.image.tiffRepresentation, "iOS lightning glyph disappears on battery power")
            expect(MenubarRenderer.iosFillWidth(percentage: 10, bodyWidth: 30) < MenubarRenderer.iosFillWidth(percentage: 90, bodyWidth: 30), "iOS icon fill follows battery percentage")
            expect(MenubarRenderer.iosFillWidth(percentage: nil, bodyWidth: 30) == 0, "unknown percentage has no invented iOS fill")
            expect(MenubarRenderer.iosFillWidth(percentage: 100, bodyWidth: 30) == 30, "full iOS charge fills original capsule without inset")
            expect(MenubarRenderer.iosFillWidth(percentage: 1, bodyWidth: 30) == 0.3, "low iOS charge is proportional without minimum inflated fill")
            var half = snapshot(.batteryOnly, at: now)
            half.percentage = 50
            let halfImage = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: half, lowPower: false, now: now), maxWidth: 200, bundle: bundle).image
            let halfPixels = NSBitmapImageRep(data: halfImage.tiffRepresentation!)!
            // Near the capsule top, away from the percentage glyphs: original full-height
            // silhouette stays filled at left and has a subdued remaining track at right.
            let scale = CGFloat(halfPixels.pixelsWide) / halfImage.size.width
            let leftAlpha = halfPixels.colorAt(x: Int(6 * scale), y: Int(6 * scale))!.alphaComponent
            let rightAlpha = halfPixels.colorAt(x: Int(16 * scale), y: Int(6 * scale))!.alphaComponent
            expect(leftAlpha > 0.8, "iOS fill retains original full-height solid capsule")
            expect(rightAlpha > 0.15 && rightAlpha < 0.5, "iOS empty portion preserves subdued capsule silhouette")
            var legacyIOS = ios
            legacyIOS.lowPowerTint = false
            let lowPowerIOS = MenubarRenderer.render(MenubarPresentation(preferences: legacyIOS, snapshot: half, lowPower: true, now: now), maxWidth: 200, bundle: bundle).image
            expect(!lowPowerIOS.isTemplate, "iOS low power preserves yellow even with legacy tint disabled")
            let lowPowerPixels = NSBitmapImageRep(data: lowPowerIOS.tiffRepresentation!)!
            let lowPowerColor = lowPowerPixels.colorAt(x: Int(6 * scale), y: Int(6 * scale))!.usingColorSpace(.deviceRGB)!
            expect(lowPowerColor.redComponent > 0.8 && lowPowerColor.greenComponent > 0.6 && lowPowerColor.blueComponent < 0.35, "actual low power renders iOS battery fill yellow")
            let lowPowerTrack = lowPowerPixels.colorAt(x: Int(16 * scale), y: Int(6 * scale))!.usingColorSpace(.deviceRGB)!
            expect(abs(lowPowerTrack.redComponent - lowPowerTrack.greenComponent) < 0.08 &&
                   abs(lowPowerTrack.greenComponent - lowPowerTrack.blueComponent) < 0.08,
                   "empty iOS battery track stays neutral gray in low power")
            let normalIOS = MenubarRenderer.render(MenubarPresentation(preferences: legacyIOS, snapshot: half, lowPower: false, now: now), maxWidth: 200, bundle: bundle).image
            expect(normalIOS.isTemplate, "iOS battery returns to native monochrome outside low power")
            var full = snapshot(.charging, at: now); full.percentage = 100
            let iosFull = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: full, lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            expect(iosFull.image.size.width > iosWithoutExternalPercent.image.size.width, "three digits plus bolt have enough width")
            full.percentage = nil
            let iosMissing = MenubarRenderer.render(MenubarPresentation(preferences: ios, snapshot: full, lowPower: false, now: now), maxWidth: 200, bundle: bundle)
            expect(iosMissing.description.contains("Doluluk: —"), "missing iOS percentage stays unknown")
            if CommandLine.arguments.count > 2 { try renderSheet(bundle: bundle, path: CommandLine.arguments[2], now: now) }
        }
        print("Menubar: \(assertions) assertions passed; isolated preferences and offscreen rendering only.")
    }

    static func renderSheet(bundle: Bundle, path: String, now: Date) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 720, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let modes: [PowerFlowMode] = [.charging, .adapterOnly, .batteryOnly, .batteryAssist, .unavailable]
        for (themeIndex, theme) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: theme)!.performAsCurrentDrawingAppearance {
                let yBase = CGFloat(themeIndex * 360)
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: yBase, width: 1200, height: 360).fill()
                for (column, style) in MenubarStyle.allCases.enumerated() {
                    (style.title as NSString).draw(at: NSPoint(x: CGFloat(column * 200 + 12), y: yBase + 330), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
                    for (row, mode) in modes.enumerated() {
                        var prefs = MenubarPreferences(); prefs.style = style
                        prefs.metrics = [.percentage, .temperatureC]
                        let output = MenubarRenderer.render(MenubarPresentation(preferences: prefs, snapshot: snapshot(mode, at: now), lowPower: false, now: now), maxWidth: 184, bundle: bundle)
                        output.image.draw(in: NSRect(x: CGFloat(column * 200 + 12), y: yBase + 278 - CGFloat(row * 50), width: output.image.size.width, height: 22))
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
