//
//  WorkspacePreviewContent.swift
//  Liney
//
//  Author: everettjf
//

import Foundation

/// Describes what the workspace's right-hand preview panel should render.
///
/// The panel sits alongside the terminal split tree (it is not part of it) and
/// can show either:
/// - a local file rendered for reading — Markdown is converted to styled HTML,
///   `.html` files are loaded directly (covers "AI artifact" rendering), or
/// - a live web page served on the machine running Liney (e.g. a dev server on
///   `http://localhost:3000`). Because the page is loaded by a `WKWebView` in
///   the same process, it uses the server's own network — exactly like opening
///   the URL in a browser that lives on the server.
nonisolated enum WorkspacePreviewContent: Equatable, Hashable {
    case file(URL)
    case web(URL)

    /// How a local file should be rendered in the preview panel.
    enum FileRenderMode: Equatable, Hashable {
        /// Markdown source converted to HTML and shown in the web view.
        case markdown
        /// An HTML document loaded directly from disk.
        case html
    }

    /// File extensions Liney knows how to render in the preview panel.
    /// Anything outside this set should be opened externally instead.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]

    /// Returns the render mode for a file URL, or `nil` when the file is not a
    /// type the preview panel can render.
    static func fileRenderMode(for url: URL) -> FileRenderMode? {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if htmlExtensions.contains(ext) { return .html }
        return nil
    }

    /// Whether a file at `url` can be opened in the preview panel.
    static func isPreviewable(_ url: URL) -> Bool {
        fileRenderMode(for: url) != nil
    }

    /// Convenience initializer that only succeeds for previewable files.
    static func makeFile(_ url: URL) -> WorkspacePreviewContent? {
        isPreviewable(url) ? .file(url) : nil
    }

    /// The render mode when this content is a previewable file.
    var fileRenderMode: FileRenderMode? {
        guard case let .file(url) = self else { return nil }
        return Self.fileRenderMode(for: url)
    }

    /// A short title suitable for the panel header.
    var title: String {
        switch self {
        case let .file(url):
            return url.lastPathComponent
        case let .web(url):
            return url.host.map { host in
                url.port.map { "\(host):\($0)" } ?? host
            } ?? url.absoluteString
        }
    }

    /// A longer subtitle: the file's parent directory, or the full URL.
    var subtitle: String {
        switch self {
        case let .file(url):
            return url.deletingLastPathComponent().path
        case let .web(url):
            return url.absoluteString
        }
    }

    /// SF Symbol used to represent the content.
    var symbolName: String {
        switch self {
        case .file:
            switch fileRenderMode {
            case .markdown: return "doc.richtext"
            case .html: return "chevron.left.forwardslash.chevron.right"
            case .none: return "doc"
            }
        case .web:
            return "globe"
        }
    }

    /// Whether navigation chrome (back/forward/reload as a live page) applies.
    var isWeb: Bool {
        if case .web = self { return true }
        return false
    }
}

nonisolated extension WorkspacePreviewContent {
    /// Normalizes user-entered text into a web URL.
    ///
    /// Accepts bare hosts/ports (`localhost:3000`, `:8080`, `127.0.0.1`) and
    /// adds an `http://` scheme when none is present. Returns `nil` for input
    /// that cannot form a host.
    static func webURL(fromUserInput rawInput: String) -> URL? {
        var text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // ":3000" -> "localhost:3000"
        if text.hasPrefix(":"), text.dropFirst().allSatisfy(\.isNumber) {
            text = "localhost\(text)"
        }

        if !text.contains("://") {
            text = "http://\(text)"
        }

        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    /// Builds a `localhost` URL for a detected listening port.
    static func localhostURL(port: Int) -> URL? {
        URL(string: "http://localhost:\(port)")
    }
}
