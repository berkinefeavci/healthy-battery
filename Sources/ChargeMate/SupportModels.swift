import Darwin
import Foundation

enum ChargeMatePreferences {
    static let uiKeys = [
        "appearance", "appReduceTransparency", "backgroundDashboardUpdates",
        "showPanelAtLaunch", "showDockIcon", "popoverShowPercentage",
        "panelSizeMode", "popoverLayout", "energyThreshold", "historyHours",
        "includeBackgroundEnergyProcesses", MenubarPreferences.storageKey,
        "showMenuPercentage", "showMenuTemperature", "showMenuPower",
        "showBatteryChart", "showPowerFlow", "showQuickStats", "onboardingCompleted"
    ]

    static func resetUI(in defaults: UserDefaults) {
        uiKeys.forEach { defaults.removeObject(forKey: $0) }
        MenubarPreferences().save(to: defaults)
    }
}

enum ChargeMateDiagnostics {
    static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Bilinmiyor" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Bilinmiyor" }
        return String(cString: bytes)
    }

    static func report(snapshot: BatterySnapshot, nativeLimit: Int?, currentSystemLimit: Int?,
                       nativeLimits: [Int], otherControllerRunning: Bool, applyingLimit: Bool,
                       recoveryRequired: Bool, historyCount: Int, historyError: Bool,
                       energyState: EnergySampleState, bundle: Bundle = .main,
                       now: Date = Date(), model: String? = nil,
                       osVersion: String? = nil) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Bilinmiyor"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Bilinmiyor"
        let formatter = ISO8601DateFormatter()
        let flow = PowerFlowPresentation(snapshot: snapshot, now: now)
        let energy: String
        switch energyState {
        case .idle: energy = "bekliyor"
        case .loading: energy = "örnekleniyor"
        case .ready: energy = "hazır"
        case .empty: energy = "boş"
        case .failed: energy = "hata-var"
        }
        let measurementLines = BatteryField.allCases.map { field -> String in
            let reading = snapshot.reading(field, now: now)
            return "- \(field.rawValue): kalite=\(reading.metadata.quality.rawValue), kaynak=\(safeSource(reading.metadata.source))"
        }.joined(separator: "\n")
        return """
        Healthy Battery Tanılama Raporu
        Oluşturma: \(formatter.string(from: now))
        Uygulama: \(version) (\(build))
        macOS: \(safeToken(osVersion ?? ProcessInfo.processInfo.operatingSystemVersionString))
        Model: \(safeToken(model ?? machineModel()))
        Mimari: \(machineArchitecture)

        Güç durumu
        - mod: \(flow.mode.rawValue)
        - adaptör bağlı: \(yesNo(snapshot.externalConnected))
        - şarj oluyor: \(yesNo(snapshot.isCharging))
        - doluluk kalitesi: \(snapshot.reading(.percentage, now: now).metadata.quality.rawValue)

        Yerel limit yeteneği
        - kayıtlı limit: \(nativeLimit.map(String.init) ?? "bilinmiyor")
        - sistem limiti: \(currentSystemLimit.map(String.init) ?? "bilinmiyor")
        - sunulan limitler: \(nativeLimits.isEmpty ? "yok" : nativeLimits.map(String.init).joined(separator: ","))
        - başka denetleyici: \(yesNo(otherControllerRunning))
        - işlem sürüyor: \(yesNo(applyingLimit))
        - kurtarma gerekli: \(yesNo(recoveryRequired))
        - yazma politikası: yalnız açık kullanıcı Uygula eylemi ve doğrulanmış limit

        Yerel veriler
        - geçmiş ölçümü: \(historyCount)
        - geçmiş hatası: \(yesNo(historyError))
        - enerji örneği: \(energy)

        Ölçüm kaynakları
        \(measurementLines)

        Gizlilik
        - seri numarası, kullanıcı adı, dosya yolu ve süreç listesi dahil edilmedi
        """
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "bilinmiyor"
        #endif
    }

    private static func yesNo(_ value: Bool) -> String { value ? "evet" : "hayır" }
    private static func safeSource(_ source: String?) -> String {
        guard let source else { return "bilinmiyor" }
        return safeToken(source)
    }
    private static func safeToken(_ value: String) -> String {
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), value.count <= 80 else { return "ayıklanmış" }
        return value
    }
}
