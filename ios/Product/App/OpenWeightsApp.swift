import SwiftUI
import OpenWeightsCore
import BackgroundTasks
import UserNotifications

@MainActor final class ProductState: ObservableObject {
    let downloads: ModelDownloads?
    let chat: ChatController?
    let memory: MemoryController?
    let files: WorkspaceController?
    let watches: WatchController?
    let failure: String?
    init() {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenWeights")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
            let library = try ModelLibrary(file: root.appendingPathComponent("models.json"))
            let manager = ModelDownloads(root: root.appendingPathComponent("Models"), library: library)
            let usage: UsageStore?
            let usageOpenError: String?
            do { usage = try UsageStore(file: root.appendingPathComponent("usage.json")); usageOpenError = nil }
            catch { usage = nil; usageOpenError = "Usage could not be opened. Its existing file was preserved: " + error.localizedDescription }
            let attachments = AttachmentController(store: try ChatAttachmentStore(root: root.appendingPathComponent("Attachments")))
            let savedMemory = MemoryController(store: try MemoryStore(file: root.appendingPathComponent("memory.json")))
            let workspace = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"))
            workspace.pageChecker = { canvas, folder in await CanvasPageChecker.check(canvas, workspace: folder) }
            let watchStore = try WatchStore(file: root.appendingPathComponent("watches.json"))
            let watchManager = WatchController(store: watchStore, scheduler: AppleWatchScheduler(store: watchStore))
            let scriptRunner: (any ScriptRunner)?
            if #available(iOS 26.0, *) { scriptRunner = IsolatedScriptRunner() } else { scriptRunner = nil }
            let controller = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: manager, memory: savedMemory, files: workspace, goals: try GoalStore(file: root.appendingPathComponent("goal.json")), watches: watchManager, web: WebController(), scriptRunner: scriptRunner, usage: usage, usageOpenError: usageOpenError, attachments: attachments)
            watchManager.bind(controller); watches = watchManager
            files = workspace
            memory = savedMemory
            downloads = manager
            chat = controller
            failure = nil
            ProductDelegate.downloads = manager
            ProductDelegate.watches = watchManager
        } catch { downloads = nil; chat = nil; memory = nil; files = nil; watches = nil; failure = error.localizedDescription }
    }
}
final class ProductDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static let productState = ProductState()
    @MainActor static weak var downloads: ModelDownloads?
    @MainActor static weak var watches: WatchController?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background launches need storage before SwiftUI presents a scene.
        _ = Self.productState
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
        if let downloads = Self.downloads { BackgroundDownloadValidation.captureLaunch(downloads) }
#endif
        Task { @MainActor in
            await Self.downloads?.restore()
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
            if let downloads = Self.downloads { await BackgroundDownloadValidation.start(downloads) }
#endif
        }
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppleWatchScheduler.taskIdentifier, using: .main) { task in
            let epoch = UUID()
            let work = Task { @MainActor in
                let completed = await Self.watches?.runBackground(epoch) ?? false
                task.expirationHandler = nil
                task.setTaskCompleted(success: completed)
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in Self.watches?.cancelBackground(epoch) }
            }
        }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = notification.request.content.userInfo["watchKind"] as? String
        completionHandler(kind == "due" ? [] : [.banner, .sound, .list])
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == "org.experimentalmachines.openweights.models", let downloads = Self.downloads else { completionHandler(); return }
#if OW_BACKGROUND_DOWNLOAD_VALIDATION
        BackgroundDownloadValidation.record("os-background-session-handler", fields: ["identifier": identifier])
        downloads.handleBackgroundEvents {
            Task { @MainActor in
                await BackgroundDownloadValidation.verifyReady()
                BackgroundDownloadValidation.record("os-background-session-completion", fields: ["identifier": identifier])
                completionHandler()
            }
        }
#else
        downloads.handleBackgroundEvents(completion: completionHandler)
#endif
    }
}
@main struct OpenWeightsApp: App {
    @UIApplicationDelegateAdaptor(ProductDelegate.self) private var delegate
    @StateObject private var state = ProductDelegate.productState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group {
                if let chat = state.chat, let downloads = state.downloads, let memory = state.memory, let files = state.files, let watches = state.watches {
                    ProductRoot(chat: chat, downloads: downloads, memory: memory, files: files, watches: watches)
                        .task { await files.restore(); await downloads.restore(); await chat.restore(); await watches.restore(); watches.setForeground(scenePhase == .active) }
                } else {
                    ContentUnavailableView("App data could not be opened", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(state.failure ?? "Your existing files have been preserved."))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { state.chat?.prepareForInactivity() }
                state.watches?.setForeground(phase == .active)
            }
            .font(OWTheme.interface()).tint(OWTheme.text).foregroundStyle(OWTheme.text)
            .preferredColorScheme(OWTheme.preferredColorScheme(appearance))
        }
    }
}
struct ProductRoot: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var memory: MemoryController
    @ObservedObject var files: WorkspaceController
    @ObservedObject var watches: WatchController
    var body: some View {
        TabView {
            NavigationStack { ChatScreen(chat: chat, downloads: downloads) }.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { ModelsScreen(downloads: downloads, chat: chat) }.tabItem { Label("Models", systemImage: "shippingbox") }
            NavigationStack { WatchScreen(watches: watches, chat: chat) }.tabItem { Label("Watches", systemImage: "clock") }
            NavigationStack { SettingsScreen(memory: memory, chat: chat, files: files) }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}
