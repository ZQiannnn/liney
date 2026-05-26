//
//  WorkspaceCodeEditorView.swift
//  Liney
//

import AppKit
import Combine
import Highlightr
import SwiftUI
import WebKit

enum EditorViewMode: Hashable {
    case source
    case preview
    case split
}

/// Plain-text / source-code editor for the right-hand preview panel. Loads a
/// file from disk into an in-memory buffer, lets the user edit it (when not
/// locked), and writes the buffer back atomically on save. No syntax
/// highlighting in this Phase 1; that lives behind a follow-up that introduces
/// a TreeSitter / Highlightr dependency.
struct WorkspaceCodeEditorView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject var state: CodeEditorState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LineyTheme.border)
            ZStack {
                LineyTheme.paneBackground
                switch state.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .loaded:
                    contentArea
                case .failed(let message):
                    errorOverlay(message)
                }

                if let saveError = state.saveError {
                    saveErrorBanner(saveError)
                }
            }
        }
        .background(LineyTheme.panelBackground)
    }

    @ViewBuilder
    private var contentArea: some View {
        if state.isMarkdown {
            switch state.viewMode {
            case .source:
                sourceView
            case .preview:
                previewView
            case .split:
                HSplitView {
                    sourceView
                        .frame(minWidth: 200)
                    previewView
                        .frame(minWidth: 200)
                }
            }
        } else {
            sourceView
        }
    }

    private var sourceView: some View {
        CodeTextView(
            text: Binding(
                get: { state.bufferContents },
                set: { state.bufferContents = $0 }
            ),
            isEditable: state.isEditable,
            language: state.languageHint
        )
    }

    private var previewView: some View {
        MarkdownPreviewView(
            markdown: state.bufferContents,
            baseURL: state.url.deletingLastPathComponent()
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LineyTheme.accent)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(state.url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LineyTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if state.isDirty {
                        Circle()
                            .fill(LineyTheme.warning)
                            .frame(width: 6, height: 6)
                            .help(localized("editor.dirty"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if state.isMarkdown {
                modeSegmented
                    .padding(.trailing, 4)
            }

            // Edit / Lock toggle
            iconButton(
                state.isEditable ? "lock.open" : "lock",
                help: state.isEditable ? localized("editor.lock") : localized("editor.unlock")
            ) {
                state.isEditable.toggle()
            }

            // Save
            iconButton("square.and.arrow.down",
                       help: localized("editor.save"),
                       enabled: state.isDirty) {
                Task { await state.save() }
            }
            .keyboardShortcut("s", modifiers: .command)

            // Discard
            iconButton("arrow.uturn.backward",
                       help: localized("editor.discard"),
                       enabled: state.isDirty) {
                state.discard()
            }

            // Reload from disk
            iconButton("arrow.clockwise",
                       help: localized("editor.reload")) {
                Task { await state.load() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(LineyTheme.paneHeaderBackground)
    }

    private var modeSegmented: some View {
        HStack(spacing: 1) {
            modeButton(.source, symbol: "curlybraces", help: localized("editor.mode.source"))
            modeButton(.preview, symbol: "doc.richtext", help: localized("editor.mode.preview"))
            modeButton(.split, symbol: "rectangle.split.2x1", help: localized("editor.mode.split"))
        }
        .background(LineyTheme.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func modeButton(_ mode: EditorViewMode, symbol: String, help: String) -> some View {
        Button {
            state.viewMode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(
                    state.viewMode == mode ? LineyTheme.accent.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(state.viewMode == mode ? LineyTheme.accent : LineyTheme.secondaryText)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        tint: Color = LineyTheme.secondaryText,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? tint : LineyTheme.mutedText.opacity(0.4))
        .disabled(!enabled)
        .help(help)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(LineyTheme.warning)
            Text(localized("editor.loadFailed"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LineyTheme.tertiaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LineyTheme.mutedText)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button(localized("editor.retry")) {
                Task { await state.load() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(LineyTheme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LineyTheme.border, lineWidth: 1))
    }

    private func saveErrorBanner(_ message: String) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LineyTheme.danger)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(LineyTheme.tertiaryText)
                    .lineLimit(2)
                Spacer()
                Button(action: { state.saveError = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LineyTheme.mutedText)
            }
            .padding(8)
            .background(LineyTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(LineyTheme.danger.opacity(0.5), lineWidth: 1))
            .padding(10)
            Spacer()
        }
    }

    private func localized(_ key: String) -> String { localization.string(key) }
}

// MARK: - State

@MainActor
final class CodeEditorState: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// 5 MB cap — anything larger refuses to load (would block the UI thread
    /// during string conversion and balloon memory). The user can still open
    /// externally from the file tree context menu.
    private static let maxLoadableBytes: Int = 5 * 1024 * 1024

    let url: URL
    @Published private(set) var phase: Phase = .loading
    @Published var bufferContents: String = ""
    @Published private(set) var diskContents: String = ""
    @Published var isEditable: Bool = true
    @Published var saveError: String?
    @Published var viewMode: EditorViewMode

    var isDirty: Bool { bufferContents != diskContents }
    var isMarkdown: Bool {
        WorkspacePreviewContent.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Highlightr language identifier inferred from the file extension /
    /// basename, or `nil` when no syntax mode applies (plain text).
    var languageHint: String? {
        SyntaxLanguage.identifier(for: url)
    }

    init(url: URL) {
        self.url = url
        // Markdown defaults to rendered preview; everything else to source.
        let ext = url.pathExtension.lowercased()
        self.viewMode = WorkspacePreviewContent.markdownExtensions.contains(ext) ? .preview : .source
    }

    func load() async {
        phase = .loading
        saveError = nil
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = (attrs[.size] as? NSNumber)?.intValue, size > Self.maxLoadableBytes {
                phase = .failed(String(format: NSLocalizedString("editor.tooLarge", value: "File too large to preview (%d MB > 5 MB cap).", comment: ""), size / (1024 * 1024)))
                return
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                phase = .failed(NSLocalizedString("editor.notUTF8", value: "File is not valid UTF-8 text.", comment: ""))
                return
            }
            diskContents = text
            bufferContents = text
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func save() async {
        guard isDirty else { return }
        do {
            try bufferContents.write(to: url, atomically: true, encoding: .utf8)
            diskContents = bufferContents
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func discard() {
        bufferContents = diskContents
    }
}

// MARK: - NSTextView wrapper

private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let language: String?

    static let backgroundFill = NSColor(red: 0.085, green: 0.095, blue: 0.115, alpha: 1)
    static let foregroundFill = NSColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1)
    static let highlightTheme = "atom-one-dark"

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = CodeAttributedString()
        textStorage.highlightr.setTheme(to: Self.highlightTheme)
        textStorage.highlightr.theme.codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textStorage.language = language

        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.insertionPointColor = Self.foregroundFill
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.35)
        ]
        textView.backgroundColor = Self.backgroundFill
        textView.drawsBackground = true
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Self.backgroundFill
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let storage = textView.textStorage as? CodeAttributedString, storage.language != language {
            storage.language = language
        }
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
        }
        textView.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - Markdown preview

private struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        loadIfChanged(webView: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadIfChanged(webView: webView, context: context)
    }

    private func loadIfChanged(webView: WKWebView, context: Context) {
        // Skip reload when neither the markdown nor the baseURL changed —
        // re-rendering on every keystroke is expensive and flashes the view.
        if context.coordinator.lastMarkdown == markdown,
           context.coordinator.lastBaseURL == baseURL {
            return
        }
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastBaseURL = baseURL
        let html = MarkdownToHTMLRenderer.renderDocument(markdown, title: baseURL.lastPathComponent)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastMarkdown: String?
        var lastBaseURL: URL?
    }
}

