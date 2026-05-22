//
//  MarkdownToHTMLRenderer.swift
//  Liney
//
//  Author: everettjf
//

import Foundation

/// Converts a Markdown document into an HTML string for display in a `WKWebView`.
///
/// This is a deliberately self-contained renderer (no third-party dependency or
/// bundled JavaScript) covering the GitHub-Flavored-Markdown subset that AI
/// tools emit in practice: ATX headings, paragraphs, hard breaks, fenced and
/// inline code, bold / italic / strikethrough, links, images, blockquotes,
/// ordered / unordered (nested) lists, tables, and horizontal rules.
///
/// `renderBody(_:)` is pure and unit-tested; `renderDocument(_:title:)` wraps it
/// in a full HTML page with light/dark aware styling.
nonisolated enum MarkdownToHTMLRenderer {

    // MARK: - Public API

    /// Renders Markdown into a complete, styled HTML document.
    static func renderDocument(_ markdown: String, title: String = "") -> String {
        let body = renderBody(markdown)
        let safeTitle = escape(title)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article class="markdown-body">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    /// Renders Markdown into an HTML fragment (no surrounding document chrome).
    static func renderBody(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return renderBlocks(lines)
    }

    // MARK: - Block parsing

    private static func renderBlocks(_ lines: [String]) -> String {
        var html = ""
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Blank line — skip.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            // Fenced code block.
            if let fence = fenceMarker(line) {
                var code: [String] = []
                index += 1
                while index < lines.count, !isClosingFence(lines[index], marker: fence.marker) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // consume closing fence
                let langClass = fence.language.isEmpty ? "" : " class=\"language-\(escape(fence.language))\""
                html += "<pre><code\(langClass)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // ATX heading.
            if let heading = atxHeading(line) {
                html += "<h\(heading.level)>\(renderInline(heading.text))</h\(heading.level)>\n"
                index += 1
                continue
            }

            // Horizontal rule.
            if isHorizontalRule(line) {
                html += "<hr>\n"
                index += 1
                continue
            }

            // Blockquote.
            if isBlockquote(line) {
                var quoted: [String] = []
                while index < lines.count, isBlockquote(lines[index]) || (!lines[index].trimmingCharacters(in: .whitespaces).isEmpty && !quoted.isEmpty && !isBlankLine(lines[index])) {
                    if isBlockquote(lines[index]) {
                        quoted.append(stripBlockquoteMarker(lines[index]))
                    } else {
                        // Lazy continuation line.
                        quoted.append(lines[index])
                    }
                    index += 1
                    if index < lines.count, isBlankLine(lines[index]) { break }
                }
                html += "<blockquote>\n\(renderBlocks(quoted))</blockquote>\n"
                continue
            }

            // Table (header row + delimiter row).
            if index + 1 < lines.count, isTableDelimiter(lines[index + 1]), looksLikeTableRow(line) {
                var tableLines = [line, lines[index + 1]]
                index += 2
                while index < lines.count, looksLikeTableRow(lines[index]), !isBlankLine(lines[index]) {
                    tableLines.append(lines[index])
                    index += 1
                }
                html += renderTable(tableLines)
                continue
            }

            // List (ordered or unordered).
            if listMarker(line) != nil {
                var listLines: [String] = []
                while index < lines.count {
                    let current = lines[index]
                    if isBlankLine(current) {
                        // Allow a single blank line inside a list if the next
                        // line continues the list or is indented.
                        if index + 1 < lines.count,
                           (listMarker(lines[index + 1]) != nil || lines[index + 1].hasPrefix("  ") || lines[index + 1].hasPrefix("\t")) {
                            listLines.append(current)
                            index += 1
                            continue
                        }
                        break
                    }
                    if listMarker(current) != nil || current.hasPrefix("  ") || current.hasPrefix("\t") {
                        listLines.append(current)
                        index += 1
                    } else {
                        break
                    }
                }
                html += renderList(listLines)
                continue
            }

            // Paragraph — gather consecutive non-blank, non-block lines.
            var paragraph: [String] = []
            while index < lines.count {
                let current = lines[index]
                if isBlankLine(current) { break }
                if fenceMarker(current) != nil || atxHeading(current) != nil || isHorizontalRule(current)
                    || isBlockquote(current) || listMarker(current) != nil {
                    break
                }
                paragraph.append(current)
                index += 1
            }
            if !paragraph.isEmpty {
                html += "<p>\(renderParagraph(paragraph))</p>\n"
            }
        }

        return html
    }

    // MARK: - Block helpers

    private struct Fence { let marker: Character; let length: Int; let language: String }

    private static func fenceMarker(_ line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let language = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A code fence info string must not contain backticks.
        if first == "`", language.contains("`") { return nil }
        return Fence(marker: first, length: run.count, language: language)
    }

    private static func isClosingFence(_ line: String, marker: Character) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0 == marker }) else { return false }
        return trimmed.count >= 3
    }

    private struct Heading { let level: Int; let text: String }

    private static func atxHeading(_ line: String) -> Heading? {
        let trimmed = line.drop(while: { $0 == " " })
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Strip optional closing hashes.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return Heading(level: hashes.count, text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] {
            let stripped = trimmed.replacingOccurrences(of: " ", with: "")
            if stripped.count >= 3, stripped.allSatisfy({ String($0) == marker }) {
                return true
            }
        }
        return false
    }

    private static func isBlankLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isBlockquote(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).first == ">"
    }

    private static func stripBlockquoteMarker(_ line: String) -> String {
        var stripped = String(line.drop(while: { $0 == " " }))
        if stripped.first == ">" { stripped.removeFirst() }
        if stripped.first == " " { stripped.removeFirst() }
        return stripped
    }

    private struct ListItemMarker { let indent: Int; let ordered: Bool; let contentStart: Int }

    private static func listMarker(_ line: String) -> ListItemMarker? {
        let indent = line.prefix(while: { $0 == " " }).count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }

        // Unordered: -, *, + followed by a space.
        if first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            if after.first == " " {
                return ListItemMarker(indent: indent, ordered: false, contentStart: indent + 2)
            }
            return nil
        }

        // Ordered: digits followed by '.' or ')' then a space.
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let afterDigits = rest.dropFirst(digits.count)
            if let delim = afterDigits.first, delim == "." || delim == ")" {
                let afterDelim = afterDigits.dropFirst()
                if afterDelim.first == " " {
                    return ListItemMarker(indent: indent, ordered: true, contentStart: indent + digits.count + 2)
                }
            }
        }
        return nil
    }

    /// Renders a contiguous run of list lines, handling nesting by indentation.
    private static func renderList(_ lines: [String]) -> String {
        guard let firstMarker = lines.first(where: { listMarker($0) != nil }).flatMap(listMarker) else {
            return ""
        }
        let ordered = firstMarker.ordered
        let baseIndent = firstMarker.indent

        var html = ordered ? "<ol>\n" : "<ul>\n"
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlankLine(line) { index += 1; continue }
            guard let marker = listMarker(line), marker.indent <= baseIndent + 1 else {
                index += 1
                continue
            }

            // Gather this item's content: the marker line's text plus any
            // following lines that are more-indented (children / continuations).
            let itemContent: [String] = [String(line.dropFirst(marker.contentStart))]
            index += 1
            var nested: [String] = []
            while index < lines.count {
                let next = lines[index]
                if isBlankLine(next) {
                    // Peek: keep consuming if the item continues.
                    if index + 1 < lines.count,
                       let nextMarker = listMarker(lines[index + 1]), nextMarker.indent > baseIndent {
                        nested.append(next)
                        index += 1
                        continue
                    }
                    break
                }
                if let nextMarker = listMarker(next), nextMarker.indent <= baseIndent + 1 {
                    break // sibling item
                }
                // Continuation or nested content — strip the base indentation.
                let stripCount = min(next.prefix(while: { $0 == " " }).count, baseIndent + 2)
                nested.append(String(next.dropFirst(stripCount)))
                index += 1
            }

            var itemHTML = renderInline(itemContent.joined(separator: " ").trimmingCharacters(in: .whitespaces))
            if !nested.isEmpty {
                let nestedRendered = renderBlocks(nested)
                itemHTML += "\n" + nestedRendered
            }
            html += "<li>\(itemHTML)</li>\n"
        }
        html += ordered ? "</ol>\n" : "</ul>\n"
        return html
    }

    // MARK: - Tables

    private static func looksLikeTableRow(_ line: String) -> Bool {
        line.contains("|")
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.allSatisfy({ "-:| ".contains($0) }) else {
            return false
        }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private enum ColumnAlignment { case none, left, center, right }

    private static func columnAlignment(_ delimiterCell: String) -> ColumnAlignment {
        let c = delimiterCell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        switch (left, right) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return .none
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for char in trimmed {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                current.append(char)
                escaped = true
            } else if char == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        return cells
    }

    private static func renderTable(_ lines: [String]) -> String {
        guard lines.count >= 2 else { return "" }
        let header = splitTableRow(lines[0])
        let alignments = splitTableRow(lines[1]).map(columnAlignment)
        let bodyRows = lines.dropFirst(2).map(splitTableRow)

        func alignmentAttr(_ index: Int) -> String {
            guard index < alignments.count else { return "" }
            switch alignments[index] {
            case .none: return ""
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }

        var html = "<table>\n<thead>\n<tr>"
        for (column, cell) in header.enumerated() {
            html += "<th\(alignmentAttr(column))>\(renderInline(cell.trimmingCharacters(in: .whitespaces)))</th>"
        }
        html += "</tr>\n</thead>\n<tbody>\n"
        for row in bodyRows {
            html += "<tr>"
            for column in 0..<header.count {
                let cell = column < row.count ? row[column].trimmingCharacters(in: .whitespaces) : ""
                html += "<td\(alignmentAttr(column))>\(renderInline(cell))</td>"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Paragraph / inline

    private static func renderParagraph(_ lines: [String]) -> String {
        var pieces: [String] = []
        for (offset, line) in lines.enumerated() {
            let isLast = offset == lines.count - 1
            let hardBreak = line.hasSuffix("  ") && !isLast
            pieces.append(renderInline(line.trimmingCharacters(in: .whitespaces)))
            if hardBreak { pieces.append("<br>\n") }
        }
        return pieces.joined(separator: hardBreakJoinNeeded(lines) ? "" : " ")
    }

    private static func hardBreakJoinNeeded(_ lines: [String]) -> Bool {
        lines.contains { $0.hasSuffix("  ") }
    }

    /// Renders inline Markdown (emphasis, code, links, images, …) to HTML,
    /// escaping all literal text.
    static func renderInline(_ text: String) -> String {
        let chars = Array(text)
        var output = ""
        var i = 0

        func peek(_ offset: Int) -> Character? {
            let index = i + offset
            return index < chars.count ? chars[index] : nil
        }

        while i < chars.count {
            let char = chars[i]

            // Backslash escape.
            if char == "\\", let next = peek(1), "\\`*_{}[]()#+-.!>~|".contains(next) {
                output += escape(String(next))
                i += 2
                continue
            }

            // Inline code span.
            if char == "`" {
                let tickRun = countRun(chars, from: i, of: "`")
                if let closeStart = findClosingTicks(chars, after: i + tickRun, count: tickRun) {
                    let codeChars = chars[(i + tickRun)..<closeStart]
                    var code = String(codeChars)
                    // Per CommonMark, trim a single leading/trailing space when
                    // the content is not all spaces.
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.trimmingCharacters(in: .whitespaces).isEmpty == false {
                        code = String(code.dropFirst().dropLast())
                    }
                    output += "<code>\(escape(code))</code>"
                    i = closeStart + tickRun
                    continue
                }
            }

            // Image: ![alt](src "title")
            if char == "!", peek(1) == "[" {
                if let image = parseLinkLike(chars, from: i + 1) {
                    let alt = escape(stripInlineMarkup(image.text))
                    output += "<img src=\"\(escapeAttribute(image.destination))\" alt=\"\(alt)\""
                    if let title = image.title { output += " title=\"\(escapeAttribute(title))\"" }
                    output += ">"
                    i = image.endIndex
                    continue
                }
            }

            // Link: [text](href "title")
            if char == "[" {
                if let link = parseLinkLike(chars, from: i) {
                    output += "<a href=\"\(escapeAttribute(link.destination))\""
                    if let title = link.title { output += " title=\"\(escapeAttribute(title))\"" }
                    output += ">\(renderInline(link.text))</a>"
                    i = link.endIndex
                    continue
                }
            }

            // Autolink: <https://example.com>
            if char == "<" {
                if let close = chars[i...].firstIndex(of: ">") {
                    let inner = String(chars[(i + 1)..<close])
                    if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
                        output += "<a href=\"\(escapeAttribute(inner))\">\(escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                }
            }

            // Strikethrough: ~~text~~
            if char == "~", peek(1) == "~" {
                if let close = findClosingDelimiter(chars, after: i + 2, delimiter: "~~") {
                    let inner = String(chars[(i + 2)..<close])
                    output += "<del>\(renderInline(inner))</del>"
                    i = close + 2
                    continue
                }
            }

            // Strong: ** or __
            if char == "*" || char == "_" {
                let runLength = countRun(chars, from: i, of: char)
                if runLength >= 2, char == "*" || isUnderscoreBoundary(chars, openIndex: i) {
                    let delimiter = String(repeating: String(char), count: 2)
                    if let close = findClosingDelimiter(chars, after: i + 2, delimiter: delimiter) {
                        let inner = String(chars[(i + 2)..<close])
                        output += "<strong>\(renderInline(inner))</strong>"
                        i = close + 2
                        continue
                    }
                }
                // Emphasis: single * or _
                if char == "*" || isUnderscoreBoundary(chars, openIndex: i) {
                    if let close = findClosingDelimiter(chars, after: i + 1, delimiter: String(char)) {
                        let inner = String(chars[(i + 1)..<close])
                        output += "<em>\(renderInline(inner))</em>"
                        i = close + 1
                        continue
                    }
                }
            }

            output += escape(String(char))
            i += 1
        }

        return output
    }

    // MARK: - Inline helpers

    private static func countRun(_ chars: [Character], from index: Int, of char: Character) -> Int {
        var count = 0
        var i = index
        while i < chars.count, chars[i] == char { count += 1; i += 1 }
        return count
    }

    private static func findClosingTicks(_ chars: [Character], after index: Int, count: Int) -> Int? {
        var i = index
        while i < chars.count {
            if chars[i] == "`" {
                let run = countRun(chars, from: i, of: "`")
                if run == count { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Finds the index where a closing emphasis/strikethrough delimiter begins.
    private static func findClosingDelimiter(_ chars: [Character], after index: Int, delimiter: String) -> Int? {
        let delimChars = Array(delimiter)
        guard !delimChars.isEmpty, index < chars.count else { return nil }
        var i = index
        while i <= chars.count - delimChars.count {
            // Skip escaped characters.
            if chars[i] == "\\" { i += 2; continue }
            if Array(chars[i..<(i + delimChars.count)]) == delimChars {
                // Don't match an empty span.
                if i == index { i += 1; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Underscore emphasis must not start inside a word (e.g. `a_b_c`).
    private static func isUnderscoreBoundary(_ chars: [Character], openIndex: Int) -> Bool {
        guard chars[openIndex] == "_" else { return true }
        if openIndex == 0 { return true }
        let before = chars[openIndex - 1]
        return !(before.isLetter || before.isNumber)
    }

    private struct LinkLike { let text: String; let destination: String; let title: String?; let endIndex: Int }

    /// Parses `[text](dest "title")` starting at the opening `[`.
    private static func parseLinkLike(_ chars: [Character], from start: Int) -> LinkLike? {
        guard start < chars.count, chars[start] == "[" else { return nil }

        // Find matching ] accounting for nested brackets.
        var depth = 0
        var i = start
        var textEnd: Int?
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "[" { depth += 1 }
            else if chars[i] == "]" {
                depth -= 1
                if depth == 0 { textEnd = i; break }
            }
            i += 1
        }
        guard let textEndIndex = textEnd, textEndIndex + 1 < chars.count, chars[textEndIndex + 1] == "(" else {
            return nil
        }

        let text = String(chars[(start + 1)..<textEndIndex])

        // Parse (destination "optional title")
        var j = textEndIndex + 2
        var destination = ""
        var parenDepth = 1
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count { destination.append(chars[j + 1]); j += 2; continue }
            if c == "(" { parenDepth += 1 }
            if c == ")" {
                parenDepth -= 1
                if parenDepth == 0 { break }
            }
            if c == " " || c == "\"" { break }
            destination.append(c)
            j += 1
        }

        var title: String?
        // Optional title.
        while j < chars.count, chars[j] == " " { j += 1 }
        if j < chars.count, chars[j] == "\"" {
            var t = ""
            j += 1
            while j < chars.count, chars[j] != "\"" {
                if chars[j] == "\\", j + 1 < chars.count { t.append(chars[j + 1]); j += 2; continue }
                t.append(chars[j]); j += 1
            }
            if j < chars.count { j += 1 } // closing quote
            title = t
        }
        while j < chars.count, chars[j] == " " { j += 1 }
        guard j < chars.count, chars[j] == ")" else { return nil }

        return LinkLike(text: text, destination: destination, title: title, endIndex: j + 1)
    }

    private static func stripInlineMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    // MARK: - Escaping

    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(char)
            }
        }
        return result
    }

    static func escapeAttribute(_ string: String) -> String {
        escape(string).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
        margin: 0;
        font: 15px/1.65 -apple-system, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
        color: #1f2328;
        background: #ffffff;
        -webkit-font-smoothing: antialiased;
    }
    .markdown-body { max-width: 920px; margin: 0 auto; padding: 28px 32px 64px; }
    h1, h2, h3, h4, h5, h6 { font-weight: 650; line-height: 1.3; margin: 1.6em 0 0.6em; }
    h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid rgba(128,128,128,.25); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid rgba(128,128,128,.2); }
    h3 { font-size: 1.25em; } h4 { font-size: 1.05em; } h5 { font-size: .95em; } h6 { font-size: .9em; color: #6b7280; }
    p { margin: 0 0 1em; }
    a { color: #2563eb; text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font: 0.88em ui-monospace, "SF Mono", Menlo, Consolas, monospace;
        background: rgba(128,128,128,.16);
        padding: .15em .4em; border-radius: 5px;
    }
    pre {
        background: #f6f8fa; border: 1px solid rgba(128,128,128,.2);
        border-radius: 10px; padding: 14px 16px; overflow: auto; line-height: 1.5;
    }
    pre code { background: none; padding: 0; font-size: .86em; }
    blockquote {
        margin: 0 0 1em; padding: .2em 1em; color: #57606a;
        border-left: 3px solid rgba(128,128,128,.4);
    }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
    li { margin: .25em 0; }
    li > ul, li > ol { margin: .25em 0; }
    table { border-collapse: collapse; margin: 0 0 1em; display: block; overflow: auto; }
    th, td { border: 1px solid rgba(128,128,128,.35); padding: 6px 13px; }
    th { background: rgba(128,128,128,.12); font-weight: 650; }
    tr:nth-child(2n) td { background: rgba(128,128,128,.06); }
    img { max-width: 100%; border-radius: 8px; }
    hr { border: none; border-top: 1px solid rgba(128,128,128,.3); margin: 1.8em 0; }
    del { opacity: .7; }
    @media (prefers-color-scheme: dark) {
        body { color: #e6edf3; background: #0d1117; }
        h6 { color: #9ca3af; }
        a { color: #58a6ff; }
        pre { background: #161b22; }
        blockquote { color: #9ca3af; }
    }
    """
}
