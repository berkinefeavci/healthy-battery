import Foundation

/// %100'de bekleme uyarısı: takılıyken 3 saatten uzun süre %95 üstünde kalınca bir kez uyarır.
struct FullChargeDwellState: Equatable {
    var aboveSince: Date?
    var notified = false
}

enum FullChargeDwell {
    static let threshold = 95
    static let rearmBelow = 90
    static let duration: TimeInterval = 3 * 3600

    /// `canSuggestLimit`: sınır zaten %80 ya da altındaysa "%80 yap" önerisi anlamsız; uyarı verilmez.
    static func step(_ state: FullChargeDwellState, percentage: Int?, externalConnected: Bool,
                     enabled: Bool, canSuggestLimit: Bool, now: Date)
        -> (state: FullChargeDwellState, notify: Bool) {
        var next = state
        guard externalConnected else { return (FullChargeDwellState(), false) }
        guard let percentage else { return (state, false) }
        if percentage < rearmBelow { return (FullChargeDwellState(), false) }
        if percentage < threshold { next.aboveSince = nil; return (next, false) }
        if next.aboveSince == nil { next.aboveSince = now }
        guard enabled, canSuggestLimit, !next.notified, let since = next.aboveSince,
              now.timeIntervalSince(since) > duration else { return (next, false) }
        next.notified = true
        return (next, true)
    }

    static var notificationTitle: String { String(localized: "Pil 3 saattir %95 üstünde") }
    static var notificationBody: String {
        String(localized: "Uzun süre dolu kalmak pili yorar. Sınırı %80'e çekebilirsiniz.")
    }
}
