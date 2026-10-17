import Foundation

@main enum MagSafeLEDCoordinatorTests {
    static func main() throws {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool) { precondition(condition()); assertions += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chargemate-led-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func path(_ name: String = UUID().uuidString) -> URL { root.appendingPathComponent(name).appendingPathComponent("session.json") }
        let supported: Set<MagSafeLEDOutput> = [.system, .off, .green, .orange]

        expect(MagSafeLEDRawCodec.decode(0) == .system)
        expect(MagSafeLEDRawCodec.decode(1) == .off)
        expect(MagSafeLEDRawCodec.decode(3) == .green)
        expect(MagSafeLEDRawCodec.decode(4) == .orange)
        expect(MagSafeLEDRawCodec.decode(2) == nil)
        for output in MagSafeLEDOutput.allCases { expect(MagSafeLEDRawCodec.decode(MagSafeLEDRawCodec.encode(output)) == output) }

        var value = MagSafeLEDOutput.green
        var writes: [MagSafeLEDOutput] = []
        let journal = path("normal")
        let coordinator = MagSafeLEDControlCoordinator(journal: journal, backend: .init(
            supportedOutputs: supported, read: { value }, write: { value = $0; writes.append($0) }
        ))
        expect(coordinator.apply(.green) == .unchanged)
        expect(writes.isEmpty)
        expect(coordinator.apply(.orange) == .applied)
        expect(value == .orange && writes == [.orange] && coordinator.requiresRecovery)
        // A second test colour is written directly; the original baseline is kept.
        expect(coordinator.apply(.off) == .applied)
        expect(value == .off && writes == [.orange, .off] && coordinator.sessionActive)
        expect(coordinator.apply(.off) == .unchanged && writes == [.orange, .off])

        let restarted = MagSafeLEDControlCoordinator(journal: journal, backend: .init(
            supportedOutputs: supported, read: { value }, write: { value = $0; writes.append($0) }
        ))
        expect(restarted.requiresRecovery && restarted.sessionActive)
        expect(restarted.restore() == .restored)
        expect(value == .green && writes == [.orange, .off, .green])
        expect(!FileManager.default.fileExists(atPath: journal.path))

        var unsupportedWrites = 0
        let unsupported = MagSafeLEDControlCoordinator(journal: path(), backend: .init(
            supportedOutputs: [.system, .green], read: { .green }, write: { _ in unsupportedWrites += 1 }
        ))
        expect(unsupported.apply(.orange) == .blocked("Bu LED çıktısı backend tarafından desteklenmiyor."))
        expect(unsupportedWrites == 0)

        let mismatch = MagSafeLEDOutput.green
        var uncertainWrites: [MagSafeLEDOutput] = []
        let uncertainJournal = path("uncertain")
        let uncertain = MagSafeLEDControlCoordinator(journal: uncertainJournal, backend: .init(
            supportedOutputs: supported, read: { mismatch }, write: { uncertainWrites.append($0) }
        ))
        expect(uncertain.apply(.off) == .blocked("LED yazma sonucu doğrulanamadı; geri yükleme gerekli."))
        expect(uncertain.requiresRecovery && !uncertain.sessionActive)
        expect(uncertain.apply(.orange) == .blocked("Önceki LED oturumu geri yüklenmeyi bekliyor."))
        expect(uncertain.restore() == .restored)
        expect(uncertainWrites == [.off, .green])

        var external = MagSafeLEDOutput.green
        var externalWrites = 0
        let externalCoordinator = MagSafeLEDControlCoordinator(journal: path("external"), backend: .init(
            supportedOutputs: supported, read: { external }, write: { external = $0; externalWrites += 1 }
        ))
        expect(externalCoordinator.apply(.orange) == .applied)
        external = .off // Another owner changed it after our verified write.
        expect(externalCoordinator.restore() == .blocked("LED durumu dışarıdan değişti; otomatik geri yükleme yapılmadı."))
        expect(external == .off && externalWrites == 1 && externalCoordinator.requiresRecovery)

        try FileManager.default.createDirectory(at: path("corrupt").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: path("corrupt"))
        let corrupt = MagSafeLEDControlCoordinator(journal: path("corrupt"), backend: .init(
            supportedOutputs: supported, read: { .green }, write: { _ in }
        ))
        expect(corrupt.requiresRecovery)
        expect(corrupt.apply(.off) == .blocked("Önceki LED oturumu okunamıyor."))

        print("MagSafe LED coordinator: \(assertions) assertions passed; fake backend only, no hardware writes.")
    }
}
