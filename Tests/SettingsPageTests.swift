import Foundation

@main struct SettingsPageTests {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
        }

        let expected: [SettingsPage: String] = [
            .dashboard: "Gösterge Tablosu",
            .charge: "Şarj Kontrolü",
            .sleep: "Uyku Davranışı",
            .energy: "Enerji Kullanımı",
            .schedule: "Takvim",
            .shortcuts: "Kısayollar",
            .popover: "Açılır Panel",
            .menubar: "Menü Çubuğu",
            .pro: "Pro",
            .general: "Genel",
            .magsafeLED: "MagSafe Işığı",
            .about: "Hakkında"
        ]
        check(SettingsPage.allCases.count == expected.count, "all settings pages covered")
        for (page, title) in expected {
            check(page.title == title, "localized title for \(page)")
            check(!page.title.isEmpty, "title is not empty")
            check(!page.icon.isEmpty, "icon is not empty")
        }
        check(Set(SettingsPage.allCases.map(\.id)).count == SettingsPage.allCases.count, "stable IDs are unique")
        print("Settings pages: \(assertions) assertions passed.")
    }
}
