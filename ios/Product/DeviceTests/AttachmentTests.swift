import XCTest
import UIKit
import SwiftUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeDocumentAttachmentAndImageNormalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-attachment-document-" + UUID().uuidString)
        let suite = "native-attachment-document-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), owned = try ChatAttachmentStore(root: root.appendingPathComponent("Attachments"))
        let attachments = AttachmentController(store: owned)
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var actions: [String] = [], completed = false
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            attachmentEvidence(["purpose":"native-document-and-image-normalization","completed":completed,"actions":actions,
                "limitations":["Direct production APIs and a mounted composer, no system picker/camera gestures or permission prompts.","The image is a synthetic codec/orientation fixture, not an image quality benchmark."]])
        }
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.backend = .llamaCPU
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 32; model.settings.thinking = false
        try await downloads.saveSettings(model)
        let file = root.appendingPathComponent("conversations.json"), store = try ConversationStore(file:file)
        let chat = ChatController(store:store,downloads:downloads,defaults:defaults,attachments:attachments)
        await chat.load(model); XCTAssertNil(chat.error)
        let document = root.appendingPathComponent("Project.txt")
        try Data("The project name is Cedar.".utf8).write(to:document)
        await chat.stageDocument(document); XCTAssertNil(attachments.error); XCTAssertEqual(attachments.document?.info.wasTrimmed,false)
        try FileManager.default.removeItem(at:document)
        chat.draft = "What is the project name? Answer with the name only."
        await chat.send(); try await waitUntil(seconds:60) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertTrue(chat.current?.messages.last?.content.lowercased().contains("cedar") == true)
        let saved = try await store.conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(saved.messages.first?.attachedDocument?.name,"Project.txt")
        XCTAssertTrue(saved.messages.first?.content.contains("The project name is Cedar.") == true)
        let reopened = try ConversationStore(file:file), durable = try await reopened.conversation(saved.id)
        XCTAssertEqual(durable.messages,saved.messages); XCTAssertFalse(attachments.hasStaged)
        actions.append("copied-document-text-survives-original-removal-real-CPU-answer-and-store-reopen")
        let image = root.appendingPathComponent("Rotated.jpg")
        try attachmentImage(image,color:.red,width:1600,height:800,orientation:6)
        await attachments.stage(image,type:.jpeg,support:RuntimeMediaSupport(vision:true))
        XCTAssertNil(attachments.error); let photo = try XCTUnwrap(attachments.staged.first), url = try await owned.resolve(photo)
        let decoder = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoder,0,nil) as? [CFString:Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        XCTAssertGreaterThan(height,width); XCTAssertLessThanOrEqual(width * height,524_288)
        XCTAssertEqual(photo.mediaType,"image/jpeg"); XCTAssertGreaterThan(photo.bytes,0)
        try FileManager.default.removeItem(at:image); _ = try await owned.resolve(photo)
        actions.append("image-orientation-applied-pixel-area-bounded-and-private-JPEG-verified-after-source-removal")
        // Actual loaded text runtime refuses this staged image, preserving the user's work.
        let before = chat.current
        chat.draft = "What color is this?"; await chat.send()
        XCTAssertNotNil(chat.error); XCTAssertEqual(chat.current,before); XCTAssertEqual(attachments.staged,[photo])
        actions.append("text-only-runtime-refuses-staged-image-without-clearing-composer")
        let mountedImage = try await NativeMountedView.capture(AttachmentComposer(chat:chat,attachments:attachments).padding().background(OWTheme.canvas),size:CGSize(width:390,height:260))
        let screenshot = XCTAttachment(image:mountedImage)
        screenshot.name = "Mounted staged attachment composer"; screenshot.lifetime = .keepAlways; add(screenshot)
        await attachments.remove(photo.id); XCTAssertFalse(attachments.hasStaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        actions.append("explicit-staged-removal-deletes-only-owned-file")
        completed = true
    }

    @MainActor func testNativeAudioConversionAndVideoFrameSampling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-attachment-codecs-" + UUID().uuidString)
        let store = try ChatAttachmentStore(root:root.appendingPathComponent("Owned")), attachments = AttachmentController(store:store)
        var observations: [[String:Any]] = [], completed = false
        defer {
            try? FileManager.default.removeItem(at:root)
            attachmentEvidence(["purpose":"native-attachment-audio-and-video-preparation","completed":completed,"observations":observations,
                "limitations":["Synthetic stereo PCM and four-color H.264 fixtures through actual AVFoundation normalization. No audio-capable model inference, arbitrary codecs or system picker gestures verified.","Video becomes four sampled JPEG frames, not native video understanding or audio extraction."]])
        }
        let audio = root.appendingPathComponent("Stereo.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate:44_100,channels:2))
        do {
            let output = try AVAudioFile(forWriting:audio,settings:format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:44_100)); buffer.frameLength = 44_100
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<44_100 { let value = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.25); channels[0][frame] = value; channels[1][frame] = value }
            try output.write(from:buffer)
        }
        await attachments.stage(audio,type:.wav,support:RuntimeMediaSupport(audio:true))
        XCTAssertNil(attachments.error); let sound = try XCTUnwrap(attachments.staged.first), soundURL = try await store.resolve(sound)
        let decoded = try AVAudioFile(forReading:soundURL)
        XCTAssertEqual(decoded.fileFormat.sampleRate,16_000); XCTAssertEqual(decoded.fileFormat.channelCount,1)
        XCTAssertLessThanOrEqual(abs(decoded.length - 16_000),2); XCTAssertEqual(sound.mediaType,"audio/wav")
        observations.append(["kind":"audio","sampleRate":decoded.fileFormat.sampleRate,"channels":decoded.fileFormat.channelCount,"frames":decoded.length,"sha256":sound.sha256])
        await attachments.remove(sound.id)
        let video = root.appendingPathComponent("Four colors.mp4")
        try await attachmentVideo(video)
        let sourceDuration = try await AVURLAsset(url:video).load(.duration).seconds
        XCTAssertEqual(sourceDuration,4,accuracy:0.05)
        observations.append(["kind":"source-video","durationSeconds":sourceDuration])
        await attachments.stage(video,type:.mpeg4Movie,support:RuntimeMediaSupport(vision:true))
        XCTAssertNil(attachments.error); XCTAssertEqual(attachments.staged.count,4)
        let expected: [[Int]] = [[255,0,0],[0,255,0],[0,0,255],[255,255,0]]
        for (index, item) in attachments.staged.enumerated() {
            let url = try await store.resolve(item), pixel = try attachmentCenterPixel(url)
            for channel in 0..<3 { XCTAssertLessThanOrEqual(abs(pixel[channel] - expected[index][channel]),35) }
            XCTAssertTrue(item.name.contains("frame \(index + 1)")); XCTAssertEqual(item.kind,.image)
            observations.append(["kind":"video-frame","index":index,"centerRGB":pixel,"sha256":item.sha256])
        }
        try FileManager.default.removeItem(at:video)
        for item in attachments.staged { _ = try await store.resolve(item) }
        await attachments.clear(); XCTAssertTrue(attachments.staged.isEmpty)
        completed = true
    }

    @MainActor func testNativePairedVisionAttachmentHistoryBranchAndCancellation() async throws {
        try await attachmentVisionFlow(latestQuestion: "What is the main color in this new image? Answer briefly.", purpose: "native-paired-vision-attachment-history")
    }
    @MainActor func testNativePairedVisionExplicitReferenceHistoryBranchAndCancellation() async throws {
        try await attachmentVisionFlow(latestQuestion: "Describe only the image attached to this latest message. What color is it?", purpose: "native-paired-vision-explicit-reference-history")
    }
    @MainActor private func attachmentVisionFlow(latestQuestion: String, purpose: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-vision-attachments-" + UUID().uuidString)
        let suite = "native-vision-attachments-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String:Any]] = [], completed = false
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            attachmentEvidence(["purpose":purpose,"completed":completed,"observations":observations,
                "limitations":["Pinned SmolVLM-500M Q8_0 base/projector and synthetic red/blue images. This is exercised media delivery and durability, not general vision quality or runtime performance.",
                    "Direct product APIs, no system picker/camera/QuickLook gestures, external providers or app-process termination.",
                    "Text-only prompt count is a lower bound while media exists. The native engine performs actual embedding admission. Media folding stays unavailable until a media-aware summary path is implemented."]])
        }
        let (downloads,model) = try await attachmentVisionModel()
        defer { downloads.cancelAllTransfers() }
        let owned = try ChatAttachmentStore(root:root.appendingPathComponent("Owned")), attachments = AttachmentController(store:owned)
        let file = root.appendingPathComponent("conversations.json"), store = try ConversationStore(file:file)
        let chat = ChatController(store:store,downloads:downloads,defaults:defaults,attachments:attachments)
        await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.mediaSupport.vision); XCTAssertFalse(chat.mediaSupport.audio)
        XCTAssertFalse(chat.mediaSupport.marker.isEmpty)
        observations.append(["stage":"paired-model-loaded","repository":model.repository ?? "","revision":model.revision ?? "",
            "files":model.files.map { ["path":$0.path,"bytes":$0.bytes ?? 0,"sha256":$0.sha256 ?? ""] },"vision":chat.mediaSupport.vision,"audio":chat.mediaSupport.audio])
        let redSource = root.appendingPathComponent("Red.jpg"); try attachmentImage(redSource,color:.red)
        await chat.stageAttachment(redSource,type:.jpeg); XCTAssertNil(attachments.error)
        let red = try XCTUnwrap(attachments.staged.first); try FileManager.default.removeItem(at:redSource)
        chat.draft = "What is the main color in this image? Answer briefly."
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error)
        let first = try XCTUnwrap(chat.current), firstReply = try XCTUnwrap(first.messages.last)
        XCTAssertEqual(firstReply.status,.complete); XCTAssertTrue(firstReply.content.lowercased().contains("red"),firstReply.content)
        XCTAssertEqual(first.messages.first?.attachments,[red]); XCTAssertFalse(attachments.hasStaged)
        observations.append(["stage":"first-red-image","reply":firstReply.content,"attachmentSHA256":red.sha256,"contextUsed":chat.contextUsed])
        let blueSource = root.appendingPathComponent("Blue.jpg"); try attachmentImage(blueSource,color:.blue)
        await chat.stageAttachment(blueSource,type:.jpeg); XCTAssertNil(attachments.error)
        let blue = try XCTUnwrap(attachments.staged.first); try FileManager.default.removeItem(at:blueSource)
        chat.draft = latestQuestion
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertTrue(chat.current?.messages.last?.content.lowercased().contains("blue") == true,chat.current?.messages.last?.content ?? "")
        let original = try XCTUnwrap(chat.current)
        XCTAssertEqual(original.messages[0].attachments,[red]); XCTAssertEqual(original.messages[2].attachments,[blue])
        observations.append(["stage":"second-blue-image-with-red-history","reply":original.messages.last?.content ?? "","attachmentSHA256":blue.sha256,"contextUsed":chat.contextUsed])
        let reopened = try ConversationStore(file:file), durable = try await reopened.conversation(original.id)
        XCTAssertEqual(durable.messages,original.messages)
        await chat.branch(through:firstReply.id); XCTAssertNil(chat.error)
        let branch = try XCTUnwrap(chat.current); XCTAssertNotEqual(branch.id,original.id); XCTAssertEqual(branch.messages.count,2)
        XCTAssertEqual(branch.messages.first?.attachments,[red]); XCTAssertTrue(chat.contextIsExact); XCTAssertFalse(chat.contextIncludesUncountedMedia)
        await chat.delete(original)
        _ = try await owned.resolve(red); XCTAssertFalse(FileManager.default.fileExists(atPath:owned.displayURL(blue).path))
        chat.draft = "What is the main color of the image in this chat? Answer briefly."
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertTrue(chat.current?.messages.last?.content.lowercased().contains("red") == true,chat.current?.messages.last?.content ?? "")
        observations.append(["stage":"branch-reopen-and-original-delete","reply":chat.current?.messages.last?.content ?? "","retainedRed":true,"unreferencedBlueRemoved":true])
        var stopIssued = false
        let stop = chat.$current.sink { value in
            guard !stopIssued,chat.busy,let last=value?.messages.last,last.role == .assistant,last.status == .streaming,!last.content.isEmpty else { return }
            stopIssued = true; chat.cancel()
        }
        chat.draft = "Write a detailed long description of the image and its color."
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }; stop.cancel()
        XCTAssertTrue(stopIssued); XCTAssertEqual(chat.current?.messages.last?.status,.cancelled)
        _ = try await owned.resolve(red)
        chat.draft = "Name the main color only."
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
        XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.messages.last?.status,.complete)
        XCTAssertTrue(chat.current?.messages.last?.content.lowercased().contains("red") == true,chat.current?.messages.last?.content ?? "")
        observations.append(["stage":"cancel-real-stream-and-recover-with-media-history","reply":chat.current?.messages.last?.content ?? "","stopIssuedWhileStreaming":stopIssued])
        await chat.delete(try XCTUnwrap(chat.current)); XCTAssertNil(chat.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.displayURL(red).path))
        let final = try ConversationStore(file:file), all = await final.all(); XCTAssertTrue(all.isEmpty)
        observations.append(["stage":"delete-last-reference","remainingConversations":all.count,"redRemoved":true])
        completed = true
    }

    @MainActor func testNativeVisionColorDeliveryDiagnosis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-vision-diagnosis-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var observations: [[String:Any]] = []
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            try? FileManager.default.removeItem(at: root)
            attachmentEvidence(["purpose":"native-vision-color-delivery-diagnosis", "observations":observations,
                "limitations":["Diagnostic controls preserve actual model answers without scoring them as a passing multi-turn feature."]])
        }
        let (downloads,model) = try await attachmentVisionModel(); defer { downloads.cancelAllTransfers() }
        let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:downloads.directory(model))
        let red = root.appendingPathComponent("red.jpg"), blue = root.appendingPathComponent("blue.jpg")
        try attachmentImage(red,color:.red); try attachmentImage(blue,color:.blue)
        let redRGB = try attachmentCenterPixel(red), blueRGB = try attachmentCenterPixel(blue)
        XCTAssertGreaterThan(redRGB[0],220); XCTAssertLessThan(redRGB[2],35)
        XCTAssertGreaterThan(blueRGB[2],220); XCTAssertLessThan(blueRGB[0],35)
        let system = ["role":"system","content":model.settings.systemInstructions(base:ChatController.systemPrompt,toolsAvailable:false)]
        let question = ["role":"user","content":"What is the main color in this image? Answer briefly."]
        let newQuestion = ["role":"user","content":"What is the main color in this new image? Answer briefly."]
        func reply(_ name:String,_ prompt:RuntimePrompt,reset:Bool) async throws -> RuntimeReply {
            if reset { await runtime.reset() }
            var final: RuntimeReply?
            for try await event in runtime.stream(prompt:prompt,settings:model.settings,tools:[]) { if case .reply(let value)=event { final=value } }
            let value = try XCTUnwrap(final)
            observations.append(["stage":name,"reply":value.content,"cachedTokens":value.cachedTokens,"contextUsed":value.contextUsed,"reset":reset,"redRGB":redRGB,"blueRGB":blueRGB])
            return value
        }
        let singleBlue = RuntimePrompt(messages:[system,question],mediaPaths:[[],[blue.path]])
        _ = try await reply("fresh-blue",singleBlue,reset:true)
        let first = try await reply("fresh-red",RuntimePrompt(messages:[system,question],mediaPaths:[[],[red.path]]),reset:true)
        let history = RuntimePrompt(messages:[system,question,["role":"assistant","content":first.promptContent ?? first.content],newQuestion],mediaPaths:[[],[red.path],[],[blue.path]])
        _ = try await reply("retained-red-then-blue",history,reset:false)
        _ = try await reply("reset-full-red-then-blue",history,reset:true)
        let precise = RuntimePrompt(messages:[system,question,["role":"assistant","content":first.promptContent ?? first.content],["role":"user","content":"Describe only the image attached to this latest message. What color is it?"]],mediaPaths:[[],[red.path],[],[blue.path]])
        _ = try await reply("reset-full-latest-image-reference",precise,reset:true)
        _ = try await reply("fresh-blue-after-history",singleBlue,reset:true)
    }

    @MainActor private func attachmentVisionModel() async throws -> (ModelDownloads,LocalModel) {
        struct Manifest: Decodable { var repository: String; var revision: String; var files: [ModelFile] }
        let url = try XCTUnwrap(Bundle.main.url(forResource:"vision-validation-artifact",withExtension:"json"))
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:url))
        let details = try await HubClient.details(manifest.repository,revision:manifest.revision,transport:HubAPITransport(useStoredCredential:false))
        let base = try XCTUnwrap(details.siblings.first { !$0.rfilename.hasPrefix("mmproj") && $0.rfilename.hasSuffix("Q8_0.gguf") })
        let projector = try XCTUnwrap(details.siblings.first { $0.rfilename.hasPrefix("mmproj") && $0.rfilename.hasSuffix("Q8_0.gguf") })
        var model = try HubClient.gguf(details,file:base,projector:projector)
        XCTAssertEqual(model.files,manifest.files)
        model.id = try XCTUnwrap(UUID(uuidString:"737DA024-740F-469D-93D2-7D33778756D8"))
        model.settings.contextTokens = 4096; model.settings.outputTokens = 32; model.settings.temperature = 0
        model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.thinking = false
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VisionValidation")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:root.appendingPathComponent("models.json")),sessionIdentifier:"org.experimentalmachines.openweights.vision-validation")
        await downloads.restore()
        if let existing = downloads.models.first(where: { $0.id == model.id }) {
            if existing.state != .ready { await downloads.resume(existing) }
        } else { await downloads.install(model) }
        try await waitUntil(seconds:480) { downloads.models.first(where: { $0.id == model.id })?.state == .ready || downloads.error != nil || downloads.models.first(where: { $0.id == model.id })?.state == .failed }
        XCTAssertNil(downloads.error)
        let ready = try XCTUnwrap(downloads.models.first { $0.id == model.id }); XCTAssertEqual(ready.state,.ready,ready.failure ?? "")
        for file in model.files { try ModelDownloads.verify(file.destination(in:downloads.directory(ready)),file:file) }
        model.state = .ready; try await downloads.saveSettings(model)
        return (downloads,model)
    }

    private func attachmentEvidence(_ value: [String:Any]) {
        let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = value["purpose"] as? String ?? "Attachments"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func attachmentImage(_ url: URL, color: UIColor, width: Int = 640, height: Int = 480, orientation: Int = 1) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:width,height:height),format:format).image { context in
            color.setFill(); context.fill(CGRect(x:0,y:0,width:width,height:height))
        }
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(encoder,try XCTUnwrap(image.cgImage),[kCGImagePropertyOrientation:orientation,kCGImageDestinationLossyCompressionQuality:1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
    }
    private func attachmentCenterPixel(_ url: URL) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil)), image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        var pixel = [UInt8](repeating:0,count:4)
        let space = try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none; context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))
        }
        return pixel.prefix(3).map(Int.init)
    }
    private func attachmentVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:240,
            AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:240])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime:.zero)
        let colors: [[CGFloat]] = [[1,0,0,1],[0,1,0,1],[0,0,1,1],[1,1,0,1]]
        for frame in 0..<120 {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AttachmentError.unavailable }
                try await Task.sleep(nanoseconds:1_000_000)
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,320,240,kCVPixelFormatType_32BGRA,nil,&pixel),kCVReturnSuccess)
            let value = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(value,[])
            let context = try XCTUnwrap(CGContext(data:CVPixelBufferGetBaseAddress(value),width:320,height:240,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(value),space:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            let components = colors[frame / 30]
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace:try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),components:components))); context.fill(CGRect(x:0,y:0,width:320,height:240))
            if frame % 30 == 0 {
                let bytes = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to:UInt8.self)
                XCTAssertEqual(Int(bytes[2]),Int(components[0] * 255))
                XCTAssertEqual(Int(bytes[1]),Int(components[1] * 255))
                XCTAssertEqual(Int(bytes[0]),Int(components[2] * 255))
            }
            CVPixelBufferUnlockBaseAddress(value,[])
            XCTAssertTrue(adaptor.append(value,withPresentationTime:CMTime(value:Int64(frame),timescale:30)))
        }
        writer.endSession(atSourceTime:CMTime(seconds:4,preferredTimescale:30)); input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status,.completed,writer.error?.localizedDescription ?? "")
    }
}
