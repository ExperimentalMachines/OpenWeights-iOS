import Foundation

public enum HubShortlist {
    // Keep the Android-curated list separate from iPhone runtime/default decisions.
    public static let recommended = [
        "LiquidAI/LFM2.5-1.2B-Instruct-GGUF",
        "LiquidAI/LFM2.5-2.6B-GGUF",
        "LiquidAI/LFM2.5-VL-1.6B-GGUF",
        "unsloth/Qwen3-1.7B-GGUF"
    ]
    public static let experimental = [
        "experimentalmachines/LFM2.5-1.2B-Instruct-heretic",
        "experimentalmachines/LFM2.5-2.6B-heretic"
    ]
    public static let androidMeasuredFiles = [
        "LiquidAI/LFM2.5-1.2B-Instruct-GGUF": "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
        "unsloth/Qwen3-1.7B-GGUF": "Qwen3-1.7B-Q8_0.gguf"
    ]
}
