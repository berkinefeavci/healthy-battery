import Foundation

/// Isı koruması v1: pil sıcakken macOS yerel sınırını geçici olarak %80'e çeker. Gerçek şarj
/// durdurma değildir; pil zaten %80'in altındaysa şarjı durduramaz. Bu dosya yalnızca saf karar
/// ve kalıcı kayıt içerir; donanıma yazan kısım HealthAutomation.swift içindedir.
struct HeatProtectionOverride: Codable, Equatable {
    var schemaVersion = 1
    /// Isı koruması devreye girmeden önceki macOS yerel sınırı.
    var previousLimit: Int
    /// Turbo'dan çıkarıldıysa önceki adaptör güç modu (SystemPowerMode.rawValue).
    var previousAdapterModeRawValue: Int?
    var startedAt: Date
}

struct HeatProtectionInput {
    var enabled: Bool
    var temperatureC: Double?
    var externalConnected: Bool
    var isCharging: Bool
    var nativeLimit: Int?
    var availableLimits: [Int]
    var adapterMode: SystemPowerMode
    var topUpActive: Bool
    /// Çakışma, kurtarma, başka denetleyici ya da süren yazma: yazmak yasak.
    var controlBlocked: Bool
    var override: HeatProtectionOverride?
}

enum HeatProtectionAction: Equatable {
    case none
    /// Sınırı `limit`e çek; `switchAdapterModeFrom` doluysa adaptör modunu Otomatik yap.
    case engage(previousLimit: Int, limit: Int, switchAdapterModeFrom: SystemPowerMode?)
    /// Eski sınırı geri yaz; `restoreAdapterMode` doluysa modu da geri ver.
    case restore(limit: Int, restoreAdapterMode: SystemPowerMode?)
    /// Geri yazılacak bir şey kalmadı (kullanıcı kendisi değiştirdi); yalnızca kaydı sil.
    case forgetOverride
}

enum HeatProtection {
    static let engageAbove = 35.0
    static let releaseBelow = 32.0
    static let protectedLimit = 80

    static func decide(_ input: HeatProtectionInput) -> HeatProtectionAction {
        if let override = input.override { return decideRestore(input, override: override) }
        guard input.enabled, input.externalConnected, input.isCharging,
              let temperature = input.temperatureC, temperature.isFinite, temperature > engageAbove,
              let limit = input.nativeLimit, limit > protectedLimit,
              input.availableLimits.contains(protectedLimit),
              !input.topUpActive, !input.controlBlocked else { return .none }
        return .engage(previousLimit: limit, limit: protectedLimit,
                       switchAdapterModeFrom: input.adapterMode == .turbo ? .turbo : nil)
    }

    private static func decideRestore(_ input: HeatProtectionInput,
                                      override: HeatProtectionOverride) -> HeatProtectionAction {
        let cooled = input.temperatureC.map { $0 < releaseBelow } ?? false
        let shouldRelease = !input.enabled || !input.externalConnected || cooled
        guard shouldRelease else { return .none }
        // Çalışan bir Top Up kendi sınır geri yüklemesini yapar; ona karışma.
        guard !input.topUpActive else { return .none }
        // Sınır artık bizim yazdığımız değer değilse kullanıcı/başka biri değiştirmiştir: dokunma.
        guard let native = input.nativeLimit else { return .none }
        guard native == protectedLimit else { return .forgetOverride }
        guard !input.controlBlocked else { return .none }
        // Mod yalnızca bizim bıraktığımız haldeyse geri verilir.
        var mode: SystemPowerMode?
        if let raw = override.previousAdapterModeRawValue, let previous = SystemPowerMode(rawValue: raw),
           input.adapterMode == .automatic { mode = previous }
        return .restore(limit: override.previousLimit, restoreAdapterMode: mode)
    }

    static func notificationBody(temperatureC: Double, modeChanged: Bool) -> String {
        let temperature = String(format: "%.0f", temperatureC)
        if modeChanged {
            return String(localized: "Pil \(temperature) °C. Şarj sınırı geçici olarak %80'e çekildi ve Turbo kapatıldı.")
        }
        return String(localized: "Pil \(temperature) °C. Şarj sınırı geçici olarak %80'e çekildi.")
    }
}

/// Geçici geçersiz kılmayı diske yazar; uygulama çökse ya da yeniden başlasa eski sınır geri verilir.
struct HeatOverrideStore {
    let url: URL

    func load() -> HeatProtectionOverride? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(HeatProtectionOverride.self, from: data),
              value.schemaVersion == 1, (20...100).contains(value.previousLimit) else { return nil }
        return value
    }

    func save(_ value: HeatProtectionOverride) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
