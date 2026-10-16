import Foundation

struct ChargePolicy: Codable, Equatable {
    let schemaVersion: Int
    var desiredLimit: Int
    var enabled: Bool
    var lastVerifiedNativeLimit: Int?
    var lastOperationID: UUID?
    var lastVerifiedAt: Date?

    init(desiredLimit: Int, enabled: Bool, lastVerifiedNativeLimit: Int? = nil,
         lastOperationID: UUID? = nil, lastVerifiedAt: Date? = nil) {
        schemaVersion = 1
        self.desiredLimit = desiredLimit
        self.enabled = enabled
        self.lastVerifiedNativeLimit = lastVerifiedNativeLimit
        self.lastOperationID = lastOperationID
        self.lastVerifiedAt = lastVerifiedAt
    }
}

struct TopUpSession: Codable, Equatable {
    enum Phase: String, Codable { case starting, charging, restoring, recoveryRequired }

    let schemaVersion: Int
    let id: UUID
    let originExecutionID: UUID?
    let startedAt: Date
    let deadline: Date
    let previousNativeLimit: Int
    let restoreLimit: Int
    var phase: Phase
    var nonChargingSamples: Int
    var failureReason: String?

    init(id: UUID = UUID(), originExecutionID: UUID?, startedAt: Date, deadline: Date,
         previousNativeLimit: Int, restoreLimit: Int, phase: Phase,
         nonChargingSamples: Int = 0, failureReason: String? = nil) {
        schemaVersion = 1
        self.id = id
        self.originExecutionID = originExecutionID
        self.startedAt = startedAt
        self.deadline = deadline
        self.previousNativeLimit = previousNativeLimit
        self.restoreLimit = restoreLimit
        self.phase = phase
        self.nonChargingSamples = nonChargingSamples
        self.failureReason = failureReason
    }
}

struct ChargeTelemetry: Equatable {
    var sampledAt: Date
    var percentage: Int
    var hardwarePercentage: Int
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var batteryWatts: Double
}

enum ChargePolicyTrigger: Equatable { case startup, telemetry, wake, powerSourceChange, user }
enum ChargePolicyIntent: Equatable {
    case none
    case adoptNativeLimit
    case reapplyPolicy
    case startTopUp(originExecutionID: UUID?)
    case cancelTopUp
}

enum ChargePolicyCommand: Equatable {
    case none
    case write(limit: Int, source: ChargeControlCoordinator.Source)
}

enum ChargePolicyState: Equatable {
    case idle
    case maintainingLimit(Int)
    case pausedByConflict(expected: Int, observed: Int)
    case topUpStarting
    case topUpCharging(Int?)
    case topUpRestoring(Int)
    case recoveryRequired(String)
}

struct ChargePolicyEvaluationInput {
    let policy: ChargePolicy?
    let session: TopUpSession?
    let nativeState: NativeChargeState?
    let telemetry: ChargeTelemetry
    let intent: ChargePolicyIntent
    let rivalRunning: Bool
    let coordinatorRecovery: Bool
    let now: Date
    let trigger: ChargePolicyTrigger
    var externalChangeResponse: ExternalChangeResponse = .ask
    var autoReapplyAllowed: Bool = true
}

struct ChargePolicyDecision {
    let state: ChargePolicyState
    let command: ChargePolicyCommand
    let policy: ChargePolicy?
    let session: TopUpSession?
    let clearSession: Bool
    let message: String?
}

enum ChargePolicyEngine {
    static func evaluate(_ input: ChargePolicyEvaluationInput) -> ChargePolicyDecision {
        if input.coordinatorRecovery {
            var session = input.session
            session?.phase = .recoveryRequired
            session?.failureReason = String(localized: "Önceki yazma işlemi doğrulanamadı.")
            return decision(.recoveryRequired(String(localized: "Önceki yazma işlemi doğrulanamadı.")), policy: input.policy,
                            session: session)
        }
        if input.rivalRunning {
            return decision(.recoveryRequired(String(localized: "Başka bir şarj denetleyicisi çalışıyor.")), policy: input.policy,
                            session: input.session)
        }
        guard let native = input.nativeState else {
            return decision(.recoveryRequired(String(localized: "Yerel şarj durumu okunamadı.")), policy: input.policy,
                            session: input.session)
        }

        if let session = input.session {
            return evaluateTopUp(input, native: native, session: session)
        }
        if case .startTopUp(let originExecutionID) = input.intent {
            return startTopUp(input, native: native, originExecutionID: originExecutionID)
        }
        return evaluatePolicy(input, native: native)
    }

    private static func startTopUp(_ input: ChargePolicyEvaluationInput, native: NativeChargeState,
                                   originExecutionID: UUID?) -> ChargePolicyDecision {
        guard input.telemetry.externalConnected else {
            return decision(.recoveryRequired(String(localized: "Top Up için adaptör bağlı olmalı.")), policy: input.policy)
        }
        guard native.availableLimits.contains(100) else {
            return decision(.recoveryRequired("Bu Mac %100 yerel limitini desteklemiyor."), policy: input.policy)
        }
        guard native.availableLimits.contains(native.manualLimit) else {
            return decision(.recoveryRequired(String(localized: "Mevcut %\(native.manualLimit) limiti Top Up sonrasında tam olarak geri yüklenemez.")),
                            policy: input.policy)
        }
        let phase: TopUpSession.Phase = native.manualLimit == 100 ? .charging : .starting
        let session = TopUpSession(originExecutionID: originExecutionID, startedAt: input.now,
                                   deadline: input.now.addingTimeInterval(10_800),
                                   previousNativeLimit: native.manualLimit,
                                   restoreLimit: native.manualLimit, phase: phase)
        let command: ChargePolicyCommand = native.manualLimit == 100
            ? .none : .write(limit: 100, source: .topUp)
        return decision(phase == .charging ? .topUpCharging(input.telemetry.percentage) : .topUpStarting, command: command,
                        policy: input.policy, session: session)
    }

    private static func evaluateTopUp(_ input: ChargePolicyEvaluationInput, native: NativeChargeState,
                                      session original: TopUpSession) -> ChargePolicyDecision {
        var session = original
        if session.phase == .recoveryRequired {
            return decision(.recoveryRequired(session.failureReason ?? String(localized: "Top Up geri yüklemesi doğrulanmalı.")),
                            policy: input.policy, session: session)
        }

        if session.phase == .restoring {
            if native.manualLimit == session.restoreLimit {
                let state = input.policy?.enabled == true
                    ? ChargePolicyState.maintainingLimit(input.policy!.desiredLimit) : .idle
                return decision(state, policy: input.policy, session: session, clearSession: true)
            }
            guard native.availableLimits.contains(session.restoreLimit) else {
                session.phase = .recoveryRequired
                session.failureReason = String(localized: "Kaydedilmiş geri yükleme limiti artık desteklenmiyor.")
                return decision(.recoveryRequired(session.failureReason!), policy: input.policy, session: session)
            }
            return decision(.topUpRestoring(session.restoreLimit),
                            command: .write(limit: session.restoreLimit,
                                            source: recoverySource(for: input.trigger)),
                            policy: input.policy, session: session)
        }

        if session.phase == .starting {
            if native.manualLimit == 100 {
                session.phase = .charging
                return decision(.topUpCharging(input.telemetry.percentage), policy: input.policy, session: session)
            }
            guard native.availableLimits.contains(100) else {
                session.phase = .recoveryRequired
                session.failureReason = String(localized: "%100 limiti artık desteklenmiyor.")
                return decision(.recoveryRequired(session.failureReason!), policy: input.policy, session: session)
            }
            return decision(.topUpStarting,
                            command: .write(limit: 100, source: recoverySource(for: input.trigger, default: .topUp)),
                            policy: input.policy, session: session)
        }

        guard native.manualLimit == 100 else {
            session.phase = .recoveryRequired
            session.failureReason = String(localized: "Top Up sırasında yerel limit dışarıdan değişti.")
            return decision(.recoveryRequired(session.failureReason!), policy: input.policy, session: session)
        }

        let restoreRequested: Bool
        if case .cancelTopUp = input.intent { restoreRequested = true }
        else {
            let fresh = input.telemetry.sampledAt <= input.now
                && input.now.timeIntervalSince(input.telemetry.sampledAt) <= 10
            if fresh, input.telemetry.hardwarePercentage >= 99,
               !input.telemetry.isCharging, input.telemetry.batteryWatts <= 0.5 {
                session.nonChargingSamples += 1
            } else {
                session.nonChargingSamples = 0
            }
            restoreRequested = (input.trigger == .powerSourceChange && !input.telemetry.externalConnected)
                || input.now >= session.deadline
                || input.telemetry.fullyCharged
                || session.nonChargingSamples >= 2
        }

        guard restoreRequested else {
            return decision(.topUpCharging(input.telemetry.percentage), policy: input.policy, session: session)
        }
        session.phase = .restoring
        if native.manualLimit == session.restoreLimit {
            let state = input.policy?.enabled == true
                ? ChargePolicyState.maintainingLimit(input.policy!.desiredLimit) : .idle
            return decision(state, policy: input.policy, session: session, clearSession: true)
        }
        return decision(.topUpRestoring(session.restoreLimit),
                        command: .write(limit: session.restoreLimit, source: .restore),
                        policy: input.policy, session: session)
    }

    private static func evaluatePolicy(_ input: ChargePolicyEvaluationInput,
                                       native: NativeChargeState) -> ChargePolicyDecision {
        guard var policy = input.policy, policy.enabled else {
            return decision(.idle, policy: input.policy)
        }
        guard native.availableLimits.contains(policy.desiredLimit) else {
            return decision(.recoveryRequired(String(localized: "Kaydedilmiş hedef bu Mac tarafından desteklenmiyor.")), policy: policy)
        }
        if case .adoptNativeLimit = input.intent {
            guard native.availableLimits.contains(native.manualLimit) else {
                return decision(.recoveryRequired("Okunan yerel limit desteklenmiyor."), policy: policy)
            }
            policy.desiredLimit = native.manualLimit
            return decision(.maintainingLimit(native.manualLimit), policy: policy)
        }
        if native.manualLimit == policy.desiredLimit {
            return decision(.maintainingLimit(policy.desiredLimit), policy: policy)
        }
        if case .reapplyPolicy = input.intent {
            return decision(.pausedByConflict(expected: policy.desiredLimit, observed: native.manualLimit),
                            command: .write(limit: policy.desiredLimit, source: .manual), policy: policy)
        }
        if case .none = input.intent {
            switch input.externalChangeResponse {
            case .adopt where native.availableLimits.contains(native.manualLimit):
                policy.desiredLimit = native.manualLimit
                return decision(.maintainingLimit(native.manualLimit), policy: policy)
            case .reapply where input.autoReapplyAllowed:
                return decision(.pausedByConflict(expected: policy.desiredLimit, observed: native.manualLimit),
                                command: .write(limit: policy.desiredLimit, source: .manual), policy: policy)
            default: break
            }
        }
        return decision(.pausedByConflict(expected: policy.desiredLimit, observed: native.manualLimit),
                        policy: policy)
    }

    private static func recoverySource(for trigger: ChargePolicyTrigger,
                                       default fallback: ChargeControlCoordinator.Source = .restore)
        -> ChargeControlCoordinator.Source {
        trigger == .startup || trigger == .wake ? .wakeRecovery : fallback
    }

    private static func decision(_ state: ChargePolicyState,
                                 command: ChargePolicyCommand = .none,
                                 policy: ChargePolicy?,
                                 session: TopUpSession? = nil,
                                 clearSession: Bool = false,
                                 message: String? = nil) -> ChargePolicyDecision {
        .init(state: state, command: command, policy: policy, session: session,
              clearSession: clearSession, message: message)
    }
}

enum ChargePolicyPresentationAction: Equatable {
    case reapplyChargeMateTarget
    case adoptMacOSValue
    case acknowledgeRecovery
}

extension ChargePolicyState {
    var title: String {
        switch self {
        case .idle: return String(localized: "Şarj denetimi hazır")
        case .maintainingLimit(let limit): return String(localized: "Limit korunuyor: %\(limit)")
        case .topUpStarting: return String(localized: "Top Up başlatılıyor")
        case .topUpCharging(let percent): return String(localized: "Top Up: %\(percent ?? 0) → %100")
        case .topUpRestoring(let limit): return String(localized: "Önceki limite dönülüyor: %\(limit)")
        case .pausedByConflict(_, let observed): return String(localized: "macOS limiti dışarıdan %\(observed) yapıldı")
        case .recoveryRequired: return String(localized: "Kontrol gerekli; yeni işlem durduruldu")
        }
    }

    var availableActions: [ChargePolicyPresentationAction] {
        switch self {
        case .pausedByConflict: return [.reapplyChargeMateTarget, .adoptMacOSValue]
        case .recoveryRequired: return [.acknowledgeRecovery]
        default: return []
        }
    }

    var menubarText: String {
        if case .topUpCharging(let percent) = self { return "Top Up %\(percent ?? 0)" }
        return title
    }
}

enum ChargeStoreError: Error, Equatable { case blocked }

struct ChargeStoreLoad<Value> {
    let value: Value?
    let issue: String?
    let blocked: Bool
}

private struct ChargeJSONStore<Value: Codable> {
    let url: URL
    let currentSchema: Int
    let schema: (Value) -> Int

    func load() -> ChargeStoreLoad<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(value: nil, issue: nil, blocked: false)
        }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(Value.self, from: data)
            guard schema(value) == currentSchema else {
                backup(data)
                return .init(value: nil, issue: String(localized: "Desteklenmeyen kayıt sürümü."), blocked: true)
            }
            return .init(value: value, issue: nil, blocked: false)
        } catch {
            if let data = try? Data(contentsOf: url) { backup(data) }
            return .init(value: nil, issue: error.localizedDescription, blocked: true)
        }
    }

    func save(_ value: Value) throws {
        if load().blocked { throw ChargeStoreError.blocked }
        try replace(with: value)
    }

    func reconcile(with value: Value) throws { try replace(with: value) }

    func clear() throws {
        if load().blocked { throw ChargeStoreError.blocked }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func replace(with value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func backup(_ data: Data) {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".invalid-"
        if let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil),
           files.contains(where: { candidate in
               guard candidate.lastPathComponent.hasPrefix(prefix),
                     let existing = try? Data(contentsOf: candidate) else { return false }
               return existing == data
           }) { return }
        let backup = directory.appendingPathComponent(prefix + UUID().uuidString + ".backup")
        try? data.write(to: backup, options: .atomic)
    }
}

struct ChargePolicyStore {
    let url: URL
    private var store: ChargeJSONStore<ChargePolicy> {
        .init(url: url, currentSchema: 1, schema: { $0.schemaVersion })
    }
    func load() -> ChargeStoreLoad<ChargePolicy> { store.load() }
    func save(_ value: ChargePolicy) throws { try store.save(value) }
    func reconcile(with value: ChargePolicy) throws { try store.reconcile(with: value) }
}

struct TopUpSessionStore {
    let url: URL
    private var store: ChargeJSONStore<TopUpSession> {
        .init(url: url, currentSchema: 1, schema: { $0.schemaVersion })
    }
    func load() -> ChargeStoreLoad<TopUpSession> { store.load() }
    func save(_ value: TopUpSession) throws { try store.save(value) }
    func reconcile(with value: TopUpSession) throws { try store.reconcile(with: value) }
    func clear() throws { try store.clear() }
}
