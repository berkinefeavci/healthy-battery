import Foundation
import CryptoKit

/// Pro license keys ("BEA1-…"), verified offline: no network call is ever needed to unlock Pro.
/// The format is shared by every app and the license server (lisans-sunucusu/src/license.js):
/// base32 of a 12-byte payload — format version, product bits, issue day, random id — followed
/// by its Ed25519 signature over "BEA-LICENSE-v1" + payload.
enum LicenseKey {
    static let prefix = "BEA1-"
    /// Product bit for Healthy Battery (PanelLight 2, Portside 4).
    static let productBit: UInt8 = 1
    static let productionPublicKey = Data(base64Encoded: "MiXeYO2SFnDRFbGAsGtcqOlzaZQk/cjqUcrVYU4JV04=")!

    struct Info: Equatable {
        let products: UInt8
        /// Issue day, "yyyy-MM-dd" (UTC).
        let issued: String
        let id: String
    }

    private static let context = Array("BEA-LICENSE-v1".utf8)
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    private static let epoch = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

    /// Ignores anything outside the base32 alphabet, so pasted spaces, dashes and line breaks don't matter.
    static func base32Decode(_ text: String) -> [UInt8] {
        var bits = 0, value = 0
        var out: [UInt8] = []
        for scalar in text.uppercased().utf8 {
            guard let index = alphabet.firstIndex(of: scalar) else { continue }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= 0xFFFF
        }
        return out
    }

    static func read(_ key: String, publicKey: Data = productionPublicKey) -> Info? {
        let text = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.uppercased().hasPrefix(prefix) else { return nil }
        let bytes = base32Decode(String(text.dropFirst(prefix.count)))
        guard bytes.count == 76, bytes[0] == 1,
              let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return nil }
        let payload = Array(bytes[0..<12])
        guard verifier.isValidSignature(Data(bytes[12...]), for: Data(context + payload)) else { return nil }
        let day = Int(payload[2]) << 8 | Int(payload[3])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let issued = formatter.string(from: epoch.addingTimeInterval(Double(day) * 86_400))
        let id = payload[4...].map { String(format: "%02x", $0) }.joined()
        return Info(products: payload[1], issued: issued, id: id)
    }

    static func unlocksThisApp(_ key: String, publicKey: Data = productionPublicKey) -> Bool {
        guard let info = read(key, publicKey: publicKey) else { return false }
        return info.products & productBit != 0
    }
}

/// Who has Pro: people who used the app before Pro existed (kept free for good), a valid license,
/// or a 7-day trial that starts on a new install. Everything lives in UserDefaults; nothing is sent anywhere.
enum ProAccess {
    static let licenseKeyDefault = "proLicenseKey"
    static let trialStartDefault = "proTrialStart"
    static let earlyAdopterDefault = "proEarlyAdopter"
    static let initializedDefault = "proAccessInitializedV1"
    static let trialDays = 7
    static let didChange = Notification.Name("ProAccessDidChange")
    static let purchaseURL = URL(string: "https://healthybatteryapp.com/buy")!

    enum Status: Equatable {
        case earlyAdopter
        case licensed
        case trial(daysLeft: Int)
        case free

        var isPro: Bool { self != .free }
    }

    static func status(defaults: UserDefaults = .standard, now: Date = Date(),
                       publicKey: Data = LicenseKey.productionPublicKey) -> Status {
        if defaults.bool(forKey: earlyAdopterDefault) { return .earlyAdopter }
        if let key = defaults.string(forKey: licenseKeyDefault), verified(key, publicKey: publicKey) { return .licensed }
        if let start = defaults.object(forKey: trialStartDefault) as? Date {
            let elapsed = max(0, now.timeIntervalSince(start))
            let left = trialDays - Int(elapsed / 86_400)
            if left > 0 { return .trial(daysLeft: left) }
        }
        return .free
    }

    static var isPro: Bool { status().isPro }

    /// Defaults or files that only exist if this Mac ran Healthy Battery (or ChargeMate/Cellkeep) before.
    /// `identityMigrationV1Completed` is left out on purpose: the migration sets it on every first launch.
    static let existingUserDefaults = ["chargeLimit", "committedChargeLimit", "onboardingCompleted", "preferencesSchemaVersion", "popoverLayout"]
    static let existingUserFiles = ["history.json", "daily-summary.json", "schedules.json", "charge-policy.json", "control-session.json"]

    static func looksLikeExistingUser(defaults: UserDefaults, supportDirectory: URL,
                                      fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        existingUserDefaults.contains { defaults.object(forKey: $0) != nil }
            || existingUserFiles.contains { fileExists(supportDirectory.appendingPathComponent($0).path) }
    }

    /// Runs once per Mac, at launch, before anything creates the data folder or defaults
    /// (same rule as IdentityMigration): an existing user keeps Pro for free, a new install starts the trial.
    static func bootstrapIfNeeded(defaults: UserDefaults = .standard, supportDirectory: URL, now: Date = Date(),
                                  fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) {
        guard !defaults.bool(forKey: initializedDefault) else { return }
        if looksLikeExistingUser(defaults: defaults, supportDirectory: supportDirectory, fileExists: fileExists) {
            defaults.set(true, forKey: earlyAdopterDefault)
        } else {
            defaults.set(now, forKey: trialStartDefault)
        }
        defaults.set(true, forKey: initializedDefault)
    }

    /// Stores the key only if it is valid for this app.
    @discardableResult
    static func activate(_ key: String, defaults: UserDefaults = .standard,
                         publicKey: Data = LicenseKey.productionPublicKey) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LicenseKey.unlocksThisApp(clean, publicKey: publicKey) else { return false }
        defaults.set(clean, forKey: licenseKeyDefault)
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    static func deactivate(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: licenseKeyDefault)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// "healthybattery://activate?key=BEA1-…" from the purchase page.
    static func key(fromActivationURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "healthybattery", url.host?.lowercased() == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" })?.value else { return nil }
        return key
    }

    // Views and the heat check ask often; a signature check is cheap but there is no reason to repeat it.
    private static let cacheLock = NSLock()
    private static var cache: (key: String, publicKey: Data, valid: Bool)?

    private static func verified(_ key: String, publicKey: Data) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, cache.key == key, cache.publicKey == publicKey { return cache.valid }
        let valid = LicenseKey.unlocksThisApp(key, publicKey: publicKey)
        cache = (key, publicKey, valid)
        return valid
    }
}
