import SwiftUI
import Charts
import OpenWeightsCore

@MainActor final class DashboardController: ObservableObject {
    @Published private(set) var summary = UsageSummary()
    @Published private(set) var usageRecords: [UsageRecord] = []
    @Published private(set) var conversationCount = 0
    @Published private(set) var storage: ModelStorageSnapshot?
    @Published private(set) var headroomBytes: Int64?
    @Published private(set) var freeStorageBytes: Int64?
    @Published private(set) var error: String?
    private let inspector = ModelStorageInspector()
    private var refreshEpoch = UUID()
    func refresh(chat: ChatController, downloads: ModelDownloads) async {
        let epoch = UUID(); refreshEpoch = epoch
        let records = await chat.usage?.list() ?? []
        let measuredSummary = UsageSummary(records: records)
        let chats = await chat.store.list().count + chat.store.list(archived: true).count
        let headroom = OWRuntimeSession.availableMemoryBytes().int64Value
        let free = try? downloads.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        do {
            let snapshot = try await inspector.snapshot(root: downloads.root, models: downloads.models)
            guard refreshEpoch == epoch, !Task.isCancelled else { return }
            summary = measuredSummary; usageRecords = records; conversationCount = chats; headroomBytes = headroom; freeStorageBytes = free
            storage = snapshot; error = nil
        }
        catch is CancellationError { }
        catch {
            guard refreshEpoch == epoch else { return }
            summary = measuredSummary; usageRecords = records; conversationCount = chats; headroomBytes = headroom; freeStorageBytes = free
            storage = nil; self.error = "Storage could not be inspected: " + error.localizedDescription
        }
    }
}

struct DashboardScreen: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var downloads: ModelDownloads
    @StateObject private var dashboard = DashboardController()
    var body: some View {
        List {
            if let failure = chat.usageError { Section { Text(failure).foregroundStyle(OWTheme.danger) } }
            Section {
                Text(dashboard.summary.totals.generatedTokens.formatted()).font(OWTheme.metric(32))
                Text("Tokens generated on this device").foregroundStyle(OWTheme.secondary)
                LabeledContent("Today", value: dashboard.summary.tokensToday.formatted())
                if let change = dashboard.summary.dayOverDayChange {
                    LabeledContent("Change from yesterday", value: change.formatted(.percent.precision(.fractionLength(0))))
                }
                if dashboard.summary.totals.passes == 0 {
                    Text("Usage starts with new inference passes. Earlier messages have no recorded token counts and are not estimated.").font(OWTheme.interface(13))
                }
            } header: { Text("Local usage") } footer: {
                Text("No analytics, accounts or uploads. Each recorded model pass counts, including tool rounds, summaries, watches and interrupted passes that return metrics. Deleting chats or models keeps their usage.")
            }
            if !dashboard.summary.growth.isEmpty {
                Section("Last 30 days") {
                    Chart(dashboard.summary.growth) { point in
                        LineMark(x: .value("Day", point.day), y: .value("Lifetime tokens", point.cumulativeTokens))
                            .foregroundStyle(OWTheme.signal)
                        PointMark(x: .value("Day", point.day), y: .value("Lifetime tokens", point.cumulativeTokens))
                            .foregroundStyle(OWTheme.signal)
                    }.chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .trailing) { _ in
                                AxisGridLine().foregroundStyle(OWTheme.secondary.opacity(0.3))
                                AxisValueLabel().foregroundStyle(OWTheme.secondary)
                            }
                        }.frame(height: 150)
                        .accessibilityLabel("Lifetime generated tokens across the last 30 days")
                    ForEach(dashboard.summary.growth.suffix(7)) { point in
                        LabeledContent(dayLabel(point.day), value: "\(point.generatedTokens.formatted()) generated")
                    }
                }
            }
            Section("Work recorded") {
                LabeledContent("Inference passes", value: dashboard.summary.totals.passes.formatted())
                LabeledContent("Chats stored", value: dashboard.conversationCount.formatted())
                LabeledContent("Active days", value: dashboard.summary.activeDays.formatted())
                LabeledContent("Tokens freshly read", value: dashboard.summary.totals.promptTokens.formatted())
                LabeledContent("Tokens reused from cache", value: dashboard.summary.totals.cachedTokens.formatted())
                LabeledContent("Computing time", value: duration(dashboard.summary.totals.inferenceMilliseconds))
                LabeledContent("Prompt processing", value: speed(dashboard.summary.totals.prefillTokensPerSecond))
                LabeledContent("Decoding", value: speed(dashboard.summary.totals.decodeTokensPerSecond))
                Text("Rates divide total measured tokens by total measured time. The first generated token is excluded from the decode interval. ExecuTorch records total time but has no measured split here. Cache warming outside generation is not included. These are usage measurements, not controlled benchmarks.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                if dashboard.summary.incompleteMetalTimingPasses > 0 {
                    Text("\(dashboard.summary.incompleteMetalTimingPasses.formatted()) earlier Metal passes have incomplete prompt timings. They are excluded from prompt-processing and computing-time totals. Their token counts and decoding rates remain recorded.")
                        .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                }
            }
            if !dashboard.summary.perModel.isEmpty {
                Section("By model and backend") {
                    ForEach(dashboard.summary.perModel) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.modelName).font(OWTheme.interface().weight(.semibold))
                            Text(row.backend.label).font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary)
                            Text("\(row.totals.generatedTokens.formatted()) tokens · \(row.totals.passes.formatted()) passes")
                            LabeledContent("Prompt processing", value: speed(row.totals.prefillTokensPerSecond))
                            LabeledContent("Decoding", value: speed(row.totals.decodeTokensPerSecond))
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section {
                LabeledContent("Model files", value: bytes(dashboard.storage?.ownedBytes))
                LabeledContent("Free storage", value: bytes(dashboard.freeStorageBytes))
                LabeledContent("Current app memory headroom", value: bytes(dashboard.headroomBytes))
                if let snapshot = dashboard.storage, snapshot.unlistedBytes > 0 {
                    LabeledContent("Files outside listed models", value: bytes(snapshot.unlistedBytes))
                }
                if let failure = dashboard.error { Text(failure).foregroundStyle(OWTheme.danger) }
                Button("Refresh measurements") { Task { await dashboard.refresh(chat: chat, downloads: downloads) } }
            } header: { Text("Storage and memory") } footer: {
                Text("File totals count actual model-folder bytes, including paused downloads and staging files. They exclude chats, caches and other app data. Free storage and app headroom can change while iOS runs.")
            }
            if let snapshot = dashboard.storage {
                Section {
                    ForEach(downloads.models) { model in
                        if let row = snapshot.rows.first(where: { $0.id == model.id }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.name).font(OWTheme.interface().weight(.semibold))
                                LabeledContent("Files on disk", value: bytes(row.ownedBytes))
                                if row.incompleteBytes > 0 { LabeledContent("Partial or staging files", value: bytes(row.incompleteBytes)) }
                                if let metadata = row.metadata {
                                    let preview = GGUFMemoryPreview(metadata: metadata, weightBytes: row.declaredFileBytes, context: model.settings.contextTokens,
                                        headroomBytes: dashboard.headroomBytes, storageBytes: dashboard.freeStorageBytes)
                                    LabeledContent("Selected context", value: model.settings.contextTokens.formatted())
                                    LabeledContent("Weights plus F16 cache", value: bytes(preview.weightsAndKVBytes))
                                    if preview.exceedsCurrentHeadroom { Text("Estimated weights and cache exceed current app headroom.").foregroundStyle(OWTheme.danger) }
                                    if preview.kvBytes == nil { Text("This header does not describe enough cache dimensions to estimate memory.") }
                                } else if let failure = row.inspectionError { Text("Header estimate unavailable: " + failure).foregroundStyle(OWTheme.secondary) }
                                else { Text("Cache and runtime memory estimates are unavailable for this artifact.").foregroundStyle(OWTheme.secondary) }
                                ThroughputEstimateView(estimates: ThroughputEstimates(records: dashboard.usageRecords,
                                    installed: snapshot.modelsWithKnownWeights(downloads.models), backend: model.backend), weightBytes: row.weights?.bytes, backend: model.backend)
                            }.padding(.vertical, 4)
                        }
                    }
                } header: { Text("Installed model estimates") } footer: {
                    Text("These estimates omit runtime buffers, recurrent state and other allocations. A value below headroom does not guarantee loading or sustained operation. No automatic context or backend changes are made.")
                }
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Usage and storage")
            .task(id: chat.usageRevision) { await dashboard.refresh(chat: chat, downloads: downloads) }
            .onChange(of: downloads.models) { Task { await dashboard.refresh(chat: chat, downloads: downloads) } }
            .refreshable { await dashboard.refresh(chat: chat, downloads: downloads) }
    }
    private func bytes(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown" }
    private func speed(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(1))) + " tokens/s" } ?? "Not measured" }
    private func duration(_ value: Double) -> String { (value / 1000).formatted(.number.precision(.fractionLength(1))) + " seconds" }
    private func dayLabel(_ value: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(value) * 86400)
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
