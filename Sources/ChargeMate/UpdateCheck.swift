import Foundation

/// Daily "is there a newer release?" check against this repository's public GitHub releases.
/// It is on unless the user turned it off, and sends nothing but a plain GET for the latest
/// release. Downloading and installing happen only when the user presses "Update"; see
/// `UpdateInstaller`.
enum UpdateCheck {
    static let releasesAPI = URL(string: "https://api.github.com/repos/berkinefeavci/healthy-battery/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Keys {
        static let automatic = "updateCheckAutomatic"
        static let lastCheck = "updateCheckLastDate"
        static let latestVersion = "updateCheckLatestVersion"
        static let latestURL = "updateCheckLatestURL"
        static let notifications = "updateNotificationsEnabled"
        static let notifiedVersion = "updateNotificationLastVersion"
    }

    struct Release: Equatable {
        let version: String
        let pageURL: URL
    }

    enum Outcome: Equatable {
        case upToDate(current: String)
        case available(Release)
        case failed(String)
    }

    /// "v1.2.0", "1.2", "1.2.0-beta" → [1, 2, 0]. Pre-release suffixes are ignored, so a
    /// "1.2.0-beta" tag never counts as newer than an installed 1.2.0.
    static func versionComponents(_ text: String) -> [Int]? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let core = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var lhs = versionComponents(candidate), var rhs = versionComponents(current) else { return false }
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        return rhs.lexicographicallyPrecedes(lhs)
    }

    /// Only a release page of this repository on github.com is ever opened.
    static func isTrustedReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && (url.path.hasPrefix("/berkinefeavci/healthy-battery/releases/")
                || url.path.hasPrefix("/berkinefeavci/cellkeep/releases/"))
    }

    /// On unless the user explicitly turned the toggle off.
    static func automaticEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.automatic) == nil || defaults.bool(forKey: Keys.automatic)
    }

    static func notificationsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.notifications) == nil || defaults.bool(forKey: Keys.notifications)
    }

    /// One notification per version: a release already announced is not announced again.
    static func shouldNotify(_ release: Release, in defaults: UserDefaults = .standard,
                             currentVersion: String = currentVersion) -> Bool {
        guard notificationsEnabled(in: defaults), isNewer(release.version, than: currentVersion) else { return false }
        if let notified = defaults.string(forKey: Keys.notifiedVersion), versionComponents(notified) != nil {
            return isNewer(release.version, than: notified)
        }
        return true
    }

    static func parseLatestRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, versionComponents(tag) != nil,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              isTrustedReleasePage(page) else { return nil }
        return Release(version: tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag, pageURL: page)
    }

    static func outcome(for release: Release?, currentVersion: String) -> Outcome {
        guard let release else { return .failed(String(localized: "GitHub yanıtı okunamadı.")) }
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate(current: currentVersion)
    }

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval || now < lastCheck
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Latest release remembered from the last successful check, if it is newer than this build.
    static func rememberedUpdate(in defaults: UserDefaults = .standard, currentVersion: String = currentVersion) -> Release? {
        guard let version = defaults.string(forKey: Keys.latestVersion),
              let page = defaults.string(forKey: Keys.latestURL).flatMap(URL.init(string:)),
              isTrustedReleasePage(page), isNewer(version, than: currentVersion) else { return nil }
        return Release(version: version, pageURL: page)
    }

    static func check(defaults: UserDefaults = .standard, session: URLSession = .shared) async -> Outcome {
        var request = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed(String(localized: "GitHub şu an yanıt vermiyor.")) }
            data = body
        } catch {
            return .failed(String(localized: "GitHub'a bağlanılamadı."))
        }
        let release = parseLatestRelease(data)
        let result = outcome(for: release, currentVersion: currentVersion)
        defaults.set(Date(), forKey: Keys.lastCheck)
        if let release {
            defaults.set(release.version, forKey: Keys.latestVersion)
            defaults.set(release.pageURL.absoluteString, forKey: Keys.latestURL)
        }
        return result
    }

    /// Called on launch and hourly while running: checks at most once a day, and not at all when
    /// the user turned it off. Returns nil when no check ran.
    static func checkIfDue(defaults: UserDefaults = .standard, now: Date = Date()) async -> Outcome? {
        guard automaticEnabled(in: defaults),
              isDue(lastCheck: defaults.object(forKey: Keys.lastCheck) as? Date, now: now) else { return nil }
        return await check(defaults: defaults)
    }
}
