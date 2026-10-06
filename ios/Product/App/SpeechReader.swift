import AVFoundation
import Combine
import Foundation
import SwiftUI
import OpenWeightsCore

@MainActor final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPreparing = false
    @Published private(set) var error: String?
    @Published private(set) var messageID: UUID?
    var isReading: Bool { isPreparing || isSpeaking }
    private let synthesizer: AVSpeechSynthesizer
    private let voiceProvider: () -> AVSpeechSynthesisVoice?
    private var preparation: Task<Void, Never>?
    private var startTimeout: Task<Void, Never>?
    private var epoch = UUID()
    private var utterances: Set<ObjectIdentifier> = []
    private var started = false

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
         voiceProvider: @escaping () -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) }) {
        self.synthesizer = synthesizer; self.voiceProvider = voiceProvider
        super.init()
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }
    func toggle(messageID: UUID, text: String) {
        if isReading { stop(); return }
        stop(); error = nil; self.messageID = messageID; isPreparing = true
        let ticket = epoch
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let parsed = try await TranscriptMarkdownParser.shared.parse(text)
                try Task.checkCancellation()
                guard self.epoch == ticket else { return }
                self.isPreparing = false; self.preparation = nil
                guard !parsed.speechText.isEmpty else { return }
                guard let voice = self.voiceProvider() else { self.error = "No speech voice is available. Check the speech settings under Accessibility in Settings, then try again."; return }
                let queue = SpeechText.fragments(parsed.speechText).map { text -> AVSpeechUtterance in
                    let value = AVSpeechUtterance(string: text); value.voice = voice; return value
                }
                self.utterances = Set(queue.map(ObjectIdentifier.init)); self.isSpeaking = true; self.started = false
                for value in queue { self.synthesizer.speak(value) }
                self.startTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    guard !Task.isCancelled, let self, self.epoch == ticket, !self.started else { return }
                    self.stop(); self.error = "Speech did not start. Try reading the reply again."
                }
            } catch is CancellationError {} catch {
                guard self.epoch == ticket else { return }
                self.isPreparing = false; self.preparation = nil; self.error = error.localizedDescription
            }
        }
    }
    func stop() {
        epoch = UUID(); preparation?.cancel(); preparation = nil; startTimeout?.cancel(); startTimeout = nil
        utterances.removeAll(); synthesizer.stopSpeaking(at: .immediate); isPreparing = false; isSpeaking = false
    }
    func prepareForInactivity() { stop() }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterances.contains(ObjectIdentifier(utterance)) else { return }
            self.started = true; self.startTimeout?.cancel(); self.startTimeout = nil
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finish(utterance) }
    }
    private func finish(_ utterance: AVSpeechUtterance) {
        guard utterances.remove(ObjectIdentifier(utterance)) != nil else { return }
        if utterances.isEmpty { isSpeaking = false; startTimeout?.cancel(); startTimeout = nil }
    }
}

struct ReadReplyButton: View {
    let messageID: UUID
    let text: String
    @ObservedObject var reader: SpeechReader
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { reader.toggle(messageID: messageID, text: text) } label: {
                Label(reader.isReading ? "Stop reading" : "Read aloud", systemImage: reader.isReading ? "stop.fill" : "speaker.wave.2")
                    .font(OWTheme.interface(13)).frame(minHeight: 44)
            }.buttonStyle(.bordered).accessibilityIdentifier("transcript.readAloud.\(messageID)")
            if reader.messageID == messageID, let error = reader.error { Text(error).font(OWTheme.interface(13)).foregroundStyle(OWTheme.danger) }
        }
    }
}
