import AppKit
import CryptoKit
import Foundation
import Security

/// Pure parts of the in-app update, separate so they can be tested without network or disk.
enum UpdatePackage {
    static func dmgName(_ version: String) -> String { "Healthy-Battery-\(version).dmg" }

    /// Only release assets of this repository, for a plain numeric version, are ever downloaded.
    static func downloadURL(version: String, file: String) -> URL? {
        guard UpdateCheck.versionComponents(version) != nil, !version.contains("-"),
              !file.contains("/"),
              (file == dmgName(version) || file == dmgName(version) + ".sha256") else { return nil }
        return URL(string: "https://github.com/berkinefeavci/healthy-battery/releases/download/v\(version)/\(file)")
    }

    /// `shasum -a 256` output ("<64 hex>  <name>"); only the line for `name` counts.
    static func expectedChecksum(in text: String, for name: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            let file = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            if file == name, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) { return hash }
        }
        return nil
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs after Healthy Battery quits: swaps the bundle, restores the old one if the copy fails, and
    /// reopens the app. Paths arrive as positional arguments and are never interpolated.
    static let swapScript = """
    pid="$1"; staged="$2"; target="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    backup="$target.cellkeep-old"
    rm -rf "$backup"
    if mv "$target" "$backup" && /usr/bin/ditto "$staged" "$target"; then
      rm -rf "$backup"
    else
      rm -rf "$target"; mv "$backup" "$target"
    fi
    rm -rf "$(dirname "$staged")"
    /usr/bin/open "$target"
    """
}

/// Downloads, verifies and installs a newer release when the user presses "Update". Nothing is
/// installed unless the DMG matches the published SHA-256, the app inside is validly signed with
/// the same Team ID as the running app, Gatekeeper accepts it (notarized), and it reports the
/// expected version and bundle identifier. Anything else falls back to the release page.
final class UpdateInstaller: ObservableObject {
    static let shared = UpdateInstaller()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    var busy: Bool { if case .working = phase { return true } else { return false } }

    enum InstallError: LocalizedError {
        case unsupportedLocation
        case unsignedBuild
        case download
        case checksum
        case mount
        case verification(String)
        case copy

        var errorDescription: String? {
            switch self {
            case .unsupportedLocation: return String(localized: "Healthy Battery bu konumdan güncellenemiyor. Uygulamayı Applications klasörüne taşıyın veya sürümü sayfasından indirin.")
            case .unsignedBuild: return String(localized: "Bu kopya imzalı bir sürüm değil; güncellemeyi sürüm sayfasından indirin.")
            case .download: return String(localized: "Güncelleme indirilemedi.")
            case .checksum: return String(localized: "İndirilen dosya yayınlanan sağlama değeriyle uyuşmuyor; kurulmadı.")
            case .mount: return String(localized: "Güncelleme dosyası açılamadı.")
            case .verification(let detail): return String(localized: "Güncelleme doğrulanamadı; kurulmadı. \(detail)")
            case .copy: return String(localized: "Güncelleme hazırlanamadı.")
            }
        }
    }

    func install(_ release: UpdateCheck.Release) {
        guard !busy else { return }
        phase = .working(String(localized: "Güncelleme indiriliyor…"))
        let version = release.version
        let target = Bundle.main.bundleURL
        let teamIdentifier = HelperInstallState.currentTeamIdentifier()
        let bundleIdentifier = Bundle.main.bundleIdentifier
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let teamIdentifier else { throw InstallError.unsignedBuild }
                try Self.checkTarget(target)
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cellkeep-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = try await Self.download(version: version, into: work)
                await self?.report(String(localized: "İmza ve Apple onayı doğrulanıyor…"))
                let staged = try Self.stage(dmg: dmg, in: work, version: version,
                                            teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier)
                await self?.report(String(localized: "Yeniden başlatılıyor…"))
                try Self.launchSwap(staged: staged, target: target)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.phase = .failed(message) }
            }
        }
    }

    @MainActor private func report(_ message: String) { phase = .working(message) }

    private static func checkTarget(_ target: URL) throws {
        let parent = target.deletingLastPathComponent().path
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
              !target.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: parent),
              FileManager.default.isWritableFile(atPath: target.path) else { throw InstallError.unsupportedLocation }
    }

    private static func download(version: String, into work: URL) async throws -> URL {
        let name = UpdatePackage.dmgName(version)
        guard let dmgURL = UpdatePackage.downloadURL(version: version, file: name),
              let sumURL = UpdatePackage.downloadURL(version: version, file: name + ".sha256") else { throw InstallError.download }
        let (sumData, sumResponse) = try await URLSession.shared.data(from: sumURL)
        guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = UpdatePackage.expectedChecksum(in: String(decoding: sumData, as: UTF8.self), for: name)
        else { throw InstallError.download }
        let (temporary, response) = try await URLSession.shared.download(from: dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.download }
        let dmg = work.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: dmg)
        guard try UpdatePackage.sha256Hex(of: dmg) == expected else { throw InstallError.checksum }
        return dmg
    }

    private static func stage(dmg: URL, in work: URL, version: String,
                              teamIdentifier: String, bundleIdentifier: String?) throws -> URL {
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mount.path, dmg.path]) == 0 else { throw InstallError.mount }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let app = mount.appendingPathComponent("Healthy Battery.app")
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw InstallError.verification(String(localized: "Sürüm veya paket kimliği beklenen değil."))
        }
        guard signingTeam(of: app) == teamIdentifier else {
            throw InstallError.verification(String(localized: "İmza bu uygulamanın geliştiricisine ait değil."))
        }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw InstallError.verification(String(localized: "Apple onayı (notarization) doğrulanamadı."))
        }
        let staged = work.appendingPathComponent("Healthy Battery.app")
        guard run("/usr/bin/ditto", [app.path, staged.path]) == 0 else { throw InstallError.copy }
        return staged
    }

    /// Team ID of a bundle whose signature, including nested code, is valid; nil otherwise.
    static func signingTeam(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let strict = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode)
                                    | UInt32(kSecCSStrictValidate))
        guard SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func launchSwap(staged: URL, target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdatePackage.swapScript, "cellkeep-update",
                             String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path]
        try process.run()
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
