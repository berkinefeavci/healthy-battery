import Foundation

enum SettingsPage: String, CaseIterable, Identifiable {
    case dashboard, charge, sleep, energy, schedule, shortcuts, popover, menubar, pro, general, magsafeLED, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return String(localized: "Gösterge Tablosu")
        case .charge: return String(localized: "Şarj Kontrolü")
        case .sleep: return String(localized: "Uyku Davranışı")
        case .energy: return String(localized: "Enerji Kullanımı")
        case .schedule: return String(localized: "Takvim")
        case .shortcuts: return String(localized: "Kısayollar")
        case .popover: return String(localized: "Açılır Panel")
        case .menubar: return String(localized: "Menü Çubuğu")
        case .pro: return String(localized: "Pro")
        case .general: return String(localized: "Genel")
        case .magsafeLED: return String(localized: "MagSafe Işığı")
        case .about: return String(localized: "Hakkında")
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .charge: return "bolt.fill"
        case .sleep: return "moon.fill"
        case .energy: return "chart.xyaxis.line"
        case .schedule: return "calendar"
        case .shortcuts: return "square.stack.3d.up.fill"
        case .popover: return "macwindow"
        case .menubar: return "menubar.rectangle"
        case .pro: return "star.circle.fill"
        case .general: return "gearshape.fill"
        case .magsafeLED: return "light.beacon.max.fill"
        case .about: return "info.circle.fill"
        }
    }
}
