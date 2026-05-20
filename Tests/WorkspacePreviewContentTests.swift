//
//  WorkspacePreviewContentTests.swift
//  LineyTests
//
//  Author: everettjf
//

import XCTest
@testable import Liney

final class WorkspacePreviewContentTests: XCTestCase {
    func testFileRenderModeClassification() {
        XCTAssertEqual(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/README.md")), .markdown)
        XCTAssertEqual(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/notes.MARKDOWN")), .markdown)
        XCTAssertEqual(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/index.html")), .html)
        XCTAssertEqual(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/page.HTM")), .html)
        XCTAssertNil(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/main.swift")))
        XCTAssertNil(WorkspacePreviewContent.fileRenderMode(for: URL(fileURLWithPath: "/a/data.json")))
    }

    func testIsPreviewableAndMakeFile() {
        XCTAssertTrue(WorkspacePreviewContent.isPreviewable(URL(fileURLWithPath: "/x/a.md")))
        XCTAssertFalse(WorkspacePreviewContent.isPreviewable(URL(fileURLWithPath: "/x/a.png")))
        XCTAssertNotNil(WorkspacePreviewContent.makeFile(URL(fileURLWithPath: "/x/a.html")))
        XCTAssertNil(WorkspacePreviewContent.makeFile(URL(fileURLWithPath: "/x/a.png")))
    }

    func testWebURLNormalization() {
        XCTAssertEqual(WorkspacePreviewContent.webURL(fromUserInput: ":3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(WorkspacePreviewContent.webURL(fromUserInput: "localhost:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(WorkspacePreviewContent.webURL(fromUserInput: "example.com")?.absoluteString, "http://example.com")
        XCTAssertEqual(WorkspacePreviewContent.webURL(fromUserInput: "https://example.com/x")?.absoluteString, "https://example.com/x")
        XCTAssertEqual(WorkspacePreviewContent.webURL(fromUserInput: "  127.0.0.1:5173 ")?.absoluteString, "http://127.0.0.1:5173")
        XCTAssertNil(WorkspacePreviewContent.webURL(fromUserInput: ""))
        XCTAssertNil(WorkspacePreviewContent.webURL(fromUserInput: "   "))
    }

    func testLocalhostURL() {
        XCTAssertEqual(WorkspacePreviewContent.localhostURL(port: 3000)?.absoluteString, "http://localhost:3000")
    }

    func testTitlesAndFlags() {
        let md = WorkspacePreviewContent.file(URL(fileURLWithPath: "/repo/docs/Guide.md"))
        XCTAssertEqual(md.title, "Guide.md")
        XCTAssertEqual(md.subtitle, "/repo/docs")
        XCTAssertEqual(md.fileRenderMode, .markdown)
        XCTAssertFalse(md.isWeb)

        let web = WorkspacePreviewContent.web(URL(string: "http://localhost:3000/path")!)
        XCTAssertEqual(web.title, "localhost:3000")
        XCTAssertTrue(web.isWeb)
        XCTAssertNil(web.fileRenderMode)
    }
}
