import CoreGraphics
import Foundation

/// Küçük, kendiliğinden kaybolan hatırlatmaların saf karar katmanı (Pil-Sağlığı-Rehberi bölüm 3).
/// Saat ve örnekler dışarıdan verilir; burada UI, bildirim ya da donanım erişimi yoktur.
enum ReminderKind: String, CaseIterable, Codable {
    case cableRemoved, reached40, reached20, chargingWarm, pluggedFull, calibration

    var defaultEnabled: Bool { self != .calibration }
    var defaultsKey: String { "reminder.\(rawValue)" }

    /// Aynı türün tekrar gösterilmesi için en kısa süre. Eşik türleri bunun yerine "deşarj başına bir kez".
    var cooldown: TimeInterval {
        switch self {
        case .cableRemoved: return 4 * 3600
        case .chargingWarm: return 30 * 60
        case .pluggedFull: return 12 * 3600
        case .calibration: return 30 * 86400
        case .reached40, .reached20: return 0
        }
    }

    var message: String {
        switch self {
        case .cableRemoved: return String(localized: "Yataktaysan altına sert bir şey koy.")
        case .reached40: return String(localized: "Pil %40 — fırsat varsa şarja tak.")
        case .reached20: return String(localized: "Pil %20 — şarja tak ya da Düşük Güç Modu'nu aç.")
        case .chargingWarm: return String(localized: "Pil ısınıyor — havalandırmayı kontrol et, yumuşak yüzeyden kaldır.")
        case .pluggedFull: return String(localized: "Pil dolu — bir süre pille kullanabilirsin.")
        case .calibration: return String(localized: "Ayda bir tam döngü göstergeyi doğru tutar (isteğe bağlı).")
        }
    }

    var title: String {
        switch self {
        case .cableRemoved: return String(localized: "Kablo çıkarılınca")
        case .reached40: return String(localized: "Pil %40'a inince")
        case .reached20: return String(localized: "Pil %20'ye inince")
        case .chargingWarm: return String(localized: "Şarjda ısınırsa")
        case .pluggedFull: return String(localized: "Dolu pille takılınca")
        case .calibration: return String(localized: "Aylık kalibrasyon")
        }
    }
}

struct ReminderSettings: Equatable {
    var enabled = true
    var kinds: Set<ReminderKind> = Set(ReminderKind.allCases.filter(\.defaultEnabled))
    static let masterKey = "remindersEnabled"

    static func load(_ defaults: UserDefaults) -> ReminderSettings {
        var settings = ReminderSettings()
        settings.enabled = defaults.object(forKey: masterKey) as? Bool ?? true
        settings.kinds = Set(ReminderKind.allCases.filter {
            defaults.object(forKey: $0.defaultsKey) as? Bool ?? $0.defaultEnabled
        })
        return settings
    }
}

struct ReminderSample: Equatable {
    var percentage: Int?
    var externalConnected: Bool
    var isCharging: Bool
    var temperatureC: Double?
    /// Makinenin gerçekten uyguladığı şarj sınırı; bilinmiyorsa nil.
    var limit: Int?
}

struct ReminderState: Codable, Equatable {
    var lastFired: [String: Date] = [:]
    var armed40 = true
    var armed20 = true
    var warmStreak = 0
    /// Son tam döngü (≥%98 sonra ≤%20) ya da ilk gözlem; aylık kalibrasyon bundan sayılır.
    var calibrationBaseline: Date?
    var sawFull = false
    // Kalıcı değil: açılışta mevcut durum için tetik çıkmasın diye ilk örnek yalnızca referanstır.
    var previous: ReminderSample?
    var asleep = false
    var wokeAt: Date?

    enum CodingKeys: String, CodingKey { case lastFired, armed40, armed20, warmStreak, calibrationBaseline, sawFull }
}

enum ReminderEngine {
    static let warmThresholdC = 35.0
    static let warmSamples = 2
    static let wakeQuietPeriod: TimeInterval = 60
    static let calibrationInterval: TimeInterval = 30 * 86400

    static func willSleep(_ state: ReminderState) -> ReminderState {
        var next = state; next.asleep = true; next.previous = nil; next.warmStreak = 0; return next
    }

    static func didWake(_ state: ReminderState, now: Date) -> ReminderState {
        var next = state; next.asleep = false; next.wokeAt = now; next.previous = nil; return next
    }

    /// Yeni bir örneği işler. Dönen `fire` listesi önceliğe göre sıralıdır; çağıran en fazla birini gösterir.
    static func step(_ state: ReminderState, sample: ReminderSample, settings: ReminderSettings, now: Date)
        -> (state: ReminderState, fire: [ReminderKind]) {
        var next = state
        let previous = state.previous
        next.previous = sample
        if next.calibrationBaseline == nil { next.calibrationBaseline = now }
        let percent = sample.percentage

        // Ardışık sıcak örnek sayacı (susturulsa da sayılır).
        if sample.isCharging, let t = sample.temperatureC, t >= warmThresholdC { next.warmStreak += 1 }
        else { next.warmStreak = 0 }

        // Yeniden silahlanma: takılınca bir sonraki deşarj için eşikler açılır.
        if sample.externalConnected { next.armed40 = true; next.armed20 = true }

        if let percent {
            if percent >= 98 { next.sawFull = true }
            else if percent <= 20, next.sawFull { next.sawFull = false; next.calibrationBaseline = now }
        }

        // Önceki örnek yoksa (açılış, uyku sonrası) olay üretilmez; yalnızca sonraki geçişler sayılır.
        var events: [ReminderKind] = []
        if let previous {
            if previous.externalConnected && !sample.externalConnected { events.append(.cableRemoved) }
            if !sample.externalConnected, let p = percent, let q = previous.percentage {
                let cross20 = q > 20 && p <= 20 && next.armed20
                let cross40 = q > 40 && p <= 40 && next.armed40
                if cross20 { events.append(.reached20); next.armed20 = false }
                if cross40 { next.armed40 = false; if !cross20 { events.append(.reached40) } }
            }
            if !previous.externalConnected && sample.externalConnected,
               let p = percent, p >= 95, let limit = sample.limit, limit > 80 { events.append(.pluggedFull) }
        }
        if next.warmStreak >= warmSamples { events.append(.chargingWarm) }
        if !sample.externalConnected, let baseline = next.calibrationBaseline,
           now.timeIntervalSince(baseline) >= calibrationInterval { events.append(.calibration) }

        let quiet = next.asleep || !settings.enabled
            || (next.wokeAt.map { now.timeIntervalSince($0) < wakeQuietPeriod } ?? false)
        var fire: [ReminderKind] = []
        if !quiet {
            for kind in priority where events.contains(kind) && settings.kinds.contains(kind) {
                if let last = next.lastFired[kind.rawValue], now.timeIntervalSince(last) < kind.cooldown { continue }
                fire.append(kind)
            }
        }
        // Yalnızca ilk sıradaki gösterilir; cooldown yalnızca gerçekten gösterilecek olana yazılır.
        if let first = fire.first {
            next.lastFired[first.rawValue] = now
            if first == .calibration { next.calibrationBaseline = now }
            fire = [first]
        }
        return (next, fire)
    }

    private static let priority: [ReminderKind] =
        [.reached20, .chargingWarm, .reached40, .pluggedFull, .cableRemoved, .calibration]
}

/// En fazla bir görünen, bir bekleyen toast; fazlası düşer.
struct ToastQueue: Equatable {
    var showing = false
    var pending: String?

    enum Action: Equatable { case show(String), queued, dropped }

    mutating func enqueue(_ text: String) -> Action {
        if !showing { showing = true; return .show(text) }
        if pending == nil { pending = text; return .queued }
        return .dropped
    }

    /// Görünen toast kapandı; varsa bekleyeni döndürür.
    mutating func finished() -> String? {
        if let next = pending { pending = nil; showing = true; return next }
        showing = false
        return nil
    }
}

enum ToastGeometry {
    static let size = CGSize(width: 300, height: 44)
    static let gap: CGFloat = 6

    /// `anchor` durum çubuğu öğesinin ekran çerçevesi; yoksa sağ üst köşe. Koordinatlar AppKit (alt-sol başlangıç).
    static func frame(anchor: CGRect?, screen: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let x: CGFloat
        let top: CGFloat
        if let anchor, !anchor.isEmpty {
            x = anchor.midX - size.width / 2
            top = anchor.minY - gap
        } else {
            x = screen.maxX - size.width - margin
            top = screen.maxY - gap
        }
        let clampedX = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        return CGRect(x: clampedX, y: top - size.height, width: size.width, height: size.height)
    }
}
