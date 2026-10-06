import AppKit
import UserNotifications

/// Tells the user about a newer release found by `UpdateCheck`, once per version, with a local
/// notification. No push service. Clicking it opens Settings → About, where "Update" installs it.
@MainActor
final class UpdateNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifications()
    nonisolated private static let identifier = "cellkeep.release-update"
    private let center = UNUserNotificationCenter.current()
    private var timer: Timer?
    private var checking = false

    func start() {
        center.delegate = self
        guard timer == nil else { return }
        // `UpdateCheck.checkIfDue` limits network checks to once a day; the hourly tick only makes
        // a long-running app notice the next day without a relaunch.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateNotifications.shared.checkAndNotify() }
        }
        Task { await checkAndNotify() }
    }

    func checkAndNotify() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if case .available(let release) = await UpdateCheck.checkIfDue() { await notify(release) }
    }

    private func notify(_ release: UpdateCheck.Release) async {
        guard UpdateCheck.shouldNotify(release), await permissionGranted() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Yeni sürüm var: \(release.version)")
        content.body = String(localized: "Güncellemek için tıklayın.")
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            UserDefaults.standard.set(release.version, forKey: UpdateCheck.Keys.notifiedVersion)
        } catch {
            // Not marked as notified, so the next check retries.
        }
    }

    private func permissionGranted() async -> Bool {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        completionHandler(identifier == Self.identifier || HealthNotifications.owns(identifier) ? [.banner, .sound] : [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in HealthNotifications.shared.handle(response) }
        if response.notification.request.identifier == Self.identifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in AppDelegate.shared?.showSettings(page: .about) }
        }
        completionHandler()
    }
}
