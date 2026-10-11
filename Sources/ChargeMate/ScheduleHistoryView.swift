import SwiftUI

struct ScheduleHistoryView: View {
    let records: [ScheduleExecutionRecord]
    let taskNames: [UUID: String]
    @Binding var filter: ScheduleHistoryFilter
    let onSelect: (ScheduleExecutionRecord) -> Void

    private var filtered: [ScheduleExecutionRecord] {
        records.filter { filter.includes($0.status) }.sorted {
            $0.plannedAt == $1.plannedAt
                ? $0.executionID.uuidString > $1.executionID.uuidString
                : $0.plannedAt > $1.plannedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Görev geçmişi", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Text("\(filtered.count) kayıt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Geçmiş filtresi", selection: $filter) {
                    ForEach(ScheduleHistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: filter == .all ? "clock.badge.questionmark" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(filter == .all ? String(localized: "Henüz çalışma kaydı yok") : String(localized: "Bu filtrede kayıt yok"))
                        .font(.subheadline.weight(.semibold))
                    Text("Görev sonuçları, atlamalar ve kurtarma gerektiren durumlar burada görünür.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 110)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { record in
                        ScheduleHistoryRow(record: record,
                            taskName: taskNames[record.taskID] ?? String(localized: "Silinmiş görev")) {
                                onSelect(record)
                            }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.10)))
    }
}

private struct ScheduleHistoryRow: View {
    let record: ScheduleExecutionRecord
    let taskName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(taskName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("·") .foregroundStyle(.tertiary)
                        Text(actionText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        Text(Self.dateText(record.plannedAt, zoneID: record.timezoneIDSnapshot))
                        Text(record.timezoneIDSnapshot ?? TimeZone.current.identifier)
                        if let reason = record.failureReason {
                            Text("·"); Text(reason).lineLimit(1)
                        } else if let observed = record.observedResult {
                            Text("·"); Text(observed).lineLimit(1)
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Text(record.status.title)
                    .font(.caption2.weight(.semibold)).foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(statusColor.opacity(0.12), in: Capsule())
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(11)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(taskName), \(record.status.title), \(actionText)")
        .accessibilityHint("Çalışma ayrıntılarını açar")
    }

    private var actionText: String {
        record.requestedValue.map { "\(record.actionSnapshot.title) %\($0)" } ?? record.actionSnapshot.title
    }
    private var statusColor: Color {
        switch record.status {
        case .configurationVerified, .completed: return .green
        case .failed, .recoveryRequired: return .red
        case .unsupported, .cancelled: return .orange
        case .skippedMissed, .skippedConflict: return .secondary
        case .planned, .dispatched, .running: return .blue
        }
    }
    private var statusIcon: String {
        switch record.status {
        case .configurationVerified, .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .recoveryRequired: return "exclamationmark.shield.fill"
        case .unsupported: return "nosign"
        case .cancelled: return "minus.circle.fill"
        case .skippedMissed: return "clock.badge.xmark"
        case .skippedConflict: return "arrow.triangle.branch"
        case .planned: return "calendar.badge.clock"
        case .dispatched: return "paperplane.fill"
        case .running: return "progress.indicator"
        }
    }

    static func dateText(_ date: Date, zoneID: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ScheduleExecutionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: ScheduleExecutionRecord
    let taskName: String
    /// False hides the retry button: the task is gone, the action cannot run on this Mac, or the run succeeded.
    let retryAllowed: Bool
    let onRetry: (ScheduleExecutionRecord) -> String
    @State private var retryMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Çalışma ayrıntısı").font(.title2.bold())
                    Text(taskName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Kapat") { dismiss() }
                    .chargeMateButtonStyle()
            }
            Divider()
            VStack(spacing: 11) {
                detail(String(localized: "Durum"), record.status.title)
                detail(String(localized: "Eylem"), actionText)
                detail(String(localized: "Planlanan"), ScheduleHistoryRow.dateText(record.plannedAt, zoneID: record.timezoneIDSnapshot))
                detail(String(localized: "Saat dilimi"), record.timezoneIDSnapshot ?? String(localized: "Kayıtta yok"))
                if let startedAt = record.startedAt { detail(String(localized: "Başlangıç"), ScheduleHistoryRow.dateText(startedAt, zoneID: record.timezoneIDSnapshot)) }
                if let finishedAt = record.finishedAt { detail(String(localized: "Bitiş"), ScheduleHistoryRow.dateText(finishedAt, zoneID: record.timezoneIDSnapshot)) }
                if let observed = record.observedResult { detail(String(localized: "Gözlenen sonuç"), observed) }
                if let reason = record.failureReason { detail(String(localized: "Açıklama"), reason) }
                detail(String(localized: "Çalışma kimliği"), record.executionID.uuidString)
                if let operationID = record.operationID { detail(String(localized: "İşlem kimliği"), operationID.uuidString) }
            }
            if let retryMessage {
                Label(retryMessage, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Yeniden deneme eski kaydı değiştirmez; yeni bir çalışma kimliği oluşturur.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if retryAllowed {
                    Button("Yeni çalışma olarak dene") { retryMessage = onRetry(record) }
                        .chargeMateButtonStyle()
                        .disabled(retryMessage != nil)
                }
            }
        }
        .padding(22)
        .frame(width: 590)
        .frame(minHeight: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actionText: String {
        record.requestedValue.map { "\(record.actionSnapshot.title) — %\($0)" } ?? record.actionSnapshot.title
    }
    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 125, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }
}
