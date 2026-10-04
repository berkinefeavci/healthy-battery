import Foundation

@main enum UpdateCheckTests {
    static func main() {
        // Version parsing and ordering.
        precondition(UpdateCheck.versionComponents("v1.2.0") == [1, 2, 0])
        precondition(UpdateCheck.versionComponents("1.2.0-beta.1") == [1, 2, 0])
        precondition(UpdateCheck.versionComponents("1..2") == nil)
        precondition(UpdateCheck.versionComponents("1.x") == nil)
        precondition(UpdateCheck.versionComponents("") == nil)
        precondition(UpdateCheck.isNewer("1.0.1", than: "1.0.0"))
        precondition(UpdateCheck.isNewer("v1.1", than: "1.0.9"))
        precondition(UpdateCheck.isNewer("2.0", than: "1.99.99"))
        precondition(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
        precondition(!UpdateCheck.isNewer("1.0.0", than: "1.0.1"))
        precondition(!UpdateCheck.isNewer("1.0.0-beta", than: "1.0.0"))
        precondition(!UpdateCheck.isNewer("garbage", than: "1.0.0"))

        // Only this repository's release pages on github.com are trusted.
        precondition(UpdateCheck.isTrustedReleasePage(URL(string: "https://github.com/berkinefeavci/cellkeep/releases/tag/v1.1.0")!))
        precondition(UpdateCheck.isTrustedReleasePage(URL(string: "https://github.com/berkinefeavci/healthy-battery/releases/tag/v1.1.0")!))
        precondition(!UpdateCheck.isTrustedReleasePage(URL(string: "http://github.com/berkinefeavci/cellkeep/releases/tag/v1.1.0")!))
        precondition(!UpdateCheck.isTrustedReleasePage(URL(string: "https://evil.example/berkinefeavci/cellkeep/releases/x")!))
        precondition(!UpdateCheck.isTrustedReleasePage(URL(string: "https://github.com/someone/else/releases/tag/v9")!))

        // Parsing the GitHub "latest release" payload.
        func payload(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
        let page = "https://github.com/berkinefeavci/cellkeep/releases/tag/v1.1.0"
        precondition(UpdateCheck.parseLatestRelease(payload(["tag_name": "v1.1.0", "html_url": page]))
                     == UpdateCheck.Release(version: "1.1.0", pageURL: URL(string: page)!))
        precondition(UpdateCheck.parseLatestRelease(payload(["tag_name": "v1.1.0", "html_url": page, "prerelease": true])) == nil)
        precondition(UpdateCheck.parseLatestRelease(payload(["tag_name": "v1.1.0", "html_url": page, "draft": true])) == nil)
        precondition(UpdateCheck.parseLatestRelease(payload(["tag_name": "v1.1.0", "html_url": "https://evil.example/x"])) == nil)
        precondition(UpdateCheck.parseLatestRelease(payload(["tag_name": "latest", "html_url": page])) == nil)
        precondition(UpdateCheck.parseLatestRelease(Data("not json".utf8)) == nil)

        let release = UpdateCheck.Release(version: "1.1.0", pageURL: URL(string: page)!)
        precondition(UpdateCheck.outcome(for: release, currentVersion: "1.0.0") == .available(release))
        precondition(UpdateCheck.outcome(for: release, currentVersion: "1.1.0") == .upToDate(current: "1.1.0"))
        if case .failed = UpdateCheck.outcome(for: nil, currentVersion: "1.0.0") {} else { preconditionFailure() }

        // Weekly schedule; a clock moved backwards re-checks instead of waiting.
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        precondition(UpdateCheck.isDue(lastCheck: nil, now: now))
        precondition(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        precondition(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-UpdateCheck.checkInterval), now: now))
        precondition(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3600), now: now))

        // A remembered release is shown only while it is newer than the running build.
        let suite = "UpdateCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(UpdateCheck.rememberedUpdate(in: defaults, currentVersion: "1.0.0") == nil)
        defaults.set("1.1.0", forKey: UpdateCheck.Keys.latestVersion)
        defaults.set(page, forKey: UpdateCheck.Keys.latestURL)
        precondition(UpdateCheck.rememberedUpdate(in: defaults, currentVersion: "1.0.0") == release)
        precondition(UpdateCheck.rememberedUpdate(in: defaults, currentVersion: "1.1.0") == nil)
        defaults.set("https://evil.example/x", forKey: UpdateCheck.Keys.latestURL)
        precondition(UpdateCheck.rememberedUpdate(in: defaults, currentVersion: "1.0.0") == nil)
        // On by default; an explicit opt-out is kept.
        let blank = UserDefaults(suiteName: suite + ".off")!
        defer { blank.removePersistentDomain(forName: suite + ".off") }
        precondition(UpdateCheck.automaticEnabled(in: blank) && UpdateCheck.notificationsEnabled(in: blank))
        blank.set(false, forKey: UpdateCheck.Keys.automatic)
        precondition(!UpdateCheck.automaticEnabled(in: blank))
        // One notification per version, and none once notifications are turned off.
        precondition(UpdateCheck.shouldNotify(release, in: blank, currentVersion: "1.0.0"))
        precondition(!UpdateCheck.shouldNotify(release, in: blank, currentVersion: "1.1.0"))
        blank.set("1.1.0", forKey: UpdateCheck.Keys.notifiedVersion)
        precondition(!UpdateCheck.shouldNotify(release, in: blank, currentVersion: "1.0.0"))
        blank.removeObject(forKey: UpdateCheck.Keys.notifiedVersion)
        blank.set(false, forKey: UpdateCheck.Keys.notifications)
        precondition(!UpdateCheck.shouldNotify(release, in: blank, currentVersion: "1.0.0"))

        print("Update check: version, trusted-URL, payload, schedule and opt-in assertions passed; no network.")
    }
}
