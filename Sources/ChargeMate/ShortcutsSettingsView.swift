import AppKit
import SwiftUI

struct ShortcutsSettingsView: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @State private var readyActions: Int?

    private struct Action: Identifiable {
        let title: String
        let detail: String
        let example: String
        let icon: String
        var id: String { title }
    }

    private let reads = [
        Action(title: String(localized: "Pil Yüzdesini Al"), detail: String(localized: "macOS veya bağımsız donanım yüzdesi"),
               example: String(localized: "Çıktı: 83"), icon: "battery.75percent"),
        Action(title: String(localized: "Şarj Limitini Al"), detail: String(localized: "Healthy Battery hedefi, native manuel veya geçerli limit"),
               example: String(localized: "Çıktı: 85"), icon: "gauge.with.dots.needle.33percent"),
        Action(title: String(localized: "Healthy Battery Durumunu Al"), detail: String(localized: "Kararlı otomasyon durum adı"),
               example: String(localized: "Çıktı: charging"), icon: "bolt.shield"),
        Action(title: String(localized: "Batarya Sıcaklığını Al"), detail: String(localized: "Sayısal Celsius değeri"),
               example: String(localized: "Çıktı: 35,5"), icon: "thermometer.medium")
    ]

    private let controls = [
        Action(title: String(localized: "Şarj Limitini Ayarla"), detail: String(localized: "%80, %85, %90, %95 veya %100"),
               example: String(localized: "Çıktı: doğrulama sonucu ve işlem kimliği"), icon: "battery.100percent"),
        Action(title: String(localized: "Top Up Denetle"), detail: String(localized: "Başlat veya önceki limite dönerek iptal et"),
               example: String(localized: "Çıktı: başlatma/geri yükleme sonucu"), icon: "plus.circle"),
        Action(title: String(localized: "Deşarjı Denetle"), detail: String(localized: "Kablo takılıyken sınıra ya da verilen yüzdeye in; iptal et"),
               example: String(localized: "Şarj yardımcısı ve geçen adaptör testi gerekir"), icon: "minus.circle"),
        Action(title: String(localized: "Kalibrasyonu Denetle"), detail: String(localized: "%100 → 1 saat → %15 → %100; başlat veya iptal et"),
               example: String(localized: "Şarj yardımcısı ve geçen adaptör testi gerekir"), icon: "arrow.triangle.2.circlepath"),
        Action(title: String(localized: "Güç Modunu Ayarla"), detail: String(localized: "Otomatik, Tasarruf veya Turbo"),
               example: String(localized: "Önceden etkinleştirilmiş helper gerekir"), icon: "speedometer"),
        Action(title: String(localized: "MagSafe Işığını Ayarla"), detail: String(localized: "Sistem, yeşil, turuncu veya kapalı"),
               example: String(localized: "Önceden etkinleştirilmiş LED denetimi gerekir"), icon: "light.beacon.max")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 25)).foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Apple Kestirmeler").font(.headline)
                    Text("On yerel eylem. Okumalar güncel veri döndürür; denetimler Healthy Battery'in güvenli işlem hattını kullanır.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 9) {
                    if let readyActions {
                        let all = readyActions == ChargeMateShortcutReadiness.total
                        Label("\(readyActions) / \(ChargeMateShortcutReadiness.total) eylem hazır",
                              systemImage: all ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(all ? Color.green : Color.orange)
                            .help(String(localized: "Okumalar her zaman hazırdır. Limit ve Top Up için macOS'un sunduğu limitler, güç modu ve MagSafe ışığı için kurulu yardımcı gerekir."))
                    }
                    Button("Kestirmeler'i Aç") { openShortcuts() }
                        .chargeMateButtonStyle()
                }
            }
            Divider()
            Text("Deşarj ve Kalibrasyon adaptörü keserek çalışır; şarj yardımcısı kurulu ve adaptör testi geçmiş olmalı. Değilse eylem nedenini söyleyerek durur.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chargeCard()
        // Checking the helpers launches a process, so it runs off the main thread, never while rendering.
        .task(id: battery.nativeLimits) {
            let limits = !battery.nativeLimits.isEmpty
            let adapterCut = AdapterModeController.shared.adapterCutAvailable
            readyActions = await Task.detached(priority: .utility) {
                ChargeMateShortcutReadiness.ready(nativeLimitsAvailable: limits, adapterCutVerified: adapterCut,
                                                  powerModeHelperInstalled: SystemPowerModeService.installed(),
                                                  magSafeHelperInstalled: MagSafeLEDHardwareService.installed())
            }.value
        }

        actionCard(title: String(localized: "Oku"), icon: "arrow.down.circle", actions: reads)
        actionCard(title: String(localized: "Denetle"), icon: "slider.horizontal.3", actions: controls)
    }

    private func actionCard(title: String, icon: String, actions: [Action]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon).font(.headline).padding(.bottom, 8)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 { Divider().padding(.leading, 37) }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: action.icon)
                        .font(.system(size: 15)).foregroundStyle(.blue)
                        .frame(width: 25, height: 25)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(.system(size: 12, weight: .semibold))
                        Text(action.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(action.example)
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.62))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 250, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chargeCard()
    }

    private func openShortcuts() {
        let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
