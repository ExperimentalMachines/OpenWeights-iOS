import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable
import QuickLook
import OpenWeightsCore

struct AttachmentComposer: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var attachments: AttachmentController
    @State private var files = false
    @State private var document = false
    @State private var camera = false
    @State private var photos: [PhotosPickerItem] = []
    private var disabled: Bool { chat.busy || chat.loading || chat.boardUpdating || chat.goalActive || chat.pendingUserQuestion != nil || chat.loadedModel == nil || attachments.busy }
    private var fileTypes: [UTType] {
        (chat.mediaSupport.vision ? [.image, .movie] : []) + (chat.mediaSupport.audio ? [.audio] : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.hasStaged {
                ScrollView(.horizontal) {
                    HStack {
                        if let document = attachments.document {
                            VStack(alignment: .leading) {
                                HStack {
                                    Label(document.info.name, systemImage: "doc.text").lineLimit(1)
                                    Button { attachments.removeDocument() } label: { Image(systemName: "xmark.circle") }
                                        .accessibilityLabel("Remove document " + document.info.name).disabled(attachments.busy)
                                }
                                Text("\(document.info.characters) characters" + (document.info.wasTrimmed ? ", cut to fit the context" : ""))
                                    .font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary)
                            }.padding(10).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(attachments.staged) { item in
                            HStack {
                                Label(item.name, systemImage: item.kind == .audio ? "waveform" : "photo").lineLimit(1)
                                Button { Task { await attachments.remove(item.id) } } label: { Image(systemName: "xmark.circle") }
                                    .accessibilityLabel("Remove attachment " + item.name).disabled(attachments.busy)
                            }.padding(10).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack {
                Menu {
                    Button("Text document", systemImage: "doc.text") { document = true }
                    if chat.mediaSupport.vision {
                        PhotosPicker(selection: $photos, maxSelectionCount: 0, matching: .any(of: [.images, .videos])) { Label("Photos and videos", systemImage: "photo.on.rectangle") }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Take photo", systemImage: "camera") { camera = true }
                        }
                    }
                    if !fileTypes.isEmpty { Button("Media from Files", systemImage: "folder") { files = true } }
                } label: { Label("Attach", systemImage: "paperclip").font(OWTheme.interface(13)).frame(minHeight: 44) }
                .disabled(disabled).accessibilityIdentifier("chat.attach")
                if attachments.busy { ProgressView(); Text("Preparing attachment…").font(OWTheme.interface(13)) }
                Spacer()
            }
        }
        .fileImporter(isPresented: $document, allowedContentTypes: [.plainText, .json, .xml], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { attachments.acquire { await chat.stageDocument(url, access: .securityScoped) } }
            case .failure: attachments.error = "The document could not be selected. Try again."
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: fileTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                attachments.acquire {
                    for url in urls {
                        if Task.isCancelled { break }
                        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
                        await chat.stageAttachment(url, type: type, access: .securityScoped)
                    }
                }
            case .failure: attachments.error = "The media could not be selected. Try again."
            }
        }
        .onChange(of: photos) { _, selected in
            guard !selected.isEmpty else { return }
            attachments.acquire {
                defer { photos = [] }
                for item in selected {
                    if Task.isCancelled { break }
                    do {
                        guard let picked = try await item.loadTransferable(type: PickedChatMedia.self) else { throw AttachmentError.unavailable }
                        defer { try? FileManager.default.removeItem(at: picked.url) }
                        await chat.stageAttachment(picked.url, type: picked.type)
                    } catch { if !Task.isCancelled { attachments.error = "The selected photo or video could not be copied. Try again." } }
                }
            }
        }
        .sheet(isPresented: $camera) {
            ChatCamera { result in
                camera = false
                if let url = result {
                    attachments.acquire { await chat.stageAttachment(url, type: .jpeg); try? FileManager.default.removeItem(at: url) }
                }
            }.ignoresSafeArea()
        }
        .alert("Attachment could not be prepared", isPresented: Binding(get: { attachments.error != nil }, set: { if !$0 { attachments.error = nil } })) {
            Button("Dismiss", role: .cancel) { attachments.error = nil }
        } message: { Text(attachments.error ?? "") }
    }
}

private struct PickedChatMedia: Transferable, Sendable {
    let url: URL
    let type: UTType
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in SentTransferredFile(value.url) } importing: { value in
            try await copy(value.file, type: .image, limit: ChatAttachmentStore.mediaByteLimit)
        }
        FileRepresentation(contentType: .movie) { value in SentTransferredFile(value.url) } importing: { value in
            try await copy(value.file, type: .movie, limit: ChatAttachmentStore.videoByteLimit)
        }
    }
    private static func copy(_ source: URL, type: UTType, limit: Int64) async throws -> PickedChatMedia {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openweights-picked-" + UUID().uuidString + "." + source.pathExtension)
        _ = try await AttachmentFileCopy.copy(source, to: url, limit: limit)
        return PickedChatMedia(url: url, type: type)
    }
}

private struct ChatCamera: UIViewControllerRepresentable {
    let finished: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.mediaTypes = [UTType.image.identifier]; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (URL?) -> Void
        init(_ finished: @escaping (URL?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85), Int64(data.count) <= ChatAttachmentStore.mediaByteLimit else { finished(nil); return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("openweights-camera-" + UUID().uuidString + ".jpg")
            do { try data.write(to: url, options: .withoutOverwriting); finished(url) } catch { finished(nil) }
        }
    }
}

struct StoredAttachmentView: View {
    let attachment: ChatAttachment
    let store: ChatAttachmentStore
    @State private var preview: URL?
    @State private var failure: String?
    var body: some View {
        Button {
            Task { do { preview = try await store.resolve(attachment) } catch { failure = error.localizedDescription } }
        } label: { Label(attachment.name, systemImage: attachment.kind == .audio ? "waveform" : "photo").frame(minHeight: 44) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview { OwnedAttachmentPreview(url: preview).ignoresSafeArea() }
        }
        .alert("Attachment unavailable", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("Dismiss") { failure = nil } } message: { Text(failure ?? "") }
    }
}
private struct OwnedAttachmentPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let value = QLPreviewController(); value.dataSource = context.coordinator; return value }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
