import Foundation
import Markdown

public struct TranscriptSpan: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strike = false
    public var link: URL? = nil
    public var speechOverride: String? = nil
}
public struct TranscriptListItem: Equatable, Sendable {
    public var checked: Bool?
    public var blocks: [TranscriptBlock]
}
public struct TranscriptTable: Equatable, Sendable {
    public enum Alignment: Sendable { case left, center, right }
    public var header: [[TranscriptSpan]]
    public var rows: [[[TranscriptSpan]]]
    public var alignments: [Alignment]
}
public indirect enum TranscriptBlock: Equatable, Sendable {
    case paragraph([TranscriptSpan])
    case heading(Int, [TranscriptSpan])
    case quote([TranscriptBlock])
    case list(start: UInt?, items: [TranscriptListItem])
    case code(language: String?, text: String)
    case table(TranscriptTable)
    case divider
    case literal(String)
}

public struct TranscriptMarkdown: Equatable, Sendable {
    public let source: String
    public let blocks: [TranscriptBlock]
    public init(_ source: String) {
        self.source = source
        blocks = Self.blocks(Document(parsing: source), depth: 0)
    }
    public var plainText: String { Self.plain(blocks).trimmingCharacters(in: .whitespacesAndNewlines) }
    public var speechText: String { Self.spoken(blocks).trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func browsableURL(_ destination: String?) -> URL? {
        guard let destination, let url = URL(string: destination),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func blocks(_ node: any Markup, depth: Int) -> [TranscriptBlock] {
        // Deep generated markup remains visible without unbounded view recursion.
        guard depth < 32 else { return [.literal(node.format())] }
        switch node {
        case let value as Paragraph: return [.paragraph(spans(value))]
        case let value as Heading: return [.heading(value.level, spans(value))]
        case let value as CodeBlock: return [.code(language: value.language, text: value.code)]
        case let value as BlockQuote: return [.quote(value.children.flatMap { blocks($0, depth: depth + 1) })]
        case let value as UnorderedList:
            return [.list(start: nil, items: value.listItems.map { item($0, depth: depth) })]
        case let value as OrderedList:
            return [.list(start: value.startIndex, items: value.listItems.map { item($0, depth: depth) })]
        case let value as Table:
            let header = Array(value.head.cells.map { spans($0) })
            let rows = Array(value.body.rows.map { Array($0.cells.map { spans($0) }) })
            let alignments: [TranscriptTable.Alignment] = value.columnAlignments.map {
                switch $0 { case .center: return .center; case .right: return .right; default: return .left }
            }
            return [.table(TranscriptTable(header: header, rows: rows, alignments: alignments))]
        case is ThematicBreak: return [.divider]
        case let value as HTMLBlock: return [.literal(value.rawHTML)]
        default: return node.children.flatMap { blocks($0, depth: depth + 1) }
        }
    }
    private static func item(_ value: ListItem, depth: Int) -> TranscriptListItem {
        TranscriptListItem(checked: value.checkbox.map { $0 == .checked }, blocks: value.children.flatMap { blocks($0, depth: depth + 1) })
    }
    private static func spans(_ node: any Markup, style: TranscriptSpan = TranscriptSpan(text: ""), depth: Int = 0) -> [TranscriptSpan] {
        guard depth < 64 else { return [TranscriptSpan(text: node.format())] }
        var style = style
        switch node {
        case let value as Markdown.Text: style.text = value.string; return [style]
        case let value as InlineCode: style.text = value.code; style.code = true; return [style]
        case is Strong: style.bold = true
        case is Emphasis: style.italic = true
        case is Strikethrough: style.strike = true
        case let value as Link:
            style.link = browsableURL(value.destination)
            let children = value.children.flatMap { spans($0, style: style, depth: depth + 1) }
            // Keep refused addresses visible without turning them into actions.
            if style.link == nil, let address = value.destination, !address.isEmpty {
                return children + [TranscriptSpan(text: " (" + address + ")", speechOverride: "")]
            }
            return children
        case let value as Markdown.Image:
            style.link = browsableURL(value.source)
            let label = value.plainText.isEmpty ? (value.source ?? "Image") : value.plainText
            style.text = label
            style.speechOverride = label
            // A model-authored image is a link. Rendering must never fetch it.
            if style.link == nil, let address = value.source, address != label { style.text += " (" + address + ")" }
            return [style]
        case is SoftBreak: style.text = "\n"; return [style]
        case is LineBreak: style.text = "\n"; return [style]
        case let value as InlineHTML: style.text = value.rawHTML; return [style]
        default: break
        }
        return node.children.flatMap { spans($0, style: style, depth: depth + 1) }
    }
    private static func plainSpans(_ spans: [TranscriptSpan]) -> String {
        var grouped: [(text: String, link: URL?)] = []
        for span in spans {
            if let link = span.link, grouped.last?.link == link {
                grouped[grouped.count - 1].text += span.text
            } else { grouped.append((span.text, span.link)) }
        }
        return grouped.map { value in
            if let link = value.link, value.text != link.absoluteString { return value.text + " (" + link.absoluteString + ")" }
            return value.text
        }.joined()
    }

    private static func spoken(_ blocks: [TranscriptBlock]) -> String {
        func inline(_ spans: [TranscriptSpan]) -> String { spans.map { $0.speechOverride ?? $0.text }.joined() }
        return blocks.map { block in
            switch block {
            case .paragraph(let spans), .heading(_, let spans): return inline(spans)
            case .code, .literal: return "(code sample)"
            case .quote(let blocks): return spoken(blocks)
            case .divider: return ""
            case .list(_, let items): return items.map { spoken($0.blocks) }.joined(separator: "\n")
            case .table(let table):
                return ([table.header] + table.rows).map { $0.map { inline($0) }.joined(separator: ", ") }.joined(separator: "\n")
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func plain(_ blocks: [TranscriptBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let value), .heading(_, let value): return plainSpans(value)
            case .code(_, let text), .literal(let text): return text
            case .quote(let value): return plain(value)
            case .divider: return "---"
            case .table(let table):
                return ([table.header] + table.rows).map { $0.map { plainSpans($0) }.joined(separator: " | ") }.joined(separator: "\n")
            case .list(let start, let items):
                return items.enumerated().map { index, item in
                    let marker = item.checked.map { $0 ? "☑ " : "☐ " } ?? start.map { String($0 + UInt(index)) + ". " } ?? "• "
                    return marker + plain(item.blocks).replacingOccurrences(of: "\n", with: "\n  ")
                }.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}

public actor TranscriptMarkdownParser {
    public static let shared = TranscriptMarkdownParser()
    public func parse(_ source: String) throws -> TranscriptMarkdown {
        try Task.checkCancellation()
        let value = TranscriptMarkdown(source)
        try Task.checkCancellation()
        return value
    }
}
