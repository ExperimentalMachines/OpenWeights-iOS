import SwiftUI
import OpenWeightsCore

struct MemoryScreen: View {
    @ObservedObject var memory: MemoryController
    @State private var editor: MemoryEditorTarget?
    @State private var confirmDeleteAll = false
    var body: some View {
        List {
            Section {
                if memory.facts.isEmpty {
                    Text("No saved facts. Add a fact you want to keep across conversations.")
                        .foregroundStyle(OWTheme.secondary)
                }
                ForEach(memory.facts) { fact in
                    Button { editor = MemoryEditorTarget(fact: fact) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(fact.text).foregroundStyle(OWTheme.text).multilineTextAlignment(.leading)
                            Text(fact.savedAt, style: .date).font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.accessibilityLabel("Edit saved fact: " + fact.text)
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await memory.delete(fact) } }
                    }
                }
                Button("Add a fact", systemImage: "plus") { editor = MemoryEditorTarget() }
            } header: { Text("Saved facts") } footer: {
                Text("Kept on this device. Each fact can contain up to 160 characters. The oldest facts are removed when the 24-fact or 1,000-character total limit is reached.")
            }
            if let error = memory.error { Section { Text(error).foregroundStyle(OWTheme.danger).accessibilityLabel("Memory error: " + error) } }
            if !memory.facts.isEmpty {
                Section { Button("Delete all saved facts", role: .destructive) { confirmDeleteAll = true } }
            }
        }.disabled(memory.busy)
        .scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Saved memory")
        .task { await memory.restore() }
        .sheet(item: $editor) { target in
            NavigationStack { MemoryEditor(memory: memory, target: target) }
        }
        .confirmationDialog("Delete all saved facts?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await memory.deleteAll() } }
        } message: { Text("This removes saved facts from this device. Conversations are kept.") }
    }
}

private struct MemoryEditorTarget: Identifiable {
    let id = UUID()
    var fact: RememberedFact?
}

private struct MemoryEditor: View {
    @ObservedObject var memory: MemoryController
    let target: MemoryEditorTarget
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    init(memory: MemoryController, target: MemoryEditorTarget) {
        self.memory = memory; self.target = target; _text = State(initialValue: target.fact?.text ?? "")
    }
    var body: some View {
        let normalized = MemoryStore.normalizedFact(text)
        let tooLong = normalized.utf16.count > MemoryStore.maximumFactCharacters
        Form {
            Section("Fact") {
                TextField("One fact to remember", text: $text, axis: .vertical).lineLimit(3...8)
                Text("\(normalized.utf16.count)/160 characters").font(OWTheme.interface(12)).foregroundStyle(tooLong ? OWTheme.danger : OWTheme.secondary)
            }
            if let error = memory.error { Section { Text(error).foregroundStyle(OWTheme.danger) } }
        }.disabled(memory.busy).scrollContentBackground(.hidden).background(OWTheme.canvas)
        .navigationTitle(target.fact == nil ? "Add a fact" : "Edit fact")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(memory.busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(memory.busy ? "Saving…" : "Save") {
                    Task { if await memory.save(text, replacing: target.fact) { dismiss() } }
                }.disabled(memory.busy || normalized.isEmpty || tooLong)
            }
        }
    }
}
