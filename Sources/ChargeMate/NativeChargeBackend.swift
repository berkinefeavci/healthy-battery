import Darwin
import Foundation

struct NativeChargeState: Codable, Equatable {
    let manualLimit: Int
    let availableLimits: [Int]
    let enabledRaw: Int
    let currentLimit: Int
}

struct NativeChargeCapabilities: Equatable {
    let supported: Bool
    let availableLimits: [Int]
    let reason: String?
}

/// The charge helper is a separate process without the app's language setting, so its fixed failure
/// messages (PowerUIBridge.m, NativeChargeHelper/main.swift) are Turkish source keys that the app translates.
/// A new helper message must be added here; Tests/NativeChargeBackendTests.swift checks the sources.
enum NativeHelperText {
    static let messages: [String: String] = [
        "Bu macOS sürümünde yerel limit arayüzü kullanılamıyor.": String(localized: "Bu macOS sürümünde yerel limit arayüzü kullanılamıyor."),
        "Kayıtlı macOS limiti okunamadı.": String(localized: "Kayıtlı macOS limiti okunamadı."),
        "Desteklenen limitler okunamadı.": String(localized: "Desteklenen limitler okunamadı."),
        "Beklenmeyen macOS limit listesi.": String(localized: "Beklenmeyen macOS limit listesi."),
        "macOS şarj durumu okunamadı.": String(localized: "macOS şarj durumu okunamadı."),
        "Geçerli sistem limiti okunamadı.": String(localized: "Geçerli sistem limiti okunamadı."),
        "Bu şarj limiti desteklenmiyor; değişiklik yapılmadı.": String(localized: "Bu şarj limiti desteklenmiyor; değişiklik yapılmadı."),
        "macOS limit değişikliğini kabul etmedi.": String(localized: "macOS limit değişikliğini kabul etmedi."),
        "Limit değişikliği okuma ile doğrulanamadı.": String(localized: "Limit değişikliği okuma ile doğrulanamadı."),
        "Geçersiz yardımcı komutu.": String(localized: "Geçersiz yardımcı komutu."),
        "Yanıt kodlanamadı.": String(localized: "Yanıt kodlanamadı.")
    ]
    static func localized(_ message: String) -> String { messages[message] ?? message }
}

enum NativeChargeBackendError: LocalizedError, Equatable {
    case helperMissing
    case timedOut
    case rejected(String)
    case malformedResponse
    case oversizedResponse

    var errorDescription: String? {
        switch self {
        case .helperMissing: return String(localized: "Yerel şarj yardımcısı bulunamadı.")
        case .timedOut: return String(localized: "Yerel şarj yardımcısı zaman aşımına uğradı.")
        case .rejected(let message): return NativeHelperText.localized(message)
        case .malformedResponse: return String(localized: "Yerel şarj yardımcısı geçersiz yanıt verdi.")
        case .oversizedResponse: return String(localized: "Yerel şarj yardımcısının yanıtı sınırı aştı.")
        }
    }
}

struct NativeChargeProcessResult {
    let status: Int32
    let output: Data
}

struct NativeChargeBackend {
    typealias Executor = (_ arguments: [String], _ timeout: TimeInterval) throws -> NativeChargeProcessResult
    static let allowedLimits = Set([80, 85, 90, 95, 100])
    static let maximumOutputBytes = 65_536

    let version: String
    private let timeout: TimeInterval
    private let execute: Executor

    init(version: String = "PowerUI-MCL-v2", timeout: TimeInterval = 8,
         execute: @escaping Executor) {
        self.version = version
        self.timeout = timeout
        self.execute = execute
    }

    static func production(helperURL: URL, timeout: TimeInterval = 8) -> Self {
        Self(timeout: timeout) { arguments, timeout in
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                throw NativeChargeBackendError.helperMissing
            }
            return try run(helperURL: helperURL, arguments: arguments, timeout: timeout)
        }
    }

    func capabilities() throws -> NativeChargeCapabilities {
        do {
            let state = try readState()
            return .init(supported: true, availableLimits: state.availableLimits, reason: nil)
        } catch let error as NativeChargeBackendError {
            return .init(supported: false, availableLimits: [], reason: error.localizedDescription)
        }
    }

    func readState() throws -> NativeChargeState {
        try request(["read"])
    }

    func setLimit(_ limit: Int) throws -> NativeChargeState {
        guard Self.allowedLimits.contains(limit) else {
            throw NativeChargeBackendError.rejected(String(localized: "Bu şarj limiti desteklenmiyor."))
        }
        return try request(["set", String(limit)])
    }

    private func request(_ arguments: [String]) throws -> NativeChargeState {
        let result = try execute(arguments, timeout)
        guard result.output.count <= Self.maximumOutputBytes else {
            throw NativeChargeBackendError.oversizedResponse
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: result.output) }
        catch { throw NativeChargeBackendError.malformedResponse }
        guard envelope.schemaVersion == 1 else { throw NativeChargeBackendError.malformedResponse }
        guard result.status == 0, envelope.ok, let raw = envelope.state else {
            throw NativeChargeBackendError.rejected(envelope.error ?? String(localized: "Yerel şarj işlemi reddedildi."))
        }
        let limits = raw.availableLimits.sorted()
        guard Set(limits).count == limits.count,
              limits.allSatisfy((80...100).contains),
              (0...100).contains(raw.manualLimit),
              (0...100).contains(raw.currentLimit) else {
            throw NativeChargeBackendError.malformedResponse
        }
        return NativeChargeState(manualLimit: raw.manualLimit, availableLimits: limits,
                                 enabledRaw: raw.enabledRaw, currentLimit: raw.currentLimit)
    }

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let ok: Bool
        let state: NativeChargeState?
        let error: String?
    }

    private static func run(helperURL: URL, arguments: [String], timeout: TimeInterval) throws -> NativeChargeProcessResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellkeep-native-charge-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            throw NativeChargeBackendError.rejected(String(localized: "Yerel şarj yanıt dosyası oluşturulamadı."))
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw NativeChargeBackendError.helperMissing }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = finished.wait(timeout: .now() + 1)
            }
            throw NativeChargeBackendError.timedOut
        }
        try output.synchronize()
        guard let reader = try? FileHandle(forReadingFrom: outputURL) else {
            throw NativeChargeBackendError.malformedResponse
        }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: maximumOutputBytes + 1)) ?? Data()
        guard data.count <= maximumOutputBytes else { throw NativeChargeBackendError.oversizedResponse }
        return NativeChargeProcessResult(status: process.terminationStatus, output: data)
    }
}
