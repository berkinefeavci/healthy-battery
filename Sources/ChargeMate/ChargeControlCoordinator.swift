import Foundation

/// Sole transaction owner for native charge-limit writes.
final class ChargeControlCoordinator {
    enum Status: String, Codable {
        case pending, rejected, busy, cancelled, configurationVerified, recoveryRequired, reconciled
    }

    enum Source: String, Codable {
        case manual, topUp, restore, schedule, shortcut, wakeRecovery, heatProtection
    }

    final class Request {
        let id: UUID
        let requested: Int
        let source: Source
        private let lock = NSLock()
        private var cancelled = false
        private var enteredWriter = false

        init(_ requested: Int, source: Source = .manual, id: UUID = UUID()) {
            self.requested = requested
            self.source = source
            self.id = id
        }

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func beginWrite() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled, !enteredWriter else { return false }
            enteredWriter = true
            return true
        }
    }

    struct Session: Codable {
        let schemaVersion: Int
        let id: UUID
        let requested: Int
        let previous: Int
        let startedAt: Date
        var finishedAt: Date?
        var status: Status
        let source: Source
        let backendVersion: String
        var failureReason: String?

        init(id: UUID, requested: Int, previous: Int, startedAt: Date, status: Status,
             source: Source, backendVersion: String, finishedAt: Date? = nil,
             failureReason: String? = nil) {
            schemaVersion = 2
            self.id = id
            self.requested = requested
            self.previous = previous
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.status = status
            self.source = source
            self.backendVersion = backendVersion
            self.failureReason = failureReason
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, id, requested, previous, startedAt, date, finishedAt
            case status, source, backendVersion, failureReason
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let schema = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard schema == 1 || schema == 2 else { throw CocoaError(.fileReadUnsupportedScheme) }
            schemaVersion = 2
            id = try values.decode(UUID.self, forKey: .id)
            requested = try values.decode(Int.self, forKey: .requested)
            previous = try values.decode(Int.self, forKey: .previous)
            if let value = Self.decodeDate(values, key: .startedAt) ?? Self.decodeDate(values, key: .date) {
                startedAt = value
            } else { throw CocoaError(.fileReadCorruptFile) }
            finishedAt = Self.decodeDate(values, key: .finishedAt)
            status = try values.decode(Status.self, forKey: .status)
            let rawSource = try values.decodeIfPresent(String.self, forKey: .source) ?? "manual"
            source = Source(rawValue: rawSource) ?? (rawSource == "manualApply" ? .manual : .wakeRecovery)
            backendVersion = try values.decodeIfPresent(String.self, forKey: .backendVersion) ?? "PowerUI-MCL-v1"
            failureReason = try values.decodeIfPresent(String.self, forKey: .failureReason)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(id, forKey: .id)
            try values.encode(requested, forKey: .requested)
            try values.encode(previous, forKey: .previous)
            try values.encode(startedAt, forKey: .startedAt)
            try values.encodeIfPresent(finishedAt, forKey: .finishedAt)
            try values.encode(status, forKey: .status)
            try values.encode(source, forKey: .source)
            try values.encode(backendVersion, forKey: .backendVersion)
            try values.encodeIfPresent(failureReason, forKey: .failureReason)
        }

        private static func decodeDate(_ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Date? {
            if let date = try? values.decodeIfPresent(Date.self, forKey: key) { return date }
            if let raw = try? values.decodeIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSinceReferenceDate: raw)
            }
            if let text = try? values.decode(String.self, forKey: key) {
                return ISO8601DateFormatter().date(from: text)
            }
            return nil
        }
    }

    struct Result {
        let operationID: UUID
        let status: Status
        let state: NativeChargeState?
        let message: String
    }

    let backend: NativeChargeBackend
    private let rival: () -> Bool
    private let journal: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var active = false
    private var recovery = false

    var requiresRecovery: Bool { lock.withLock { recovery } }
    var isBusy: Bool { lock.withLock { active } }

    init(journal: URL, backend: NativeChargeBackend, rival: @escaping () -> Bool,
         now: @escaping () -> Date = Date.init) {
        self.journal = journal
        self.backend = backend
        self.rival = rival
        self.now = now
        if FileManager.default.fileExists(atPath: journal.path) {
            do {
                let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: journal))
                recovery = ![Status.configurationVerified, .cancelled, .rejected, .reconciled].contains(session.status)
            } catch { recovery = true }
        }
    }

    func apply(_ requested: Int, source: Source = .manual) -> Result {
        apply(Request(requested, source: source))
    }

    func apply(_ request: Request) -> Result {
        guard admit() else {
            let status: Status = requiresRecovery ? .recoveryRequired : .busy
            let message = status == .recoveryRequired
                ? String(localized: "Önceki işlemin sonucu belirsiz. macOS Batarya ayarını kontrol edin; yeni işlem engellendi.")
                : String(localized: "Bir şarj işlemi zaten sürüyor.")
            return .init(operationID: request.id, status: status, state: nil, message: message)
        }
        defer { lock.withLock { active = false } }

        if request.isCancelled {
            return .init(operationID: request.id, status: .cancelled, state: nil,
                         message: String(localized: "İstek iptal edildi; ayar değiştirilmedi."))
        }

        let before: NativeChargeState
        do { before = try backend.readState() }
        catch {
            return .init(operationID: request.id, status: .rejected, state: nil,
                         message: String(localized: "Şarj durumu okunamadı; ayar değiştirilmedi: \(error.localizedDescription)"))
        }
        guard !rival(), before.availableLimits.contains(request.requested) else {
            return .init(operationID: request.id, status: .rejected, state: before,
                         message: String(localized: "Şarj denetimi durumu değişti veya hedef desteklenmiyor. Ayar değiştirilmedi."))
        }

        var session = Session(id: request.id, requested: request.requested,
                              previous: before.manualLimit, startedAt: now(), status: .pending,
                              source: request.source, backendVersion: backend.version)
        do { try persist(session) }
        catch {
            return .init(operationID: request.id, status: .rejected, state: before,
                         message: String(localized: "İşlem kaydı yazılamadı; ayar değiştirilmedi: \(error.localizedDescription)"))
        }

        let latest: NativeChargeState
        do { latest = try backend.readState() }
        catch {
            session.status = .rejected
            session.failureReason = error.localizedDescription
            return finishWithoutWrite(session, state: nil,
                                      message: String(localized: "Kontrol durumu yeniden okunamadı; ayar değiştirilmedi."))
        }
        if request.isCancelled {
            session.status = .cancelled
            return finishWithoutWrite(session, state: latest, message: String(localized: "İstek iptal edildi; ayar değiştirilmedi."))
        }
        guard !rival(), latest.manualLimit == before.manualLimit,
              latest.availableLimits.contains(request.requested) else {
            session.status = .rejected
            return finishWithoutWrite(session, state: latest,
                                      message: String(localized: "Kontrol durumu işlem sırasında değişti. Ayar değiştirilmedi; güncel değeri inceleyip yeniden deneyin."))
        }
        guard request.beginWrite() else {
            session.status = .cancelled
            return finishWithoutWrite(session, state: latest, message: String(localized: "İstek iptal edildi; ayar değiştirilmedi."))
        }

        if before.manualLimit == request.requested {
            session.status = .configurationVerified
            session.finishedAt = now()
            do { try persist(session) }
            catch { return journalFailure(session, state: latest, error: error) }
            return .init(operationID: request.id, status: .configurationVerified, state: latest,
                         message: String(localized: "%\(request.requested) macOS kaydı okuma ile doğrulandı."))
        }

        var writerError: Error?
        do { _ = try backend.setLimit(request.requested) }
        catch { writerError = error }
        let after = try? backend.readState()
        let verified = writerError == nil && after?.manualLimit == request.requested && !rival()
        session.status = verified ? .configurationVerified : .recoveryRequired
        session.finishedAt = now()
        session.failureReason = writerError?.localizedDescription
            ?? (verified ? nil : String(localized: "Okunan limit veya kontrol sahibi değişti."))
        do { try persist(session) }
        catch { return journalFailure(session, state: after, error: error) }
        guard verified else {
            lock.withLock { recovery = true }
            let detail = session.failureReason ?? String(localized: "İşlem sonucu doğrulanamadı.")
            return .init(operationID: request.id, status: .recoveryRequired, state: after,
                         message: detail + String(localized: " Sonuç belirsiz; otomatik geri yazma yapılmadı. macOS Batarya ayarını kontrol edin."))
        }
        let message = request.isCancelled
            ? String(localized: "İptal isteği macOS işlemi başladıktan sonra geldi. Kayıtlı %\(request.requested) okuma ile doğrulandı; geri alma yapılmadı.")
            : String(localized: "%\(request.requested) macOS kaydı okuma ile doğrulandı.")
        return .init(operationID: request.id, status: .configurationVerified, state: after, message: message)
    }

    func reconcile(expectedLimit: Int) -> Result {
        let id = UUID()
        lock.lock()
        guard !active else {
            lock.unlock()
            return .init(operationID: id, status: .busy, state: nil,
                         message: String(localized: "Devam eden macOS işleminin bitmesini bekleyin."))
        }
        guard recovery else {
            lock.unlock()
            return .init(operationID: id, status: .rejected, state: nil,
                         message: String(localized: "Çözülmesi gereken belirsiz bir işlem yok."))
        }
        active = true
        lock.unlock()
        defer { lock.withLock { active = false } }

        let state: NativeChargeState
        do { state = try backend.readState() }
        catch {
            return .init(operationID: id, status: .recoveryRequired, state: nil,
                         message: String(localized: "Güncel ayar okunamadı: \(error.localizedDescription)"))
        }
        guard !rival(), state.manualLimit == expectedLimit,
              state.availableLimits.contains(expectedLimit) else {
            return .init(operationID: id, status: .recoveryRequired, state: state,
                         message: String(localized: "Gösterilen ayar değişti, okunamadı veya başka bir şarj uygulaması açık. Güncel durumu yeniden inceleyin."))
        }
        let session = Session(id: id, requested: expectedLimit, previous: expectedLimit,
                              startedAt: now(), status: .reconciled, source: .wakeRecovery,
                              backendVersion: backend.version, finishedAt: now())
        do {
            if FileManager.default.fileExists(atPath: journal.path) {
                let backup = journal.deletingLastPathComponent()
                    .appendingPathComponent("control-session-before-recovery-\(id).json")
                try FileManager.default.copyItem(at: journal, to: backup)
            }
            try persist(session)
        } catch {
            return .init(operationID: id, status: .recoveryRequired, state: state,
                         message: String(localized: "İşlem kaydı korunamadı; kilit kaldırılmadı: \(error.localizedDescription)"))
        }
        lock.withLock { recovery = false }
        return .init(operationID: id, status: .reconciled, state: state,
                     message: String(localized: "Mevcut %\(expectedLimit) ayarı kontrol edildi. Kilit kaldırıldı; macOS ayarı değiştirilmedi. Yeni hedef için ayrıca Uygula’yı kullanın."))
    }

    private func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !recovery, !active else { return false }
        active = true
        return true
    }

    private func persist(_ session: Session) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: journal, options: .atomic)
    }

    private func finishWithoutWrite(_ session: Session, state: NativeChargeState?, message: String) -> Result {
        var finished = session
        finished.finishedAt = now()
        do { try persist(finished) }
        catch { return journalFailure(finished, state: state, error: error) }
        return .init(operationID: session.id, status: session.status, state: state, message: message)
    }

    private func journalFailure(_ session: Session, state: NativeChargeState?, error: Error) -> Result {
        lock.withLock { recovery = true }
        return .init(operationID: session.id, status: .recoveryRequired, state: state,
                     message: String(localized: "İşlem sonucu kaydedilemedi. Yeni işlem engellendi: \(error.localizedDescription)"))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
