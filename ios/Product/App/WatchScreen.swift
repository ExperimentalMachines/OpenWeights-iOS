import SwiftUI
import UIKit
import OpenWeightsCore

struct WatchScreen: View {
    @ObservedObject var watches: WatchController
    @ObservedObject var chat: ChatController
    @State private var creating = false
    var body: some View {
        List {
            Section {
                Toggle("Let chat request watches", isOn: $watches.toolEnabled)
                    .disabled(chat.busy || chat.loading || chat.goalActive)
                if watches.toolEnabled && chat.loadedModel != nil && !chat.supportsTools {
                    Text("Choose a tool-capable model for chat to request a watch. You can add one here with any loaded text model.").foregroundStyle(OWTheme.secondary)
                }
                LabeledContent("Notifications", value: watches.notifications.label)
                if watches.notifications == .denied {
                    Button("Open notification settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                } else if watches.notifications != .enabled {
                    Button("Enable watch notifications") { Task { await watches.requestNotifications() } }.disabled(watches.updating)
                }
                Text("Requested intervals are due times. iOS chooses background execution time. Due reminders do not mean a check ran.")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                Text(chat.loadedModel.map { "Checks use \($0.name). Background checks need a loaded CPU backend. Metal and MLX checks need the app open." } ?? "Load a model in Chat to run checks.")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            }
            if let warning = watches.schedulingWarning { Section { Text(warning).foregroundStyle(OWTheme.secondary) } }
            if let error = watches.error { Section { Text(error).foregroundStyle(OWTheme.danger) } }
            if watches.watches.isEmpty {
                Section {
                    Text("No watches saved").font(OWTheme.interface(18).weight(.semibold))
                    Text("Check a condition again later, or deliver a due reminder. Each watch ends after 60 checks or 72 hours.")
                        .foregroundStyle(OWTheme.secondary)
                    Button("Add watch") { creating = true }.frame(minHeight: 44)
                }
            } else {
                Section("Saved watches") {
                    ForEach(watches.watches) { watch in
                        NavigationLink {
                            WatchDetailScreen(id: watch.id, watches: watches)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(watch.task).lineLimit(3)
                                Text(watches.checkingID == watch.id ? "Checking now" : watch.state.label)
                                    .font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                                if watch.state == .active {
                                    Text("Requested every \(watch.everyMinutes) min. Due \(watch.nextDueAt.formatted(date: .abbreviated, time: .shortened)).")
                                        .font(OWTheme.metric(11)).foregroundStyle(OWTheme.secondary)
                                }
                                if let summary = watch.lastSummary { Text(summary).font(OWTheme.interface(13)).lineLimit(3) }
                                Text("\(watch.runs)/60 checks").font(OWTheme.metric(11)).foregroundStyle(OWTheme.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("watch.row.\(watch.id.uuidString)")
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Watches")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add") { creating = true }.disabled(watches.updating) } }
            .sheet(isPresented: $creating) { NavigationStack { WatchEditor(watches: watches, existing: nil) } }
    }
}

private extension ScheduledWatch.State {
    var label: String {
        switch self { case .active: return "Active"; case .paused: return "Paused"; case .stopped: return "Stopped"; case .failed: return "Stopped after failed checks"; case .expired: return "Time or check budget ended" }
    }
}

struct WatchDetailScreen: View {
    let id: UUID
    @ObservedObject var watches: WatchController
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var removing = false
    private var watch: ScheduledWatch? { watches.watches.first { $0.id == id } }
    var body: some View {
        Group {
            if let watch {
                Form {
                    Section {
                        Text(watch.task).textSelection(.enabled)
                        LabeledContent("State", value: watches.checkingID == id ? "Checking now" : watch.state.label)
                        LabeledContent("Requested interval", value: "\(watch.everyMinutes) minutes")
                        LabeledContent("Checks used", value: "\(watch.runs)/60")
                        LabeledContent("Window ends", value: watch.expiresAt.formatted(date: .abbreviated, time: .shortened))
                        if watch.state == .active { LabeledContent("Next due", value: watch.nextDueAt.formatted(date: .abbreviated, time: .shortened)) }
                        if let actual = watch.lastRunAt { LabeledContent("Last actual attempt", value: actual.formatted(date: .abbreviated, time: .shortened)) }
                        if let summary = watch.lastSummary { Text(summary).textSelection(.enabled) }
                    } footer: { Text("A due time is not a guaranteed run time. Skipped attempts do not spend checks. Three consecutive failures stop the watch.") }
                    WatchWebSourcesSection(authorization: watch.webAuthorization)
                    Section {
                        if watch.state == .active {
                            Button("Pause watch") { Task { await watches.pause(id) } }
                            if watches.checkingID == id { Button("Cancel this check") { watches.cancelCheck(id) } }
                        }
                        if watch.state == .paused { Button("Resume watch") { Task { await watches.resume(id) } } }
                        if [.active, .paused].contains(watch.state) {
                            Button("Edit task or interval") { editing = true }
                            Button("Stop watch", role: .destructive) { Task { await watches.stop(id) } }
                        }
                        Button("Remove watch and history", role: .destructive) { removing = true }
                    }.disabled(watches.updating)
                    if !watch.history.isEmpty {
                        Section {
                            ForEach(watch.history.reversed()) { run in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(run.outcome.rawValue.capitalized + (run.changed ? ", changed" : "")).font(OWTheme.interface(14).weight(.semibold))
                                    Text(run.at.formatted(date: .abbreviated, time: .shortened)).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                                    Text(run.summary).textSelection(.enabled)
                                }.padding(.vertical, 4)
                            }
                        } header: { Text("Checks and skipped attempts") } footer: { Text("The latest 20 entries are retained. History may include results from an earlier task before an edit.") }
                    }
                    if let error = watches.error { Section { Text(error).foregroundStyle(OWTheme.danger) } }
                }.scrollContentBackground(.hidden).background(OWTheme.canvas)
                    .sheet(isPresented: $editing) { NavigationStack { WatchEditor(watches: watches, existing: watch) } }
            } else { ContentUnavailableView("Watch removed", systemImage: "clock") }
        }.navigationTitle("Watch")
            .confirmationDialog("Remove this watch and its history?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await watches.forget(id); if watch == nil { dismiss() } } }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct WatchEditor: View {
    @ObservedObject var watches: WatchController
    let existing: ScheduledWatch?
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var minutes = "15"
    @State private var allowWeb = false
    @State private var pages = ""
    @State private var queries = ""
    @State private var sourceDisclosure = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("What to check") { TextField("Condition, fact, or due reminder", text: $task, axis: .vertical).lineLimit(3...8) }
            Section {
                TextField("Requested interval in minutes", text: $minutes).keyboardType(.numberPad)
                Text("Use 1 to 1,440 minutes. Fast checks run while the app is open. Background checks depend on iOS granting time and a loaded CPU model.")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            } header: { Text("Schedule") } footer: {
                Text(existing == nil ? "Stops after 60 checks or 72 hours. Due reminders need notification permission." : "Editing keeps the original time and check budgets. Changing the task clears the last comparison. The current check will be cancelled.")
            }
            Section {
                Toggle("Approve repeated web sources", isOn: $allowWeb)
                if allowWeb {
                    TextField("Public page addresses, one per line", text: $pages, axis: .vertical).lineLimit(2...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Exact search queries, one per line", text: $queries, axis: .vertical).lineLimit(2...6)
                    Text(sourceDisclosure).font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                }
            } header: { Text("Web access") } footer: {
                Text("Saving approves repeated requests for only these addresses and queries, including after previous findings. Include any required redirect addresses. Up to eight of each. Tool switches still apply. A changed search provider or proxy needs approval again. Other calls still follow unattended approval rules, and pages cannot be saved by a watch.")
            }
            if let error { Section { Text(error).foregroundStyle(OWTheme.danger) } }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle(existing == nil ? "Add watch" : "Edit watch")
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving..." : existing == nil ? "Start watch" : "Save") {
                        guard let interval = Int(minutes), (1...1440).contains(interval) else { error = "Use a whole number between 1 and 1,440 minutes."; return }
                        saving = true; error = nil
                        Task {
                            let authorization: WatchWebAuthorization?
                            do {
                                if allowWeb && !queries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sourceDisclosure != watches.webAuthorizationDisclosure {
                                    sourceDisclosure = watches.webAuthorizationDisclosure
                                    throw WatchError.invalid("Search providers or the proxy changed. Review the updated web access description before saving again.")
                                }
                                authorization = allowWeb ? try watches.webAuthorization(pages: pages, queries: queries) : nil
                                if allowWeb && authorization == nil { throw WatchError.invalid("Enter at least one page address or search query to approve.") }
                            } catch { saving = false; self.error = error.localizedDescription; return }
                            let saved: Bool
                            if let existing { saved = await watches.edit(existing.id, task: task, everyMinutes: interval, webAuthorization: authorization) }
                            else { saved = await watches.create(task: task, everyMinutes: interval, webAuthorization: authorization) }
                            saving = false
                            if saved { dismiss() } else { error = watches.error ?? "The watch could not be saved. Try again." }
                        }
                    }.disabled(saving || watches.updating || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.onAppear {
                sourceDisclosure = watches.webAuthorizationDisclosure
                if let existing {
                task = existing.task; minutes = String(existing.everyMinutes)
                allowWeb = existing.webAuthorization != nil
                pages = existing.webAuthorization?.pages.joined(separator: "\n") ?? ""
                queries = existing.webAuthorization?.queries.joined(separator: "\n") ?? ""
            } }
    }
}

private struct WatchWebSourcesSection: View {
    let authorization: WatchWebAuthorization?
    var body: some View {
        if let authorization {
            Section {
                ForEach(authorization.pages, id: \.self) { Text($0).textSelection(.enabled) }
                ForEach(authorization.queries, id: \.self) { Text("Search: " + $0).textSelection(.enabled) }
                if !authorization.queries.isEmpty {
                    Text("Providers: " + authorization.providers.map(\.label).joined(separator: ", "))
                    Text(authorization.proxyAddress.isEmpty ? "Search connects directly." : "Search proxy: " + authorization.proxyAddress)
                }
            } header: { Text("Approved repeated web sources") } footer: {
                Text("Only these exact outbound inputs are approved. Edit the watch to change or remove them. Page fetches connect directly.")
            }
        }
    }
}
