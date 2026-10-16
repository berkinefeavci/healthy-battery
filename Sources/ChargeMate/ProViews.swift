import SwiftUI
import AppKit

/// Shows `content` with Pro, otherwise a small card that explains the feature and opens the Pro page.
struct ProGate<Content: View>: View {
    let feature: String
    @ViewBuilder var content: () -> Content
    @State private var refresh = 0

    var body: some View {
        Group {
            if ProAccess.isPro { content() } else { ProLockedCard(feature: feature) }
        }
        .id(refresh)
        .onReceive(NotificationCenter.default.publisher(for: ProAccess.didChange)) { _ in refresh += 1 }
    }
}

struct ProLockedCard: View {
    let feature: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature).font(.system(size: 12, weight: .semibold))
                Text("Healthy Battery Pro ile açılır.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Pro'ya bak") { AppDelegate.shared?.showSettings(page: .pro) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chargeCard()
    }
}

/// Settings → Pro: status, buying and entering a license key.
struct ProSettingsView: View {
    @State private var status = ProAccess.status()
    @State private var entered = ""
    @State private var message: String?

    private let features: [(String, String)] = [
        ("point.3.connected.trianglepath.dotted", String(localized: "Canlı güç akışı")),
        ("chart.xyaxis.line", String(localized: "7 ve 30 günlük geçmiş, uzun süreli sağlık")),
        ("calendar", String(localized: "Takvim ve “Şu saatte hazır”")),
        ("square.stack.3d.up.fill", String(localized: "Kısayollar ve otomasyon eylemleri")),
        ("thermometer.sun.fill", String(localized: "Isı koruması")),
        ("powerplug.fill", String(localized: "Adaptör modu")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusCard
            VStack(alignment: .leading, spacing: 10) {
                Text("Pro'da neler var").font(.system(size: 13, weight: .semibold))
                ForEach(features, id: \.1) { icon, title in
                    Label(title, systemImage: icon).font(.system(size: 12))
                }
                Text("Şarj sınırı, Doldur, pil sağlığı ve menü paneli her zaman ücretsiz.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
            if status != .licensed && status != .earlyAdopter { licenseEntry }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProAccess.didChange)) { _ in status = ProAccess.status() }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch status {
            case .earlyAdopter:
                Label("Pro açık: erken kullanıcı hediyesi", systemImage: "gift.fill").font(.system(size: 13, weight: .semibold))
                Text("Healthy Battery'yi Pro çıkmadan önce kullandığınız için bütün Pro özellikleri bu Mac'te ücretsiz ve kalıcı. Teşekkürler!")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .licensed:
                Label("Pro açık", systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold))
                Text("Lisans bu Mac'te kayıtlı. Mac'inizi değiştirirseniz aynı anahtarı yeni Mac'e girin.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Bu Mac'ten lisansı kaldır", role: .destructive) { ProAccess.deactivate() }.controlSize(.small)
            case .trial(let days):
                Label(String(localized: "Pro denemesi: \(days) gün kaldı"), systemImage: "hourglass").font(.system(size: 13, weight: .semibold))
                Text("Deneme bitince ücretsiz sürüm devam eder; ayarlarınız ve geçmişiniz silinmez.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                buyButton
            case .free:
                Label("Ücretsiz sürüm", systemImage: "battery.75percent").font(.system(size: 13, weight: .semibold))
                Text("Pro tek seferlik bir satın alma: abonelik yok, güncellemeler dahil.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                buyButton
            }
        }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
    }

    private var buyButton: some View {
        Button("Pro'yu satın al") { NSWorkspace.shared.open(ProAccess.purchaseURL) }
            .buttonStyle(.borderedProminent)
    }

    private var licenseEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lisans anahtarı").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("BEA1-…", text: $entered).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                Button("Etkinleştir") {
                    message = ProAccess.activate(entered) ? nil
                        : String(localized: "Bu anahtar geçerli değil ya da Healthy Battery için değil.")
                    if message == nil { entered = "" }
                }.disabled(entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.red) }
            Text("Satın aldıktan sonra açılan sayfadaki “Uygulamada etkinleştir” düğmesi anahtarı kendiliğinden girer.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).chargeCard()
    }
}
