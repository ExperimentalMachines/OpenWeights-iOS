import SwiftUI
import OpenWeightsCore

struct GoalStrip: View {
    @ObservedObject var chat: ChatController
    let goal: WorkGoal
    @State private var details = false
    private var label: String {
        switch goal.state {
        case .planning: return "Planning"
        case .working: return goal.research == nil ? "Working" : "Researching"
        case .writing: return "Writing report"
        case .done: return goal.research == nil ? "Goal finished" : "Research finished"
        case .stopped: return "Goal stopped"
        case .halted: return "Goal paused"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Button { details = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(OWTheme.interface(13).weight(.semibold))
                    Text(goal.note ?? goal.plan?.next?.text ?? goal.task).font(OWTheme.metric(12))
                        .foregroundStyle(OWTheme.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.accessibilityLabel("\(label). \(goal.note ?? goal.task). Show goal details")
            if chat.goalActive { Button("Stop") { chat.stopGoal() }.frame(minHeight: 44) }
            else { Button("Details") { details = true }.frame(minHeight: 44) }
        }.padding(.horizontal, 12).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("chat.goal")
            .sheet(isPresented: $details) {
                NavigationStack {
                    Form {
                        Section {
                            Text(goal.task).textSelection(.enabled)
                            LabeledContent("State", value: label)
                            LabeledContent("Steps completed", value: "\(goal.stepsTaken)/\(WorkGoal.maximumSteps)")
                            if let note = goal.note { Text(note).foregroundStyle(OWTheme.secondary) }
                        }
                        if let plan = chat.current?.plan ?? goal.plan {
                            Section("Plan") {
                                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                                    Toggle(step.text, isOn: Binding(get: { step.done }, set: { done in
                                        Task { await chat.setPlanStep(index, done: done) }
                                    })).disabled(chat.goalActive || chat.busy || chat.loading || chat.boardUpdating)
                                }
                            }
                        }
                        if let research = goal.research, let plan = goal.plan {
                            Section("Verified sources") {
                                ForEach(research.sources(for: plan), id: \.self) { source in Text(source).textSelection(.enabled) }
                                Text("Each question requires a successful search and a fetched result. Checked questions without recorded evidence are researched again on resume.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                            }
                        }
                        if !goal.steering.isEmpty {
                            Section("Queued for the next step") {
                                ForEach(Array(goal.steering.enumerated()), id: \.offset) { _, message in Text(message) }
                            }
                        }
                        Section {
                            if chat.goalActive { Button("Stop goal", role: .destructive) { chat.stopGoal() } }
                            else {
                                if [.halted, .stopped].contains(goal.state), goal.hasBudget {
                                    Button("Resume reviewed plan") { Task { await chat.resumeGoal() }; details = false }
                                        .disabled(chat.busy || chat.loading || chat.boardUpdating || chat.pendingUserQuestion != nil || chat.loadedModel == nil || !chat.supportsTools)
                                }
                                Button("Dismiss goal") { Task { await chat.dismissGoal() }; details = false }
                            }
                        } footer: {
                            Text("Goals spend at most 12 steps and pause after two consecutive failures, critical heat or less than 15% battery. Type in chat to steer the next step. This build pauses when the app becomes inactive. Review actual tool results before resuming interrupted work.")
                        }
                    }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Goal")
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { details = false } } }
                }.presentationDragIndicator(.visible)
            }
    }
}
