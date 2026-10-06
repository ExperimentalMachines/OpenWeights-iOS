import SwiftUI
import OpenWeightsCore

struct TranscriptMarkdownView: View {
    let content: String
    @State private var parsed: TranscriptMarkdown?
    var body: some View {
        Group {
            if let parsed { TranscriptBlocksView(blocks: parsed.blocks) }
            else { Text(verbatim: content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .task(id: content) {
            do {
                let value = try await TranscriptMarkdownParser.shared.parse(content)
                try Task.checkCancellation()
                parsed = value
            } catch is CancellationError {} catch { parsed = TranscriptMarkdown(content) }
        }
    }
}

struct TranscriptBlocksView: View {
    let blocks: [TranscriptBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                TranscriptBlockView(block: block, index: index)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let index: Int
    var body: some View {
        switch block {
        case .paragraph(let spans): TranscriptInlineView(spans: spans)
        case .heading(let level, let spans):
            TranscriptInlineView(spans: spans, headingLevel: level).accessibilityAddTraits(.isHeader)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(OWTheme.outline).frame(width: 3)
                TranscriptBlocksView(blocks: blocks)
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.checked.map { $0 ? "☑" : "☐" } ?? start.map { String($0 + UInt(offset)) + "." } ?? "•")
                            .font(OWTheme.interface()).foregroundStyle(OWTheme.secondary)
                            .accessibilityLabel(item.checked.map { $0 ? "Completed" : "Not completed" } ?? "")
                        TranscriptBlocksView(blocks: item.blocks)
                    }
                }
            }
        case .code(let language, let text): TranscriptCodeView(language: language, text: text, index: index)
        case .table(let table): TranscriptTableView(table: table)
        case .divider: Divider().overlay(OWTheme.outline)
        case .literal(let text): Text(verbatim: text).font(OWTheme.metric(14)).textSelection(.enabled)
        }
    }
}

private struct TranscriptInlineView: View {
    let spans: [TranscriptSpan]
    var headingLevel: Int? = nil
    var alignment: Alignment = .leading
    private var formatted: AttributedString {
        spans.reduce(into: AttributedString()) { result, span in
            var value = AttributedString(span.text)
            var font = span.code ? OWTheme.metric(15) : headingLevel.map { OWTheme.display(CGFloat(max(17, 28 - $0 * 2))) } ?? OWTheme.interface()
            if span.bold || headingLevel != nil { font = font.weight(.semibold) }
            if span.italic { font = font.italic() }
            value.font = font
            if span.code { value.backgroundColor = OWTheme.raised }
            if span.strike { value.strikethroughStyle = .single }
            if let link = span.link { value.link = link; value.foregroundColor = OWTheme.signal }
            result.append(value)
        }
    }
    var body: some View {
        Text(formatted).textSelection(.enabled).tint(OWTheme.signal)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct TranscriptCodeView: View {
    let language: String?
    let text: String
    let index: Int
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: HighlightedCode?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language?.isEmpty == false ? language! : "Code").font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy code") { TranscriptCopy.copyCode(text); copied = true }
                    .font(OWTheme.interface(13)).frame(minHeight: 44)
                    .accessibilityIdentifier("transcript.code.copy.\(index)")
                    .task(id: copied) { if copied { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { copied = false } } }
            }
            ScrollView(.horizontal) {
                Text(highlighted?.source == text ? highlighted!.attributed : AttributedString(text)).font(OWTheme.metric(14)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(.bottom, 4)
            }.accessibilityLabel("Code block, scroll horizontally for long lines")
        }.padding(12).background(OWTheme.raised, in: RoundedRectangle(cornerRadius: 10))
        .task(id: text + "\0" + (language ?? "") + (colorScheme == .dark ? "dark" : "light")) {
            do {
                let value = try await CodeHighlighter.shared.highlight(text, language: language, dark: colorScheme == .dark)
                try Task.checkCancellation(); highlighted = value
            } catch {}
        }
    }
}

private struct TranscriptTableView: View {
    let table: TranscriptTable
    @ScaledMetric(relativeTo: .body) private var characterWidth = 8.5
    private var widths: [CGFloat] {
        table.header.indices.map { column in
            let length = ([table.header] + table.rows).map { row in
                row.indices.contains(column) ? row[column].map(\.text).joined().count : 0
            }.max() ?? 0
            return CGFloat(min(32, max(12, length))) * characterWidth
        }
    }
    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, header: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
            }.overlay(RoundedRectangle(cornerRadius: 4).stroke(OWTheme.outline, lineWidth: 1))
                .padding(1)
        }.accessibilityElement(children: .contain)
            .accessibilityLabel("Table, \(table.header.count) columns, \(table.rows.count) data rows. Scroll horizontally for more columns.")
    }
    private func row(_ cells: [[TranscriptSpan]], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(table.header.indices), id: \.self) { column in
                let alignment: Alignment = column < table.alignments.count && table.alignments[column] == .right ? .trailing :
                    column < table.alignments.count && table.alignments[column] == .center ? .center : .leading
                let cell = cells.indices.contains(column) ? cells[column] : []
                TranscriptInlineView(spans: cell.map { span in var value = span; value.bold = value.bold || header; return value }, alignment: alignment)
                    .frame(width: widths[column], alignment: alignment).fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .accessibilityLabel((header ? "" : table.header[column].map(\.text).joined() + ": ") + cell.map(\.text).joined())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(header ? OWTheme.raised : OWTheme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(OWTheme.outline).frame(height: 0.5) }
    }
}

enum TranscriptCopy {
    static func copyCode(_ text: String) { UIPasteboard.general.string = text }
    static func copyMarkdown(_ text: String) { UIPasteboard.general.string = text }
    static func copyPlainText(_ text: String) async {
        guard let parsed = try? await TranscriptMarkdownParser.shared.parse(text), !Task.isCancelled else { return }
        await MainActor.run { UIPasteboard.general.string = parsed.plainText }
    }
}
