import SwiftUI

/// Mirrors a topic's console page: Subscriptions, Publish message, Access
/// policy, Delivery policy, Details (display name, encryption, delete) and
/// Tags.
struct SnsTopicDetailView: View {
    let topicArn: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case subscriptions = "Subscriptions"
        case publish = "Publish message"
        case accessPolicy = "Access policy"
        case deliveryPolicy = "Delivery policy"
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .subscriptions
    @State private var detailState: LoadState<SnsTopicDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.name,
                        subtitle: detail.displayName.map { "Display name: \($0)" },
                        status: detail.fifoTopic ? "FIFO" : "Standard",
                        tab: $tab
                    )
                    Group {
                        switch tab {
                        case .subscriptions:
                            SnsSubscriptionsTab(detail: detail, onChanged: { Task { await loadDetail() } })
                        case .publish:
                            SnsPublishTab(detail: detail)
                        case .accessPolicy:
                            JsonPolicyEditor(
                                title: "Access policy",
                                warning: "Defines who can publish and subscribe. A mistake here can lock out the services that publish to this topic - double-check before saving.",
                                reloadKey: topicArn,
                                load: { try await api.getSnsTopicPolicy(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, attribute: "Policy") },
                                save: { try await api.setSnsTopicAttribute(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, attribute: "Policy", value: $0) }
                            )
                        case .deliveryPolicy:
                            JsonPolicyEditor(
                                title: "Delivery policy (HTTP/S)",
                                warning: "Retry behaviour for HTTP/S subscriptions only; other protocols ignore it.",
                                emptyMessage: "No delivery policy - SNS uses its default retry policy.",
                                template: Self.deliveryPolicyTemplate,
                                reloadKey: topicArn,
                                load: { try await api.getSnsTopicPolicy(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, attribute: "DeliveryPolicy") },
                                save: { try await api.setSnsTopicAttribute(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, attribute: "DeliveryPolicy", value: $0) }
                            )
                        case .details:
                            SnsDetailsTab(detail: detail, onUpdated: { Task { await loadDetail() } }, onDeleted: onDeleted)
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "topic", onAdd: { key, value in
                                detailState = .loaded(try await api.addSnsTopicTag(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeSnsTopicTag(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: topicArn) {
            await loadDetail()
        }
    }

    /// SNS's documented default HTTP/S retry policy, offered as a starting point.
    private static let deliveryPolicyTemplate = """
    {
      "http": {
        "defaultHealthyRetryPolicy": {
          "minDelayTarget": 20,
          "maxDelayTarget": 20,
          "numRetries": 3,
          "numMaxDelayRetries": 0,
          "numNoDelayRetries": 0,
          "numMinDelayRetries": 0,
          "backoffFunction": "linear"
        },
        "disableSubscriptionOverrides": false
      }
    }
    """

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getSnsTopicDetail(profile: appState.currentProfile, region: appState.currentRegion, arn: topicArn))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct SnsSubscriptionsTab: View {
    let detail: SnsTopicDetail
    var onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private static let protocols = ["sqs", "lambda", "email", "email-json", "https", "http", "sms", "firehose"]

    @State private var state: LoadState<[SnsSubscription]> = .loading
    @State private var newProtocol = "sqs"
    @State private var newEndpoint = ""
    @State private var isSubscribing = false
    @State private var removing: String?
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            HStack(spacing: 12) {
                MetricTile(title: "Confirmed", value: "\(detail.subscriptionsConfirmed)", tint: .green)
                MetricTile(title: "Pending confirmation", value: "\(detail.subscriptionsPending)", tint: detail.subscriptionsPending > 0 ? .orange : .primary)
                MetricTile(title: "Deleted", value: "\(detail.subscriptionsDeleted)")
            }

            DetailSection(title: "Create subscription", spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $newProtocol) {
                        ForEach(Self.protocols, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    TextField(endpointPlaceholder, text: $newEndpoint)
                        .textFieldStyle(.roundedBorder)
                    NewButton("Subscribe", isLoading: isSubscribing, isDisabled: newEndpoint.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await subscribe() }
                    }
                }
                Text(protocolHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let message { Text(message).font(.caption).foregroundStyle(.green) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            DetailSection(title: "Subscriptions") {
                LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No subscriptions", minHeight: 80) { subs in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(subs) { sub in
                            HStack(spacing: 10) {
                                Text(sub.protocol)
                                    .font(.caption.bold())
                                    .frame(width: 80, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.endpoint)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if !sub.pendingConfirmation {
                                        Text(sub.subscriptionArn.split(separator: ":").last.map(String.init) ?? "")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if sub.pendingConfirmation {
                                    StatusBadge("Pending confirmation", color: .orange)
                                        .help("Unconfirmed subscriptions can't be deleted - they expire after 3 days.")
                                } else {
                                    StatusBadge("Confirmed", color: .green)
                                    DeleteButton(compactSize: 20, isLoading: removing == sub.subscriptionArn, isDisabled: removing != nil, help: "Delete Subscription") {
                                        Task { await unsubscribe(sub) }
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: detail.topicArn) { await load() }
    }

    private var endpointPlaceholder: String {
        switch newProtocol {
        case "sqs": return "arn:aws:sqs:region:account:queue-name"
        case "lambda": return "arn:aws:lambda:region:account:function:name"
        case "email", "email-json": return "someone@example.com"
        case "http", "https": return "\(newProtocol)://example.com/endpoint"
        case "sms": return "+905551234567"
        case "firehose": return "arn:aws:firehose:region:account:deliverystream/name"
        default: return "Endpoint"
        }
    }

    private var protocolHint: String {
        switch newProtocol {
        case "sqs": return "The queue's access policy must allow this topic to send messages to it."
        case "lambda": return "The function's resource policy must allow sns.amazonaws.com to invoke it."
        case "email", "email-json", "http", "https": return "The endpoint receives a confirmation request and must confirm before messages are delivered."
        case "firehose": return "Requires a subscription role ARN, which can only be set in the AWS console."
        default: return ""
        }
    }

    private func load() async {
        state = .loading
        do {
            let subs = try await api.getSnsSubscriptions(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.topicArn)
            state = subs.isEmpty ? .empty : .loaded(subs)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func subscribe() async {
        isSubscribing = true
        error = nil
        message = nil
        do {
            try await api.createSnsSubscription(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.topicArn, protocol: newProtocol, endpoint: newEndpoint.trimmingCharacters(in: .whitespaces))
            message = ["email", "email-json", "http", "https"].contains(newProtocol)
                ? "Subscription created - waiting for the endpoint to confirm."
                : "Subscription created."
            newEndpoint = ""
            await load()
            onChanged()
        } catch {
            self.error = error.friendlyMessage
        }
        isSubscribing = false
    }

    private func unsubscribe(_ sub: SnsSubscription) async {
        removing = sub.subscriptionArn
        error = nil
        message = nil
        do {
            try await api.deleteSnsSubscription(profile: appState.currentProfile, region: appState.currentRegion, subscriptionArn: sub.subscriptionArn)
            await load()
            onChanged()
        } catch {
            self.error = error.friendlyMessage
        }
        removing = nil
    }
}

private struct SnsPublishTab: View {
    let detail: SnsTopicDetail

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var subject = ""
    @State private var message = ""
    @State private var groupId = ""
    @State private var dedupId = ""
    @State private var isPublishing = false
    @State private var error: String?
    @State private var success: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Publish message", spacing: 10) {
                Text("Delivered to every confirmed subscription of this topic, exactly like publishing from the console.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                TextField("Subject (optional - used by email subscriptions)", text: $subject)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $message)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                if detail.fifoTopic {
                    HStack(spacing: 8) {
                        TextField("Message group ID", text: $groupId)
                            .textFieldStyle(.roundedBorder)
                        TextField(detail.contentBasedDeduplication ? "Deduplication ID (optional)" : "Deduplication ID", text: $dedupId)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let success { Text(success).font(.caption).foregroundStyle(.green) }
                    Spacer()
                    NewButton("Publish Message", systemImage: "paperplane", isLoading: isPublishing, isDisabled: !canPublish) {
                        Task { await publish() }
                    }
                }
            }
        }
    }

    private var canPublish: Bool {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if detail.fifoTopic {
            if groupId.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if !detail.contentBasedDeduplication && dedupId.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    private func publish() async {
        isPublishing = true
        error = nil
        success = nil
        do {
            let id = try await api.publishSnsMessage(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.topicArn, message: message, subject: subject, messageGroupId: groupId, messageDeduplicationId: dedupId)
            success = "Published" + (id.map { " (\($0.prefix(12)))" } ?? "")
            message = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isPublishing = false
    }
}

private struct SnsDetailsTab: View {
    let detail: SnsTopicDetail
    var onUpdated: () -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var displayName = ""
    @State private var isSaving = false
    @State private var saved = false
    @State private var saveError: String?
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        DetailTabPage {
            SettingsFieldRow(label: "Display name (SMS sender name, email \"From\")", isSaving: isSaving, error: saveError, saved: saved, save: { Task { await saveDisplayName() } }) {
                TextField("", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            DetailSection(title: "Details") {
                DetailField("ARN", detail.topicArn)
                HStack(spacing: 24) {
                    DetailField("Type", detail.fifoTopic ? "FIFO" : "Standard")
                    if detail.fifoTopic {
                        DetailField("Content-based deduplication", detail.contentBasedDeduplication ? "Enabled" : "Disabled")
                    }
                    DetailField("Owner", detail.owner ?? "-")
                }
                DetailField("Encryption", detail.kmsMasterKeyId.map { "SSE-KMS (\($0))" } ?? "Not encrypted")
            }

            Divider()

            DetailSection(title: "Danger zone", spacing: 8) {
                Text("Deleting the topic also deletes all of its subscriptions. Publishers that still send to it start failing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DeleteButton("Delete Topic", isLoading: isDeleting) {
                    Task { await deleteTopic() }
                }
                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: detail.topicArn) {
            displayName = detail.displayName ?? ""
        }
    }

    private func saveDisplayName() async {
        isSaving = true
        saveError = nil
        saved = false
        do {
            try await api.setSnsTopicAttribute(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.topicArn, attribute: "DisplayName", value: displayName)
            saved = true
            onUpdated()
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func deleteTopic() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteSnsTopic(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.topicArn)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}
