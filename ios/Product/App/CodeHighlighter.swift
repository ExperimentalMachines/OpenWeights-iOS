import Foundation
import UIKit
import Highlighter

struct CodeColorRun: Sendable {
    var location: Int
    var length: Int
    var red: Double
    var green: Double
    var blue: Double
}
struct HighlightedCode: Sendable {
    var source: String
    var runs: [CodeColorRun]
    var highlighted: Bool
    var attributed: AttributedString {
        let value = NSMutableAttributedString(string: source)
        for run in runs {
            value.addAttribute(.foregroundColor, value: UIColor(red: run.red, green: run.green, blue: run.blue, alpha: 1),
                               range: NSRange(location: run.location, length: run.length))
        }
        return (try? AttributedString(value, including: \.uiKit)) ?? AttributedString(source)
    }
}

actor CodeHighlighter {
    static let shared = CodeHighlighter()
    private var engine: Highlighter?
    private var languages: Set<String> = []
    func highlight(_ text: String, language: String?, dark: Bool) throws -> HighlightedCode {
        try Task.checkCancellation()
        let fallback = HighlightedCode(source: text, runs: [], highlighted: false)
        guard text.utf16.count <= 128 * 1024, let tag = language?.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              !["text", "plaintext", "plain", "txt"].contains(tag) else { return fallback }
        if engine == nil { engine = Highlighter(); languages = Set(engine?.supportedLanguages() ?? []) }
        let aliases = ["js":"javascript", "ts":"typescript", "py":"python", "kt":"kotlin", "sh":"bash", "c++":"cpp", "c#":"csharp", "html":"xml", "yml":"yaml"]
        let language = aliases[tag] ?? tag
        guard let engine, languages.contains(language), engine.setTheme(dark ? "a11y-dark" : "a11y-light") else { return fallback }
        engine.ignoreIllegals = true
        // Only bundled grammar executes. The source is a JSValue argument, never a script.
        // The fast span parser avoids the system HTML renderer and its resource loading.
        guard let result = engine.highlight(text, as: language, doFastRender: true), result.string == text else { return fallback }
        try Task.checkCancellation()
        var runs: [CodeColorRun] = []
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let color = value as? UIColor else { return }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            let rgb = Self.readable([Double(red), Double(green), Double(blue)], dark: dark)
            runs.append(CodeColorRun(location: range.location, length: range.length, red: rgb[0], green: rgb[1], blue: rgb[2]))
        }
        return HighlightedCode(source: text, runs: runs, highlighted: !runs.isEmpty)
    }
    static func contrast(_ foreground: [Double], dark: Bool) -> Double {
        let background = dark ? [22.0/255, 23.0/255, 25.0/255] : [244.0/255, 245.0/255, 243.0/255]
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private static func readable(_ color: [Double], dark: Bool) -> [Double] {
        guard contrast(color, dark: dark) < 4.5 else { return color }
        let target = dark ? [245.0/255, 246.0/255, 243.0/255] : [5.0/255, 43.0/255, 66.0/255]
        for step in 1...20 {
            let mix = Double(step) / 20
            let next = zip(color, target).map { $0 + ($1 - $0) * mix }
            if contrast(next, dark: dark) >= 4.5 { return next }
        }
        return target
    }
}
