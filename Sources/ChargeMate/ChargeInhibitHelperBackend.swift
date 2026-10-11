import Foundation

/// Wire format of `Tools/ChargeInhibitIPC.h`. Pure, so the protocol is unit-testable without a helper.
enum ChargeInhibitWire {
    enum Failure: Error, Equatable, LocalizedError {
        case badRequest, refused, failed, unsupported, gated, malformed, helperMissing, helperNotTrusted, locked
        /// The helper install did not complete (administrator prompt denied or the install command failed).
        case installFailed
        /// The user dismissed the administrator prompt; nothing was installed.
        case cancelled
        var errorDescription: String? {
            switch self {
            case .badRequest: return String(localized: "Şarj durdurma yardımcısı isteği anlamadı.")
            case .refused: return String(localized: "Şarj durdurma güvenlik kuralıyla reddedildi (pil düşük, adaptör yok veya uyku).")
            case .failed: return String(localized: "Şarj durdurma yazılamadı ya da doğrulanamadı; her şey serbest bırakıldı.")
            case .gated: return String(localized: "macOS bu anahtarı özel yetkiye bağlamış (kIOReturnNotPrivileged); root olsa bile yazılamıyor.")
            case .unsupported: return String(localized: "Bu Mac'te doğrulanmış şarj durdurma anahtarı yok.")
            case .malformed: return String(localized: "Şarj durdurma yardımcısından geçersiz yanıt geldi.")
            case .helperMissing: return String(localized: "Şarj durdurma yardımcısı kurulu değil.")
            case .helperNotTrusted: return String(localized: "Şarj durdurma yardımcısı güvenli değil; işlem durduruldu.")
            case .locked: return String(localized: "Şarj durdurma henüz kilitli (deneysel, fiziksel test bekliyor).")
            case .installFailed: return String(localized: "Şarj durdurma yardımcısı kurulamadı.")
            case .cancelled: return String(localized: "Yönetici onayı iptal edildi; yardımcı kurulmadı.")
            }
        }
    }

    static let readRequest = "R\n"
    static let capabilitiesRequest = "C\n"
    static let heartbeatRequest = "H\n"

    static func setRequest(_ state: ChargeInhibitState) -> String {
        "S \(state.chargingInhibited ? 1 : 0) \(state.adapterInhibited ? 1 : 0)\n"
    }

    /// Splits "<status> <values…>"; throws the matching failure for a non-zero status.
    static func values(from response: String, allowed: ClosedRange<Int> = 0...1) throws -> [Int] {
        let fields = response.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = fields.first, let status = Int(first) else { throw Failure.malformed }
        switch status {
        case 0: break
        case 2: throw Failure.badRequest
        case 3: throw Failure.refused
        case 4: throw Failure.failed
        case 5: throw Failure.unsupported
        case 6: throw Failure.gated
        default: throw Failure.malformed
        }
        let numbers = fields.dropFirst().compactMap { Int($0) }
        guard numbers.count == fields.count - 1, numbers.allSatisfy({ allowed.contains($0) }) else { throw Failure.malformed }
        return numbers
    }

    static func state(from response: String) throws -> ChargeInhibitState {
        let numbers = try values(from: response)
        guard numbers.count == 2 else { throw Failure.malformed }
        return ChargeInhibitState(chargingInhibited: numbers[0] == 1, adapterInhibited: numbers[1] == 1)
    }

    /// "0 c a" (old) or "0 c a chargingReason adapterReason" with reasons 0 ok, 1 missing, 2 gated, 3 error.
    static func capabilities(from response: String) throws -> (charging: Bool, adapter: Bool, chargingReason: Int, adapterReason: Int) {
        let numbers = try values(from: response, allowed: 0...3)
        guard numbers.count == 2 || numbers.count == 4, numbers[0] <= 1, numbers[1] <= 1 else { throw Failure.malformed }
        let reasons = numbers.count == 4 ? (numbers[2], numbers[3]) : (numbers[0] == 1 ? 0 : 1, numbers[1] == 1 ? 0 : 1)
        return (numbers[0] == 1, numbers[1] == 1, reasons.0, reasons.1)
    }
}

/// Hidden/debug unlock. There is deliberately no settings UI for it: the feature stays locked
/// ("deneysel, fiziksel test bekliyor") until `docs/2026-10-06-Faz3-Fiziksel-Test.md` is signed off.
/// Enable for a test with: `defaults write io.github.berkinefeavci.cellkeep debug.chargeInhibitUnlocked -bool YES`
enum ChargeInhibitUnlock {
    static let defaultsKey = "debug.chargeInhibitUnlocked"
    static func isUnlocked(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

/// `ChargeInhibitBackend` that talks to the root helper. Supported only when the feature is unlocked,
/// the helper is installed and trusted, and it reports the SMC keys as verified on this Mac.
struct ChargeInhibitHelperBackend: ChargeInhibitBackend {
    var isUnlocked: () -> Bool = { ChargeInhibitUnlock.isUnlocked() }
    var isInstalled: () -> Bool = { ChargeInhibitHelperService.installed() }
    var transport: (String) throws -> String = { try ChargeInhibitHelperService.request($0) }

    func capabilities() -> ChargeInhibitCapabilities {
        guard isUnlocked() else {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: ChargeInhibitWire.Failure.locked.errorDescription)
        }
        guard isInstalled() else {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: ChargeInhibitWire.Failure.helperMissing.errorDescription)
        }
        do {
            let verified = try ChargeInhibitWire.capabilities(from: transport(ChargeInhibitWire.capabilitiesRequest))
            guard verified.charging || verified.adapter else {
                // Gated (macOS refuses the key) is reported distinctly from missing (no such key).
                let gated = verified.chargingReason == 2 || verified.adapterReason == 2
                return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                                 reason: (gated ? ChargeInhibitWire.Failure.gated : .unsupported).errorDescription)
            }
            // The adapter channel (CHIE) alone is enough; CHTE is not required.
            return ChargeInhibitCapabilities(canInhibitCharging: verified.charging, canForceDischarge: verified.adapter,
                                             reason: nil)
        } catch {
            return ChargeInhibitCapabilities(canInhibitCharging: false, canForceDischarge: false,
                                             reason: error.localizedDescription)
        }
    }

    func readState() throws -> ChargeInhibitState {
        try requireSupported(forInhibit: false)
        return try ChargeInhibitWire.state(from: transport(ChargeInhibitWire.readRequest))
    }

    func apply(_ state: ChargeInhibitState) throws -> ChargeInhibitState {
        // Releasing is always allowed once the helper exists; inhibiting needs a verified capability.
        let releasing = !state.chargingInhibited && !state.adapterInhibited
        if !releasing {
            let current = capabilities()
            guard current.canInhibitCharging || current.canForceDischarge else {
                throw ChargeInhibitWire.Failure.unsupported
            }
            if state.chargingInhibited && !current.canInhibitCharging { throw ChargeInhibitWire.Failure.unsupported }
            if state.adapterInhibited && !current.canForceDischarge { throw ChargeInhibitWire.Failure.unsupported }
        } else {
            guard isInstalled() else { return .released }
        }
        let applied = try ChargeInhibitWire.state(from: transport(ChargeInhibitWire.setRequest(state)))
        guard applied == state else { throw ChargeInhibitWire.Failure.failed } // the helper already read it back
        return applied
    }

    func heartbeat() throws {
        try requireSupported(forInhibit: false)
        _ = try ChargeInhibitWire.values(from: transport(ChargeInhibitWire.heartbeatRequest))
    }

    private func requireSupported(forInhibit: Bool) throws {
        guard isUnlocked() else { throw ChargeInhibitWire.Failure.locked }
        guard isInstalled() else { throw ChargeInhibitWire.Failure.helperMissing }
    }
}

/// Installs/queries the root helper. Mirrors `SystemPowerModeService` (one admin prompt, root-owned
/// copy checked before it runs). Nothing calls `install()` automatically: only the "Yardımcıyı kur" button
/// does, through `AdapterModeController`. Removal is part of `UninstallPlan`.
enum ChargeInhibitHelperService {
    static let label = "io.github.berkinefeavci.cellkeep.chargeinhibit"
    static let helperPath = "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.chargeinhibit"
    static let socketPath = "/var/run/io.github.berkinefeavci.cellkeep.chargeinhibit.sock"
    static let minimumHelperVersion = 2 // 2: callers must be the signed app
    static let bundledHelperName = "CellkeepChargeInhibitHelper"

    static func installed() -> Bool {
        guard (helperVersion() ?? 0) >= minimumHelperVersion else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: helperPath)
        let owner = (attributes?[.ownerAccountID] as? NSNumber)?.intValue
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        return HelperInstallState.isTrusted(ownerUID: owner, posixPermissions: mode,
                                             socketExists: FileManager.default.fileExists(atPath: socketPath))
    }

    /// The one admin shell command: copy → verify signature → write plist → authorize this user → (re)load.
    /// Pure and public so tests can inspect it; `install()` is the only caller that runs it.
    static func installCommand(bundledHelperPath: String, teamIdentifier: String?, uid: uid_t) -> String {
        HelperInstallState.installCommand(label: label, helperPath: helperPath, bundledHelperPath: bundledHelperPath,
                                          teamIdentifier: teamIdentifier, uid: uid)
    }

    static func install() throws {
        guard let executable = Bundle.main.executableURL else { throw ChargeInhibitWire.Failure.helperMissing }
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(bundledHelperName)
        guard FileManager.default.fileExists(atPath: bundled.path) else { throw ChargeInhibitWire.Failure.helperMissing }
        try authorized(installCommand(bundledHelperPath: bundled.path,
                                      teamIdentifier: HelperInstallState.currentTeamIdentifier(), uid: getuid()))
        guard installed() else { throw ChargeInhibitWire.Failure.helperNotTrusted }
    }

    static func request(_ line: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChargeInhibitWire.Failure.helperMissing }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            socketPath.utf8CString.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ChargeInhibitWire.Failure.helperMissing }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw ChargeInhibitWire.Failure.helperNotTrusted }
        let bytes = Array(line.utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress!, bytes.count) }) == bytes.count else {
            throw ChargeInhibitWire.Failure.failed
        }
        var response = [UInt8]()
        while response.count < 32 {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { throw ChargeInhibitWire.Failure.malformed }
            if byte == 10 { break }
            response.append(byte)
        }
        guard let text = String(bytes: response, encoding: .utf8) else { throw ChargeInhibitWire.Failure.malformed }
        return text
    }

    private static func authorized(_ command: String) throws {
        do { try AdminAuthorization.run(command) }
        catch AdminAuthorization.Failure.cancelled { throw ChargeInhibitWire.Failure.cancelled }
        catch { throw ChargeInhibitWire.Failure.installFailed }
    }

    private static func helperVersion() -> Int? {
        HelperInstallState.cachedVersion(atPath: helperPath) { HelperInstallState.readVersion(ofHelperAt: helperPath) }
    }
}
