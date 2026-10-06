import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import OpenWeightsCore

@MainActor final class AttachmentController: ObservableObject {
    let store: ChatAttachmentStore
    @Published private(set) var staged: [ChatAttachment] = []
    @Published private(set) var document: StagedAttachmentDocument?
    @Published private(set) var processing = false
    @Published private(set) var acquiring = false
    var busy: Bool { processing || acquiring }
    func acquire(_ body: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        acquiring = true
        acquisition = Task { await body(); acquiring = false; acquisition = nil }
    }
    @Published var error: String?
    private var operation: Task<Void, Never>?
    private var acquisition: Task<Void, Never>?
    var hasStaged: Bool { !staged.isEmpty || document != nil }
    init(store: ChatAttachmentStore) { self.store = store }
    private func run(_ body: @escaping @MainActor () async -> Void) async {
        guard !processing else { return }; processing = true; error = nil
        let task = Task { await body() }; operation = task
        defer { operation = nil; processing = false }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func cancel() { acquisition?.cancel(); operation?.cancel() }
    func stageDocument(_ source: URL, characterLimit: Int, access: WorkspaceAccess = .local) async {
        await run { await self.readDocument(source, characterLimit: characterLimit, access: access) }
    }
    private func readDocument(_ source: URL, characterLimit: Int, access: WorkspaceAccess) async {
        do { document = try await ChatAttachmentStore.readDocument(source, characterLimit: characterLimit, access: access) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func stage(_ source: URL, type: UTType, support: RuntimeMediaSupport, access: WorkspaceAccess = .local) async {
        await run { await self.prepare(source, type: type, support: support, access: access) }
    }
    private func prepare(_ source: URL, type: UTType, support: RuntimeMediaSupport, access: WorkspaceAccess) async {
        let kind: ChatAttachment.Kind
        if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .movie) { kind = .video }
        else if type.conforms(to: .audio) { kind = .audio }
        else { self.error = "Select an image, audio file or video."; return }
        guard support.accepts(kind) else { self.error = "The loaded model cannot read this attachment type."; return }
        var made: [ChatAttachment] = []
        var raw: ChatAttachment?
        do {
            let copied = try await store.importFile(source, mediaType: type.preferredMIMEType ?? "application/octet-stream", kind: kind, access: access)
            raw = copied
            let owned = try await store.resolve(copied)
            let normal = try await AttachmentNormalizer.prepare(owned, kind: kind, mediaType: UTType(filenameExtension: source.pathExtension).flatMap { $0.conforms(to: type) ? $0.preferredMIMEType : nil } ?? type.preferredMIMEType)
            defer { for url in normal { try? FileManager.default.removeItem(at: url) } }
            for (index, url) in normal.enumerated() {
                try Task.checkCancellation()
                let name = kind == .video ? copied.name + " · frame \(index + 1)" : copied.name
                let saved = try await store.importFile(url, name: name, mediaType: kind == .audio ? "audio/wav" : "image/jpeg", kind: kind == .audio ? .audio : .image)
                made.append(saved)
            }
            try Task.checkCancellation()
            guard !made.isEmpty else { throw AttachmentError.unavailable }
            staged += made
        } catch {
            try? await store.discard(made)
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if let raw { try? await store.discard([raw]) }
    }
    func remove(_ id: UUID) async {
        guard !busy else { return }
        let removing = staged.filter { $0.id == id }
        do { try await store.discard(removing); staged.removeAll { $0.id == id } }
        catch { self.error = error.localizedDescription }
    }
    func removeDocument() { if !busy { document = nil } }
    func sent() { staged = []; document = nil }
    func clear() async {
        guard !busy else { return }
        do { try await store.discard(staged); staged = []; document = nil }
        catch { self.error = error.localizedDescription }
    }
}

enum AttachmentNormalizer {
    static func prepare(_ source: URL, kind: ChatAttachment.Kind, mediaType: String? = nil) async throws -> [URL] {
        if kind == .video { return try await video(source, mediaType: mediaType) }
        let work = Task.detached {
            try Task.checkCancellation()
            if kind == .image { return [try image(source)] }
            return [try audio(source)]
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func temporary(_ ext: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("openweights-attachment-" + UUID().uuidString + "." + ext) }
    private static func jpeg(_ image: CGImage) throws -> URL {
        let url = temporary("jpg")
        guard let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw AttachmentError.unavailable }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { try? FileManager.default.removeItem(at: url); throw AttachmentError.unavailable }
        return url
    }
    private static func image(_ source: URL) throws -> URL {
        guard let decoder = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(decoder, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw AttachmentError.unavailable }
        let area = width.doubleValue * height.doubleValue
        guard area.isFinite, area > 0, area <= 100_000_000 else { throw AttachmentError.unavailable }
        let scale = min(1, sqrt(524_288 / area))
        let edge = max(1, Int(floor(max(width.doubleValue, height.doubleValue) * scale)))
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(decoder, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary) else { throw AttachmentError.unavailable }
        return try jpeg(thumbnail)
    }
    private static func video(_ source: URL, mediaType: String?) async throws -> [URL] {
        var options: [String: Any] = [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue]
        if let mediaType { options[AVURLAssetOverrideMIMETypeKey] = mediaType }
        let asset = AVURLAsset(url: source, options: options), duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AttachmentError.unavailable }
        let work = Task.detached {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 512, height: 512)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            var frames: [URL] = []
            do {
                for index in 0..<4 {
                    try Task.checkCancellation()
                    let time = CMTime(seconds: duration * Double(2 * index + 1) / 8, preferredTimescale: 600)
                    frames.append(try jpeg(generator.copyCGImage(at: time, actualTime: nil)))
                }
                return frames
            } catch { frames.forEach { try? FileManager.default.removeItem(at: $0) }; throw error }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private static func audio(_ source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AttachmentError.unavailable }
        let url = temporary("wav"); var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: url) } }
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var eof = false, failure: Error?, frames: Int64 = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, state in
                if eof { state.pointee = .endOfStream; return nil }
                do {
                    // AVAudioFile can throw on a read past EOF instead of returning an empty buffer.
                    let remaining = input.length - input.framePosition
                    if remaining <= 0 { eof = true; state.pointee = .endOfStream; return nil }
                    let count = AVAudioFrameCount(min(Int64(requested), Int64(inputBuffer.frameCapacity), remaining))
                    try input.read(into: inputBuffer, frameCount: count)
                    if inputBuffer.frameLength == 0 { eof = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return inputBuffer
                } catch { failure = error; eof = true; state.pointee = .endOfStream; return nil }
            }
            if let failure { throw failure }; if let conversionError { throw conversionError }
            frames += Int64(outputBuffer.frameLength)
            guard frames * 2 <= ChatAttachmentStore.mediaByteLimit else { throw AttachmentError.tooLarge(ChatAttachmentStore.mediaByteLimit) }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            if status == .endOfStream { break }; if status == .error { throw AttachmentError.unavailable }
        }
        guard frames > 0 else { throw AttachmentError.unavailable }
        committed = true; return url
    }
}
