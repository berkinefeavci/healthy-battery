import Foundation

struct ChargePolicyEvent: Equatable {
    enum Kind: Equatable { case stateChanged, topUpFinished, topUpFailed }
    let kind: Kind
    let originExecutionID: UUID?
    let message: String
}

extension Notification.Name {
    static let chargeMatePolicyEvent = Notification.Name("ChargeMatePolicyEvent")
}

/// Synchronous transaction boundary. Production calls it only from BatteryMonitor's control queue.
final class ChargePolicyController {
    private let backend: NativeChargeBackend
    private let coordinator: ChargeControlCoordinator
    private let policyStore: ChargePolicyStore
    private let sessionStore: TopUpSessionStore
    private let rival: () -> Bool
    private let now: () -> Date
    private var persistenceRecovery = false
    var externalChangeResponse: ExternalChangeResponse = .ask
    private var externalGate = ExternalChangeGate()

    private(set) var state: ChargePolicyState = .idle
    private(set) var policy: ChargePolicy?
    private(set) var session: TopUpSession?
    private(set) var lastResult: ChargeControlCoordinator.Result?

    var isBusy: Bool { coordinator.isBusy }
    var requiresRecovery: Bool { persistenceRecovery || coordinator.requiresRecovery || state.isRecovery }
    var topUpActive: Bool { session != nil }
    var topUpRestoreLimit: Int? { session?.restoreLimit }
    var conflict: (expected: Int, observed: Int)? {
        guard case .pausedByConflict(let expected, let observed) = state else { return nil }
        return (expected, observed)
    }

    init(backend: NativeChargeBackend, coordinator: ChargeControlCoordinator,
         policyStore: ChargePolicyStore, sessionStore: TopUpSessionStore,
         rival: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.coordinator = coordinator
        self.policyStore = policyStore
        self.sessionStore = sessionStore
        self.rival = rival
        self.now = now
        let policyLoad = policyStore.load()
        let sessionLoad = sessionStore.load()
        policy = policyLoad.value
        session = sessionLoad.value
        if policyLoad.blocked || sessionLoad.blocked {
            persistenceRecovery = true
            state = .recoveryRequired(policyLoad.issue ?? sessionLoad.issue ?? String(localized: "Şarj kaydı doğrulanamadı."))
        }
    }

    func applyManualLimit(_ limit: Int, source: ChargeControlCoordinator.Source = .manual,
                          request: ChargeControlCoordinator.Request? = nil)
        -> ChargeControlCoordinator.Result {
        guard !persistenceRecovery else { return blockedResult(String(localized: "Şarj politika kaydı doğrulanmalı.")) }
        let result = request.map(coordinator.apply) ?? coordinator.apply(limit, source: source)
        lastResult = result
        guard result.status == .configurationVerified, let native = result.state else {
            if result.status == .recoveryRequired { state = .recoveryRequired(result.message) }
            return result
        }
        var updated = ChargePolicy(desiredLimit: limit, enabled: true)
        updated.lastVerifiedNativeLimit = native.manualLimit
        updated.lastOperationID = result.operationID
        updated.lastVerifiedAt = now()
        do {
            try policyStore.save(updated)
            policy = updated
            state = .maintainingLimit(limit)
            return result
        } catch {
            persistenceRecovery = true
            state = .recoveryRequired(String(localized: "Limit doğrulandı fakat politika kaydı korunamadı."))
            return .init(operationID: result.operationID, status: .recoveryRequired, state: result.state,
                         message: String(localized: "Limit doğrulandı fakat politika kaydı korunamadı; yeni işlem engellendi."))
        }
    }

    func startTopUp(originExecutionID: UUID? = nil,
                    telemetry: ChargeTelemetry) -> ChargeControlCoordinator.Result {
        run(telemetry: telemetry, trigger: .user, intent: .startTopUp(originExecutionID: originExecutionID)).result
            ?? readOnlyResult(message: String(localized: "Top Up durumu doğrulandı."))
    }

    func cancelTopUp(telemetry: ChargeTelemetry) -> ChargeControlCoordinator.Result {
        run(telemetry: telemetry, trigger: .user, intent: .cancelTopUp).result
            ?? readOnlyResult(message: String(localized: "Top Up etkin değil."))
    }

    func evaluate(telemetry: ChargeTelemetry, trigger: ChargePolicyTrigger) -> ChargePolicyEvent? {
        run(telemetry: telemetry, trigger: trigger, intent: .none).event
    }

    func adoptObservedLimit() throws {
        guard !persistenceRecovery else { throw ChargeStoreError.blocked }
        let native = try backend.readState()
        var updated = policy ?? ChargePolicy(desiredLimit: native.manualLimit, enabled: true)
        updated.desiredLimit = native.manualLimit
        updated.lastVerifiedNativeLimit = native.manualLimit
        updated.lastVerifiedAt = now()
        try policyStore.save(updated)
        policy = updated
        state = .maintainingLimit(native.manualLimit)
    }

    func reapplyPolicy() -> ChargeControlCoordinator.Result {
        guard let policy, policy.enabled else { return blockedResult("Etkin bir Healthy Battery hedefi yok.", recovery: false) }
        return applyManualLimit(policy.desiredLimit)
    }

    func reconcileObservedLimit(_ expectedLimit: Int) -> ChargeControlCoordinator.Result {
        let result = coordinator.reconcile(expectedLimit: expectedLimit)
        lastResult = result
        if result.status == .reconciled {
            persistenceRecovery = false
            if let policy, policy.enabled { state = .maintainingLimit(policy.desiredLimit) }
            else { state = .idle }
        } else if result.status == .recoveryRequired {
            state = .recoveryRequired(result.message)
        }
        return result
    }

    private func run(telemetry: ChargeTelemetry, trigger: ChargePolicyTrigger,
                     intent: ChargePolicyIntent) -> (result: ChargeControlCoordinator.Result?, event: ChargePolicyEvent?) {
        let policyLoad = policyStore.load()
        let sessionLoad = sessionStore.load()
        if policyLoad.blocked || sessionLoad.blocked {
            persistenceRecovery = true
        } else {
            policy = policyLoad.value
            session = sessionLoad.value
        }
        guard !persistenceRecovery else {
            state = .recoveryRequired(String(localized: "Şarj politika kaydı doğrulanmalı."))
            return (blockedResult(String(localized: "Şarj politika kaydı doğrulanmalı.")), nil)
        }
        let native: NativeChargeState?
        do { native = try backend.readState() }
        catch {
            state = .recoveryRequired(String(localized: "Yerel şarj durumu okunamadı: \(error.localizedDescription)"))
            return (blockedResult(String(localized: "Yerel şarj durumu okunamadı."), recovery: false), nil)
        }
        let input = ChargePolicyEvaluationInput(policy: policy, session: session, nativeState: native,
                                                telemetry: telemetry, intent: intent,
                                                rivalRunning: rival(), coordinatorRecovery: coordinator.requiresRecovery,
                                                now: now(), trigger: trigger,
                                                externalChangeResponse: externalChangeResponse,
                                                autoReapplyAllowed: native.map {
                                                    externalGate.allowsAutoReapply(observed: $0.manualLimit, now: now())
                                                } ?? false)
        let evaluated = ChargePolicyEngine.evaluate(input)
        var automatic = false
        if case .none = intent, case .write(_, .manual) = evaluated.command,
           case .pausedByConflict = evaluated.state { automatic = true }
        return execute(evaluated, telemetry: telemetry, trigger: trigger, automaticReapply: automatic)
    }

    private func execute(_ evaluated: ChargePolicyDecision, telemetry: ChargeTelemetry,
                         trigger: ChargePolicyTrigger,
                         automaticReapply: Bool = false) -> (result: ChargeControlCoordinator.Result?, event: ChargePolicyEvent?) {
        state = evaluated.state
        if evaluated.policy != policy, let updated = evaluated.policy {
            do { try policyStore.save(updated); policy = updated }
            catch { return persistenceFailure(String(localized: "Şarj politikası kaydedilemedi."), session: evaluated.session) }
        }
        if let updated = evaluated.session {
            do { try sessionStore.save(updated); session = updated }
            catch { return persistenceFailure("Top Up oturumu kaydedilemedi.", session: updated) }
        }
        if evaluated.clearSession {
            do { try sessionStore.clear(); session = nil }
            catch { return persistenceFailure("Tamamlanan Top Up oturumu temizlenemedi.", session: evaluated.session) }
            return (nil, .init(kind: .topUpFinished,
                               originExecutionID: evaluated.session?.originExecutionID,
                               message: String(localized: "Top Up tamamlandı; önceki limit geri yüklendi.")))
        }

        guard case .write(let limit, let source) = evaluated.command else { return (nil, nil) }
        let origin = evaluated.session?.originExecutionID
        let restoring = evaluated.session?.phase == .restoring
        if automaticReapply { externalGate.recordAutoReapply(at: now()) }
        let result = coordinator.apply(limit, source: source)
        lastResult = result
        guard result.status == .configurationVerified, let verified = result.state else {
            if automaticReapply {
                // One automatic attempt per external change: fall back to asking instead of looping.
                if case .pausedByConflict(_, let observed) = evaluated.state {
                    externalGate.recordFailure(observed: observed)
                    if result.status != .recoveryRequired { return (result, nil) }
                }
            }
            var failed = evaluated.session
            failed?.phase = .recoveryRequired
            failed?.failureReason = result.message
            if let failed {
                do { try sessionStore.save(failed); session = failed }
                catch { persistenceRecovery = true }
            }
            state = .recoveryRequired(result.message)
            let event = evaluated.session == nil ? nil
                : ChargePolicyEvent(kind: .topUpFailed, originExecutionID: origin, message: result.message)
            return (result, event)
        }

        let verifiedInput = ChargePolicyEvaluationInput(policy: policy, session: evaluated.session,
                                                        nativeState: verified, telemetry: telemetry, intent: .none,
                                                        rivalRunning: rival(), coordinatorRecovery: coordinator.requiresRecovery,
                                                        now: now(), trigger: trigger)
        let verifiedDecision = ChargePolicyEngine.evaluate(verifiedInput)
        state = verifiedDecision.state
        if verifiedDecision.clearSession {
            do { try sessionStore.clear(); session = nil }
            catch { return persistenceFailure(String(localized: "Doğrulanan geri yükleme kaydı temizlenemedi."), session: evaluated.session) }
            let event = restoring
                ? ChargePolicyEvent(kind: .topUpFinished, originExecutionID: origin,
                                    message: String(localized: "Top Up tamamlandı; önceki limit geri yüklendi.")) : nil
            return (result, event)
        }
        if let updated = verifiedDecision.session {
            do { try sessionStore.save(updated); session = updated }
            catch { return persistenceFailure(String(localized: "Doğrulanan Top Up durumu kaydedilemedi."), session: updated) }
        }
        return (result, nil)
    }

    private func persistenceFailure(_ message: String, session failedSession: TopUpSession?)
        -> (result: ChargeControlCoordinator.Result?, event: ChargePolicyEvent?) {
        persistenceRecovery = true
        var failed = failedSession
        failed?.phase = .recoveryRequired
        failed?.failureReason = message
        session = failed
        state = .recoveryRequired(message)
        return (blockedResult(message), failed.map {
            .init(kind: .topUpFailed, originExecutionID: $0.originExecutionID, message: message)
        })
    }

    private func blockedResult(_ message: String, recovery: Bool = true) -> ChargeControlCoordinator.Result {
        .init(operationID: UUID(), status: recovery ? .recoveryRequired : .rejected,
              state: nil, message: message)
    }

    private func readOnlyResult(message: String) -> ChargeControlCoordinator.Result {
        .init(operationID: UUID(), status: .configurationVerified,
              state: try? backend.readState(), message: message)
    }
}

private extension ChargePolicyState {
    var isRecovery: Bool {
        if case .recoveryRequired = self { return true }
        return false
    }
}
