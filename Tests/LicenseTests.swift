import Foundation

/// Pure checks for LicenseKey / ProAccess. The vector comes from lisans-sunucusu/test/vector.json
/// (a TEST-ONLY key pair), so the server and the app agree on the same bytes.
@main struct LicenseTests {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
        }

        let testKey = Data(base64Encoded: "yPj+HQj/j2TL8ho/0leBeLQbsWUY9T0OOrlCSYFkLNc=")!
        let hbLicense = "BEA1-AEAQCIABAIBQIBIGA4EENGBHDOTJY4ZX6DIHYH4J3PJFLIDVLXJCMHRTR7O63FOZPFEXGQS74JSR4SIVEQ5PGKZCDNRAQEMR3GGUSQB2ZSKNFWWLEYPMIJUVBI"
        let panelLightOnly = "BEA1-AEBACIB6IYOPN5AGWI6TODFP7LLPW5ADZVOZ6BPLTZUWZ5BERBAAUXR5PTAMWLT3ZQVKKLQIE6QUHTCFKZFOTYZNIM74BCJAQ3WB4FACUTNIEJSCRWHPKMKHAI"

        // Reading the shared vector
        let info = LicenseKey.read(hbLicense, publicKey: testKey)
        check(info == .init(products: 1, issued: "2026-10-16", id: "0102030405060708"), "vector decodes to the server's values")
        check(LicenseKey.unlocksThisApp(hbLicense, publicKey: testKey), "Healthy Battery bit unlocks")
        check(!LicenseKey.unlocksThisApp(panelLightOnly, publicKey: testKey), "a PanelLight-only key does not unlock Healthy Battery")
        check(LicenseKey.read(panelLightOnly, publicKey: testKey)?.products == 2, "PanelLight key still verifies")

        // Pasting
        let spaced = "  " + hbLicense.prefix(5) + hbLicense.dropFirst(5).lowercased().enumerated()
            .map { $0.offset % 8 == 7 ? "\($0.element)-" : "\($0.element)" }.joined() + "\n"
        check(LicenseKey.unlocksThisApp(spaced, publicKey: testKey), "spaces, dashes, lower case and newline are tolerated")
        check(LicenseKey.unlocksThisApp("bea1-" + hbLicense.dropFirst(5), publicKey: testKey), "lower-case prefix accepted")

        // Rejections
        var tampered = Array(hbLicense)
        tampered[8] = tampered[8] == "A" ? "B" : "A"
        check(LicenseKey.read(String(tampered), publicKey: testKey) == nil, "a changed character fails the signature")
        check(LicenseKey.read(hbLicense) == nil, "the test key's license is not valid for the production key")
        check(LicenseKey.read("BEA1-AAAA", publicKey: testKey) == nil, "short key rejected")
        check(LicenseKey.read("XYZ1-" + hbLicense.dropFirst(5), publicKey: testKey) == nil, "wrong prefix rejected")
        check(LicenseKey.read("", publicKey: testKey) == nil, "empty rejected")
        check(LicenseKey.productionPublicKey.count == 32, "production public key is 32 bytes")

        // ProAccess: bootstrap, trial, license, early adopter
        func freshDefaults() -> UserDefaults {
            let name = "license-tests-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return d
        }
        let support = URL(fileURLWithPath: "/tmp/does-not-matter")
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let newUser = freshDefaults()
        ProAccess.bootstrapIfNeeded(defaults: newUser, supportDirectory: support, now: start, fileExists: { _ in false })
        check(ProAccess.status(defaults: newUser, now: start, publicKey: testKey) == .trial(daysLeft: 7), "new install starts a 7-day trial")
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(6.5 * 86_400), publicKey: testKey) == .trial(daysLeft: 1), "last trial day")
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(7 * 86_400), publicKey: testKey) == .free, "trial ends after 7 days")
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(-86_400), publicKey: testKey) == .trial(daysLeft: 7), "clock set back does not extend the trial")
        ProAccess.bootstrapIfNeeded(defaults: newUser, supportDirectory: support, now: start.addingTimeInterval(30 * 86_400), fileExists: { _ in false })
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(8 * 86_400), publicKey: testKey) == .free, "bootstrap runs once; a relaunch does not restart the trial")

        check(!ProAccess.activate("BEA1-AAAA", defaults: newUser, publicKey: testKey), "invalid key is not stored")
        check(newUser.string(forKey: ProAccess.licenseKeyDefault) == nil, "nothing stored for an invalid key")
        check(!ProAccess.activate(panelLightOnly, defaults: newUser, publicKey: testKey), "another app's key is not stored")
        check(ProAccess.activate(spaced, defaults: newUser, publicKey: testKey), "valid key activates")
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(400 * 86_400), publicKey: testKey) == .licensed, "license never expires")
        ProAccess.deactivate(defaults: newUser)
        check(ProAccess.status(defaults: newUser, now: start.addingTimeInterval(8 * 86_400), publicKey: testKey) == .free, "deactivate returns to free")

        let byDefaults = freshDefaults()
        byDefaults.set(85, forKey: "chargeLimit")
        ProAccess.bootstrapIfNeeded(defaults: byDefaults, supportDirectory: support, now: start, fileExists: { _ in false })
        check(ProAccess.status(defaults: byDefaults, now: start.addingTimeInterval(999 * 86_400), publicKey: testKey) == .earlyAdopter, "existing defaults → Pro kept for free")

        let byFiles = freshDefaults()
        ProAccess.bootstrapIfNeeded(defaults: byFiles, supportDirectory: support, now: start,
                                    fileExists: { $0.hasSuffix("/history.json") })
        check(ProAccess.status(defaults: byFiles, publicKey: testKey) == .earlyAdopter, "existing history file → Pro kept for free")

        let migratedOnly = freshDefaults()
        migratedOnly.set(true, forKey: "identityMigrationV1Completed")
        ProAccess.bootstrapIfNeeded(defaults: migratedOnly, supportDirectory: support, now: start, fileExists: { _ in false })
        check(ProAccess.status(defaults: migratedOnly, now: start, publicKey: testKey) == .trial(daysLeft: 7), "the migration marker alone is a new install")

        // Activation link
        check(ProAccess.key(fromActivationURL: URL(string: "healthybattery://activate?key=\(hbLicense)")!) == hbLicense, "activation link carries the key")
        check(ProAccess.key(fromActivationURL: URL(string: "https://example.com/activate?key=x")!) == nil, "other schemes ignored")
        check(ProAccess.key(fromActivationURL: URL(string: "healthybattery://settings?key=x")!) == nil, "other hosts ignored")

        print("License: \(assertions) assertions passed.")
    }
}
