import AppIntents
import Foundation

enum ShortcutBatterySource: String, AppEnum {
    case macOS
    case hardware

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pil yüzdesi kaynağı")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .macOS: "macOS yüzdesi",
        .hardware: "Donanım yüzdesi"
    ]

    var core: ChargeMateShortcutBatterySource { self == .macOS ? .macOS : .hardware }
}

enum ShortcutLimitSource: String, AppEnum {
    case committed
    case nativeManual
    case nativeCurrent

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Şarj limiti kaynağı")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .committed: "Healthy Battery hedefi",
        .nativeManual: "macOS manuel limiti",
        .nativeCurrent: "macOS geçerli limiti"
    ]

    var core: ChargeMateShortcutLimitSource {
        switch self {
        case .committed: return .committed
        case .nativeManual: return .nativeManual
        case .nativeCurrent: return .nativeCurrent
        }
    }
}

enum ShortcutChargeLimit: Int, AppEnum {
    case percent80 = 80
    case percent85 = 85
    case percent90 = 90
    case percent95 = 95
    case percent100 = 100

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Şarj hedefi")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .percent80: "%80", .percent85: "%85", .percent90: "%90",
        .percent95: "%95", .percent100: "%100"
    ]
}

enum ShortcutTopUpAction: String, AppEnum {
    case start
    case cancel

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Top Up eylemi")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .start: "Başlat", .cancel: "İptal et"
    ]
}

enum ShortcutPowerMode: String, AppEnum {
    case automatic
    case lowPower
    case turbo

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Güç modu")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .automatic: "Otomatik", .lowPower: "Tasarruf", .turbo: "Turbo"
    ]

    var system: SystemPowerMode {
        switch self {
        case .automatic: return .automatic
        case .lowPower: return .lowPower
        case .turbo: return .turbo
        }
    }
}

enum ShortcutMagSafeOutput: String, AppEnum {
    case system
    case green
    case orange
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "MagSafe ışığı")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .system: "Sistem", .green: "Yeşil", .orange: "Turuncu", .off: "Kapalı"
    ]

    var hardware: MagSafeLEDOutput {
        switch self {
        case .system: return .system
        case .green: return .green
        case .orange: return .orange
        case .off: return .off
        }
    }
}

struct GetBatteryPercentageIntent: AppIntent {
    static let title: LocalizedStringResource = "Pil Yüzdesini Al"
    static let description = IntentDescription("macOS veya donanım pil yüzdesini sayısal değer olarak döndürür.")
    static let openAppWhenRun = false

    @Parameter(title: "Kaynak", default: .macOS)
    var source: ShortcutBatterySource

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try await ChargeMateShortcutService.batteryPercentage(source.core))
    }
}

struct GetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Şarj Limitini Al"
    static let description = IntentDescription("Healthy Battery hedefini veya macOS native limitini döndürür.")
    static let openAppWhenRun = false

    @Parameter(title: "Kaynak", default: .committed)
    var source: ShortcutLimitSource

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        .result(value: try await ChargeMateShortcutService.chargeLimit(source.core))
    }
}

struct GetChargeMateStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Healthy Battery Durumunu Al"
    static let description = IntentDescription("Kararlı Healthy Battery durum adını döndürür.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ChargeMateShortcutService.state().rawValue)
    }
}

struct GetBatteryTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Batarya Sıcaklığını Al"
    static let description = IntentDescription("Batarya sıcaklığını sayısal Celsius değeri olarak döndürür.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        .result(value: try await ChargeMateShortcutService.temperatureCelsius())
    }
}

struct SetChargeLimitIntent: AppIntent {
    static let title: LocalizedStringResource = "Şarj Limitini Ayarla"
    static let description = IntentDescription("Desteklenen hedefi Healthy Battery'in güvenli şarj denetim hattından uygular.")
    static let openAppWhenRun = false

    @Parameter(title: "Hedef")
    var limit: ShortcutChargeLimit

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ChargeMateShortcutService.setChargeLimit(limit.rawValue))
    }
}

struct ControlTopUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Top Up Denetle"
    static let description = IntentDescription("Top Up işlemini başlatır veya önceki limite dönerek iptal eder.")
    static let openAppWhenRun = false

    @Parameter(title: "Eylem")
    var action: ShortcutTopUpAction

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ChargeMateShortcutService.controlTopUp(start: action == .start))
    }
}

struct SetPowerModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Güç Modunu Ayarla"
    static let description = IntentDescription("Önceden etkinleştirilmiş Healthy Battery yardımcısıyla macOS güç modunu değiştirir.")
    static let openAppWhenRun = false

    @Parameter(title: "Mod")
    var mode: ShortcutPowerMode

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ChargeMateShortcutService.setPowerMode(mode.system))
    }
}

struct SetMagSafeLightIntent: AppIntent {
    static let title: LocalizedStringResource = "MagSafe Işığını Ayarla"
    static let description = IntentDescription("Önceden etkinleştirilmiş Healthy Battery LED denetimiyle MagSafe ışığını değiştirir.")
    static let openAppWhenRun = false

    @Parameter(title: "Işık")
    var output: ShortcutMagSafeOutput

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await ChargeMateShortcutService.setMagSafe(output.hardware))
    }
}

struct ChargeMateAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetBatteryPercentageIntent(),
                    phrases: ["\(.applicationName) ile pil yüzdesini öğren"],
                    shortTitle: "Pil yüzdesi", systemImageName: "battery.75percent")
        AppShortcut(intent: GetChargeLimitIntent(),
                    phrases: ["\(.applicationName) şarj limitini öğren"],
                    shortTitle: "Şarj limiti", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(intent: GetChargeMateStateIntent(),
                    phrases: ["\(.applicationName) durumunu öğren"],
                    shortTitle: "Healthy Battery durumu", systemImageName: "bolt.shield")
        AppShortcut(intent: GetBatteryTemperatureIntent(),
                    phrases: ["\(.applicationName) batarya sıcaklığını öğren"],
                    shortTitle: "Batarya sıcaklığı", systemImageName: "thermometer.medium")
        AppShortcut(intent: SetChargeLimitIntent(),
                    phrases: ["\(.applicationName) şarj limitini ayarla"],
                    shortTitle: "Limiti ayarla", systemImageName: "battery.100percent")
        AppShortcut(intent: ControlTopUpIntent(),
                    phrases: ["\(.applicationName) Top Up denetle"],
                    shortTitle: "Top Up", systemImageName: "plus.circle")
        AppShortcut(intent: SetPowerModeIntent(),
                    phrases: ["\(.applicationName) güç modunu ayarla"],
                    shortTitle: "Güç modu", systemImageName: "speedometer")
        AppShortcut(intent: SetMagSafeLightIntent(),
                    phrases: ["\(.applicationName) MagSafe ışığını ayarla"],
                    shortTitle: "MagSafe ışığı", systemImageName: "light.beacon.max")
    }
}

private enum ChargeMateShortcutService {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Value, Error>?
        func set(_ result: Result<Value, Error>) { lock.lock(); value = result; lock.unlock() }
        func get() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct MonitorValues {
        let committedLimit: Int?
        let state: ChargeMateShortcutState
    }

    private static func withinDeadline<Value>(_ operation: @escaping () throws -> Value) throws -> Value {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(Result { try operation() })
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, let result = box.get() else {
            throw ChargeMateShortcutError.staleMeasurement
        }
        return try result.get()
    }

    private static func monitorValues(for battery: BatterySnapshot) -> MonitorValues {
        let read = {
            let monitor = BatteryMonitor.shared
            return MonitorValues(
                committedLimit: monitor.committedLimit,
                state: ChargeMateShortcutState.resolve(
                    available: battery.available,
                    controlState: monitor.controlState.rawValue,
                    policyState: monitor.policyState.shortcutKey,
                    isCharging: battery.isCharging,
                    externalConnected: battery.externalConnected
                )
            )
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    private static func batterySnapshot() throws -> ChargeMateShortcutSnapshot {
        let battery = try withinDeadline { BatteryMonitor.readBattery() }
        let monitor = monitorValues(for: battery)
        return ChargeMateShortcutSnapshot(
            sampledAt: battery.sampledAt,
            macOSPercentage: battery.percentage,
            hardwarePercentage: battery.hardwarePercentage,
            temperatureC: battery.temperatureC,
            committedLimit: monitor.committedLimit,
            nativeManualLimit: nil,
            nativeCurrentLimit: nil,
            state: monitor.state
        )
    }

    private static func nativeState() throws -> NativeChargeState {
        let helper = Bundle.main.resourceURL?.appendingPathComponent("CellkeepNativeChargeHelper")
            ?? URL(fileURLWithPath: "/missing/CellkeepNativeChargeHelper")
        return try withinDeadline { try NativeChargeBackend.production(helperURL: helper).readState() }
    }

    static func batteryPercentage(_ source: ChargeMateShortcutBatterySource) async throws -> Int {
        let snapshot = try batterySnapshot()
        return try ChargeMateShortcutReader(snapshot: snapshot, now: Date()).percentage(source)
    }

    static func temperatureCelsius() async throws -> Double {
        let snapshot = try batterySnapshot()
        return try ChargeMateShortcutReader(snapshot: snapshot, now: Date()).temperatureCelsius()
    }

    static func state() async throws -> ChargeMateShortcutState {
        let snapshot = try batterySnapshot()
        return try ChargeMateShortcutReader(snapshot: snapshot, now: Date()).state()
    }

    static func chargeLimit(_ source: ChargeMateShortcutLimitSource) async throws -> Int {
        let snapshot: ChargeMateShortcutSnapshot
        if source == .committed {
            let committed = await MainActor.run { BatteryMonitor.shared.committedLimit }
            snapshot = .init(sampledAt: Date(), macOSPercentage: nil, hardwarePercentage: nil,
                             temperatureC: nil, committedLimit: committed,
                             nativeManualLimit: nil, nativeCurrentLimit: nil, state: .monitoring)
        } else {
            let native = try nativeState()
            snapshot = .init(sampledAt: Date(), macOSPercentage: nil, hardwarePercentage: nil,
                             temperatureC: nil, committedLimit: nil,
                             nativeManualLimit: native.manualLimit,
                             nativeCurrentLimit: native.currentLimit, state: .monitoring)
        }
        return try ChargeMateShortcutReader(snapshot: snapshot, now: Date()).limit(source)
    }

    static func setChargeLimit(_ limit: Int) async throws -> String {
        guard try nativeState().availableLimits.contains(limit) else {
            throw ChargeMateShortcutError.unsupportedChargeLimit(limit)
        }
        return try requireSuccess(await BatteryMonitor.shared.applyShortcutLimit(limit))
    }

    static func controlTopUp(start: Bool) async throws -> String {
        let snapshot = try withinDeadline { BatteryMonitor.readBattery() }
        let result = start
            ? await BatteryMonitor.shared.startShortcutTopUp(snapshot: snapshot)
            : await BatteryMonitor.shared.cancelShortcutTopUp(snapshot: snapshot)
        return try requireSuccess(result)
    }

    static func setPowerMode(_ mode: SystemPowerMode) async throws -> String {
        guard SystemPowerModeService.availableModes().contains(mode) else {
            throw ChargeMateShortcutError.commandFailed("\(mode.title) bu Mac'te desteklenmiyor.")
        }
        switch SystemPowerModeService.applyInstalled(mode) {
        case .success(let confirmed): return String(localized: "\(confirmed.title) seçildi.")
        case .failure(let error): throw ChargeMateShortcutError.commandFailed(error.localizedDescription)
        }
    }

    static func setMagSafe(_ output: MagSafeLEDOutput) async throws -> String {
        switch MagSafeLEDHardwareService.shared.apply(output) {
        case .applied: return String(localized: "MagSafe ışığı: \(output.rawValue).")
        case .unchanged: return String(localized: "MagSafe ışığı zaten seçilen durumda.")
        case .blocked(let message): throw ChargeMateShortcutError.commandFailed(message)
        case .restored:
            return String(localized: "MagSafe ışığı kayıtlı ışık politikasına döndü.")
        }
    }

    private static func requireSuccess(_ result: ChargeControlCoordinator.Result) throws -> String {
        guard result.status == .configurationVerified else {
            throw ChargeMateShortcutError.commandFailed(result.message)
        }
        return String(localized: "\(result.message) İşlem: \(result.operationID.uuidString)")
    }
}

private extension ChargePolicyState {
    var shortcutKey: String {
        switch self {
        case .idle: return "idle"
        case .maintainingLimit: return "maintainingLimit"
        case .pausedByConflict: return "pausedByConflict"
        case .topUpStarting: return "topUpStarting"
        case .topUpCharging: return "topUpCharging"
        case .topUpRestoring: return "topUpRestoring"
        case .recoveryRequired: return "recoveryRequired"
        }
    }
}
