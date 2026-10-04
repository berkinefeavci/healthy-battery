import Foundation

enum MenubarStyle: String, Codable, CaseIterable, Identifiable {
    case hidden, cellkeepLogo, chargeStatus, macNative, macColored, iosBattery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: return String(localized: "Gizle")
        case .cellkeepLogo: return String(localized: "Healthy Battery logosu")
        case .chargeStatus: return String(localized: "Healthy Battery durumu")
        case .macNative: return String(localized: "macOS sade")
        case .macColored: return String(localized: "macOS renkli")
        case .iosBattery: return String(localized: "iOS tarzı")
        }
    }
}

enum MenubarMetric: String, Codable, CaseIterable, Identifiable {
    case percentage, healthPercent, macOSCondition, cycleCount
    case hardwarePercentage, temperatureC, timeRemaining, batteryCurrentMA, batteryVoltageV, batteryWatts, systemWatts
    case adapterCurrentA, adapterVoltageV, adapterWatts
    case calibration, heatProtection, sailing, topUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percentage: return String(localized: "Batarya yüzdesi")
        case .healthPercent: return String(localized: "Maksimum kapasite")
        case .macOSCondition: return String(localized: "macOS pil durumu")
        case .cycleCount: return String(localized: "Döngü sayısı")
        case .hardwarePercentage: return String(localized: "Donanım yüzdesi")
        case .temperatureC: return String(localized: "Sıcaklık")
        case .timeRemaining: return String(localized: "Kalan süre")
        case .batteryCurrentMA: return String(localized: "Batarya akımı")
        case .batteryVoltageV: return String(localized: "Batarya voltajı")
        case .batteryWatts: return String(localized: "Batarya gücü")
        case .systemWatts: return String(localized: "Sistem gücü")
        case .adapterCurrentA: return String(localized: "Adaptör akımı")
        case .adapterVoltageV: return String(localized: "Adaptör voltajı")
        case .adapterWatts: return String(localized: "Adaptör gücü")
        case .calibration: return String(localized: "Kalibrasyon")
        case .heatProtection: return String(localized: "Sıcaklık koruması")
        case .sailing: return String(localized: "Yelken")
        case .topUp: return "Top Up"
        }
    }
    /// Stable group identifier (not shown as-is; see MenubarSettingsView.groupTitle).
    var group: String {
        switch self {
        case .healthPercent, .macOSCondition, .cycleCount: return "Sağlık"
        case .adapterCurrentA, .adapterVoltageV, .adapterWatts: return "Adaptör"
        case .calibration, .heatProtection, .sailing, .topUp: return "Kontrol durumları"
        default: return "Batarya"
        }
    }
    var unavailableReason: String? {
        switch self {
        case .macOSCondition: return String(localized: "macOS pil durumu için doğrulanmış veri kaynağı bulunmuyor.")
        case .calibration, .heatProtection, .sailing:
            return String(localized: "Bu kontrol henüz etkin değil; doğrulanmış işlem durumu bekleniyor.")
        case .topUp: return nil
        default: return nil
        }
    }
}

enum MenubarRightClick: String, Codable, CaseIterable, Identifiable {
    case none, likeLeftClick, openDashboard, toggleCharging, toggleLowPower
    var id: String { rawValue }
    var supported: Bool { self != .toggleCharging && self != .toggleLowPower }
    var title: String {
        switch self {
        case .none: return String(localized: "Hiçbir şey yapma")
        case .likeLeftClick: return String(localized: "Paneli aç / kapat")
        case .openDashboard: return String(localized: "Gösterge Tablosu’nu aç")
        case .toggleCharging: return String(localized: "Şarjı başlat / durdur — henüz kullanılamıyor")
        case .toggleLowPower: return String(localized: "Düşük Güç Modunu değiştir — henüz kullanılamıyor")
        }
    }
}

struct MenubarPreferences: Codable, Equatable {
    static let storageKey = "menubarPreferences.v1"
    var schemaVersion = 1
    var style = MenubarStyle.chargeStatus
    var metrics: [MenubarMetric] = [.percentage]
    var lowPowerTint = true
    var spacing = 5
    var interval = 5
    var rightClick = MenubarRightClick.likeLeftClick

    var effectiveStyle: MenubarStyle {
        style == .hidden && visibleMetrics.isEmpty ? .chargeStatus : style
    }
    var visibleMetrics: [MenubarMetric] { metrics.filter { $0.unavailableReason == nil } }
    var accessFallback: Bool { effectiveStyle != style }

    func normalized() -> Self {
        var result = self
        result.spacing = min(20, max(0, spacing))
        result.interval = min(20, max(2, interval))
        var seen = Set<MenubarMetric>()
        result.metrics = metrics.filter { seen.insert($0).inserted }
        return result
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: storageKey),
           let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1 {
            return value.normalized()
        }
        var result = Self()
        // Existing toggles migrate in the same order, including an explicitly empty list.
        result.metrics = []
        if defaults.object(forKey: "showMenuPercentage") as? Bool ?? true { result.metrics.append(.percentage) }
        if defaults.bool(forKey: "showMenuTemperature") { result.metrics.append(.temperatureC) }
        if defaults.bool(forKey: "showMenuPower") { result.metrics.append(.batteryWatts) }
        return result
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        if defaults.data(forKey: Self.storageKey) != data { defaults.set(data, forKey: Self.storageKey) }
    }

    mutating func toggle(_ metric: MenubarMetric) {
        if metrics.contains(metric) { metrics.removeAll { $0 == metric } }
        else if metric.unavailableReason == nil { metrics.append(metric) }
    }

    mutating func move(_ source: MenubarMetric, before target: MenubarMetric) {
        guard source != target, metrics.contains(source), metrics.contains(target) else { return }
        metrics.removeAll { $0 == source }
        metrics.insert(source, at: metrics.firstIndex(of: target)!)
    }

    mutating func move(_ metric: MenubarMetric, by offset: Int) {
        guard let index = metrics.firstIndex(of: metric), metrics.indices.contains(index + offset) else { return }
        metrics.swapAt(index, index + offset)
    }
}

/// Keep the leftmost items. Count indicator participates in the same width budget.
enum MenubarOverflow {
    static func visibleCount(widths: [Double], iconWidth: Double, spacing: Double,
                             budget: Double, indicatorWidth: (Int) -> Double) -> Int {
        for count in stride(from: widths.count, through: 0, by: -1) {
            var pieces = Array(widths.prefix(count))
            if iconWidth > 0 { pieces.insert(iconWidth, at: 0) }
            if count < widths.count { pieces.append(indicatorWidth(widths.count - count)) }
            let width = pieces.reduce(0, +) + Double(max(0, pieces.count - 1)) * spacing
            if width <= budget || count == 0 { return count }
        }
        return 0
    }
}
