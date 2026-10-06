import Foundation

public enum SpeechText {
    // Queue bounded utterances rather than dropping the tail of a long reply.
    public static func fragments(_ text: String, maximumUTF16: Int = 4000) -> [String] {
        precondition(maximumUTF16 >= 2)
        var result: [String] = [], buffer = "", units = 0
        for scalar in text.unicodeScalars {
            let count = scalar.value > 0xFFFF ? 2 : 1
            if units + count > maximumUTF16 { result.append(buffer); buffer = ""; units = 0 }
            buffer.unicodeScalars.append(scalar); units += count
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}
