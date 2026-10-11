import SwiftUI

private enum ScheduleSheet: Identifiable {
    case editor(ScheduleTask)
    case execution(ScheduleExecutionRecord)
    case readyBy
    var id: String {
        switch self {
        case .readyBy: return "ready-by"
        case .editor(let task): return "editor-\(task.id.uuidString)"
        case .execution(let record): return "execution-\(record.executionID.uuidString)"
        }
    }
}

struct ScheduleView: View {
    @EnvironmentObject private var battery: BatteryMonitor
    @State private var tasks: [ScheduleTask] = []
    @State private var records: [ScheduleExecutionRecord] = []
    @State private var presentedSheet: ScheduleSheet?
    @State private var warning: String?
    @State private var lastDeleted: ScheduleTask?
    @State private var historyFilter: ScheduleHistoryFilter = .all
    private let storageDirectory: URL

    init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cellkeep")
    }

    private var store: ScheduleStore {
        ScheduleStore(url: storageDirectory.appendingPathComponent("schedules.json"))
    }
    private var executionStore: ScheduleExecutionStore {
        ScheduleExecutionStore(url: storageDirectory.appendingPathComponent("schedule-executions.json"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Programlar").font(.headline)
                    Text("Programlar yerel olarak kaydedilir. Yeni görevler kapalı başlar ve kaydetmek hiçbir eylemi hemen çalıştırmaz.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(ScheduleTemplate.allCases) { template in
                        Button(template.title) { presentedSheet = .editor(template.task(now: Date())) }
                    }
                    Divider()
                    Button(String(localized: "Şu saatte %100 hazır olsun…")) { presentedSheet = .readyBy }
                } label: { Label("Şablon", systemImage: "wand.and.stars") }
                Button { presentedSheet = .editor(.new(now: Date())) } label: { Label("Görev ekle", systemImage: "plus") }
                    .chargeMateButtonStyle()
            }
            if let warning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 36)).foregroundStyle(.blue)
                    Text("Henüz program yok").font(.headline)
                    Text("Bir görev oluşturun veya güvenli bir şablonla başlayın.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 180).chargeCard()
            } else {
                ForEach(sortedTasks) { task in taskRow(task) }
            }
            if let lastDeleted {
                HStack {
                    Text("“\(lastDeleted.name)” silindi.").font(.caption).foregroundStyle(.secondary)
                    Button("Geri al") { tasks.append(lastDeleted); self.lastDeleted = nil; persist() }
                        .chargeMateButtonStyle()
                }
            }
            Label("Etkin görevler zamanı gelince çalışır: şarj limiti, Top Up ve güç modu görevleri macOS ayarını değiştirir. Şarjı duraklatma, kalibrasyon ve hedefe kadar boşaltma henüz çalıştırılamaz.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary).chargeCard()
            ScheduleHistoryView(records: records,
                taskNames: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.name) }),
                filter: $historyFilter) { presentedSheet = .execution($0) }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: .chargeMateScheduleRuntimeUpdated)) { _ in load() }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .editor(let task):
                ScheduleEditor(task: task, capabilities: battery.scheduleCapabilities) { saved in
                    if let index = tasks.firstIndex(where: { $0.id == saved.id }) { tasks[index] = saved }
                    else { tasks.append(saved) }
                    presentedSheet = nil; persist()
                } onCancel: { presentedSheet = nil }
            case .readyBy:
                ReadyBySheet(rateSamples: battery.history.map {
                    ChargeRateSample(date: $0.date, percentage: $0.percentage ?? 0,
                                     isCharging: ($0.percentage != nil) && ($0.wattage ?? 0) > 0)
                }, onCreate: { presentedSheet = .editor($0) }, onCancel: { presentedSheet = nil })
            case .execution(let record):
                ScheduleExecutionDetailView(record: record,
                    taskName: tasks.first(where: { $0.id == record.taskID })?.name ?? String(localized: "Silinmiş görev"),
                    retryAllowed: retryAllowed(record), onRetry: retry)
            }
        }
    }

    private var sortedTasks: [ScheduleTask] {
        tasks.sorted {
            let a = $0.next(after: Date()) ?? .distantFuture
            let b = $1.next(after: Date()) ?? .distantFuture
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }

    private func taskRow(_ task: ScheduleTask) -> some View {
        let unavailable = task.action.availability(in: battery.scheduleCapabilities)
        return HStack(spacing: 14) {
            Image(systemName: task.enabled ? "calendar.badge.clock" : "calendar").font(.title2).foregroundStyle(task.enabled ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.name).font(.subheadline.weight(.semibold))
                Text("\(task.action.title) · \(task.recurrence.title) · \(nextText(task))")
                    .font(.caption).foregroundStyle(.secondary)
                if let unavailable { Text(unavailable).font(.caption2).foregroundStyle(.orange) }
            }
            Spacer()
            Toggle("Etkin", isOn: Binding(get: { task.enabled }, set: { enabled in
                guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
                tasks[index].enabled = enabled
                tasks[index].activationStart = enabled ? Date() : nil
                tasks[index].modifiedAt = Date()
                persist()
            })).labelsHidden().disabled(unavailable != nil).help(unavailable ?? String(localized: "Görevi etkinleştir"))
            Button { presentedSheet = .editor(task) } label: { Image(systemName: "pencil") }.help("Düzenle")
            Button {
                tasks.append(task.duplicated(now: Date()))
                persist()
            } label: { Image(systemName: "plus.square.on.square") }.help("Çoğalt")
            Button(role: .destructive) {
                tasks.removeAll { $0.id == task.id }; lastDeleted = task; persist()
            } label: { Image(systemName: "trash") }.help("Sil")
        }.buttonStyle(IconCircleButtonStyle()).padding(14)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func nextText(_ task: ScheduleTask) -> String {
        guard let next = task.next(after: Date()) else { return String(localized: "sonraki çalışma yok") }
        return next.formatted(date: .abbreviated, time: .shortened)
    }
    private func load() {
        let taskResult = store.load()
        let executionResult = executionStore.load()
        tasks = taskResult.tasks; records = executionResult.records
        warning = [taskResult.warning, executionResult.warning].compactMap { $0 }.joined(separator: " ")
        if warning?.isEmpty == true { warning = nil }
    }
    private func persist() {
        do {
            try store.save(tasks); warning = nil
            NotificationCenter.default.post(name: .chargeMateScheduleChanged, object: nil)
        }
        catch { warning = String(localized: "Programlar kaydedilemedi: \(error.localizedDescription)") }
    }
    /// A finished run can be tried again when the task still exists, the action can run on this Mac right
    /// now (its capability is there) and the scheduler is running.
    private func retryAllowed(_ record: ScheduleExecutionRecord) -> Bool {
        record.status.isTerminal && ![.configurationVerified, .completed].contains(record.status)
            && ScheduleRuntime.shared != nil
            && tasks.contains { $0.id == record.taskID }
            && record.actionSnapshot.availability(in: battery.scheduleCapabilities) == nil
    }

    /// Runs the action again through the scheduler (same admission rules and writers as a scheduled run) and
    /// says what really happened.
    private func retry(_ record: ScheduleExecutionRecord) -> String {
        guard let runtime = ScheduleRuntime.shared, let retried = runtime.retry(record) else {
            load()
            return String(localized: "Yeni çalışma başlatılamadı: görev silinmiş ya da kayıt yazılamadı.")
        }
        load()
        let id = String(retried.executionID.uuidString.prefix(8))
        switch retried.status {
        case .configurationVerified, .completed:
            return String(localized: "Yeni çalışma \(id) tamamlandı; ayar okunarak doğrulandı.")
        case .running:
            return String(localized: "Yeni çalışma \(id) başladı; sonuç Görev geçmişinde güncellenir.")
        default:
            return String(localized: "Yeni çalışma \(id) tamamlanamadı: \(retried.failureReason ?? retried.status.title)")
        }
    }
}

private struct ScheduleEditor: View {
    @State var task: ScheduleTask
    /// The action the task had when the editor opened: an old task saved with an action that cannot run any
    /// more stays selectable (and visibly unsupported) until the user picks another one.
    private let initialAction: ScheduleAction
    let capabilities: ScheduleCapabilities
    let onSave: (ScheduleTask) -> Void
    let onCancel: () -> Void

    init(task: ScheduleTask, capabilities: ScheduleCapabilities,
         onSave: @escaping (ScheduleTask) -> Void, onCancel: @escaping () -> Void) {
        _task = State(initialValue: task)
        initialAction = task.action
        self.capabilities = capabilities
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var timezone: TimeZone { TimeZone(identifier: task.timezoneID) ?? .current }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timezone; return c }
    private var dateBinding: Binding<Date> {
        Binding(get: { calendar.date(from: task.startLocalComponents) ?? Date() }, set: {
            task.startLocalComponents = ScheduleTask.localComponents($0, calendar: calendar)
        })
    }
    private var validation: String? { task.validationError(capabilities: capabilities) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Programı düzenle").font(.title2.bold()); Spacer(); Button("İptal", action: onCancel).chargeMateButtonStyle() }
            Form {
                TextField("Ad", text: $task.name)
                Picker("Eylem", selection: $task.action) {
                    ForEach(ScheduleAction.offered(keeping: initialAction)) { Text($0.title).tag($0) }
                }.onChange(of: task.action) { action in task.target = action.needsTarget ? (task.target ?? capabilities.chargeLimits.first ?? 80) : nil }
                if task.action.needsTarget {
                    Stepper("Hedef: %\(task.target ?? 80)", value: Binding(get: { task.target ?? 80 }, set: { task.target = $0 }), in: 20...100, step: 5)
                }
                Picker("Tekrar", selection: $task.recurrence) {
                    ForEach(ScheduleRecurrence.allCases) { Text($0.title).tag($0) }
                }
                DatePicker(String(localized: "Başlangıç"), selection: dateBinding)
                TextField("Saat dilimi", text: $task.timezoneID)
                Toggle("Uyanınca son kaçırılan çalışmayı değerlendir", isOn: $task.catchUpEnabled)
                Toggle("Etkin", isOn: $task.enabled).disabled(task.action.availability(in: capabilities) != nil)
                if let reason = task.action.availability(in: capabilities) {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }.formStyle(.grouped)
            if let validation { Label(validation, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Kaydetmek görevi çalıştırmaz.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Kaydet") {
                    task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if task.enabled && task.activationStart == nil { task.activationStart = Date() }
                    task.modifiedAt = Date(); onSave(task)
                }.chargeMateButtonStyle().disabled(validation != nil)
            }
        }.padding(22).frame(width: 560)
    }
}
