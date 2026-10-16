import Foundation
import UserNotifications

/// Sağlık otomasyonlarının yerel bildirimleri. Delege `UpdateNotifications`tadır; o, yanıtları ve
/// ön plan sunumunu buraya yönlendirir.
@MainActor
final class HealthNotifications {
    static let shared = HealthNotifications()
    nonisolated static let heatIdentifier = "cellkeep.heat-protection"
    nonisolated static let dwellIdentifier = "cellkeep.full-charge-dwell"
    nonisolated private static let category = "cellkeep.limit80"
    nonisolated private static let setLimitAction = "cellkeep.set-limit-80"
    private let center = UNUserNotificationCenter.current()

    nonisolated static func owns(_ identifier: String) -> Bool {
        identifier == heatIdentifier || identifier == dwellIdentifier
    }

    /// Delege `UpdateNotifications` olduğundan yalnızca kategori kaydedilir.
    func registerCategories() {
        let action = UNNotificationAction(identifier: Self.setLimitAction,
                                          title: String(localized: "Sınırı %80 yap"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action],
                                                                 intentIdentifiers: [], options: [])])
    }

    func post(identifier: String, title: String, body: String, offerLimit80: Bool) {
        Task {
            guard await permissionGranted() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if offerLimit80 { content.categoryIdentifier = Self.category }
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    private func permissionGranted() async -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    nonisolated func handle(_ response: UNNotificationResponse) {
        guard Self.owns(response.notification.request.identifier),
              response.actionIdentifier == Self.setLimitAction else { return }
        Task { @MainActor in HealthAutomation.shared.setLimit80FromNotification() }
    }
}
