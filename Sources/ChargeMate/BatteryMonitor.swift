import Foundation
import IOKit.ps
import Combine
import AppKit
import Darwin

enum BatteryField: String, CaseIterable, Codable {
    case percentage, hardwarePercentage, temperature, voltage, current, batteryPower, cycles
    case fullCapacity, designCapacity, remainingCapacity, health, adapterPower, systemPower
    case processorPower, displayPower
    case adapterRatedPower, adapterVoltage, adapterCurrent, timeRemaining
    var unit: String {
        switch self {
        case .percentage, .hardwarePercentage, .health: return "%"
        case .temperature: return "°C"
        case .voltage, .adapterVoltage: return "V"
        case .current: return "mA"
        case .adapterCurrent: return "A"
        case .batteryPower, .adapterPower, .systemPower, .processorPower, .displayPower, .adapterRatedPower: return "W"
        case .fullCapacity, .designCapacity, .remainingCapacity: return "mAh"
        case .timeRemaining: return "dk"
        case .cycles: return ""
        }
    }
}

enum MeasurementQuality: String, Codable { case valid, missing, invalid, stale }
struct MeasurementMetadata: Codable {
    let source: String?
    let unit: String
    let sampledAt: Date
    let quality: MeasurementQuality
}
struct BatteryReading {
    let value: Double?
    let metadata: MeasurementMetadata
    var validValue: Double? { metadata.quality == .valid ? value : nil }
    func text(digits: Int = 1) -> String {
        guard let value = validValue else { return "—" }
        let number = String(format: "%.*f", digits, value)
        if metadata.unit == "%" { return String(localized: "%\(number)") }
        return number + (metadata.unit.isEmpty ? "" : " " + metadata.unit)
    }
}

struct BatterySnapshot {
    var sampledAt = Date()
    var batteryPowerAvailable = false
    var available = false
    var percentage: Int?
    var hardwarePercentage: Int?
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var timeRemainingMinutes: Int?
    var temperatureC: Double?
    var temperatureSource = String(localized: "Kullanılamıyor")
    var voltage: Double?
    var amperage: Double?
    var wattage: Double?
    var cycleCount: Int?
    var nominalChargeCapacity: Int?
    var designCapacity: Int?
    var healthPercent: Double?
    var adapterWatts: Double?
    var systemWatts: Double?
    var processorWatts: Double?
    var displayWatts: Double?
    var adapterRatedWatts: Double?
    var adapterVoltage: Double?
    var adapterAmperage: Double?
    var remainingCapacity: Int?
    var sources: [BatteryField: String] = [:]
    var invalidFields: Set<BatteryField> = []

    func reading(_ field: BatteryField, now: Date = Date()) -> BatteryReading {
        let value: Double?
        switch field {
        case .percentage: value = percentage.map(Double.init)
        case .hardwarePercentage: value = hardwarePercentage.map(Double.init)
        case .temperature: value = temperatureC
        case .voltage: value = voltage
        case .current: value = amperage
        case .batteryPower: value = batteryPowerAvailable ? wattage : nil
        case .cycles: value = cycleCount.map(Double.init)
        case .fullCapacity: value = nominalChargeCapacity.map(Double.init)
        case .designCapacity: value = designCapacity.map(Double.init)
        case .remainingCapacity: value = remainingCapacity.map(Double.init)
        case .health: value = healthPercent
        case .adapterPower: value = adapterWatts
        case .systemPower: value = systemWatts
        case .processorPower: value = processorWatts
        case .displayPower: value = displayWatts
        case .adapterRatedPower: value = adapterRatedWatts
        case .adapterVoltage: value = adapterVoltage
        case .adapterCurrent: value = adapterAmperage
        case .timeRemaining: value = timeRemainingMinutes.map(Double.init)
        }
        let age = now.timeIntervalSince(sampledAt)
        let quality: MeasurementQuality
        if let value, !value.isFinite { quality = .invalid }
        else if value == nil { quality = invalidFields.contains(field) ? .invalid : .missing }
        else if !age.isFinite || age < 0 { quality = .invalid }
        // Product contract §5.2: battery/power/temperature are fresh for 10 seconds.
        else if age > 10 { quality = .stale }
        else { quality = .valid }
        return BatteryReading(value: value, metadata: MeasurementMetadata(source: sources[field], unit: field.unit,
                                                                          sampledAt: sampledAt, quality: quality))
    }

    var state: BatteryState {
        if externalConnected && isCharging { return .charging }
        if externalConnected && (amperage ?? 0) >= 0 { return .paused }
        return .discharging
    }

    var powerFlow: PowerFlowPresentation { PowerFlowPresentation(snapshot: self) }

    /// FullChargeCapacity / DesignCapacity, unclamped: the charge the gauge can deliver right now.
    var usableCapacityText: String {
        guard let full = reading(.fullCapacity).validValue,
              let design = reading(.designCapacity).validValue, design > 0 else { return "—" }
        let number = String(format: "%.1f", full / design * 100)
        return String(localized: "%\(number)")
    }
}

enum BatteryState: String { case charging, paused, discharging }

enum PowerFlowMode: String, Equatable {
    case charging, adapterOnly, batteryOnly, batteryAssist, unavailable
}

enum PowerFlowNode: String {
    case adapter = "Adaptör", mac = "MacBook", battery = "Batarya"
    case display = "Ekran", processor = "İşlemci", other = "Diğer"

    /// Display name. The Turkish raw values stay as they are because they identify the node.
    var title: String {
        switch self {
        case .adapter: return String(localized: "Adaptör")
        case .mac: return "MacBook"
        case .battery: return String(localized: "Batarya")
        case .display: return String(localized: "Ekran")
        case .processor: return String(localized: "İşlemci")
        case .other: return String(localized: "Diğer")
        }
    }
}
enum PowerFlowColumn: Equatable { case source, device, destination }
enum PowerFlowLayout {
    enum BatteryTone: Equatable { case red, yellow, green }

    static func batteryTone(for percentage: Int?) -> BatteryTone {
        guard let percentage else { return .green }
        if percentage <= 20 { return .red }
        if percentage <= 50 { return .yellow }
        return .green
    }

    static func column(for node: PowerFlowNode, mode: PowerFlowMode) -> PowerFlowColumn {
        switch node {
        case .adapter: return .source
        case .mac: return .device
        case .display, .processor, .other: return .destination
        case .battery:
            if mode == .charging { return .device }
            return mode == .batteryOnly || mode == .batteryAssist ? .source : .destination
        }
    }

    static func verticalRank(for node: PowerFlowNode, mode: PowerFlowMode) -> Int {
        switch node {
        case .battery: return 0
        case .processor: return 1
        case .display: return 2
        case .other: return 3
        case .adapter: return 0
        case .mac: return mode == .charging ? 1 : 0
        }
    }
}
struct PowerFlowEdge: Identifiable {
    let id: String
    let source: PowerFlowNode
    let target: PowerFlowNode
    let watts: Double?
    var active: Bool { watts.map { $0.isFinite && $0 > PowerFlowPresentation.deadZone } ?? false }
}
struct PowerFlowPresentation {
    static let deadZone = 0.5
    let mode: PowerFlowMode
    let edges: [PowerFlowEdge]
    let notice: String?
    init(snapshot: BatterySnapshot, now: Date = Date()) {
        let fresh = snapshot.available && (0...10).contains(now.timeIntervalSince(snapshot.sampledAt))
        let battery = fresh ? snapshot.reading(.batteryPower, now: now).validValue : nil
        let adapter = fresh && snapshot.externalConnected ? snapshot.reading(.adapterPower, now: now).validValue : nil
        let system = fresh ? snapshot.reading(.systemPower, now: now).validValue : nil
        let processor = fresh ? snapshot.reading(.processorPower, now: now).validValue : nil
        let display = fresh ? snapshot.reading(.displayPower, now: now).validValue : nil
        let contradictory = battery.map { ($0 > Self.deadZone && (!snapshot.isCharging || !snapshot.externalConnected)) || ($0 < -Self.deadZone && snapshot.isCharging) } ?? false
        if !fresh || battery == nil || contradictory { mode = .unavailable }
        else if !snapshot.externalConnected { mode = .batteryOnly }
        else if battery! > Self.deadZone { mode = .charging }
        else if battery! < -Self.deadZone { mode = .batteryAssist }
        else { mode = .adapterOnly }
        var result: [PowerFlowEdge] = []
        if mode != .unavailable {
            let batteryMagnitude = abs(battery ?? 0)
            switch mode {
            case .charging:
                result.append(PowerFlowEdge(id: "adapter-mac", source: .adapter, target: .mac, watts: system))
                if batteryMagnitude > Self.deadZone {
                    result.append(PowerFlowEdge(id: "adapter-battery", source: .adapter, target: .battery, watts: batteryMagnitude))
                }
            case .adapterOnly:
                result.append(PowerFlowEdge(id: "adapter-mac", source: .adapter, target: .mac, watts: system ?? adapter))
            case .batteryOnly:
                result.append(PowerFlowEdge(id: "battery-mac", source: .battery, target: .mac, watts: system ?? batteryMagnitude))
            case .batteryAssist:
                result.append(PowerFlowEdge(id: "adapter-mac", source: .adapter, target: .mac,
                                            watts: system.map { max(0, $0 - batteryMagnitude) } ?? adapter))
                result.append(PowerFlowEdge(id: "battery-mac", source: .battery, target: .mac, watts: batteryMagnitude))
            case .unavailable: break
            }
            if let processor { result.append(PowerFlowEdge(id: "mac-processor", source: .mac, target: .processor, watts: processor)) }
            if let display { result.append(PowerFlowEdge(id: "mac-display", source: .mac, target: .display, watts: display)) }
            if let system {
                let remainder = max(0, system - (processor ?? 0) - (display ?? 0))
                if remainder > Self.deadZone {
                    result.append(PowerFlowEdge(id: "mac-other", source: .mac, target: .other, watts: remainder))
                }
            }
        }
        edges = result
        if !fresh { notice = String(localized: "Güncel güç ölçümü bekleniyor.") }
        else if contradictory { notice = String(localized: "Şarj durumu ve güç işareti uyuşmuyor; batarya yönü doğrulanamıyor.") }
        else if let system, (processor ?? 0) + (display ?? 0) > system + max(2, system * 0.15) {
            notice = String(localized: "Bileşenler farklı anlarda ölçüldü; toplamla kısa süreli fark olabilir.")
        } else if let adapter, let system, let battery, abs(adapter - system - battery) > max(2, adapter * 0.1) {
            notice = String(localized: "Kaynak ölçümleri farklı anlarda alındı; akış yönü doğru, anlık toplamlar değişebilir.")
        } else if battery == nil { notice = String(localized: "Batarya akımı veya gerilimi okunamadı.") }
        else { notice = nil }
    }
    static func lineWidth(for watts: Double?) -> CGFloat {
        guard let watts, watts.isFinite, watts > deadZone else { return 1.5 }
        return min(18, 3 + CGFloat(watts / 60) * 15)
    }
}
struct BatteryHistoryPoint: Identifiable, Codable {
    var id: Date { date }
    let date: Date
    let percentage: Int?
    let wattage: Double?
    let temperatureC: Double?
    let systemWatts: Double?
    let healthPercent: Double?
    let cycleCount: Int?
    var hardwarePercentage: Int? = nil
    var batteryCurrentMA: Double? = nil
    var batteryVoltageV: Double? = nil
    var remainingCapacityMAh: Int? = nil
    var fullCapacityMAh: Int? = nil
    var temperatureSource: String? = nil
    var measurementMetadata: [String: MeasurementMetadata]? = nil
    var hasValidMeasurement: Bool {
        // Explicitly typed: older compilers time out inferring this mixed Int?/Double? literal.
        let values: [Double?] = [percentage.map(Double.init), wattage, temperatureC, systemWatts, healthPercent,
                                 cycleCount.map(Double.init), hardwarePercentage.map(Double.init), batteryCurrentMA,
                                 batteryVoltageV, remainingCapacityMAh.map(Double.init), fullCapacityMAh.map(Double.init)]
        return values.contains { $0?.isFinite == true }
    }
}

struct LimitEvent: Codable, Equatable {
    let date: Date
    let value: Int
}

struct HistoryArchive: Codable {
    let schemaVersion: Int
    let measurements: [BatteryHistoryPoint]
    let limitEvents: [LimitEvent]

    static func read(_ url: URL, now: Date = Date()) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self(schemaVersion: 2, measurements: [], limitEvents: []) }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let archive: Self
        if let legacy = try? decoder.decode([BatteryHistoryPoint].self, from: data) {
            archive = Self(schemaVersion: 1, measurements: legacy, limitEvents: [])
        } else {
            archive = try decoder.decode(Self.self, from: data)
            guard archive.schemaVersion == 2 else { throw CocoaError(.fileReadCorruptFile) }
        }
        var unique: [Date: BatteryHistoryPoint] = [:]
        for point in archive.measurements where (0...86400).contains(now.timeIntervalSince(point.date)) && (point.percentage.map { (0...100).contains($0) } ?? true) {
            if unique[point.date]?.hasValidMeasurement == true && !point.hasValidMeasurement { continue }
            unique[point.date] = point
        }
        let events = archive.limitEvents.filter { $0.date <= now && (0...100).contains($0.value) }.sorted { $0.date < $1.date }
        let lower = now.addingTimeInterval(-86400)
        let baseline = events.last { $0.date < lower }
        return Self(schemaVersion: archive.schemaVersion,
                    measurements: Array(unique.values.sorted { $0.date < $1.date }.suffix(2881)),
                    limitEvents: (baseline.map { [$0] } ?? []) + events.filter { $0.date >= lower })
    }
    func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Decode before replacement: never erase a corrupt or unknown user's history.
            let prior = try Self.read(url)
            let backup = url.appendingPathExtension("v1.backup")
            if prior.schemaVersion == 1 && !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            let qualityBackup = url.appendingPathExtension("before-measurement-quality.backup")
            if prior.measurements.contains(where: { $0.measurementMetadata == nil }),
               !FileManager.default.fileExists(atPath: qualityBackup.path) {
                try FileManager.default.copyItem(at: url, to: qualityBackup)
            }
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// macOS `top` reports this activity score as POWER. It is not a watt reading.
struct EnergyApp: Identifiable, Equatable {
    let pid: Int
    let name: String
    let power: Double
    let cpu: Double
    let isApplication: Bool
    /// The owning `.app` bundle path (regular app's own bundle, or a helper's owner app),
    /// used to look up the real app icon. Nil for system processes with no `.app`.
    let iconPath: String?
    var id: Int { pid }

    init(pid: Int, name: String, power: Double, cpu: Double, isApplication: Bool, iconPath: String? = nil) {
        self.pid = pid
        self.name = name
        self.power = power
        self.cpu = cpu
        self.isApplication = isApplication
        self.iconPath = iconPath
    }
}

enum EnergySampleState: Equatable {
    case idle, loading, ready, empty, failed(String)
}

enum MonitorCadence {
    static let refreshInterval: TimeInterval = 5
    static let connectedDeviceInterval: TimeInterval = 5
    static let policyInterval: TimeInterval = 30
    static let energyInterval: TimeInterval = 60

    static func shouldEvaluatePolicy(topUpActive: Bool, trigger: ChargePolicyTrigger,
                                     elapsed: TimeInterval) -> Bool {
        trigger != .telemetry || topUpActive || elapsed >= policyInterval
    }
}

struct EnergySampleFailure: Error {
    let message: String
}

final class BatteryMonitor: ObservableObject, @unchecked Sendable {
    static let shared = BatteryMonitor()
    @Published private(set) var nativeLimit: Int?
    @Published private(set) var currentSystemLimit: Int?
    @Published private(set) var nativeLimits: [Int] = []
    @Published private(set) var otherControllerRunning = false
    @Published private(set) var applyingLimit = false
    @Published private(set) var limitMessage: String?
    @Published private(set) var controlRecoveryRequired = false
    var hardwareControlAvailable: Bool {
        chargeLimit.isFinite && (0...100).contains(chargeLimit)
            && !controlRecoveryRequired && !otherControllerRunning && !applyingLimit
            && nativeLimits.contains(Int(chargeLimit))
    }
    var topUpControlAvailable: Bool {
        if topUpActive { return !applyingLimit && !controlRecoveryRequired }
        return snapshot.externalConnected && nativeLimits.contains(100)
            && nativeLimit.map(nativeLimits.contains) == true
            && !otherControllerRunning && !applyingLimit && !controlRecoveryRequired
    }
    /// Why Doldur is locked, in the user's words; nil when it is usable.
    var topUpBlockReason: String? {
        if topUpControlAvailable { return nil }
        if otherControllerRunning { return String(localized: "Başka şarj uygulaması açıkken kilitli") }
        if controlRecoveryRequired { return String(localized: "Önceki işlem kontrol edilmeli") }
        if applyingLimit { return String(localized: "Bir işlem sürüyor") }
        if !snapshot.externalConnected { return String(localized: "Adaptör bağlı değil") }
        return String(localized: "Bu Mac'te şu an kullanılamıyor")
    }
    private let policyController: ChargePolicyController
    private let defaults: UserDefaults
    private let batteryReader: () -> BatterySnapshot
    private let nativeReader: () -> NativeChargeState?
    private let controllerRunning: () -> Bool
    private let energyReader: () -> Result<[EnergyApp], EnergySampleFailure>
    private let connectedDeviceReader: () -> [ConnectedDevice]
    private let powerModeReader: () -> SystemPowerModeProfiles?
    private let powerModeWriter: (SystemPowerMode, SystemPowerSource) -> Result<SystemPowerMode, SystemPowerModeService.WriteError>
    private let historyURL: URL
    private var pendingRequest: ChargeControlCoordinator.Request?
    @Published private(set) var cancellationRequested = false
    @Published var snapshot = BatterySnapshot()
    @Published var history: [BatteryHistoryPoint] = []
    /// Daily summaries kept for months (see LongTermHistory); the detailed history keeps 24 hours.
    @Published private(set) var dailySummaries: [DailySummary] = []
    @Published private(set) var limitEvents: [LimitEvent] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyBackupAvailable = false
    private var historyWritable = true
    private var lastHistoryBackupURL: URL?
    @Published private(set) var energyApps: [EnergyApp] = []
    @Published private(set) var energySampleDate: Date?
    @Published private(set) var energySampleState: EnergySampleState = .idle
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var selectedPowerMode = SystemPowerMode.automatic
    @Published private(set) var batteryPowerMode = SystemPowerMode.automatic
    @Published private(set) var adapterPowerMode = SystemPowerMode.automatic
    @Published private(set) var applyingPowerMode = false
    @Published private(set) var powerModeMessage: String?
    /// The value currently being edited. Moving a slider must never change the system limit.
    @Published var chargeLimit: Double {
        didSet { if chargeLimit.isFinite { defaults.set(chargeLimit, forKey: "chargeLimit") } }
    }
    /// A Healthy Battery target is only committed after the explicit native Apply readback succeeds.
    @Published private(set) var committedLimit: Int?
    @Published var sailingEnabled: Bool {
        didSet { defaults.set(sailingEnabled, forKey: "sailingEnabled") }
    }
    @Published var sailingDelta: Double {
        didSet { defaults.set(sailingDelta, forKey: "sailingDelta") }
    }
    @Published var heatProtection: Bool {
        didSet { defaults.set(heatProtection, forKey: "heatProtection") }
    }
    @Published var maxTemp: Double {
        didSet { defaults.set(maxTemp, forKey: "maxTemp") }
    }
    @Published private(set) var heatActive = false
    @Published private(set) var topUpActive = false
    @Published private(set) var policyState: ChargePolicyState = .idle
    @Published private(set) var policyConflict: (expected: Int, observed: Int)?
    @Published private(set) var controlState: ControlState = .idle
    @Published private(set) var actionMessage: String?
    enum ControlState: String { case idle, charging, pausedAtLimit, discharging, topUp, sailing, heatProtect }
    private var timer: Timer?
    private let readerQueue = DispatchQueue(label: "io.github.berkinefeavci.cellkeep.battery", qos: .utility)
    private let energyQueue = DispatchQueue(label: "io.github.berkinefeavci.cellkeep.energy", qos: .utility)
    private let controlQueue = DispatchQueue(label: "io.github.berkinefeavci.cellkeep.control", qos: .utility)
    private var reading = false
    private var energyReading = false
    private var lastNativeRead = Date.distantPast
    private var nativeObservationGeneration = 0
    private var lastEnergyRead = Date.distantPast
    private var lastConnectedDeviceRead = Date.distantPast
    private var lastPowerModeRead = Date.distantPast
    private var lastPolicyEvaluation = Date.distantPast
    private var lastExternalConnected: Bool?
    private var pendingPolicyTrigger: ChargePolicyTrigger = .startup
    var panelVisible = false
    var settingsVisible = false

    private convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep")
        let helper = Bundle.main.resourceURL?.appendingPathComponent("CellkeepNativeChargeHelper")
            ?? URL(fileURLWithPath: "/missing/CellkeepNativeChargeHelper")
        let backend = NativeChargeBackend.production(helperURL: helper)
        let rival = { !ChargeControllerDetector.current().isEmpty }
        let coordinator = ChargeControlCoordinator(journal: directory.appendingPathComponent("control-session.json"),
                                                    backend: backend, rival: rival)
        let policyController = ChargePolicyController(
            backend: backend, coordinator: coordinator,
            policyStore: ChargePolicyStore(url: directory.appendingPathComponent("charge-policy.json")),
            sessionStore: TopUpSessionStore(url: directory.appendingPathComponent("charge-session.json")),
            rival: rival)
        self.init(defaults: .standard,
                  policyController: policyController,
                  historyURL: directory.appendingPathComponent("history.json"),
                  batteryReader: { Self.readBattery() }, nativeReader: { try? backend.readState() },
                  controllerRunning: { !ChargeControllerDetector.current().isEmpty }, energyReader: { Self.readEnergyAppsResult() },
                  connectedDeviceReader: { ConnectedDeviceReader.read() },
                  powerModeReader: { SystemPowerModeService.readProfiles() })
    }

    /// Production inputs are injected as a unit so tests never fall through to hardware or user files.
    init(defaults: UserDefaults, policyController: ChargePolicyController, historyURL: URL,
         batteryReader: @escaping () -> BatterySnapshot, nativeReader: @escaping () -> NativeChargeState?,
         controllerRunning: @escaping () -> Bool, energyReader: @escaping () -> Result<[EnergyApp], EnergySampleFailure>,
         connectedDeviceReader: @escaping () -> [ConnectedDevice] = { [] },
         powerModeReader: @escaping () -> SystemPowerModeProfiles? = {
             .init(battery: .automatic, adapter: .automatic)
         },
         powerModeWriter: @escaping (SystemPowerMode, SystemPowerSource) -> Result<SystemPowerMode, SystemPowerModeService.WriteError> = {
             SystemPowerModeService.apply($0, source: $1)
         }) {
        self.defaults = defaults; self.policyController = policyController; self.historyURL = historyURL
        self.batteryReader = batteryReader; self.nativeReader = nativeReader
        self.controllerRunning = controllerRunning; self.energyReader = energyReader
        self.connectedDeviceReader = connectedDeviceReader
        self.powerModeReader = powerModeReader
        self.powerModeWriter = powerModeWriter
        chargeLimit = Self.saved(defaults, "chargeLimit", fallback: 80, range: 20...100)
        committedLimit = policyController.policy?.desiredLimit
        sailingEnabled = defaults.bool(forKey: "sailingEnabled")
        sailingDelta = Self.saved(defaults, "sailingDelta", fallback: 5, range: 2...15)
        heatProtection = defaults.object(forKey: "heatProtection") as? Bool ?? false
        maxTemp = Self.saved(defaults, "maxTemp", fallback: 35, range: 25...45)
        controlRecoveryRequired = policyController.requiresRecovery
        topUpActive = policyController.topUpActive
        policyState = policyController.state
        if controlRecoveryRequired { limitMessage = String(localized: "Önceki şarj işlemi doğrulama bekliyor; macOS Batarya ayarını kontrol edin.") }
        // v0.3 stored a single target and enabled Heat by default. Keep the user's
        // draft, but never reinterpret it as permission for automatic hardware writes.
        if defaults.integer(forKey: "preferencesSchemaVersion") < 2 {
            defaults.set(2, forKey: "preferencesSchemaVersion")
            defaults.set(false, forKey: "automaticControlEnabled")
        }
    }

    convenience init(defaults: UserDefaults, coordinator: ChargeControlCoordinator, historyURL: URL,
                     batteryReader: @escaping () -> BatterySnapshot,
                     nativeReader: @escaping () -> NativeChargeState?,
                     controllerRunning: @escaping () -> Bool,
                     energyReader: @escaping () -> Result<[EnergyApp], EnergySampleFailure>,
                     connectedDeviceReader: @escaping () -> [ConnectedDevice] = { [] },
                     powerModeReader: @escaping () -> SystemPowerModeProfiles? = {
                         .init(battery: .automatic, adapter: .automatic)
                     },
                     powerModeWriter: @escaping (SystemPowerMode, SystemPowerSource) -> Result<SystemPowerMode, SystemPowerModeService.WriteError> = {
                         SystemPowerModeService.apply($0, source: $1)
                     }) {
        let directory = historyURL.deletingLastPathComponent()
        let controller = ChargePolicyController(
            backend: coordinator.backend, coordinator: coordinator,
            policyStore: ChargePolicyStore(url: directory.appendingPathComponent("charge-policy.json")),
            sessionStore: TopUpSessionStore(url: directory.appendingPathComponent("charge-session.json")),
            rival: controllerRunning)
        self.init(defaults: defaults, policyController: controller, historyURL: historyURL,
                  batteryReader: batteryReader, nativeReader: nativeReader,
                  controllerRunning: controllerRunning, energyReader: energyReader,
                  connectedDeviceReader: connectedDeviceReader,
                  powerModeReader: powerModeReader, powerModeWriter: powerModeWriter)
    }

    static func loadHistory(from url: URL, now: Date = Date()) -> [BatteryHistoryPoint] {
        (try? HistoryArchive.read(url, now: now).measurements) ?? []
    }

    static func parseEnergyApps(_ output: String, applicationNames: [Int: String] = [:],
                                resolvedNames: [Int: String] = [:],
                                applicationIconPaths: [Int: String] = [:],
                                resolvedIconPaths: [Int: String] = [:],
                                excludingPID: Int? = nil) -> [EnergyApp] {
        guard let header = output.range(of: "PID    COMMAND", options: .backwards) else { return [] }
        let lines = output[header.upperBound...].split(whereSeparator: \.isNewline)
        guard let expression = try? NSRegularExpression(pattern: #"^\s*(\d+)\s+(.+?)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s*$"#) else { return [] }
        return lines.compactMap { line -> EnergyApp? in
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges == 5,
                  let pidRange = Range(match.range(at: 1), in: text), let pid = Int(text[pidRange]), pid > 0,
                  pid != excludingPID,
                  let commandRange = Range(match.range(at: 2), in: text),
                  let cpuRange = Range(match.range(at: 3), in: text), let cpu = Double(text[cpuRange]),
                  let powerRange = Range(match.range(at: 4), in: text), let power = Double(text[powerRange]) else { return nil }
            let applicationName: String? = applicationNames[pid]
            let rawName: String = String(text[commandRange]).trimmingCharacters(in: .whitespaces)
            let name: String = applicationName ?? resolvedNames[pid] ?? rawName
            let iconPath: String? = applicationIconPaths[pid] ?? resolvedIconPaths[pid]
            let isApplication: Bool = applicationName != nil
            return EnergyApp(pid: pid, name: name, power: power, cpu: cpu, isApplication: isApplication,
                             iconPath: iconPath)
        }.sorted { $0.power == $1.power ? $0.pid < $1.pid : $0.power > $1.power }
    }

    /// Resolves helper-process rows (which `top` truncates to a 16-character COMMAND) to a readable
    /// "Owner · what it's doing" name, for PIDs not already named by `NSWorkspace` (regular apps).
    /// Best-effort only: `KERN_PROCARGS2` fails for other users' processes, and any failure here just
    /// means the row keeps its existing fallback name (system mapping or raw truncated command).
    static func resolveHelperNames(pids: [Int], skipping applicationNames: [Int: String]) -> [Int: String] {
        resolveHelperInfo(pids: pids, skipping: applicationNames).mapValues(\.name)
    }

    /// As `resolveHelperNames`, but also carries the owner `.app` bundle path (for the real app icon).
    static func resolveHelperInfo(pids: [Int], skipping applicationNames: [Int: String])
        -> [Int: (name: String, iconPath: String?)] {
        var resolved: [Int: (name: String, iconPath: String?)] = [:]
        for pid in pids where applicationNames[pid] == nil {
            guard let path = executablePath(forPID: pid) else { continue }
            let bundlePath = EnergyPresentation.ownerBundlePath(fromExecutablePath: path)
            guard let owner = EnergyPresentation.ownerAppName(fromExecutablePath: path) else { continue }
            let role = processArguments(forPID: pid).flatMap(EnergyPresentation.role(fromArguments:))
            resolved[pid] = (role.map { "\(owner) · \($0)" } ?? owner, bundlePath)
        }
        return resolved
    }

    private static func executablePath(forPID pid: Int) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is `4 * MAXPATHLEN`; the macro itself is unavailable to Swift.
        var buffer = [Int8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Parses `KERN_PROCARGS2`'s layout: a leading `Int32` argc, the saved executable path (NUL
    /// terminated) with NUL padding, then `argc` NUL-terminated argv strings.
    private static func processArguments(forPID pid: Int) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, buffer.count >= 4 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }
        var args: [String] = []
        var current: [UInt8] = []
        var argsRead: Int32 = 0
        while offset < buffer.count, argsRead < argc {
            let byte = buffer[offset]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                argsRead += 1
            } else {
                current.append(byte)
            }
            offset += 1
        }
        return args
    }

    static func readEnergyAppsResult(timeout: TimeInterval = 5) -> Result<[EnergyApp], EnergySampleFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-n", "100", "-stats", "pid,command,cpu,power"]
        // File-backed output cannot block top on a full pipe while we wait for exit.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cellkeep-energy-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outputFile = try? FileHandle(forWritingTo: url) else {
            return .failure(EnergySampleFailure(message: String(localized: "Örnekleme dosyası oluşturulamadı.")))
        }
        defer { try? outputFile.close(); try? FileManager.default.removeItem(at: url) }
        process.standardOutput = outputFile
        process.standardError = outputFile
        guard (try? process.run()) != nil else { return .failure(EnergySampleFailure(message: String(localized: "macOS etkinlik örneklemesi başlatılamadı."))) }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            return .failure(EnergySampleFailure(message: String(localized: "macOS etkinlik örneklemesi zaman aşımına uğradı.")))
        }

        guard let reader = try? FileHandle(forReadingFrom: url) else {
            return .failure(EnergySampleFailure(message: String(localized: "Örnekleme çıktısı okunamadı.")))
        }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 262_145)) ?? Data()
        guard data.count <= 262_144 else { return .failure(EnergySampleFailure(message: String(localized: "Örnekleme çıktısı boyut sınırını aştı."))) }
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            return .failure(EnergySampleFailure(message: String(localized: "macOS etkinlik örneklemesi tamamlanamadı (\(process.terminationStatus)).")))
        }
        let runningApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // A terminating app can still be listed with pid -1; duplicate keys would trap in
        // `uniqueKeysWithValues`, so skip pid-less entries and keep the first of any repeat.
        let runningWithPID = runningApplications.filter { $0.processIdentifier > 0 }
        let applications = Dictionary(runningWithPID.map { application in
            (Int(application.processIdentifier), application.localizedName ?? application.bundleIdentifier ?? String(localized: "Uygulama"))
        }, uniquingKeysWith: { first, _ in first })
        let applicationIconPaths = Dictionary(runningWithPID.compactMap { application -> (Int, String)? in
            guard let path = application.bundleURL?.path else { return nil }
            return (Int(application.processIdentifier), path)
        }, uniquingKeysWith: { first, _ in first })
        // top already bounds this to -n 100 rows.
        let candidatePIDs = parseEnergyApps(output, applicationNames: applications, excludingPID: Int(getpid())).map(\.pid)
        let resolvedInfo = resolveHelperInfo(pids: candidatePIDs, skipping: applications)
        let resolvedNames = resolvedInfo.mapValues(\.name)
        let resolvedIconPaths = resolvedInfo.compactMapValues(\.iconPath)
        return .success(parseEnergyApps(output, applicationNames: applications, resolvedNames: resolvedNames,
                                        applicationIconPaths: applicationIconPaths, resolvedIconPaths: resolvedIconPaths,
                                        excludingPID: Int(getpid())))
    }

    private func receiveNativeState(_ state: NativeChargeState) {
        nativeLimit = state.manualLimit
        if (0...100).contains(state.manualLimit), limitEvents.last?.value != state.manualLimit {
            // Observation time, never an inferred historical date or a draft edit.
            limitEvents.append(LimitEvent(date: Date(), value: state.manualLimit))
        }
        currentSystemLimit = state.currentLimit
        nativeLimits = state.availableLimits
    }

    /// Only called by an explicit Apply action. Merely opening the app never writes.
    func applyNativeLimit() {
        precondition(Thread.isMainThread)
        otherControllerRunning = controllerRunning()
        guard hardwareControlAvailable else { return }
        let requested = Int(chargeLimit)
        let request = ChargeControlCoordinator.Request(requested)
        pendingRequest = request
        cancellationRequested = false
        nativeObservationGeneration += 1
        applyingLimit = true
        limitMessage = nil
        controlQueue.async {
            let result = self.policyController.applyManualLimit(requested, request: request)
            DispatchQueue.main.async {
                guard self.pendingRequest?.id == request.id else { return }
                self.pendingRequest = nil
                self.cancellationRequested = false
                self.applyingLimit = false
                self.lastNativeRead = .distantPast
                self.controlRecoveryRequired = self.policyController.requiresRecovery
                self.otherControllerRunning = self.controllerRunning()
                if let state = result.state { self.receiveNativeState(state) }
                if result.status == .configurationVerified {
                    self.committedLimit = requested
                    self.defaults.set(requested, forKey: "committedChargeLimit")
                }
                self.updatePolicyPresentation()
                self.limitMessage = result.message
            }
        }
    }

    func cancelLimitRequest() {
        precondition(Thread.isMainThread)
        guard let request = pendingRequest else { return }
        request.cancel()
        cancellationRequested = true
        limitMessage = String(localized: "İptal istendi. Başlamış bir macOS çağrısının sonucu bekleniyor; otomatik geri yazma yapılmaz.")
    }

    func cancelDraftLimit() {
        precondition(Thread.isMainThread)
        guard !applyingLimit, let saved = nativeLimit ?? committedLimit else { return }
        chargeLimit = Double(saved)
    }

    func reconcileNativeLimit(expectedLimit: Int) {
        precondition(Thread.isMainThread)
        guard controlRecoveryRequired, !applyingLimit else { return }
        nativeObservationGeneration += 1
        applyingLimit = true
        controlQueue.async {
            let result = self.policyController.reconcileObservedLimit(expectedLimit)
            DispatchQueue.main.async {
                self.applyingLimit = false
                self.lastNativeRead = .distantPast
                self.controlRecoveryRequired = self.policyController.requiresRecovery
                self.otherControllerRunning = self.controllerRunning()
                if let state = result.state { self.receiveNativeState(state) }
                self.updatePolicyPresentation()
                self.limitMessage = result.message
            }
        }
    }

    /// User-initiated only: graceful `terminate()` of competing charge controller apps, then a
    /// re-check so the write controls unlock without waiting for the next refresh. Background
    /// daemons and boot-time launchd jobs of such tools cannot be quit from here and keep the lock.
    func quitOtherChargeController() {
        precondition(Thread.isMainThread)
        let prefixes = ChargeControllerDetector.quittableBundlePrefixes(home: FileManager.default.homeDirectoryForCurrentUser.path)
        for app in NSWorkspace.shared.runningApplications
        where prefixes.contains(where: { app.bundleIdentifier?.hasPrefix($0) == true }) {
            app.terminate()
        }
        for delay in [1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.otherControllerRunning = self.controllerRunning()
            }
        }
    }

    func startTopUp(originExecutionID: UUID? = nil) {
        precondition(Thread.isMainThread)
        guard !applyingLimit else { return }
        applyingLimit = true
        actionMessage = nil
        let telemetry = Self.telemetry(from: snapshot)
        controlQueue.async { [weak self] in
            guard let self else { return }
            let result = self.policyController.startTopUp(originExecutionID: originExecutionID,
                                                          telemetry: telemetry)
            DispatchQueue.main.async {
                self.applyingLimit = false
                self.lastNativeRead = .distantPast
                if let state = result.state { self.receiveNativeState(state) }
                self.updatePolicyPresentation()
                self.actionMessage = result.message
            }
        }
    }

    func stopTopUp() {
        precondition(Thread.isMainThread)
        guard topUpActive, !applyingLimit else { return }
        applyingLimit = true
        let telemetry = Self.telemetry(from: snapshot)
        controlQueue.async { [weak self] in
            guard let self else { return }
            let result = self.policyController.cancelTopUp(telemetry: telemetry)
            DispatchQueue.main.async {
                self.applyingLimit = false
                self.lastNativeRead = .distantPast
                if let state = result.state { self.receiveNativeState(state) }
                self.updatePolicyPresentation()
                self.actionMessage = result.message
            }
        }
    }

    func handleWake() {
        precondition(Thread.isMainThread)
        pendingPolicyTrigger = .wake
        lastNativeRead = .distantPast
        refresh()
    }

    var scheduleOperationActive: Bool { policyController.isBusy }

    var scheduleCapabilities: ScheduleCapabilities {
        .init(chargeLimits: nativeLimits,
              topUpAvailable: nativeLimits.contains(100) && nativeLimit.map(nativeLimits.contains) == true
                  && !controlRecoveryRequired && !otherControllerRunning,
              powerModes: SystemPowerModeService.availableModes())
    }

    func applyScheduledLimit(_ limit: Int) -> ChargeControlCoordinator.Result {
        controlQueue.sync { policyController.applyManualLimit(limit, source: .schedule) }
    }

    /// Isı koruması gibi otomasyonlar için eşzamanlı yazma; ana iş parçacığı dışından çağrılmalı.
    /// Sonuç okunan yerel durum ana kuyrukta yayınlanır, böylece sonraki karar eski değeri görmez.
    func applyAutomationLimit(_ limit: Int, source: ChargeControlCoordinator.Source) -> ChargeControlCoordinator.Result {
        let result = controlQueue.sync { policyController.applyManualLimit(limit, source: source) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastNativeRead = .distantPast
            if let state = result.state { self.receiveNativeState(state) }
            self.updatePolicyPresentation()
        }
        return result
    }

    func startScheduledTopUp(executionID: UUID) -> ChargeControlCoordinator.Result {
        precondition(Thread.isMainThread)
        let telemetry = Self.telemetry(from: snapshot)
        return controlQueue.sync {
            policyController.startTopUp(originExecutionID: executionID, telemetry: telemetry)
        }
    }

    @MainActor
    func applyShortcutLimit(_ limit: Int) async -> ChargeControlCoordinator.Result {
        guard !applyingLimit else { return busyShortcutResult() }
        applyingLimit = true
        limitMessage = nil
        return await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: Self.unavailableShortcutResult())
                    return
                }
                let result = self.policyController.applyManualLimit(limit, source: .shortcut)
                DispatchQueue.main.async {
                    self.applyingLimit = false
                    self.lastNativeRead = .distantPast
                    self.controlRecoveryRequired = self.policyController.requiresRecovery
                    self.otherControllerRunning = self.controllerRunning()
                    if let state = result.state { self.receiveNativeState(state) }
                    if result.status == .configurationVerified { self.chargeLimit = Double(limit) }
                    self.updatePolicyPresentation()
                    self.limitMessage = result.message
                    continuation.resume(returning: result)
                }
            }
        }
    }

    @MainActor
    func startShortcutTopUp(snapshot liveSnapshot: BatterySnapshot? = nil) async -> ChargeControlCoordinator.Result {
        guard !applyingLimit else { return busyShortcutResult() }
        applyingLimit = true
        actionMessage = nil
        let telemetry = Self.telemetry(from: liveSnapshot ?? snapshot)
        return await runShortcutTopUp { [policyController] in
            policyController.startTopUp(telemetry: telemetry)
        }
    }

    @MainActor
    func cancelShortcutTopUp(snapshot liveSnapshot: BatterySnapshot? = nil) async -> ChargeControlCoordinator.Result {
        guard !applyingLimit else { return busyShortcutResult() }
        applyingLimit = true
        actionMessage = nil
        let telemetry = Self.telemetry(from: liveSnapshot ?? snapshot)
        return await runShortcutTopUp { [policyController] in
            policyController.cancelTopUp(telemetry: telemetry)
        }
    }

    @MainActor
    private func runShortcutTopUp(_ operation: @escaping () -> ChargeControlCoordinator.Result) async
        -> ChargeControlCoordinator.Result {
        await withCheckedContinuation { continuation in
            controlQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: Self.unavailableShortcutResult())
                    return
                }
                let result = operation()
                DispatchQueue.main.async {
                    self.applyingLimit = false
                    self.lastNativeRead = .distantPast
                    if let state = result.state { self.receiveNativeState(state) }
                    self.updatePolicyPresentation()
                    self.actionMessage = result.message
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func busyShortcutResult() -> ChargeControlCoordinator.Result {
        .init(operationID: UUID(), status: .busy, state: nil,
              message: String(localized: "Bir şarj işlemi zaten sürüyor."))
    }

    private static func unavailableShortcutResult() -> ChargeControlCoordinator.Result {
        .init(operationID: UUID(), status: .rejected, state: nil,
              message: String(localized: "Healthy Battery denetimi kullanılamıyor."))
    }

    func reapplyChargeMateTarget() {
        precondition(Thread.isMainThread)
        guard !applyingLimit else { return }
        applyingLimit = true
        controlQueue.async { [weak self] in
            guard let self else { return }
            let result = self.policyController.reapplyPolicy()
            DispatchQueue.main.async {
                self.applyingLimit = false
                if let state = result.state { self.receiveNativeState(state) }
                self.updatePolicyPresentation()
                self.limitMessage = result.message
            }
        }
    }

    func adoptMacOSLimit() {
        precondition(Thread.isMainThread)
        guard !applyingLimit else { return }
        applyingLimit = true
        controlQueue.async { [weak self] in
            guard let self else { return }
            let message: String
            do { try self.policyController.adoptObservedLimit(); message = String(localized: "macOS limiti Healthy Battery hedefi olarak benimsendi.") }
            catch { message = String(localized: "macOS limiti benimsenemedi: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                self.applyingLimit = false
                self.updatePolicyPresentation()
                self.limitMessage = message
            }
        }
    }

    private static func saved(_ defaults: UserDefaults, _ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    func start() {
        precondition(Thread.isMainThread)
        guard timer == nil else { return }
        do {
            let archive = try HistoryArchive.read(historyURL)
            history = archive.measurements; limitEvents = archive.limitEvents
            dailySummaries = LongTermHistory.read(dailySummaryURL)
        } catch {
            historyWritable = false
            historyError = String(localized: "Geçmiş okunamadı; özgün dosya korunuyor. Yeni ölçümler bu oturumda bellekte tutuluyor.")
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: MonitorCadence.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
    }

    func stop() { timer?.invalidate(); timer = nil }

    private var dailySummaryURL: URL {
        historyURL.deletingLastPathComponent().appendingPathComponent("daily-summary.json")
    }

    /// Recomputes today's (and, while still in the 24-hour window, yesterday's) summary from the
    /// detailed history and merges it into the long-term record.
    private func updateDailySummaries(now: Date) {
        let samples = history.map { point in
            LongTermHistory.Sample(date: point.date, percentage: point.percentage, healthPercent: point.healthPercent,
                                   fullCapacityMAh: point.fullCapacityMAh, cycleCount: point.cycleCount,
                                   temperatureC: point.temperatureC)
        }
        dailySummaries = LongTermHistory.merge(stored: dailySummaries,
                                               fresh: LongTermHistory.summarize(samples, calendar: .current),
                                               newestDay: LongTermHistory.dayKey(now, calendar: .current))
    }

    /// User-initiated only. Serialize behind pending history writes, create a local backup,
    /// then replace the archive atomically. Charging preferences and native state are untouched.
    func clearHistoryWithBackup(completion: @escaping (String) -> Void) {
        precondition(Thread.isMainThread)
        guard !applyingLimit else {
            completion(String(localized: "Şarj limiti işlemi sürerken geçmiş değiştirilmedi."))
            return
        }
        historyWritable = false
        let url = historyURL
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent().appendingPathComponent("history-before-clear-\(stamp).json")
        let currentArchive = HistoryArchive(schemaVersion: 2, measurements: history, limitEvents: limitEvents)
        readerQueue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.copyItem(at: url, to: backup)
                } else {
                    try JSONEncoder().encode(currentArchive).write(to: backup, options: .atomic)
                }
                try JSONEncoder().encode(HistoryArchive(schemaVersion: 2, measurements: [], limitEvents: []))
                    .write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self.history = []
                    self.limitEvents = []
                    self.lastHistoryBackupURL = backup
                    self.historyBackupAvailable = true
                    self.historyWritable = true
                    self.historyError = nil
                    completion(String(localized: "Geçmiş temizlendi; yerel yedek geri alınabilir."))
                }
            } catch {
                DispatchQueue.main.async {
                    self.historyWritable = true
                    completion(String(localized: "Geçmiş değiştirilmedi: yedek oluşturulamadı."))
                }
            }
        }
    }

    func restoreHistoryBackup(completion: @escaping (String) -> Void) {
        precondition(Thread.isMainThread)
        guard !applyingLimit, let backup = lastHistoryBackupURL else {
            completion(applyingLimit ? String(localized: "Şarj limiti işlemi sürerken geçmiş değiştirilmedi.") : String(localized: "Geri alınabilir geçmiş yedeği yok."))
            return
        }
        historyWritable = false
        let url = historyURL
        readerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let archive = try HistoryArchive.read(backup)
                try Data(contentsOf: backup).write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self.history = archive.measurements
                    self.limitEvents = archive.limitEvents
                    self.lastHistoryBackupURL = nil
                    self.historyBackupAvailable = false
                    self.historyWritable = true
                    self.historyError = nil
                    completion(String(localized: "Geçmiş yedeği geri alındı."))
                }
            } catch {
                DispatchQueue.main.async {
                    self.historyWritable = true
                    completion(String(localized: "Geçmiş yedeği geri alınamadı; yedek dosya korundu."))
                }
            }
        }
    }

    func refresh() {
        precondition(Thread.isMainThread)
        guard !reading else { return }
        reading = true
        otherControllerRunning = controllerRunning()
        let readNative = !applyingLimit && Date().timeIntervalSince(lastNativeRead) >= 30
        let nativeGeneration = nativeObservationGeneration
        let wantsEnergy = panelVisible || settingsVisible || defaults.bool(forKey: "backgroundDashboardUpdates")
        let readEnergy = wantsEnergy && !energyReading && Date().timeIntervalSince(lastEnergyRead) >= MonitorCadence.energyInterval
        let readConnectedDevices = Date().timeIntervalSince(lastConnectedDeviceRead) >= MonitorCadence.connectedDeviceInterval
        let readPowerMode = !applyingPowerMode && Date().timeIntervalSince(lastPowerModeRead) >= 15
        if readNative { lastNativeRead = Date() }
        if readEnergy {
            lastEnergyRead = Date()
            energyReading = true
            energySampleState = .loading
            energyQueue.async { [weak self] in
                guard let self else { return }
                let result = self.energyReader()
                DispatchQueue.main.async {
                    self.energyReading = false
                    switch result {
                    case .success(let apps):
                        self.energyApps = apps
                        self.energySampleDate = Date()
                        self.energySampleState = apps.isEmpty ? .empty : .ready
                    case .failure(let failure):
                        self.energySampleState = .failed(failure.message)
                    }
                }
            }
        }
        if readConnectedDevices { lastConnectedDeviceRead = Date() }
        if readPowerMode { lastPowerModeRead = Date() }
        readerQueue.async { [weak self] in
            guard let self else { return }
            let value = self.batteryReader()
            let native = readNative ? self.nativeReader() : nil
            let devices = readConnectedDevices ? self.connectedDeviceReader() : nil
            let powerModes = readPowerMode ? self.powerModeReader() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                self.snapshot = value
                if let devices { self.connectedDevices = devices }
                self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                if let powerModes {
                    self.batteryPowerMode = powerModes.battery
                    self.adapterPowerMode = powerModes.adapter
                }
                self.selectedPowerMode = value.externalConnected ? self.adapterPowerMode : self.batteryPowerMode
                if let native, nativeGeneration == self.nativeObservationGeneration, !self.applyingLimit {
                    self.receiveNativeState(native)
                }
                let trigger: ChargePolicyTrigger
                if self.pendingPolicyTrigger != .telemetry {
                    trigger = self.pendingPolicyTrigger
                    self.pendingPolicyTrigger = .telemetry
                } else if self.lastExternalConnected == true, !value.externalConnected,
                          self.policyController.topUpActive {
                    trigger = .powerSourceChange
                } else {
                    trigger = .telemetry
                }
                self.lastExternalConnected = value.externalConnected
                let policyElapsed = Date().timeIntervalSince(self.lastPolicyEvaluation)
                if MonitorCadence.shouldEvaluatePolicy(topUpActive: self.policyController.topUpActive,
                                                       trigger: trigger, elapsed: policyElapsed) {
                    self.lastPolicyEvaluation = Date()
                    let telemetry = Self.telemetry(from: value)
                    self.controlQueue.async { [weak self] in
                        guard let self else { return }
                        let priorOperation = self.policyController.lastResult?.operationID
                        let event = self.policyController.evaluate(telemetry: telemetry, trigger: trigger)
                        let result = self.policyController.lastResult
                        DispatchQueue.main.async {
                            if result?.operationID != priorOperation, let native = result?.state {
                                self.receiveNativeState(native)
                            }
                            self.updatePolicyPresentation(event: event)
                        }
                    }
                }
                // Observed hardware state only. Saved preferences cannot claim control before a writer exists.
                self.controlState = !value.available ? .idle : value.isCharging ? .charging : value.state == .paused ? .pausedAtLimit : .discharging
                let now = Date()
                if value.available && (self.history.last.map { now.timeIntervalSince($0.date) >= 30 } ?? true) {
                    self.history.append(Self.historyPoint(value, now: now))
                    self.history.removeAll { now.timeIntervalSince($0.date) > 86400 }
                    let lower = now.addingTimeInterval(-86400)
                    let baseline = self.limitEvents.last { $0.date < lower }
                    self.limitEvents = (baseline.map { [$0] } ?? []) + self.limitEvents.filter { $0.date >= lower }
                    let archive = HistoryArchive(schemaVersion: 2, measurements: self.history, limitEvents: self.limitEvents)
                    self.updateDailySummaries(now: now)
                    let summaries = self.dailySummaries
                    if self.historyWritable { self.readerQueue.async {
                        try? LongTermHistory.write(summaries, to: self.dailySummaryURL)
                        do {
                            try archive.write(self.historyURL)
                            DispatchQueue.main.async { self.historyError = nil }
                        } catch {
                            DispatchQueue.main.async { self.historyError = String(localized: "Geçmiş kaydedilemiyor: \(error.localizedDescription)") }
                        }
                    } }
                }
            }
        }
    }

    private static func telemetry(from snapshot: BatterySnapshot) -> ChargeTelemetry {
        ChargeTelemetry(sampledAt: snapshot.sampledAt,
                        percentage: snapshot.percentage ?? snapshot.hardwarePercentage ?? 0,
                        hardwarePercentage: snapshot.hardwarePercentage ?? snapshot.percentage ?? 0,
                        isCharging: snapshot.isCharging,
                        externalConnected: snapshot.externalConnected,
                        fullyCharged: snapshot.fullyCharged,
                        batteryWatts: snapshot.wattage ?? 0)
    }

    private func updatePolicyPresentation(event: ChargePolicyEvent? = nil) {
        precondition(Thread.isMainThread)
        policyState = policyController.state
        policyConflict = policyController.conflict
        topUpActive = policyController.topUpActive
        controlRecoveryRequired = policyController.requiresRecovery
        if let desired = policyController.policy?.desiredLimit {
            committedLimit = desired
            defaults.set(desired, forKey: "committedChargeLimit")
        }
        switch policyState {
        case .topUpStarting, .topUpCharging: controlState = .topUp
        case .topUpRestoring: controlState = .topUp
        case .recoveryRequired(let message): actionMessage = message
        case .pausedByConflict(let expected, let observed):
            actionMessage = String(localized: "Healthy Battery hedefi %\(expected), macOS ayarı %\(observed). Seçiminizi yapın.")
        case .maintainingLimit: if !topUpActive { actionMessage = nil }
        case .idle: break
        }
        guard let event else { return }
        actionMessage = event.message
        NotificationCenter.default.post(name: .chargeMatePolicyEvent, object: event)
    }

    func applyPowerMode(_ mode: SystemPowerMode) {
        applyPowerMode(mode, source: .all)
    }

    func applyPowerMode(_ mode: SystemPowerMode, source: SystemPowerSource) {
        precondition(Thread.isMainThread)
        guard !applyingPowerMode else { return }
        applyingPowerMode = true
        powerModeMessage = nil
        controlQueue.async { [weak self] in
            guard let self else { return }
            let result = self.powerModeWriter(mode, source)
            DispatchQueue.main.async {
                switch result {
                case .success(let confirmed):
                    switch source {
                    case .battery: self.batteryPowerMode = confirmed
                    case .adapter: self.adapterPowerMode = confirmed
                    case .all:
                        self.batteryPowerMode = confirmed
                        self.adapterPowerMode = confirmed
                    }
                    self.selectedPowerMode = self.snapshot.externalConnected ? self.adapterPowerMode : self.batteryPowerMode
                    self.powerModeMessage = nil
                case .failure(let error):
                    self.powerModeMessage = error.localizedDescription
                }
                self.applyingPowerMode = false
                self.lastPowerModeRead = .distantPast
                self.refresh()
            }
        }
    }

    static func historyPoint(_ snapshot: BatterySnapshot, now: Date) -> BatteryHistoryPoint {
        func value(_ field: BatteryField) -> Double? { snapshot.reading(field, now: now).validValue }
        return BatteryHistoryPoint(date: now, percentage: value(.percentage).map(Int.init), wattage: value(.batteryPower),
            temperatureC: value(.temperature), systemWatts: value(.systemPower), healthPercent: value(.health),
            cycleCount: value(.cycles).map(Int.init), hardwarePercentage: value(.hardwarePercentage).map(Int.init),
            batteryCurrentMA: value(.current), batteryVoltageV: value(.voltage),
            remainingCapacityMAh: value(.remainingCapacity).map(Int.init), fullCapacityMAh: value(.fullCapacity).map(Int.init),
            temperatureSource: snapshot.sources[.temperature],
            measurementMetadata: Dictionary(uniqueKeysWithValues: BatteryField.allCases.map {
                ($0.rawValue, snapshot.reading($0, now: now).metadata)
            }))
    }

    static func readBattery(useSMC: Bool = true) -> BatterySnapshot {
        var s = BatterySnapshot()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                s.available = true
                if let percentage = desc[kIOPSCurrentCapacityKey] as? Int, (0...100).contains(percentage) {
                    s.percentage = percentage
                    s.sources[.percentage] = "IOPS CurrentCapacity"
                }
                s.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                s.externalConnected = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                // TimeToEmpty=0 while paused on AC is not an estimate of emptying.
                if s.isCharging || !s.externalConnected,
                   let minutes = desc[s.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int, minutes >= 0 {
                    s.timeRemainingMinutes = minutes
                    s.sources[.timeRemaining] = s.isCharging ? "IOPS TimeToFullCharge" : "IOPS TimeToEmpty"
                }
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {
                applyRegistry(dict, to: &s)
            }
            if s.temperatureC == nil {
                var children: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                    defer { IOObjectRelease(children) }
                    while case let child = IOIteratorNext(children), child != 0 {
                        defer { IOObjectRelease(child) }
                        guard IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0,
                              let property = IORegistryEntryCreateCFProperty(child, "BatteryData" as CFString, kCFAllocatorDefault, 0),
                              let data = property.takeRetainedValue() as? [String: Any],
                              let raw = data["Temperature"] as? NSNumber,
                              (-4000...10000).contains(raw.doubleValue) else { continue }
                        s.temperatureC = raw.doubleValue / 100
                        s.temperatureSource = "IOKit Battery Pack"
                        s.sources[.temperature] = "IOKit Battery Pack.Temperature"
                        s.invalidFields.remove(.temperature)
                        break
                    }
                }
            }
        }
        if useSMC, let value = SMCReader.shared.batteryTemperature(), let temperature = value.number,
           temperature.isFinite, (-40...100).contains(temperature) {
            s.temperatureC = temperature
            s.temperatureSource = "SMC \(value.key) (\(value.type.trimmingCharacters(in: .whitespaces)))"
            s.sources[.temperature] = s.temperatureSource
            s.invalidFields.remove(.temperature)
        }
        if useSMC {
            let powers = SMCReader.shared.componentPowers()
            if let value = powers.system {
                s.systemWatts = value.watts
                s.sources[.systemPower] = "SMC \(value.key)"
                s.invalidFields.remove(.systemPower)
            }
            if let value = powers.processor {
                s.processorWatts = value.watts
                s.sources[.processorPower] = "SMC \(value.key)"
                s.invalidFields.remove(.processorPower)
            }
            if let value = powers.display {
                s.displayWatts = value.watts
                s.sources[.displayPower] = "SMC \(value.key)"
                s.invalidFields.remove(.displayPower)
            }
        }
        return s
    }

    static func applyRegistry(_ dict: [String: Any], to s: inout BatterySnapshot) {
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? { (dict[key] ?? data[key]) as? NSNumber }
        // Capacities/cycles must convert to Int without overflow, fraction or truncation.
        // Zero is valid for remaining charge and cycles; denominator capacities require >0.
        func integer(_ value: Double) -> Bool { value >= 0 && value < Double(Int.max) && value.rounded() == value }
        func decode(_ field: BatteryField, _ keys: [String], valid: (Double) -> Bool = { $0 >= 0 },
                    convert: (NSNumber) -> Double = { $0.doubleValue }) -> Double? {
            for key in keys {
                for (container, prefix) in [(dict, "IOKit"), (data, "IOKit BatteryData")] {
                    guard let raw = container[key] else { continue }
                    s.sources[field] = "\(prefix).\(key)"
                    guard let numeric = raw as? NSNumber, numeric.doubleValue.isFinite else {
                        s.invalidFields.insert(field); continue
                    }
                    let value = convert(numeric)
                    guard value.isFinite, valid(value) else { s.invalidFields.insert(field); continue }
                    s.sources[field] = "\(prefix).\(key)"
                    s.invalidFields.remove(field)
                    return value
                }
            }
            return nil
        }
        s.available = true
        // IOPS is the display percentage source; registry is its explicit fallback.
        if s.percentage == nil {
            s.percentage = decode(.percentage, ["CurrentCapacity"], valid: { integer($0) && $0 <= 100 }).map(Int.init)
        }
        let full = decode(.fullCapacity, ["AppleRawMaxCapacity", "FullChargeCapacity", "NominalChargeCapacity"], valid: { integer($0) && $0 > 0 })
        let current = decode(.remainingCapacity, ["AppleRawCurrentCapacity", "RemainingCapacity"], valid: integer)
        s.remainingCapacity = current.map(Int.init)
        s.hardwarePercentage = nil
        if let full, let current {
            let percent = current / full * 100
            if percent.isFinite && (0...100).contains(percent) {
                s.hardwarePercentage = Int(percent.rounded())
                s.sources[.hardwarePercentage] = "\(s.sources[.remainingCapacity] ?? "") / \(s.sources[.fullCapacity] ?? "")"
            } else { s.invalidFields.insert(.hardwarePercentage) }
        }
        s.externalConnected = number("ExternalConnected")?.boolValue ?? s.externalConnected
        s.isCharging = number("IsCharging")?.boolValue ?? s.isCharging
        s.fullyCharged = number("FullyCharged")?.boolValue ?? false
        // Existing sensor decoder guard: -40...100 °C rejects corrupt telemetry,
        // not a claim about a safe operating temperature for the battery.
        if let t = decode(.temperature, ["Temperature"], valid: { (-4000...10000).contains($0) }) {
            s.temperatureC = t / 100
            s.temperatureSource = "IOKit"
        }
        s.voltage = decode(.voltage, ["Voltage"]).map { $0 / 1000 }
        // NSNumber.int64Value preserves the signed two's-complement battery current.
        s.amperage = decode(.current, ["InstantAmperage", "Amperage"], valid: { _ in true }, convert: {
            CFNumberIsFloatType($0) ? $0.doubleValue : Double($0.int64Value)
        })
        s.wattage = nil
        if let voltage = s.voltage, let current = s.amperage {
            let power = voltage * current / 1000
            if power.isFinite {
                s.wattage = power
                s.sources[.batteryPower] = "\(s.sources[.voltage] ?? "") × \(s.sources[.current] ?? "") / 1000"
            } else { s.invalidFields.insert(.batteryPower) }
        }
        s.batteryPowerAvailable = s.wattage != nil
        s.cycleCount = decode(.cycles, ["CycleCount"], valid: integer).map(Int.init)
        s.nominalChargeCapacity = full.map(Int.init)
        s.designCapacity = decode(.designCapacity, ["DesignCapacity"], valid: { integer($0) && $0 > 0 }).map(Int.init)
        // Health follows macOS "Maximum Capacity": the reserve-inclusive nominal capacity over design,
        // capped at 100. FullChargeCapacity is the usable charge; the gauge re-estimates it with
        // temperature and load (±2–3 points a day), so it is shown separately, not as health.
        s.healthPercent = nil
        let nominal = decode(.health, ["NominalChargeCapacity"], valid: { integer($0) && $0 > 0 })
        if let capacity = nominal ?? full, let design = s.designCapacity {
            s.healthPercent = min(100, capacity / Double(design) * 100)
            let source = nominal == nil ? s.sources[.fullCapacity] : "IOKit BatteryData.NominalChargeCapacity"
            s.sources[.health] = "\(source ?? "") / \(s.sources[.designCapacity] ?? "") (≤100)"
            s.invalidFields.remove(.health)
        }
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        func external(_ field: BatteryField, _ container: [String: Any], _ prefix: String, _ key: String, scale: Double = 1) -> Double? {
            guard let raw = container[key] else { return nil }
            s.sources[field] = "\(prefix).\(key)"
            guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else {
                s.invalidFields.insert(field); return nil
            }
            s.sources[field] = "\(prefix).\(key)"
            return number.doubleValue / scale
        }
        s.adapterWatts = s.externalConnected ? external(.adapterPower, telemetry, "IOKit PowerTelemetryData", "SystemPowerIn", scale: 1000) : nil
        s.systemWatts = external(.systemPower, telemetry, "IOKit PowerTelemetryData", "SystemLoad", scale: 1000)
        let adapter = dict["AdapterDetails"] as? [String: Any] ?? [:]
        s.adapterRatedWatts = external(.adapterRatedPower, adapter, "IOKit AdapterDetails", "Watts")
        s.adapterVoltage = external(.adapterVoltage, adapter, "IOKit AdapterDetails", "AdapterVoltage", scale: 1000)
        s.adapterAmperage = external(.adapterCurrent, adapter, "IOKit AdapterDetails", "Current", scale: 1000)
    }

    var temperatureText: String { snapshot.reading(.temperature).text() }
    /// Percent in the UI language's order (`%100` in Turkish, `100%` in English) — used wherever
    /// the charge bar and its accessibility value show battery percentage.
    var percentageText: String {
        guard let value = snapshot.reading(.percentage).validValue else { return "—" }
        return String(localized: "%\(Int(value.rounded()))")
    }
    var statusSentence: String {
        guard snapshot.available else { return String(localized: "Batarya verisi bekleniyor.") }
        switch snapshot.powerFlow.mode {
        case .charging:
            return String(localized: "Adaptör MacBook’u çalıştırıyor ve bataryayı şarj ediyor. \(otherControllerRunning ? String(localized: "Şarj yönetimi için başka bir uygulama açık.") : String(localized: "macOS’un bildirdiği şarj durumu izleniyor."))")
        case .adapterOnly:
            return String(localized: "Şarj beklemede. MacBook adaptörden çalışıyor; batarya şu anda güç almıyor. \(otherControllerRunning ? String(localized: "Başka bir şarj uygulaması açık olduğu için Healthy Battery ayar değiştirmiyor.") : String(localized: "Uyku davranışını macOS yönetiyor."))")
        case .batteryOnly:
            return String(localized: "Batarya MacBook’a güç sağlıyor. Adaptör bağlı değil.")
        case .batteryAssist:
            return String(localized: "Adaptör ve batarya birlikte MacBook’a güç sağlıyor.")
        case .unavailable:
            return String(localized: "Güç akışı ölçümleri bekleniyor.")
        }
    }
}
