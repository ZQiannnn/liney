//
//  MarkdownToHTMLRendererTests.swift
//  LineyTests
//
//  Author: everettjf
//

import XCTest
@testable import Liney

final class MarkdownToHTMLRendererTests: XCTestCase {
    private func render(_ markdown: String) -> String {
        MarkdownToHTMLRenderer.renderBody(markdown)
    }

    func testHeadings() {
        XCTAssertEqual(render("# Title").trimmingCharacters(in: .whitespacesAndNewlines), "<h1>Title</h1>")
        XCTAssertEqual(render("### Sub heading ###").trimmingCharacters(in: .whitespacesAndNewlines), "<h3>Sub heading</h3>")
    }

    func testParagraphAndEmphasis() {
        let html = render("This is **bold** and *italic* and `code`.")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<p>"))
    }

    func testUnderscoreEmphasisRespectsWordBoundaries() {
        // Intra-word underscores stay literal (snake_case).
        let html = render("call my_function_name now")
        XCTAssertFalse(html.contains("<em>"))
        // Surrounded underscores still emphasize.
        XCTAssertTrue(render("an _emphasized_ word").contains("<em>emphasized</em>"))
    }

    func testStrikethrough() {
        XCTAssertTrue(render("~~gone~~").contains("<del>gone</del>"))
    }

    func testInlineCodeIsEscaped() {
        let html = render("`a < b && c > d`")
        XCTAssertTrue(html.contains("<code>a &lt; b &amp;&amp; c &gt; d</code>"))
    }

    func testFencedCodeBlockPreservesAndEscapes() {
        let markdown = """
        ```swift
        let x = a < b && c
        ```
        """
        let html = render(markdown)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(html.contains("let x = a &lt; b &amp;&amp; c"))
        XCTAssertFalse(html.contains("<strong>"), "Code fences must not be inline-parsed")
    }

    func testLinksAndImages() {
        XCTAssertTrue(render("[Liney](https://example.com)").contains("<a href=\"https://example.com\">Liney</a>"))
        let image = render("![alt text](image.png)")
        XCTAssertTrue(image.contains("<img src=\"image.png\" alt=\"alt text\">"))
    }

    func testUnorderedAndOrderedLists() {
        let unordered = render("- one\n- two\n- three")
        XCTAssertTrue(unordered.contains("<ul>"))
        XCTAssertEqual(unordered.components(separatedBy: "<li>").count - 1, 3)

        let ordered = render("1. first\n2. second")
        XCTAssertTrue(ordered.contains("<ol>"))
        XCTAssertTrue(ordered.contains("<li>first</li>"))
    }

    func testNestedList() {
        let markdown = "- parent\n  - child"
        let html = render(markdown)
        XCTAssertTrue(html.contains("<ul>"))
        // The nested list produces a second <ul>.
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 2)
        XCTAssertTrue(html.contains("child"))
    }

    func testBlockquote() {
        let html = render("> quoted text")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("quoted text"))
    }

    func testHorizontalRule() {
        XCTAssertTrue(render("---").contains("<hr>"))
        XCTAssertTrue(render("***").contains("<hr>"))
    }

    func testTable() {
        let markdown = """
        | Name | Count |
        | :--- | ----: |
        | a    | 1     |
        | b    | 2     |
        """
        let html = render(markdown)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">Name</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">Count</th>"))
        XCTAssertEqual(html.components(separatedBy: "<tr>").count - 1, 3) // header + 2 rows
    }

    func testRawHTMLIsEscapedInText() {
        let html = render("a <script>alert(1)</script> b")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testDocumentWrapsBodyWithStyling() {
        let doc = MarkdownToHTMLRenderer.renderDocument("# Hi", title: "Doc")
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains("<title>Doc</title>"))
        XCTAssertTrue(doc.contains("markdown-body"))
        XCTAssertTrue(doc.contains("<h1>Hi</h1>"))
        XCTAssertTrue(doc.contains("prefers-color-scheme: dark"))
    }

    func testHardBreak() {
        let html = render("line one  \nline two")
        XCTAssertTrue(html.contains("<br>"))
    }
}
