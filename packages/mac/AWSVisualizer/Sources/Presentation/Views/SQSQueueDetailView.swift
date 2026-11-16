import SwiftUI

/// Mirrors a queue's page in the SQS console: the queue's Details, then
/// the console's tabs - Send and receive messages, Access policy,
/// Dead-letter queue, Encryption, Tagging - plus an editable
/// Configuration tab (the console's "Edit" page) and Purge in the action
/// bar. Built from the shared detail components.
struct SqsQueueDetailView: View {
    let queueUrl: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case configuration = "Configuration"
        case messages = "Send and receive messages"
        case accessPolicy = "Access policy"
        case deadLetter = "Dead-letter queue"
        case encryption = "Encryption"
        case tags = "Tagging"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<SqsQueueDetail> = .loading
    @State private var isPurging = false
    @State private var actionError: String?
    @State private var actionNote: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.queueName,
                    subtitle: detail.fifoQueue ? "FIFO queue" : "Standard queue",
                    tab: $tab
                )
                DetailActionBar(error: actionError, note: actionNote, onRefresh: { Task { await loadDetail() } }) {
                    ConfirmedActionButton(
                        title: "Purge",
                        systemImage: "trash.slash",
                        confirmationTitle: "Purge \(detail.queueName)?",
                        confirmationMessage: "Deletes every message in the queue (about \(detail.approximateMessages + detail.approximateMessagesNotVisible + detail.approximateMessagesDelayed)). This can't be undone, and SQS allows one purge per 60 seconds.",
                        isLoading: isPurging,
                        isDisabled: isPurging
                    ) { Task { await purge() } }
                }

                Group {
                    switch tab {
                    case .details:
                        SqsDetailsTab(detail: detail)
                    case .configuration:
                        SqsConfigurationView(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .messages:
                        SqsMessagesView(queueUrl: queueUrl, isFifo: detail.fifoQueue)
                    case .accessPolicy:
                        JsonPolicyEditor(
                            title: "Access policy",
                            warning: "Defines who can access this queue. A wrong policy can block producers and consumers.",
                            emptyMessage: "No access policy - only the queue owner (and IAM principals allowed by their own policies) can use it.",
                            template: Self.policyTemplate(arn: detail.arn),
                            reloadKey: "\(queueUrl)-\(detail.policy?.hashValue ?? 0)",
                            load: { detail.policy },
                            save: { text in
                                detailState = .loaded(try await updateAttributes(["Policy": text]))
                            },
                            delete: {
                                detailState = .loaded(try await updateAttributes(["Policy": ""]))
                            }
                        )
                    case .deadLetter:
                        SqsDeadLetterTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .encryption:
                        SqsEncryptionTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "queue", onAdd: { key, value in
                            detailState = .loaded(try await api.addSQSTag(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl, key: key, value: value))
                        }, onRemove: { key in
                            detailState = .loaded(try await api.removeSQSTag(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: queueUrl) {
            await loadDetail()
        }
    }

    private func updateAttributes(_ attributes: [String: String]) async throws -> SqsQueueDetail {
        try await api.updateSQSQueueAttributes(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl, attributes: attributes)
    }

    /// The console's "Basic" access policy: only the queue owner's account.
    static func policyTemplate(arn: String?) -> String {
        let account = arn?.split(separator: ":").dropFirst(4).first.map(String.init) ?? "123456789012"
        return """
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Sid": "OwnerOnly",
              "Effect": "Allow",
              "Principal": { "AWS": "arn:aws:iam::\(account):root" },
              "Action": "SQS:*",
              "Resource": "\(arn ?? "")"
            }
          ]
        }
        """
    }

    private func purge() async {
        isPurging = true
        actionError = nil
        actionNote = nil
        do {
            detailState = .loaded(try await api.purgeSQSQueue(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl))
            actionNote = "Purge started - it can take up to 60 seconds to finish."
        } catch {
            actionError = error.friendlyMessage
        }
        isPurging = false
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getSQSQueueDetail(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

/// The console's "Details" panel plus the message counts it shows in
/// the queue list / Monitoring tab.
private struct SqsDetailsTab: View {
    let detail: SqsQueueDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            HStack(spacing: 10) {
                MetricTile(title: "Messages available", value: "\(detail.approximateMessages)")
                MetricTile(title: "Messages in flight", value: "\(detail.approximateMessagesNotVisible)", caption: "Received, not yet deleted")
                MetricTile(title: "Messages delayed", value: "\(detail.approximateMessagesDelayed)")
            }
            DetailSection(title: "Details", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Name", detail.queueName),
                    DetailItem("Type", detail.fifoQueue ? "FIFO" : "Standard", monospaced: false),
                    DetailItem("ARN", detail.arn),
                    DetailItem("URL", detail.queueUrl),
                    DetailItem("Encryption", SqsEncryptionTab.summary(detail), monospaced: false),
                    DetailItem("Dead-letter queue", detail.deadLetterTargetArn.map { $0.split(separator: ":").last.map(String.init) ?? $0 } ?? "Disabled"),
                    DetailItem("Created", Formatters.formatISODate(detail.createdTimestamp), monospaced: false),
                    DetailItem("Last updated", Formatters.formatISODate(detail.lastModifiedTimestamp), monospaced: false),
                ])
            }
            DetailSection(title: "Configuration", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Visibility timeout", SqsFormat.duration(detail.visibilityTimeout)),
                    DetailItem("Message retention period", SqsFormat.duration(detail.messageRetentionPeriod)),
                    DetailItem("Delivery delay", SqsFormat.duration(detail.delaySeconds)),
                    DetailItem("Receive message wait time", SqsFormat.duration(detail.receiveMessageWaitTimeSeconds)),
                    DetailItem("Maximum message size", "\(detail.maximumMessageSize / 1024) KB"),
                ] + (detail.fifoQueue ? [
                    DetailItem("Content-based deduplication", detail.contentBasedDeduplication ? "Enabled" : "Disabled", monospaced: false),
                    DetailItem("Deduplication scope", detail.deduplicationScope),
                    DetailItem("FIFO throughput limit", detail.fifoThroughputLimit),
                ] : []))
            }
        }
    }
}

enum SqsFormat {
    /// "30 seconds", "4 days", "1 hour 30 minutes" - how the console shows
    /// SQS durations.
    static func duration(_ seconds: Int) -> String {
        if seconds == 0 { return "0 seconds" }
        let units: [(Int, String)] = [(86400, "day"), (3600, "hour"), (60, "minute"), (1, "second")]
        var remaining = seconds
        var parts: [String] = []
        for (size, name) in units where remaining >= size {
            let count = remaining / size
            remaining %= size
            parts.append("\(count) \(name)\(count == 1 ? "" : "s")")
            if parts.count == 2 { break }
        }
        return parts.joined(separator: " ")
    }
}

/// Redrive policy: after `maxReceiveCount` failed receives a message moves
/// to the dead-letter queue (another queue, same type and region).
private struct SqsDeadLetterTab: View {
    let detail: SqsQueueDetail
    var onUpdated: (SqsQueueDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var targetArn = ""
    @State private var maxReceiveCount = "10"
    @State private var isSaving = false
    @State private var isRemoving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Dead-letter queue", spacing: 12) {
                Text("Messages that can't be processed are moved here after the maximum receives. The dead-letter queue must be the same type (\(detail.fifoQueue ? "FIFO" : "Standard")) and in the same account and Region.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let arn = detail.deadLetterTargetArn {
                    DetailGrid(items: [
                        DetailItem("Queue ARN", arn),
                        DetailItem("Maximum receives", detail.maxReceiveCount.map(String.init)),
                    ])
                } else {
                    Label("Disabled", systemImage: "circle.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            DetailSection(title: detail.deadLetterTargetArn == nil ? "Enable" : "Edit", spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dead-letter queue ARN").font(.caption).foregroundStyle(.secondary)
                    TextField("arn:aws:sqs:region:account:queue-name", text: $targetArn)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maximum receives (1-1000)").font(.caption).foregroundStyle(.secondary)
                    TextField("10", text: $maxReceiveCount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                HStack(spacing: 8) {
                    SaveButton("Save", isLoading: isSaving, isDisabled: !isValid || isRemoving) {
                        Task { await save() }
                    }
                    if detail.deadLetterTargetArn != nil {
                        DeleteButton("Disable", isLoading: isRemoving, isDisabled: isSaving) {
                            Task { await remove() }
                        }
                    }
                    if saved {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: "\(detail.queueUrl)-\(detail.deadLetterTargetArn ?? "")") {
            targetArn = detail.deadLetterTargetArn ?? ""
            maxReceiveCount = detail.maxReceiveCount.map(String.init) ?? "10"
        }
    }

    private var isValid: Bool {
        guard let count = Int(maxReceiveCount), (1...1000).contains(count) else { return false }
        return targetArn.trimmingCharacters(in: .whitespaces).hasPrefix("arn:aws")
    }

    private func save() async {
        guard let count = Int(maxReceiveCount) else { return }
        let policy = "{\"deadLetterTargetArn\":\"\(targetArn.trimmingCharacters(in: .whitespaces))\",\"maxReceiveCount\":\(count)}"
        isSaving = true
        await run(["RedrivePolicy": policy])
    }

    private func remove() async {
        isRemoving = true
        await run(["RedrivePolicy": ""])
    }

    private func run(_ attributes: [String: String]) async {
        error = nil
        saved = false
        do {
            onUpdated(try await api.updateSQSQueueAttributes(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: detail.queueUrl, attributes: attributes))
            saved = true
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
        isRemoving = false
    }
}

/// Server-side encryption: SQS-managed keys (SSE-SQS), a KMS key
/// (SSE-KMS), or none - the console's Encryption tab.
private struct SqsEncryptionTab: View {
    let detail: SqsQueueDetail
    var onUpdated: (SqsQueueDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum Mode: String, CaseIterable, Identifiable {
        case none = "Disabled"
        case sqs = "SSE-SQS"
        case kms = "SSE-KMS"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .none
    @State private var kmsKey = ""
    @State private var reusePeriod = "300"
    @State private var isSaving = false
    @State private var error: String?
    @State private var saved = false

    static func mode(of detail: SqsQueueDetail) -> Mode {
        if let key = detail.kmsMasterKeyId, !key.isEmpty { return .kms }
        return detail.sqsManagedSseEnabled == true ? .sqs : .none
    }

    static func summary(_ detail: SqsQueueDetail) -> String {
        switch mode(of: detail) {
        case .none: return "Disabled"
        case .sqs: return "Amazon SQS key (SSE-SQS)"
        case .kms: return "AWS KMS key (SSE-KMS)"
        }
    }

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Server-side encryption", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Encryption", Self.summary(detail), monospaced: false),
                    DetailItem("KMS key", detail.kmsMasterKeyId),
                    DetailItem("Data key reuse period", detail.kmsDataKeyReusePeriodSeconds.map { SqsFormat.duration($0) }),
                ])
            }
            DetailSection(title: "Edit", spacing: 10) {
                Picker("Encryption", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                if mode == .kms {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KMS key (alias, ID or ARN)").font(.caption).foregroundStyle(.secondary)
                        TextField("alias/aws/sqs", text: $kmsKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data key reuse period (seconds, 60-86400)").font(.caption).foregroundStyle(.secondary)
                        TextField("300", text: $reusePeriod)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }
                HStack(spacing: 8) {
                    SaveButton("Save", isLoading: isSaving, isDisabled: !isValid) {
                        Task { await save() }
                    }
                    if saved {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: "\(detail.queueUrl)-\(Self.summary(detail))") {
            mode = Self.mode(of: detail)
            kmsKey = detail.kmsMasterKeyId ?? "alias/aws/sqs"
            reusePeriod = detail.kmsDataKeyReusePeriodSeconds.map(String.init) ?? "300"
        }
    }

    private var isValid: Bool {
        guard mode == .kms else { return true }
        guard let period = Int(reusePeriod), (60...86400).contains(period) else { return false }
        return !kmsKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() async {
        var attributes: [String: String]
        switch mode {
        case .none:
            attributes = ["SqsManagedSseEnabled": "false", "KmsMasterKeyId": ""]
        case .sqs:
            // Turning SSE-SQS on replaces a KMS key; sending both is rejected.
            attributes = ["SqsManagedSseEnabled": "true"]
        case .kms:
            attributes = ["KmsMasterKeyId": kmsKey.trimmingCharacters(in: .whitespaces), "KmsDataKeyReusePeriodSeconds": reusePeriod]
        }
        // An empty KmsMasterKeyId is how SSE-KMS is switched off; skip it
        // when the queue never had a KMS key.
        if mode == .none, detail.kmsMasterKeyId == nil { attributes["KmsMasterKeyId"] = nil }
        isSaving = true
        error = nil
        saved = false
        do {
            onUpdated(try await api.updateSQSQueueAttributes(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: detail.queueUrl, attributes: attributes))
            saved = true
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct SqsConfigurationView: View {
    let detail: SqsQueueDetail
    var onUpdated: (SqsQueueDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var visibilityTimeout = ""
    @State private var retentionPeriod = ""
    @State private var delaySeconds = ""
    @State private var waitTimeSeconds = ""
    @State private var maxMessageSize = ""

    @State private var savingField: String?
    @State private var errors: [String: String] = [:]
    @State private var saved: Set<String> = []

    var body: some View {
        DetailTabPage {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit configuration")
                        .font(.headline)

                    SettingsFieldRow(label: "Visibility timeout (seconds, 0–43200)", isSaving: savingField == "VisibilityTimeout", error: errors["VisibilityTimeout"], saved: saved.contains("VisibilityTimeout"), save: { Task { await save("VisibilityTimeout", visibilityTimeout) } }) {
                        TextField("", text: $visibilityTimeout).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    SettingsFieldRow(label: "Message retention period (seconds, 60–1209600)", isSaving: savingField == "MessageRetentionPeriod", error: errors["MessageRetentionPeriod"], saved: saved.contains("MessageRetentionPeriod"), save: { Task { await save("MessageRetentionPeriod", retentionPeriod) } }) {
                        TextField("", text: $retentionPeriod).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    SettingsFieldRow(label: "Delivery delay (seconds, 0–900)", isSaving: savingField == "DelaySeconds", error: errors["DelaySeconds"], saved: saved.contains("DelaySeconds"), save: { Task { await save("DelaySeconds", delaySeconds) } }) {
                        TextField("", text: $delaySeconds).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    SettingsFieldRow(label: "Receive message wait time (seconds, 0–20)", isSaving: savingField == "ReceiveMessageWaitTimeSeconds", error: errors["ReceiveMessageWaitTimeSeconds"], saved: saved.contains("ReceiveMessageWaitTimeSeconds"), save: { Task { await save("ReceiveMessageWaitTimeSeconds", waitTimeSeconds) } }) {
                        TextField("", text: $waitTimeSeconds).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    SettingsFieldRow(label: "Maximum message size (bytes, 1024–262144)", isSaving: savingField == "MaximumMessageSize", error: errors["MaximumMessageSize"], saved: saved.contains("MaximumMessageSize"), save: { Task { await save("MaximumMessageSize", maxMessageSize) } }) {
                        TextField("", text: $maxMessageSize).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                }
        }
        .task(id: detail.queueUrl) {
            resetFields()
        }
    }

    private func resetFields() {
        visibilityTimeout = "\(detail.visibilityTimeout)"
        retentionPeriod = "\(detail.messageRetentionPeriod)"
        delaySeconds = "\(detail.delaySeconds)"
        waitTimeSeconds = "\(detail.receiveMessageWaitTimeSeconds)"
        maxMessageSize = "\(detail.maximumMessageSize)"
        errors = [:]
        saved = []
    }

    private func save(_ attributeName: String, _ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        savingField = attributeName
        errors[attributeName] = nil
        saved.remove(attributeName)
        do {
            let updated = try await api.updateSQSQueueAttributes(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: detail.queueUrl, attributes: [attributeName: trimmed])
            onUpdated(updated)
            saved.insert(attributeName)
        } catch {
            errors[attributeName] = error.friendlyMessage
        }
        savingField = nil
    }
}

private struct SqsMessagesView: View {
    let queueUrl: String
    let isFifo: Bool

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var messageBody = ""
    @State private var delaySeconds = ""
    @State private var messageGroupId = ""
    @State private var messageDeduplicationId = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var sendSuccess: String?

    @State private var messagesState: LoadState<[SqsMessage]> = .empty
    @State private var deletingMessageId: String?
    @State private var deleteError: String?

    var body: some View {
        DetailTabPage(maxWidth: 760) {
            sendSection
            Divider()
            receiveSection
        }
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send message")
                .font(.headline)
            TextEditor(text: $messageBody)
                .font(.system(.body, design: .monospaced))
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            HStack(spacing: 12) {
                if isFifo {
                    TextField("Message group ID", text: $messageGroupId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    TextField("Deduplication ID (optional)", text: $messageDeduplicationId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                } else {
                    TextField("Delay seconds (optional)", text: $delaySeconds)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                Spacer()
                NewButton("Send Message", isLoading: isSending, isDisabled: messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isFifo && messageGroupId.trimmingCharacters(in: .whitespaces).isEmpty)) {
                    Task { await send() }
                }
            }

            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
            }
            if let sendSuccess {
                Text(sendSuccess).font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Receive messages")
                    .font(.headline)
                Spacer()
                RefreshButton("Poll for Messages", systemImage: "tray.and.arrow.down") {
                    Task { await receive() }
                }
            }
            Text("Polling makes messages temporarily invisible to other consumers for the queue's visibility timeout - same as the AWS console's \"Poll for messages\".")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
            }

            LoadableContent(messagesState, emptyMessage: "No messages received yet") { messages in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                }
            }
            .frame(minHeight: 240)
        }
    }

    private func messageRow(_ message: SqsMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.messageId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let count = message.approximateReceiveCount, count > 1 {
                    Text("×\(count)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
                Spacer()
                DeleteButton(compactSize: 20, isLoading: deletingMessageId == message.messageId, isDisabled: deletingMessageId != nil, help: "Delete Message") {
                    Task { await delete(message) }
                }
            }
            Text(message.body)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
            if let sent = message.sentTimestamp {
                Text(Formatters.formatISODate(sent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func send() async {
        isSending = true
        sendError = nil
        sendSuccess = nil
        do {
            let id = try await api.sendSQSMessage(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                queueUrl: queueUrl,
                body: messageBody,
                delaySeconds: isFifo ? nil : Int(delaySeconds),
                messageGroupId: isFifo ? messageGroupId : nil,
                messageDeduplicationId: isFifo && !messageDeduplicationId.isEmpty ? messageDeduplicationId : nil
            )
            sendSuccess = "Sent" + (id.map { " (\($0.prefix(12)))" } ?? "")
            messageBody = ""
        } catch {
            sendError = error.friendlyMessage
        }
        isSending = false
    }

    private func receive() async {
        messagesState = .loading
        deleteError = nil
        do {
            let messages = try await api.receiveSQSMessages(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl, maxMessages: 10)
            messagesState = messages.isEmpty ? .empty : .loaded(messages)
        } catch {
            messagesState = .failed(error.friendlyMessage)
        }
    }

    private func delete(_ message: SqsMessage) async {
        deletingMessageId = message.messageId
        deleteError = nil
        do {
            try await api.deleteSQSMessage(profile: appState.currentProfile, region: appState.currentRegion, queueUrl: queueUrl, receiptHandle: message.receiptHandle)
            if case .loaded(var messages) = messagesState {
                messages.removeAll { $0.messageId == message.messageId }
                messagesState = messages.isEmpty ? .empty : .loaded(messages)
            }
        } catch {
            deleteError = error.friendlyMessage
        }
        deletingMessageId = nil
    }
}
