//
//  RichTextView.swift
//  MacAssistant
//
//  Structured markdown renderer tuned for chat bubbles.
//

import Foundation
import SwiftUI

struct RichTextView: View, Equatable {
    let text: String
    private let blocks: [MarkdownBlock]

    init(text: String) {
        self.text = text
        self.blocks = MarkdownBlockParser.parse(text)
    }

    static func == (lhs: RichTextView, rhs: RichTextView) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock

    static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        lhs.block == rhs.block
    }

    var body: some View {
        switch block.kind {
        case let .heading(level, text):
            HeadingBlock(level: level, text: text)
        case let .paragraph(text):
            MarkdownInlineText(text, style: .body)
        case let .quote(text):
            QuoteBlock(text: text)
        case let .bulletList(items):
            BulletListBlock(items: items)
        case let .orderedList(items):
            OrderedListBlock(items: items)
        case let .table(table):
            MarkdownTableView(table: table)
        case let .codeBlock(code, language):
            CodeBlockView(code: code, language: language)
        case .divider:
            Rectangle()
                .fill(Color.gray.opacity(0.14))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

private struct HeadingBlock: View, Equatable {
    let level: Int
    let text: String

    static func == (lhs: HeadingBlock, rhs: HeadingBlock) -> Bool {
        lhs.level == rhs.level && lhs.text == rhs.text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentColor)
                .frame(width: level == 1 ? 5 : 4)

            MarkdownInlineText(text, style: textStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, level == 1 ? 4 : 1)
    }

    private var accentColor: Color {
        switch level {
        case 1:
            return Color.green.opacity(0.8)
        case 2:
            return Color.green.opacity(0.55)
        default:
            return Color.gray.opacity(0.35)
        }
    }

    private var textStyle: MarkdownTextStyle {
        switch level {
        case 1:
            return .heading1
        case 2:
            return .heading2
        default:
            return .heading3
        }
    }
}

private struct QuoteBlock: View, Equatable {
    let text: String

    static func == (lhs: QuoteBlock, rhs: QuoteBlock) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.gray.opacity(0.35))
                .frame(width: 4)

            MarkdownInlineText(text, style: .quote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct BulletListBlock: View, Equatable {
    let items: [String]

    static func == (lhs: BulletListBlock, rhs: BulletListBlock) -> Bool {
        lhs.items == rhs.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.green.opacity(0.72))
                        .frame(width: 6, height: 6)
                        .padding(.top, 7)

                    MarkdownInlineText(item, style: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct OrderedListBlock: View, Equatable {
    let items: [OrderedListItem]

    static func == (lhs: OrderedListBlock, rhs: OrderedListBlock) -> Bool {
        lhs.items == rhs.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 10) {
                    Text(item.marker)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.green.opacity(0.85))
                        .frame(minWidth: 28, alignment: .trailing)

                    MarkdownInlineText(item.content, style: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct MarkdownTableView: View, Equatable {
    let table: MarkdownTable

    static func == (lhs: MarkdownTableView, rhs: MarkdownTableView) -> Bool {
        lhs.table == rhs.table
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                        TableCellView(
                            text: header,
                            role: .header,
                            alignment: columnAlignment(at: index),
                            showsTrailingDivider: index < table.headers.count - 1
                        )
                    }
                }

                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(normalizedRow(row).enumerated()), id: \.offset) { columnIndex, cell in
                            TableCellView(
                                text: cell,
                                role: .body(rowIndex: rowIndex),
                                alignment: columnAlignment(at: columnIndex),
                                showsTrailingDivider: columnIndex < table.headers.count - 1
                            )
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.gray.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func normalizedRow(_ row: [String]) -> [String] {
        if row.count == table.headers.count {
            return row
        }

        if row.count > table.headers.count {
            return Array(row.prefix(table.headers.count))
        }

        return row + Array(repeating: "", count: table.headers.count - row.count)
    }

    private func columnAlignment(at index: Int) -> TableColumnAlignment {
        let values = table.rows.compactMap { row -> String? in
            guard index < row.count else { return nil }
            return row[index]
        }

        guard !values.isEmpty else { return .leading }
        return values.allSatisfy(MarkdownTableView.looksNumeric) ? .trailing : .leading
    }

    private static func looksNumeric(_ value: String) -> Bool {
        let trimmed = value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return false }
        return Double(trimmed) != nil
    }
}

private struct TableCellView: View, Equatable {
    enum Role: Equatable {
        case header
        case body(rowIndex: Int)
    }

    let text: String
    let role: Role
    let alignment: TableColumnAlignment
    let showsTrailingDivider: Bool

    static func == (lhs: TableCellView, rhs: TableCellView) -> Bool {
        lhs.text == rhs.text &&
        lhs.role == rhs.role &&
        lhs.alignment == rhs.alignment &&
        lhs.showsTrailingDivider == rhs.showsTrailingDivider
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, role == .header ? 10 : 9)
            .frame(
                minWidth: alignment == .trailing ? 92 : 120,
                maxWidth: 220,
                alignment: alignment.swiftUIAlignment
            )
            .background(backgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.gray.opacity(role == .header ? 0.16 : 0.08))
                    .frame(height: 1)
            }
            .overlay(alignment: .trailing) {
                if showsTrailingDivider {
                    Rectangle()
                        .fill(Color.gray.opacity(0.08))
                        .frame(width: 1)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if alignment == .trailing {
            MarkdownInlineText(text, style: role == .header ? .tableHeader : .tableCell)
                .monospacedDigit()
        } else {
            MarkdownInlineText(text, style: role == .header ? .tableHeader : .tableCell)
        }
    }

    private var backgroundColor: Color {
        switch role {
        case .header:
            return Color.green.opacity(0.08)
        case let .body(rowIndex):
            return rowIndex.isMultiple(of: 2)
                ? Color(NSColor.textBackgroundColor)
                : Color.gray.opacity(0.04)
        }
    }
}

private enum TableColumnAlignment: Equatable {
    case leading
    case trailing

    var swiftUIAlignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }
}

private enum MarkdownTextStyle: Int, Equatable {
    case body
    case quote
    case heading1
    case heading2
    case heading3
    case tableHeader
    case tableCell
}

private struct MarkdownInlineText: View, Equatable {
    let source: String
    let style: MarkdownTextStyle
    private let attributed: AttributedString

    private static let parsingOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    init(_ source: String, style: MarkdownTextStyle) {
        self.source = source
        self.style = style
        self.attributed = Self.makeAttributedString(from: source)
    }

    static func == (lhs: MarkdownInlineText, rhs: MarkdownInlineText) -> Bool {
        lhs.source == rhs.source && lhs.style == rhs.style
    }

    var body: some View {
        Text(attributed)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        switch style {
        case .body:
            return .system(size: 13.5, weight: .regular, design: .rounded)
        case .quote:
            return .system(size: 13.5, weight: .regular, design: .rounded)
        case .heading1:
            return .system(size: 18, weight: .semibold, design: .rounded)
        case .heading2:
            return .system(size: 15.5, weight: .semibold, design: .rounded)
        case .heading3:
            return .system(size: 14.5, weight: .semibold, design: .rounded)
        case .tableHeader:
            return .system(size: 12.5, weight: .semibold, design: .rounded)
        case .tableCell:
            return .system(size: 12.5, weight: .regular, design: .rounded)
        }
    }

    private var color: Color {
        switch style {
        case .quote:
            return .secondary
        case .tableHeader:
            return Color.primary.opacity(0.88)
        default:
            return Color.primary.opacity(0.96)
        }
    }

    private var lineSpacing: CGFloat {
        switch style {
        case .heading1, .heading2, .heading3:
            return 4
        case .tableHeader, .tableCell:
            return 2
        default:
            return 5
        }
    }

    private static func makeAttributedString(from source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString("") }

        if let attributed = try? AttributedString(markdown: source, options: parsingOptions) {
            return attributed
        }

        return AttributedString(source)
    }
}

private struct MarkdownBlock: Identifiable, Equatable {
    let id: Int
    let kind: Kind

    enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case quote(String)
        case bulletList([String])
        case orderedList([OrderedListItem])
        case table(MarkdownTable)
        case codeBlock(code: String, language: String)
        case divider
    }
}

private struct OrderedListItem: Equatable {
    let marker: String
    let content: String
}

private struct MarkdownTable: Equatable {
    let headers: [String]
    let rows: [[String]]
}

private enum MarkdownBlockParser {
    static func parse(_ rawText: String) -> [MarkdownBlock] {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0
        var nextID = 0

        func append(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: nextID, kind: kind))
            nextID += 1
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []

                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(codeLine)
                    index += 1
                }

                append(.codeBlock(code: codeLines.joined(separator: "\n"), language: language))
                continue
            }

            if isDivider(trimmed) {
                append(.divider)
                index += 1
                continue
            }

            if let heading = headingInfo(from: trimmed) {
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isTableStart(lines, at: index) {
                let (table, nextIndex) = parseTable(lines, from: index)
                append(.table(table))
                index = nextIndex
                continue
            }

            if isQuoteLine(line) {
                var quoteLines: [String] = []
                while index < lines.count, isQuoteLine(lines[index]) {
                    quoteLines.append(strippingQuotePrefix(from: lines[index]))
                    index += 1
                }
                append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = bulletContent(from: line) {
                var items = [item]
                index += 1

                while index < lines.count {
                    if let nextItem = bulletContent(from: lines[index]) {
                        items.append(nextItem)
                        index += 1
                    } else if let continuation = listContinuation(from: lines[index]) {
                        let lastIndex = items.index(before: items.endIndex)
                        items[lastIndex].append("\n\(continuation)")
                        index += 1
                    } else {
                        break
                    }
                }

                append(.bulletList(items))
                continue
            }

            if let ordered = orderedItem(from: line) {
                var items = [ordered]
                index += 1

                while index < lines.count {
                    if let nextItem = orderedItem(from: lines[index]) {
                        items.append(nextItem)
                        index += 1
                    } else if let continuation = listContinuation(from: lines[index]) {
                        let lastIndex = items.index(before: items.endIndex)
                        items[lastIndex] = OrderedListItem(
                            marker: items[lastIndex].marker,
                            content: items[lastIndex].content + "\n" + continuation
                        )
                        index += 1
                    } else {
                        break
                    }
                }

                append(.orderedList(items))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

                if candidateTrimmed.isEmpty {
                    break
                }

                if !paragraphLines.isEmpty && lineStartsNewBlock(lines, at: index) {
                    break
                }

                paragraphLines.append(candidate)
                index += 1
            }

            append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        if blocks.isEmpty {
            blocks.append(MarkdownBlock(id: 0, kind: .paragraph(rawText)))
        }

        return blocks
    }

    private static func lineStartsNewBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("```") || isDivider(trimmed) || headingInfo(from: trimmed) != nil {
            return true
        }

        if isTableStart(lines, at: index) || isQuoteLine(line) {
            return true
        }

        return bulletContent(from: line) != nil || orderedItem(from: line) != nil
    }

    private static func headingInfo(from line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard level > 0, level <= 6 else { return nil }

        let markerEnd = line.index(line.startIndex, offsetBy: level)
        guard markerEnd < line.endIndex, line[markerEnd] == " " else { return nil }

        let textStart = line.index(after: markerEnd)
        let text = String(line[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (level, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let character = compact.first else { return false }
        guard character == "-" || character == "*" || character == "_" else { return false }
        return compact.allSatisfy { $0 == character }
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">")
    }

    private static func strippingQuotePrefix(from line: String) -> String {
        var content = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while content.hasPrefix(">") {
            content.removeFirst()
            if content.hasPrefix(" ") {
                content.removeFirst()
            }
        }
        return content
    }

    private static func bulletContent(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["- ", "* ", "• "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }

        return nil
    }

    private static func orderedItem(from line: String) -> OrderedListItem? {
        guard let match = line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) else {
            return nil
        }

        let marker = String(line[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else { return nil }
        return OrderedListItem(marker: marker, content: content)
    }

    private static func listContinuation(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let indentation = line.prefix { $0 == " " || $0 == "\t" }.count
        guard indentation >= 2 else { return nil }
        guard bulletContent(from: line) == nil, orderedItem(from: line) == nil, !isQuoteLine(line) else {
            return nil
        }

        return trimmed
    }

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let headerCells = splitTableCells(from: lines[index])
        guard headerCells.count >= 2 else { return false }
        return isTableSeparatorLine(lines[index + 1], expectedColumnCount: headerCells.count)
    }

    private static func parseTable(_ lines: [String], from index: Int) -> (MarkdownTable, Int) {
        let headers = splitTableCells(from: lines[index])
        var rows: [[String]] = []
        var currentIndex = index + 2

        while currentIndex < lines.count {
            let line = lines[currentIndex]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                break
            }

            let cells = splitTableCells(from: line)
            if cells.count < 2 {
                break
            }

            rows.append(normalize(cells, to: headers.count))
            currentIndex += 1
        }

        return (MarkdownTable(headers: headers, rows: rows), currentIndex)
    }

    private static func isTableSeparatorLine(_ line: String, expectedColumnCount: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("-") else { return false }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" }) else {
            return false
        }

        let columns = splitTableCells(from: line)
        return columns.isEmpty || columns.count == expectedColumnCount
    }

    private static func splitTableCells(from line: String) -> [String] {
        var working = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard working.contains("|") else { return [] }

        if working.hasPrefix("|") {
            working.removeFirst()
        }
        if working.hasSuffix("|") {
            working.removeLast()
        }

        return working
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func normalize(_ row: [String], to columnCount: Int) -> [String] {
        if row.count == columnCount {
            return row
        }

        if row.count > columnCount {
            return Array(row.prefix(columnCount))
        }

        return row + Array(repeating: "", count: columnCount - row.count)
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)

                Spacer()

                Button(action: copyCode) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(isCopied ? .green : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.gray.opacity(0.08))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(3)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.14), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                isCopied = false
            }
        }
    }
}
