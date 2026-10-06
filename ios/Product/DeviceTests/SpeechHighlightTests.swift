import XCTest
import UIKit
import SwiftUI
import AVFoundation
import OpenWeightsCore
@testable import OpenWeights

@MainActor private final class SpeechSceneFixture: ObservableObject { @Published var phase = ScenePhase.active }
private struct SpeechSceneView: View {
    @ObservedObject var fixture: SpeechSceneFixture
    let chat: ChatController
    let downloads: ModelDownloads
    let speech: SpeechReader
    var body: some View { ChatScreen(chat: chat, downloads: downloads, speech: speech).environment(\.scenePhase, fixture.phase) }
}

extension ProductTests {
    @MainActor func testNativeCodeHighlightingPreservesSourceContrastAndNoExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-highlight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories:true)
        let workspace = try Workspace(root:root)
        try await workspace.write("site/receiver.html",content:"Owned receiver")
        let receiver = try CanvasLocalServer(canvas:CanvasDescriptor(kind:.site,entry:"site/receiver.html"),workspace:workspace)
        let url = try await receiver.start()
        defer { receiver.stop();try? FileManager.default.removeItem(at:root) }
        _ = try await URLSession.shared.data(from:url);let positive=receiver.acceptedConnectionCount;XCTAssertGreaterThan(positive,0)
        let fixtures=[("swift","let cedar = \"🧠 Cedar\"\nprint(cedar) // local\n"), ("py","def cedar():\n    return \"Pine\"\n"), ("kt","val cedar: Int = 42\n"), ("js","globalThis.owExecuted = true; fetch('\(url.absoluteString)');\n"), ("html","<img src=\"\(url.absoluteString)\"><script>alert('inert')</script>\n"), ("json","{\"project\":\"Cedar\",\"value\":42}\n")]
        var measurements:[[String:Any]]=[]
        for dark in [true,false] {
            for (language,source) in fixtures {
                let value=try await CodeHighlighter.shared.highlight(source,language:language,dark:dark)
                XCTAssertEqual(value.source,source);XCTAssertEqual(String(value.attributed.characters),source);XCTAssertTrue(value.highlighted,language)
                let colors=Set(value.runs.map { String(format:"%.4f %.4f %.4f",$0.red,$0.green,$0.blue) });XCTAssertGreaterThan(colors.count,1,language)
                let contrasts=value.runs.map { CodeHighlighter.contrast([$0.red,$0.green,$0.blue],dark:dark) };XCTAssertTrue(contrasts.allSatisfy { $0 >= 4.5 })
                measurements.append(["language":language,"dark":dark,"runs":value.runs.count,"distinctColors":colors.count,"minimumContrast":contrasts.min() ?? 0])
            }
        }
        for language in ["unknown-openweights-language","text"] {
            let source="<script>fetch('\(url.absoluteString)')</script> 🧠 **literal**"
            let value=try await CodeHighlighter.shared.highlight(source,language:language,dark:true)
            XCTAssertFalse(value.highlighted);XCTAssertEqual(String(value.attributed.characters),source)
        }
        let large=String(repeating:"let cedar = 42\n",count:10000)
        let plain=try await CodeHighlighter.shared.highlight(large,language:"swift",dark:true)
        XCTAssertFalse(plain.highlighted);XCTAssertEqual(plain.source,large)
        XCTAssertEqual(receiver.acceptedConnectionCount,positive)
        let source=fixtures[0].1 + "let longLine = \"This code stays available across the horizontal scroll range.\"\n"
        for dark in [true,false] {
            let image=try await NativeMountedView.capture(TranscriptCodeView(language:"swift",text:source,index:0).padding(16).background(OWTheme.canvas).foregroundStyle(OWTheme.text),size:CGSize(width:390,height:350),style:dark ? .dark : .light)
            let capture=XCTAttachment(image:image);capture.name="Highlighted code, " + (dark ? "dark" : "light");capture.lifetime = .keepAlways;add(capture)
        }
        speechHighlightEvidence(["purpose":"native-code-highlighting-source-colors-contrast-no-execution","completed":true,"measurements":measurements,"positiveReceiverConnections":positive,"connectionsAfterHighlighting":receiver.acceptedConnectionCount,"limitations":["Six declared language fixtures and two themes, not every grammar. Unknown and over-128-KiB code keeps its exact plain text.","The owned receiver tests no code/image contact; no claim about arbitrary JavaScript engines or acoustic speech."]])
    }

    @MainActor func testNativeSpeechReadStopRecoveryAndStaleCallback() async throws {
        let synth=AVSpeechSynthesizer(),reader=SpeechReader(synthesizer:synth)
        defer { reader.stop() }
        XCTAssertFalse(synth.usesApplicationAudioSession)
        let id=UUID(),text="# Cedar\n\n**Project Cedar** is ready. [Guide](https://example.com/private).\n\n```swift\nlet secret = 42\n```"
        reader.toggle(messageID:id,text:text)
        try await waitUntil(seconds:20) { synth.isSpeaking || reader.error != nil }
        XCTAssertNil(reader.error);XCTAssertTrue(reader.isReading);XCTAssertEqual(reader.messageID,id)
        reader.toggle(messageID:id,text:text);XCTAssertFalse(reader.isReading)
        try await waitUntil(seconds:10) { !synth.isSpeaking }
        let recovered=UUID()
        reader.toggle(messageID:recovered,text:String(repeating:"Cedar is ready. ",count:20))
        try await waitUntil(seconds:20) { synth.isSpeaking || reader.error != nil };XCTAssertNil(reader.error);XCTAssertTrue(reader.isReading)
        reader.speechSynthesizer(synth,didCancel:AVSpeechUtterance(string:"unrelated old utterance"))
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertTrue(reader.isReading);XCTAssertEqual(reader.messageID,recovered)
        reader.prepareForInactivity();XCTAssertFalse(reader.isReading);try await waitUntil(seconds:10) { !synth.isSpeaking }
        reader.toggle(messageID:UUID(),text:"Cedar.")
        try await waitUntil(seconds:20) { synth.isSpeaking || reader.error != nil };XCTAssertNil(reader.error)
        try await waitUntil(seconds:20) { !reader.isReading };XCTAssertFalse(synth.isSpeaking)
        speechHighlightEvidence(["purpose":"native-system-speech-start-stop-recovery-completion-and-stale-callback","completed":true,"speechText":TranscriptMarkdown(text).speechText,"currentVoiceLanguage":AVSpeechSynthesisVoice.currentLanguageCode(),"usesApplicationAudioSession":synth.usesApplicationAudioSession,"limitations":["Actual AVSpeechSynthesizer playback state and delegate completion, not a human listening/voice-quality or offline-airplane-mode test.","The stale unrelated cancellation callback is directly injected while real speech runs. Inactivity uses the production callback, not actual OS suspension."]])
    }

    @MainActor func testNativeSpeechMissingVoiceRetryAndChatLifecycle() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-speech-chat-" + UUID().uuidString)
        let defaults=try XCTUnwrap(UserDefaults(suiteName:root.lastPathComponent))
        let library=try ModelLibrary(file:root.appendingPathComponent("models.json")),downloads=ModelDownloads(root:root.appendingPathComponent("Models"),library:library)
        let store=try ConversationStore(file:root.appendingPathComponent("chats.json"))
        var conversation=try await store.create(title:"Cedar speech")
        let message=StoredMessage(role:.assistant,content:"Project Cedar is ready.");conversation.messages=[message];try await store.save(conversation)
        let chat=ChatController(store:store,downloads:downloads,defaults:defaults);await chat.open(conversation)
        let synth=AVSpeechSynthesizer();var available=false
        let reader=SpeechReader(synthesizer:synth,voiceProvider:{ available ? AVSpeechSynthesisVoice(language:AVSpeechSynthesisVoice.currentLanguageCode()) : nil })
        defer { reader.stop();defaults.removePersistentDomain(forName:root.lastPathComponent);try? FileManager.default.removeItem(at:root) }
        reader.toggle(messageID:message.id,text:message.content);try await waitUntil(seconds:5) { !reader.isPreparing }
        XCTAssertFalse(reader.isReading);XCTAssertNotNil(reader.error)
        let image=try await NativeMountedView.capture(MessageRow(message:message,speechReader:reader).padding(16).background(OWTheme.canvas).foregroundStyle(OWTheme.text),size:CGSize(width:390,height:350))
        let capture=XCTAttachment(image:image);capture.name="Speech error retains reply and retry control";capture.lifetime = .keepAlways;add(capture)
        available=true;reader.toggle(messageID:message.id,text:message.content)
        try await waitUntil(seconds:20) { synth.isSpeaking || reader.error != nil };XCTAssertNil(reader.error);XCTAssertTrue(reader.isReading)
        reader.stop();try await waitUntil(seconds:10) { !synth.isSpeaking }
        let fixture=SpeechSceneFixture()
        _ = try await NativeMountedView.capture(SpeechSceneView(fixture:fixture,chat:chat,downloads:downloads,speech:reader).background(OWTheme.canvas).foregroundStyle(OWTheme.text),size:CGSize(width:390,height:800),exercise:{ _ in
            reader.toggle(messageID:message.id,text:String(repeating:"Cedar is ready. ",count:20))
            try await self.waitUntil(seconds:20) { synth.isSpeaking || reader.error != nil };XCTAssertNil(reader.error);XCTAssertTrue(reader.isReading)
            fixture.phase = .background
            try await self.waitUntil(seconds:5) { !reader.isReading };XCTAssertFalse(synth.isSpeaking)
        })
        speechHighlightEvidence(["purpose":"native-speech-missing-voice-retry-and-mounted-chat-background-routing","completed":true,"limitations":["Missing voice is a controlled provider return; retry uses the actual system voice and synthesizer.","Actual ChatScreen receives a controlled scenePhase change while XCTest remains foreground. Touch, OS interruption/background/suspension and acoustic quality remain open."]])
    }
    private func speechHighlightEvidence(_ value:[String:Any]) {
        let attachment=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name=value["purpose"] as? String ?? "Speech/highlight";attachment.lifetime = .keepAlways;add(attachment)
    }
}
