import SwiftUI
import OpenWeightsCore

struct ThroughputEstimateView: View {
    let estimates: ThroughputEstimates
    let weightBytes: Int64?
    let backend: ModelBackend
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Estimated prompt processing", value: speed(estimates.prefill))
            if let source = estimates.prefill { sourceLabel(source, phase: "Prompt") }
            LabeledContent("Estimated decoding", value: speed(estimates.decode))
            if let source = estimates.decode { sourceLabel(source, phase: "Decode") }
            if estimates.prefill == nil && estimates.decode == nil {
                Text("Run a model with known weight hashes on this backend to obtain a local measurement. Earlier usage without weight metadata cannot calibrate this estimate.")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            }
            Text("Rough estimates scale a measured rate by weight-file size on the same backend. Architecture, quantization, context, cache reuse and temperature can change the result. Short measurements are especially noisy. This is not a controlled benchmark or a memory-fit guarantee.")
                .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
        }
    }
    private func speed(_ source: ThroughputCalibration?) -> String {
        guard let weightBytes, let rate = source?.predict(weightBytes: weightBytes, backend: backend) else { return "Unavailable" }
        return "About " + rate.formatted(.number.precision(.fractionLength(1))) + " tokens/s"
    }
    private func sourceLabel(_ source: ThroughputCalibration, phase: String) -> some View {
        Text("\(phase) source: \"\(source.modelName)\". Measured with \(source.backend.label): \(source.measuredTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tokens/s from \(source.tokens.formatted()) tokens in \(source.milliseconds.formatted(.number.precision(.fractionLength(1)))) ms. Weight files: \(ByteCountFormatter.string(fromByteCount: source.weights.bytes, countStyle: .file)).")
            .font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
    }
}
