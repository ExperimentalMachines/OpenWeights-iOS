import SwiftUI
import OpenWeightsCore

struct ConversationList: View {
    @ObservedObject var chat: ChatController
    let selected: () -> Void
    private var archived: Bool { chat.viewingArchived }
    @State private var rename: Conversation?
    @State private var name = ""
    @State private var deleting: Conversation?
    private var actionsDisabled: Bool { chat.busy || chat.loading || chat.boardUpdating || chat.goalActive }
    var body: some View {
        List {
            Toggle("Archived conversations", isOn: Binding(get: { chat.viewingArchived }, set: { value in Task { await chat.refresh(archived: value) } }))
            if let error = chat.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if chat.conversations.isEmpty {
                ContentUnavailableView(archived ? "No archived conversations" : "No conversations yet", systemImage: "bubble.left",
                    description: Text(archived ? "Archived chats appear here." : "Start a chat after choosing a model."))
            }
            ForEach(chat.conversations) { conversation in
                Button { Task { await chat.open(conversation); selected() } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conversation.title).lineLimit(2)
                            Text(conversation.updatedAt, style: .date).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                        }
                        Spacer()
                        if conversation.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                    }.frame(minHeight: 44)
                }.disabled(actionsDisabled)
                .contextMenu {
                    Group {
                        Button("Rename") { rename = conversation; name = conversation.title }
                        if !conversation.archived {
                            Button(conversation.pinned ? "Unpin" : "Pin") { Task { await chat.setConversationPinned(conversation.id, pinned: !conversation.pinned) } }
                        }
                        Button(conversation.archived ? "Restore" : "Archive") { Task { await chat.setConversationArchived(conversation.id, archived: !conversation.archived) } }
                        Button("Delete", role: .destructive) { deleting = conversation }
                    }.disabled(actionsDisabled)
                }
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Conversations")
        .task { await chat.refresh(archived: false) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: selected) } }
        .alert("Rename conversation", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Title", text: $name)
            Button("Save") { if let value = rename { let title = name; Task { await chat.renameConversation(value.id, title: title) } }; rename = nil }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actionsDisabled)
            Button("Cancel", role: .cancel) { rename = nil }
        }
        .alert("Delete conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let value = deleting { Task { await chat.delete(value) } }; deleting = nil }.disabled(actionsDisabled)
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Delete \"" + (deleting?.title ?? "this conversation") + "\" and its stored messages from this device?") }
    }
}
