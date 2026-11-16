import SwiftUI

private let comparisonOperators = [
    "GreaterThanThreshold",
    "GreaterThanOrEqualToThreshold",
    "LessThanThreshold",
    "LessThanOrEqualToThreshold",
]

/// Mirrors an alarm's page in the CloudWatch console: General (state,
/// actions-enabled toggle, editable threshold, delete) and Actions (the
/// SNS/other ARNs the alarm notifies - read-only, wiring new ones needs a
/// full ARN picker across services which is out of scope here).
struct CloudWatchAlarmDetailView: View {
    let alarmName: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case general = "General"
        case actions = "Actions"
    }

    @State private var tab: DetailTab = .general
    @State private var detailState: LoadState<CloudWatchAlarmDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(title: detail.alarmName, status: detail.state, tab: $tab)

                    Group {
                        switch tab {
                        case .general:
                            CloudWatchAlarmGeneralView(detail: detail, onUpdated: { detailState = .loaded($0) }, onDeleted: onDeleted)
                        case .actions:
                            CloudWatchAlarmActionsView(detail: detail)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: alarmName) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        detailState = .loading
        do {
            let detail = try await api.getCloudWatchAlarmDetail(profile: appState.currentProfile, region: appState.currentRegion, alarmName: alarmName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudWatchAlarmGeneralView: View {
    let detail: CloudWatchAlarmDetail
    var onUpdated: (CloudWatchAlarmDetail) -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isTogglingActions = false
    @State private var toggleError: String?

    @State private var thresholdText = ""
    @State private var comparisonOperator = ""
    @State private var evaluationPeriodsText = ""
    @State private var periodText = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false

    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let description = detail.alarmDescription, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let reason = detail.stateReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Notifications")
                        .font(.headline)
                    Toggle("Actions enabled", isOn: Binding(
                        get: { detail.actionsEnabled },
                        set: { newValue in Task { await setActionsEnabled(newValue) } }
                    ))
                    .disabled(isTogglingActions)
                    if let toggleError {
                        Text(toggleError).font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Condition")
                        .font(.headline)

                    DetailField("Metric", "\(detail.namespace) / \(detail.metricName)")
                    if !detail.dimensions.isEmpty {
                        DetailField("Dimensions", detail.dimensions.map { "\($0.name)=\($0.value)" }.joined(separator: ", "))
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Comparison").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $comparisonOperator) {
                                ForEach(comparisonOperators, id: \.self) { op in
                                    Text(op).tag(op)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Threshold").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $thresholdText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Evaluation periods").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $evaluationPeriodsText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Period (seconds)").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $periodText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }

                    HStack {
                        if let saveError {
                            Text(saveError).font(.caption).foregroundStyle(.red)
                        }
                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        SaveButton("Save Condition", isLoading: isSaving) {
                            Task { await save() }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    if let arn = detail.alarmArn { DetailField("ARN", arn) }
                    if let datapoints = detail.datapointsToAlarm { DetailField("Datapoints to alarm", "\(datapoints) of \(detail.evaluationPeriods ?? 0)") }
                    if let treatMissingData = detail.treatMissingData { DetailField("Missing data treatment", treatMissingData) }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger zone")
                        .font(.headline)
                        .foregroundStyle(.red)
                    DeleteButton("Delete Alarm", isLoading: isDeleting) {
                        Task { await deleteAlarm() }
                    }
                    if let deleteError {
                        Text(deleteError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: detail.alarmName) {
            syncFieldsFromDetail()
        }
    }

    private func syncFieldsFromDetail() {
        thresholdText = detail.threshold.map { String($0) } ?? ""
        comparisonOperator = comparisonOperators.contains(detail.comparisonOperator ?? "") ? (detail.comparisonOperator ?? comparisonOperators[0]) : comparisonOperators[0]
        evaluationPeriodsText = detail.evaluationPeriods.map { String($0) } ?? ""
        periodText = detail.period.map { String($0) } ?? ""
    }


    private func setActionsEnabled(_ enabled: Bool) async {
        isTogglingActions = true
        toggleError = nil
        do {
            let updated = try await api.setCloudWatchAlarmActionsEnabled(profile: appState.currentProfile, region: appState.currentRegion, alarmName: detail.alarmName, enabled: enabled)
            onUpdated(updated)
        } catch {
            toggleError = error.friendlyMessage
        }
        isTogglingActions = false
    }

    private func save() async {
        guard let threshold = Double(thresholdText), let evaluationPeriods = Int(evaluationPeriodsText), let period = Int(periodText) else {
            saveError = "Threshold, evaluation periods and period must be numbers."
            return
        }
        isSaving = true
        saveError = nil
        saved = false
        do {
            let updated = try await api.updateCloudWatchAlarmThreshold(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                alarmName: detail.alarmName,
                threshold: threshold,
                comparisonOperator: comparisonOperator,
                evaluationPeriods: evaluationPeriods,
                period: period
            )
            onUpdated(updated)
            saved = true
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func deleteAlarm() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteCloudWatchAlarm(profile: appState.currentProfile, region: appState.currentRegion, alarmName: detail.alarmName)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}

private struct CloudWatchAlarmActionsView: View {
    let detail: CloudWatchAlarmDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                actionSection("ALARM actions", detail.alarmActions)
                actionSection("OK actions", detail.okActions)
                actionSection("INSUFFICIENT_DATA actions", detail.insufficientDataActions)
                Text("Actions are shown for reference. Wiring new ones (e.g. an SNS topic) is done from the AWS console or CLI.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func actionSection(_ title: String, _ actions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if actions.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(actions, id: \.self) { arn in
                    Text(arn)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}
