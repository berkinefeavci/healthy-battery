import AppKit

struct MenubarValue {
    let metric: MenubarMetric
    let text: String
    var description: String { "\(metric.title): \(text)" }
}

struct MenubarPresentation {
    let preferences: MenubarPreferences
    let mode: PowerFlowMode
    let percentage: Double?
    let lowPower: Bool
    let values: [MenubarValue]

    init(preferences: MenubarPreferences, snapshot: BatterySnapshot, lowPower: Bool,
         policyState: ChargePolicyState = .idle, now: Date = Date()) {
        self.preferences = preferences.normalized()
        self.mode = PowerFlowPresentation(snapshot: snapshot, now: now).mode
        self.percentage = snapshot.reading(.percentage, now: now).validValue
        self.lowPower = lowPower
        self.values = preferences.normalized().visibleMetrics.map { metric in
            let field: BatteryField
            switch metric {
            case .percentage: field = .percentage
            case .healthPercent: field = .health
            case .cycleCount: field = .cycles
            case .hardwarePercentage: field = .hardwarePercentage
            case .temperatureC: field = .temperature
            case .timeRemaining: field = .timeRemaining
            case .batteryCurrentMA: field = .current
            case .batteryVoltageV: field = .voltage
            case .batteryWatts: field = .batteryPower
            case .systemWatts: field = .systemPower
            case .adapterCurrentA: field = .adapterCurrent
            case .adapterVoltageV: field = .adapterVoltage
            case .adapterWatts: field = .adapterPower
            case .topUp: return MenubarValue(metric: metric, text: policyState.menubarText)
            default: return MenubarValue(metric: metric, text: "—")
            }
            let reading = snapshot.reading(field, now: now)
            var text = reading.text(digits: [.percentage, .hardwarePercentage, .cycles, .current, .timeRemaining].contains(field) ? 0 : 1)
            if field == .timeRemaining, let minutes = reading.validValue, minutes >= 0 {
                text = String(localized: "\(Int(minutes) / 60) sa \(Int(minutes) % 60) dk")
            }
            if field == .cycles, reading.validValue != nil { text += String(localized: " döngü") }
            return MenubarValue(metric: metric, text: text)
        }
    }

    var stateDescription: String {
        switch mode {
        case .charging: return String(localized: "Şarj oluyor")
        case .adapterOnly: return String(localized: "Adaptörden çalışıyor; batarya akışı beklemede")
        case .batteryOnly: return String(localized: "Bataryadan çalışıyor")
        case .batteryAssist: return String(localized: "Adaptör bağlı; batarya güç sağlıyor")
        case .unavailable: return String(localized: "Güncel güç durumu bilinmiyor")
        }
    }
}

struct MenubarRenderResult {
    let image: NSImage
    let description: String
    let hiddenCount: Int
    let resourceWarning: String?
}

enum MenubarRenderer {
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let assetNames = ["charging", "paused", "discharging", "unplugged", "limited"].flatMap { state in
        ["native", "bold", "colored"].map { "\(state)-\($0)" }
    }

    static func asset(_ name: String, bundle: Bundle = .main) -> NSImage? {
        bundle.image(forResource: NSImage.Name(name))
    }

    static func render(_ model: MenubarPresentation, maxWidth: CGFloat,
                       bundle: Bundle = .main) -> MenubarRenderResult {
        let style = model.preferences.effectiveStyle
        let hasIcon = style != .hidden
        let values = style == .iosBattery ? model.values.filter { $0.metric != .percentage } : model.values
        let iconWidth: CGFloat = !hasIcon ? 0 : (style == .iosBattery ? iosBodyWidth(model) + 4 : 24)
        let gap = CGFloat(model.preferences.spacing)
        let widths = values.map { width($0.text) }
        let count = MenubarOverflow.visibleCount(widths: widths.map(Double.init), iconWidth: Double(iconWidth),
                                                spacing: Double(gap), budget: Double(maxWidth),
                                                indicatorWidth: { Double(width("+\($0)")) })
        let hidden = values.count - count
        var texts = values.prefix(count).map(\.text)
        if hidden > 0 { texts.append("+\(hidden)") }
        let pieces = texts.count + (hasIcon ? 1 : 0)
        let total = iconWidth + texts.reduce(CGFloat(0)) { $0 + width($1) } + CGFloat(max(0, pieces - 1)) * gap
        let tinted = model.lowPower && (style == .iosBattery || model.preferences.lowPowerTint)
        let colored = style == .macColored || tinted
        let name = assetName(style: style, mode: model.mode)
        let source = name.flatMap { asset($0, bundle: bundle) }
        let warning = name != nil && source == nil ? String(localized: "Menü ikonu yüklenemedi (\(name!)); yedek çizim kullanılıyor.") : nil
        let image = NSImage(size: NSSize(width: max(1, total), height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            if hasIcon {
                let rect = NSRect(x: 0, y: 3, width: iconWidth, height: 16)
                let color: NSColor = tinted ? .systemYellow : (style == .macColored ? stateColor(model.mode) : .labelColor)
                if let source {
                    // Template resources are explicitly tinted; NSImage.draw alone does not apply template tint.
                    let icon = NSImage(size: rect.size, flipped: false) { _ in
                        source.draw(in: NSRect(origin: .zero, size: rect.size))
                        color.setFill()
                        NSRect(origin: .zero, size: rect.size).fill(using: .sourceIn)
                        if style == .chargeStatus { cutOutStatus(model.mode) }
                        return true
                    }
                    icon.draw(in: rect)
                } else {
                    drawIcon(style: style, model: model, rect: rect, color: color)
                }
                x = iconWidth + (texts.isEmpty ? 0 : gap)
            }
            for (index, text) in texts.enumerated() {
                (text as NSString).draw(at: NSPoint(x: x, y: 3), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                x += width(text) + (index == texts.count - 1 ? 0 : gap)
            }
            return true
        }
        image.isTemplate = !colored
        let description = (["Healthy Battery", model.stateDescription] + (style == .iosBattery ? [String(localized: "Doluluk: \(iosText(model))")] : []) + model.values.map(\.description)
                           + (hidden > 0 ? [String(localized: "\(hidden) öğe gizlendi")] : [])
                           + (warning.map { [$0] } ?? [])).joined(separator: " · ")
        return MenubarRenderResult(image: image, description: description, hiddenCount: hidden, resourceWarning: warning)
    }

    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func assetName(style: MenubarStyle, mode: PowerFlowMode) -> String? {
        let family: String
        switch style {
        case .chargeStatus: family = "bold"
        case .macNative: family = "native"
        case .macColored: family = "colored"
        default: return nil
        }
        let state: String
        switch mode {
        case .charging: state = "charging"
        case .batteryOnly: state = "unplugged"
        case .batteryAssist: state = "discharging"
        // A zero current sample does not establish that a charge limiter paused charging.
        case .adapterOnly, .unavailable: return nil
        }
        return "\(state)-\(family)"
    }

    static func stateColor(_ mode: PowerFlowMode) -> NSColor {
        switch mode {
        case .charging: return .systemGreen
        case .adapterOnly: return .systemYellow
        case .batteryAssist: return .systemOrange
        case .batteryOnly, .unavailable: return .labelColor
        }
    }

    private static func drawIcon(style: MenubarStyle, model: MenubarPresentation, rect: NSRect, color: NSColor) {
        color.setStroke(); color.setFill()
        if style == .iosBattery {
            drawIOSBattery(model, rect: rect, color: color)
            return
        }
        if style == .cellkeepLogo {
            let shield = NSBezierPath()
            shield.move(to: NSPoint(x: 4, y: 16))
            shield.line(to: NSPoint(x: 12, y: 19))
            shield.line(to: NSPoint(x: 20, y: 16))
            shield.line(to: NSPoint(x: 19, y: 9))
            shield.curve(to: NSPoint(x: 12, y: 3), controlPoint1: NSPoint(x: 18, y: 6), controlPoint2: NSPoint(x: 14, y: 4))
            shield.curve(to: NSPoint(x: 5, y: 9), controlPoint1: NSPoint(x: 10, y: 4), controlPoint2: NSPoint(x: 6, y: 6))
            shield.close(); shield.lineWidth = 1.4; shield.stroke()
            drawBolt(at: NSPoint(x: 8, y: 6), color: color)
            return
        }
        let body = NSRect(x: rect.minX + 1, y: rect.minY + 2, width: 20, height: 12)
        let outline = NSBezierPath(roundedRect: body, xRadius: style == .iosBattery ? 3 : 2, yRadius: style == .iosBattery ? 3 : 2)
        outline.lineWidth = style == .chargeStatus ? 2 : 1.2
        outline.stroke()
        NSBezierPath(roundedRect: NSRect(x: 22, y: rect.minY + 6, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
        if model.mode == .unavailable || model.percentage == nil {
            ("?" as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: color])
        } else if let percentage = model.percentage {
            let fillWidth = 16 * CGFloat(min(100, max(0, percentage))) / 100
            if fillWidth > 0 {
                NSBezierPath(roundedRect: NSRect(x: 3, y: rect.minY + 4, width: fillWidth, height: 8), xRadius: min(1.5, fillWidth / 2), yRadius: 1.5).fill()
            }
            if model.mode == .charging {
                let context = NSGraphicsContext.current?.cgContext
                context?.saveGState(); context?.setBlendMode(.destinationOut)
                drawBolt(at: NSPoint(x: 8, y: 6), color: .black)
                context?.restoreGState()
            }
        }
    }

    private static let iosFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    private static func iosHasPowerSymbol(_ model: MenubarPresentation) -> Bool {
        [.charging, .adapterOnly, .batteryAssist].contains(model.mode)
    }

    private static func iosText(_ model: MenubarPresentation) -> String {
        model.percentage.map { String(Int(min(100, max(0, $0)))) } ?? "—"
    }

    private static func iosBodyWidth(_ model: MenubarPresentation) -> CGFloat {
        let textWidth = (iosText(model) as NSString).size(withAttributes: [.font: iosFont]).width
        return max(22, ceil(textWidth) + (iosHasPowerSymbol(model) ? 6 : 0) + 4)
    }

    static func iosFillWidth(percentage: Double?, bodyWidth: CGFloat) -> CGFloat {
        guard let percentage, percentage.isFinite, percentage > 0 else { return 0 }
        return max(0, bodyWidth) * CGFloat(min(100, percentage)) / 100
    }

    private static func drawIOSBattery(_ model: MenubarPresentation, rect: NSRect, color: NSColor) {
        let body = NSRect(x: rect.minX, y: rect.midY - 6, width: iosBodyWidth(model), height: 12)
        let capsule = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5)
        NSColor.labelColor.withAlphaComponent(0.28).setFill()
        capsule.fill()
        let fillWidth = iosFillWidth(percentage: model.percentage, bodyWidth: body.width)
        if fillWidth > 0 {
            NSGraphicsContext.saveGraphicsState()
            capsule.addClip()
            color.setFill()
            NSRect(x: body.minX, y: body.minY, width: fillWidth, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.minY + 4, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // Cutouts adapt to the actual menu background and native template highlighting.
        context.setBlendMode(.destinationOut)
        let text = iosText(model) as NSString
        let size = text.size(withAttributes: [.font: iosFont])
        let boltWidth: CGFloat = iosHasPowerSymbol(model) ? 6 : 0
        let x = body.minX + (body.width - size.width - boltWidth) / 2
        text.draw(at: NSPoint(x: x, y: body.midY - size.height / 2), withAttributes: [.font: iosFont, .foregroundColor: NSColor.black])
        if iosHasPowerSymbol(model) {
            context.translateBy(x: x + size.width + 0.5, y: body.minY + 2)
            context.scaleBy(x: 0.625, y: 0.8)
            drawBolt(at: .zero, color: .black)
        }
    }

    /// Original bold assets used transparent source-over, which leaves the solid body intact.
    /// Cut the status glyph out at render time; preserve the verified asset catalog.
    private static func cutOutStatus(_ mode: PowerFlowMode) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.destinationOut)
        context.setFillColor(NSColor.black.cgColor)
        switch mode {
        case .charging:
            context.move(to: CGPoint(x: 11.2, y: 4.8))
            for point in [CGPoint(x: 8, y: 8.5), CGPoint(x: 10.5, y: 8.5), CGPoint(x: 9.3, y: 11.2), CGPoint(x: 13.6, y: 7), CGPoint(x: 11, y: 7)] { context.addLine(to: point) }
            context.closePath(); context.fillPath()
        case .batteryAssist:
            context.move(to: CGPoint(x: 10.5, y: 5))
            for point in [CGPoint(x: 10.5, y: 9.3), CGPoint(x: 8.5, y: 9.3), CGPoint(x: 11.6, y: 11.4), CGPoint(x: 14.7, y: 9.3), CGPoint(x: 12.7, y: 9.3), CGPoint(x: 12.7, y: 5)] { context.addLine(to: point) }
            context.closePath(); context.fillPath()
        case .batteryOnly: context.fillEllipse(in: CGRect(x: 8.2, y: 6, width: 5.6, height: 5.6))
        case .adapterOnly, .unavailable: break
        }
    }

    private static func drawBolt(at origin: NSPoint, color: NSColor) {
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: origin.x + 5, y: origin.y + 10))
        for point in [NSPoint(x: 0, y: 4), NSPoint(x: 3, y: 4), NSPoint(x: 2, y: 0), NSPoint(x: 8, y: 6), NSPoint(x: 4, y: 6)] {
            bolt.line(to: NSPoint(x: origin.x + point.x, y: origin.y + point.y))
        }
        bolt.close(); color.setFill(); bolt.fill()
    }
}
