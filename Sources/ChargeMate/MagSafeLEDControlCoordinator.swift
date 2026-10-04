import Foundation

enum MagSafeLEDRawCodec {
    static func decode(_ value: UInt8) -> MagSafeLEDOutput? {
        switch value {
        case 0: return .system
        case 1: return .off
        case 3: return .green
        case 4: return .orange
        default: return nil
        }
    }

    static func encode(_ output: MagSafeLEDOutput) -> UInt8? {
        switch output {
        case .system: return 0
        case .off: return 1
        case .green: return 3
        case .orange: return 4
        case .blinkingOrange: return nil
        }
    }
}

/// Crash-aware ownership for a future privileged LED backend. Production deliberately does
/// not construct this coordinator until the physical protocol and helper are approved.
final class MagSafeLEDControlCoordinator {
    struct Backend {
        let supportedOutputs: Set<MagSafeLEDOutput>
        let read: () throws -> MagSafeLEDOutput
        let write: (MagSafeLEDOutput) throws -> Void
    }

    struct Session: Codable, Equatable {
        enum Stage: String, Codable { case pending, active, uncertain }
        let id: UUID
        let startedAt: Date
        let baseline: MagSafeLEDOutput
        var requested: MagSafeLEDOutput
        var stage: Stage
    }

    enum Outcome: Equatable {
        case applied
        case unchanged
        case restored
        case blocked(String)
    }

    private let journal: URL
    private let backend: Backend
    private(set) var session: Session?
    private(set) var journalCorrupt = false

    var requiresRecovery: Bool { session != nil || journalCorrupt }
    /// A manual test whose last write was verified; another test colour can follow directly.
    var sessionActive: Bool { !journalCorrupt && session?.stage == .active }

    init(journal: URL, backend: Backend) {
        self.journal = journal
        self.backend = backend
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        do { session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: journal)) }
        catch { journalCorrupt = true }
    }

    func apply(_ output: MagSafeLEDOutput) -> Outcome {
        guard !journalCorrupt else { return .blocked(String(localized: "Önceki LED oturumu okunamıyor.")) }
        guard output != .blinkingOrange, backend.supportedOutputs.contains(output) else {
            return .blocked(String(localized: "Bu LED çıktısı backend tarafından desteklenmiyor."))
        }
        if let current = session {
            // Switching colours during a test writes the new one directly and keeps the original
            // baseline; restoring in between doubled every press (two settle waits).
            guard current.stage == .active else {
                return .blocked(String(localized: "Önceki LED oturumu geri yüklenmeyi bekliyor."))
            }
            guard current.requested != output else { return .unchanged }
            var next = current
            next.requested = output; next.stage = .pending
            do { try save(next) } catch { return .blocked(String(localized: "LED geri dönüş kaydı oluşturulamadı.")) }
            session = next
            return write(output, session: next)
        }
        let baseline: MagSafeLEDOutput
        do { baseline = try backend.read() }
        catch { return .blocked(String(localized: "Başlangıç LED durumu okunamadı.")) }
        guard backend.supportedOutputs.contains(baseline) else {
            return .blocked(String(localized: "Başlangıç LED durumu güvenle geri yüklenemiyor."))
        }
        guard baseline != output else { return .unchanged }

        var next = Session(id: UUID(), startedAt: Date(), baseline: baseline, requested: output, stage: .pending)
        do { try save(next) }
        catch { return .blocked(String(localized: "LED geri dönüş kaydı oluşturulamadı.")) }
        session = next
        return write(output, session: next)
    }

    private func write(_ output: MagSafeLEDOutput, session pending: Session) -> Outcome {
        var next = pending
        do {
            try backend.write(output)
            guard try backend.read() == output else {
                next.stage = .uncertain; try? save(next); session = next
                return .blocked(String(localized: "LED yazma sonucu doğrulanamadı; geri yükleme gerekli."))
            }
            next.stage = .active; try save(next); session = next
            return .applied
        } catch {
            next.stage = .uncertain; try? save(next); session = next
            return .blocked(String(localized: "LED yazması tamamlanamadı; geri yükleme gerekli."))
        }
    }

    func restore() -> Outcome {
        guard !journalCorrupt else { return .blocked(String(localized: "Bozuk LED oturum kaydı otomatik geri yüklenemez.")) }
        guard let session else { return .unchanged }
        do {
            let observed = try backend.read()
            // Another process may have taken ownership while Healthy Battery was closed.
            // Never overwrite an output that is neither ours nor the saved baseline.
            guard observed == session.baseline || observed == session.requested else {
                return .blocked(String(localized: "LED durumu dışarıdan değişti; otomatik geri yükleme yapılmadı."))
            }
            // An uncertain write can arrive late even when the first read still
            // equals baseline. Reassert the baseline before clearing its journal.
            if observed != session.baseline || session.stage == .uncertain {
                try backend.write(session.baseline)
                guard try backend.read() == session.baseline else {
                    return .blocked(String(localized: "Başlangıç LED durumu geri yüklenemedi."))
                }
            }
            try FileManager.default.removeItem(at: journal)
            self.session = nil
            return .restored
        } catch {
            return .blocked(String(localized: "Başlangıç LED durumu geri yüklenemedi."))
        }
    }

    private func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: journal, options: .atomic)
    }
}
