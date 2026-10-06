import SwiftUI
import OpenWeightsCore

struct ChatScreen: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var downloads: ModelDownloads
    @StateObject private var speech: SpeechReader
    @Environment(\.scenePhase) private var speechScenePhase
    @State private var history = false
    @State private var models = false
    @State private var editing: StoredMessage?
    @State private var editedText = ""
    @MainActor init(chat: ChatController, downloads: ModelDownloads, speech: SpeechReader? = nil) {
        self.chat = chat; self.downloads = downloads
        _speech = StateObject(wrappedValue: speech ?? SpeechReader())
    }
    var body: some View {
        VStack(spacing: 0) {
            Button { models = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.loadedModel?.name ?? "Choose a model").font(OWTheme.interface()).lineLimit(2)
                        Text(chat.checkingWatchID != nil ? "Checking a watch..." : chat.loading ? "Preparing chat…" : chat.loadedModel?.backend.label ?? "Download or import open weights to begin")
                            .font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.down")
                }.frame(minHeight: 44).padding(.horizontal, 16).padding(.vertical, 8)
            }.disabled(chat.busy || chat.loading || chat.boardUpdating || chat.goalActive || chat.attachments?.busy == true).accessibilityIdentifier("chat.modelPicker")
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.current?.messages.isEmpty != false {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("A conversation on your device").font(OWTheme.display())
                                Text("Chats are stored on this device. Model downloads use Hugging Face. Enabled web tools send queries and requested URLs to their providers.")
                                    .foregroundStyle(OWTheme.secondary)
                                if chat.loadedModel == nil { Button("Choose a model") { models = true }.buttonStyle(OWActionStyle()) }
                            }.padding(.top, 36)
                        }
                        ForEach(chat.current?.messages ?? []) { message in
                            MessageRow(message: message, mediaCache: chat.web?.mediaCache, attachmentStore: chat.attachments?.store, speechReader: speech)
                                .contextMenu {
                                    Button("Copy text") { Task { await TranscriptCopy.copyPlainText(message.content) } }
                                    Button("Copy Markdown") { TranscriptCopy.copyMarkdown(message.content) }
                                    ShareLink(item: message.content)
                                    if message.status == .complete { Button("Branch from here") { Task { await chat.branch(through: message.id) } }.disabled(chat.busy) }
                                    if message.role == .user { Button("Edit and resend") { editing = message; editedText = message.content }.disabled(chat.busy) }
                                    if message.id == chat.current?.messages.last?.id && message.role == .assistant {
                                        Button("Regenerate") { Task { await chat.regenerate() } }.disabled(chat.busy)
                                    }
                                }
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(16).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }.accessibilityIdentifier("chat.transcript")
                .onChange(of: chat.current?.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            VStack(spacing: 8) {
                if let goal = chat.workGoal { GoalStrip(chat: chat, goal: goal) }
                if chat.workGoal == nil, let plan = chat.current?.plan {
                    PlanPanel(plan: plan, disabled: chat.busy || chat.loading || chat.boardUpdating) { index, done in
                        Task { await chat.setPlanStep(index, done: done) }
                    } clear: { Task { await chat.clearPlan() } }
                }
                if let question = chat.pendingUserQuestion {
                    UserQuestionPanel(question: question, recovered: chat.questionRecovered, modelLoaded: chat.loadedModel != nil && chat.supportsTools,
                                      disabled: chat.boardUpdating || chat.loading) { answer in
                        Task { await chat.answerUserQuestion(answer, ticketID: question.id) }
                    }.id(question.id)
                } else if chat.canContinueQuestionAnswer && !chat.busy {
                    Button("Continue from answer") { chat.continueQuestionAnswer() }
                        .disabled(chat.loadedModel == nil || !chat.supportsTools || chat.loading || chat.boardUpdating)
                }
                if chat.files?.mode == .yolo {
                    Text("Yolo is active for this app session").font(OWTheme.metric(13)).foregroundStyle(OWTheme.danger)
                }
                if let request = chat.pendingToolApproval {
                        ToolApprovalPanel(request: request, context: chat.pendingToolApprovalContext) { approved in
                        chat.answerToolApproval(approved: approved, ticketID: request.ticketID)
                    }
                }
                if let model = chat.loadedModel, chat.contextUsed > 0 {
                    HStack {
                        ProgressView(value: min(1, Double(chat.contextUsed) / Double(model.settings.contextTokens))).tint(OWTheme.signal)
                        Text("\(chat.contextIsExact ? "" : "~")\(chat.contextUsed)/\(model.settings.contextTokens)").font(OWTheme.metric())
                        Button("Fold earlier turns") { Task { await chat.foldConversation() } }
                            .font(OWTheme.metric(12))
                            .disabled(chat.busy || chat.loading || chat.goalActive || chat.pendingUserQuestion != nil ||
                                chat.current.flatMap { ConversationContext.foldBoundary($0, contextTokens: model.settings.contextTokens) } == nil)
                            .accessibilityIdentifier("chat.fold")
                    }.accessibilityLabel("\(chat.contextIsExact ? "Context used" : "Estimated context used") \(chat.contextUsed) of \(model.settings.contextTokens) tokens")
                }
                if chat.isCompacting {
                    HStack { ProgressView(); Text("Summarizing earlier turns…").font(OWTheme.interface(13)) }
                        .accessibilityIdentifier("chat.compacting")
                } else if let value = chat.current, let fold = ConversationContext.validFold(value) {
                    DisclosureGroup("\(fold.messageCount) earlier messages summarized") {
                        Text(fold.summary).font(OWTheme.interface(13)).textSelection(.enabled)
                        Text("Full history is kept. Summary created with \(fold.modelName).").font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary)
                    }.accessibilityIdentifier("chat.summary")
                }
                if let attachments = chat.attachments { AttachmentComposer(chat: chat, attachments: attachments) }
                if chat.contextIncludesUncountedMedia { Text("Image/audio context is measured when sending, not by the text-only counter.").font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary) }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(chat.goalActive ? "Steer the next step" : "Message", text: $chat.draft, axis: .vertical).lineLimit(1...7)
                        .disabled(chat.pendingUserQuestion != nil || chat.boardUpdating)
                        .padding(12).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OWTheme.outline, lineWidth: 1))
                        .accessibilityIdentifier("chat.composer")
                    if chat.goalActive {
                        Button { Task { await chat.steerGoal(chat.draft) } } label: { Image(systemName: "arrow.up").frame(width: 20) }
                            .buttonStyle(OWActionStyle()).accessibilityLabel("Steer the next step")
                            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.pendingUserQuestion != nil || chat.boardUpdating)
                    } else if chat.busy || chat.loading || chat.attachments?.busy == true {
                        Button { chat.cancel() } label: { Image(systemName: "stop.fill").frame(width: 20) }
                            .buttonStyle(OWActionStyle()).accessibilityLabel(chat.loading ? "Stop preparing chat" : "Stop generation").accessibilityIdentifier("chat.stop")
                    } else {
                        Button { Task { await chat.send() } } label: { Image(systemName: "arrow.up").frame(width: 20) }
                            .buttonStyle(OWActionStyle()).accessibilityLabel("Send message").accessibilityIdentifier("chat.send")
                            .disabled((chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments?.hasStaged != true) || chat.attachments?.busy == true || chat.loadedModel == nil || chat.loading || chat.pendingUserQuestion != nil || chat.boardUpdating)
                    }
                }
            }.padding(16).background(OWTheme.canvas)
        }
        .background(OWTheme.canvas).navigationTitle(chat.current?.title ?? "OpenWeights").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { history = true } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Conversations").disabled(chat.attachments?.busy == true) }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Run as goal") { Task { await chat.startGoal(chat.draft) } }
                    Button("Research on the web") { Task { await chat.startResearch(chat.draft) } }
                } label: { Image(systemName: "list.bullet.clipboard") }
                    .accessibilityLabel("Goal and research actions").accessibilityIdentifier("chat.startGoal")
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.loadedModel == nil || !chat.supportsTools || chat.busy || chat.loading || chat.boardUpdating || chat.goalActive || chat.pendingUserQuestion != nil || chat.attachments?.hasStaged == true || chat.attachments?.busy == true)
            }
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await chat.newConversation() } } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation").disabled(chat.busy || chat.loading || chat.boardUpdating || chat.goalActive || chat.attachments?.busy == true) }
        }
        .onDisappear { speech.stop() }
        .onChange(of: speechScenePhase) { _, phase in if phase != .active { speech.prepareForInactivity() } }
        .onChange(of: chat.current?.id) { _, _ in speech.stop() }
        .onChange(of: models) { _, showing in if showing { speech.stop() } }
        .onChange(of: history) { _, showing in if showing { speech.stop() } }
        .sheet(isPresented: $history) { NavigationStack { ConversationList(chat: chat) { history = false } } }
        .sheet(isPresented: $models) { NavigationStack { ModelsScreen(downloads: downloads, chat: chat) }.presentationDragIndicator(.visible) }
        .overlay { if let files = chat.files { CanvasPresentation(files: files) } }
        .alert("Chat could not continue", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("Dismiss", role: .cancel) { chat.error = nil }
        } message: { Text(chat.error ?? "") }
        .alert("Edit and resend", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Message", text: $editedText)
            Button("Resend") { if let editing { Task { await chat.editAndResend(messageID: editing.id, text: editedText) } }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: { Text("Replies after this message will be replaced. Branch first to keep them.") }
    }
}

private struct CanvasPresentation: View {
    @ObservedObject var files: WorkspaceController
    @State private var visible = false
    var body: some View {
        Color.clear.allowsHitTesting(false)
            .onChange(of: files.canvas?.id) { _, value in visible = value != nil }
            .sheet(isPresented: $visible) { NavigationStack { CanvasScreen(files: files) } }
            .overlay(alignment: .topTrailing) {
                if files.canvas != nil && !visible { Button("Open preview") { visible = true }.padding(8) }
            }
    }
}

private struct PlanPanel: View {
    let plan: TaskPlan
    let disabled: Bool
    let tick: (Int, Bool) -> Void
    let clear: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(plan.isFinished ? "Plan finished" : "Plan").font(OWTheme.interface().weight(.semibold))
                Spacer(); Button("Clear", action: clear).frame(minHeight: 44)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        Button { tick(index, !step.done) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: step.done ? "checkmark.square.fill" : "square")
                                Text(step.text).strikethrough(step.done).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 44)
                        }.accessibilityLabel("Step \(index + 1): \(step.text), \(step.done ? "finished" : "unfinished")")
                    }
                }
            }.frame(maxHeight: 180)
        }.font(OWTheme.interface(13)).padding(12).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            .disabled(disabled).accessibilityIdentifier("chat.plan")
    }
}

private struct UserQuestionPanel: View {
    let question: UserQuestion
    let recovered: Bool
    let modelLoaded: Bool
    let disabled: Bool
    let answer: (String?) -> Void
    @State private var selected: Set<Int> = []
    @State private var text = ""
    private var response: String {
        let choices = question.options.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        return (choices + [text.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text).font(OWTheme.interface().weight(.semibold)).textSelection(.enabled)
                    if recovered { Text("Question restored after interruption. Answer to continue.").font(OWTheme.metric(13)).foregroundStyle(OWTheme.secondary) }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            if selected.contains(index) { selected.remove(index) }
                            else if question.multiple { selected.insert(index) }
                            else { selected = [index] }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                Text(option).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 44)
                        }.accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                    }
                    TextField("Type an answer", text: $text, axis: .vertical).lineLimit(1...4)
                        .padding(10).background(OWTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("chat.questionAnswer")
                }
            }.frame(maxHeight: 260)
            HStack {
                Button("Skip") { answer(nil) }.frame(minHeight: 44)
                Spacer()
                Button(modelLoaded ? "Answer and continue" : "Save answer") { answer(response) }
                    .buttonStyle(OWActionStyle()).disabled(response.isEmpty)
            }
        }.padding(14).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            .disabled(disabled).accessibilityIdentifier("chat.question")
    }
}
struct MessageRow: View {
    let message: StoredMessage
    var mediaCache: MediaPreviewCache? = nil
    var attachmentStore: ChatAttachmentStore? = nil
    var speechReader: SpeechReader? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == .user ? "You" : message.role == .tool ? (message.toolName ?? "Tool result") : "OpenWeights")
                .font(OWTheme.interface(13).weight(.semibold)).foregroundStyle(OWTheme.secondary)
            if let attachmentStore {
                ForEach(message.attachments ?? []) { attachment in StoredAttachmentView(attachment: attachment, store: attachmentStore) }
            }
            if let document = message.attachedDocument {
                Text("Document: " + document.name + (document.wasTrimmed ? " (cut short)" : "")).font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary)
            }
            if let calls = message.toolCalls, !calls.isEmpty {
                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                    Text("Requested: " + call.name).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                }
            }
            if message.content.isEmpty && message.status == .streaming { ProgressView().accessibilityLabel("Generating a response") }
            else if message.searchEvidence == nil && message.mediaEvidence == nil { TranscriptMarkdownView(content: message.content) }
            if let evidence = message.searchEvidence {
                Text("Results for \(evidence.query) from \(evidence.engine.label)")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                if evidence.hits.isEmpty { Text("No results matched.") }
                let hits = evidence.hits
                ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                    if let url = URL(string: hit.url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.title).font(OWTheme.interface(14).weight(.semibold))
                                if !hit.snippet.isEmpty { Text(hit.snippet).font(OWTheme.interface(13)).foregroundStyle(OWTheme.text) }
                                Text(url.host ?? hit.url).font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityLabel("Open source: " + hit.title)
                    }
                }
            }
            if let evidence = message.mediaEvidence { MediaResultCarousel(evidence: evidence, cache: mediaCache) }
            if message.role == .tool && message.status == .streaming { ProgressView().accessibilityLabel("Running tool") }
            HStack(spacing: 10) {
                if let speed = message.tokensPerSecond { Text(String(format: "%.1f tok/s", speed)).foregroundStyle(OWTheme.signal) }
                if let first = message.firstTextMilliseconds { Text(String(format: "%.2f s first text", first / 1000)) }
                if message.status == .cancelled { Text("Stopped") }
                if message.status == .failed { Text(message.role == .tool ? "Tool did not complete" : "Interrupted by an error").foregroundStyle(OWTheme.danger) }
                if message.toolResultCheckpointFailed == true { Text("Tool result checkpoint failed").foregroundStyle(OWTheme.danger) }
            }.font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
            if message.role == .assistant, !message.content.isEmpty, let speechReader {
                ReadReplyButton(messageID: message.id, text: message.content, reader: speechReader)
            }
        }.padding(.leading, message.role == .assistant ? 10 : 0)
            .overlay(alignment: .leading) { if message.role == .assistant { Rectangle().fill(OWTheme.signal).frame(width: 2) } }
    }
}

private struct ToolApprovalPanel: View {
    let request: ApprovedToolCall
    let context: String?
    let answer: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(OWTheme.interface().weight(.semibold))
            if let context { Text(context).font(OWTheme.metric(13)).foregroundStyle(OWTheme.secondary) }
            Text("Review the exact arguments before this tool runs.")
                .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            ScrollView {
                Text(request.displayedCall.argumentsJSON).font(OWTheme.metric(13))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
            HStack {
                Button("Decline") { answer(false) }.frame(minHeight: 44)
                Spacer()
                Button("Approve") { answer(true) }.buttonStyle(OWActionStyle())
            }
        }.padding(14).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
    }
    private var title: String {
        switch request.displayedCall.name {
        case "save_memory": return "Save a memory?"
        case "update_memory": return "Edit a saved memory?"
        case "forget_memory": return "Forget a saved memory?"
        case "write_file": return "Write a file?"
        case "delete_file": return "Delete a file or folder?"
        case "read_file": return "Read a file?"
        case "find_files": return "Search the shared folder?"
        default: return "Run \(request.displayedCall.name)?"
        }
    }
}
