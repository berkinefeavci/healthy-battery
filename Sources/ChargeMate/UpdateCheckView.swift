import AppKit
import SwiftUI

/// About-page controls for the daily release check and its notification; see `UpdateCheck`.
struct UpdateCheckSection: View {
    @AppStorage(UpdateCheck.Keys.automatic) private var automatic = true
    @AppStorage(UpdateCheck.Keys.notifications) private var notifications = true
    @State private var checking = false
    @State private var status: String?
    @State private var available: UpdateCheck.Release? = UpdateCheck.rememberedUpdate()
    @ObservedObject private var installer = UpdateInstaller.shared

    var body: some View {
        VStack(spacing: 8) {
            Toggle("Günde bir yeni sürüm denetle", isOn: $automatic)
            Toggle("Yeni sürüm çıkınca bildirim göster", isOn: $notifications).disabled(!automatic)
            Text("Açıksa Healthy Battery yalnızca GitHub'daki son sürüm numarasını sorar ve veri göndermez. Güncellemeyi yalnızca siz “Güncelle”ye bastığınızda indirir; imzası ve Apple onayı doğrulanmadan kurmaz.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button(checking ? "Denetleniyor…" : String(localized: "Şimdi denetle")) { Task { await checkNow() } }
                    .disabled(checking)
                if let available {
                    Button(String(localized: "Güncelle: \(available.version)")) { installer.install(available) }
                        .disabled(installer.busy)
                }
            }.chargeMateButtonStyle()
            switch installer.phase {
            case .working(let message): ProgressView(message).controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                if let available {
                    Button("Sürüm \(available.version) sayfasını aç") { NSWorkspace.shared.open(available.pageURL) }
                        .buttonStyle(.link).font(.caption)
                }
            case .idle:
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: 520)
    }

    @MainActor private func checkNow() async {
        checking = true
        defer { checking = false }
        switch await UpdateCheck.check() {
        case .upToDate(let current):
            available = nil
            status = String(localized: "Healthy Battery \(current) güncel.")
        case .available(let release):
            available = release
            status = String(localized: "Yeni sürüm var: \(release.version)")
        case .failed(let message):
            status = message
        }
    }
}
