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
/// locked), and writes the buffer back atomically on save. Adds a VSCode-style
/// find/replace bar (⌘F / ⌥⌘F) and a gutter ruler with line numbers.
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
        .background(keyboardShortcuts)
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
        VStack(spacing: 0) {
            if state.isFindBarVisible {
                FindReplaceBar(state: state)
            }
            CodeTextView(
                text: Binding(
                    get: { state.bufferContents },
                    set: { state.bufferContents = $0 }
                ),
                isEditable: state.isEditable,
                language: state.languageHint,
                controller: state.editorController,
                matches: state.matches,
                currentMatchIndex: state.currentMatchIndex
            )
        }
    }

    private var previewView: some View {
        MarkdownPreviewView(
            markdown: state.bufferContents,
            baseURL: state.url.deletingLastPathComponent()
        )
    }

    // Hidden buttons capture the keyboard shortcuts. Esc is only active while
    // the find bar is visible so it doesn't swallow Esc elsewhere.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { state.showFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { state.showReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Button("") { state.showReplace() }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { state.nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!state.isFindBarVisible)
            Button("") { state.prevMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!state.isFindBarVisible)
            if state.isFindBarVisible {
                Button("") { state.closeFindBar() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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

            // Find / Replace
            iconButton("magnifyingglass", help: localized("editor.find")) {
                state.showFind()
            }
            iconButton("text.magnifyingglass", help: localized("editor.replace")) {
                state.showReplace()
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

    // Find / Replace
    @Published var isFindBarVisible: Bool = false
    @Published var isReplaceMode: Bool = false
    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var caseSensitive: Bool = false
    @Published var useRegex: Bool = false
    @Published var wholeWord: Bool = false
    @Published private(set) var matches: [NSRange] = []
    @Published var currentMatchIndex: Int = -1
    /// Bumped whenever Cmd+F is hit so the bar refocuses the find field even
    /// when it was already visible.
    @Published var findFocusRequest: Int = 0
    /// Bumped whenever Cmd+Option+F is hit so the bar focuses the replace field.
    @Published var replaceFocusRequest: Int = 0

    let editorController = EditorController()
    private var cancellables: Set<AnyCancellable> = []

    var isDirty: Bool { bufferContents != diskContents }
    var isMarkdown: Bool {
        WorkspacePreviewContent.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Highlightr language identifier inferred from the file extension /
    /// basename, or `nil` when no syntax mode applies (plain text).
    /// Markdown is intentionally returned as `nil` for the source view —
    /// highlight.js's markdown grammar is recursive over nested code fences
    /// and inline patterns and blocks the main thread on real documents; the
    /// rendered preview is the canonical "rich" view for .md anyway.
    var languageHint: String? {
        if isMarkdown { return nil }
        return SyntaxLanguage.identifier(for: url)
    }

    init(url: URL) {
        self.url = url
        // Markdown defaults to rendered preview; everything else to source.
        let ext = url.pathExtension.lowercased()
        self.viewMode = WorkspacePreviewContent.markdownExtensions.contains(ext) ? .preview : .source

        // Recompute matches whenever the query, options, or buffer text change.
        Publishers.CombineLatest4($findText, $caseSensitive, $useRegex, $wholeWord)
            .dropFirst()
            .sink { [weak self] _, _, _, _ in self?.recomputeMatches(resetIndex: true) }
            .store(in: &cancellables)
        $bufferContents
            .dropFirst()
            .sink { [weak self] _ in self?.recomputeMatches(resetIndex: false) }
            .store(in: &cancellables)
        $isFindBarVisible
            .dropFirst()
            .sink { [weak self] visible in
                if visible { self?.recomputeMatches(resetIndex: true) }
                else { self?.clearMatches() }
            }
            .store(in: &cancellables)
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

    // MARK: Find / Replace

    func showFind() {
        isReplaceMode = false
        if !isFindBarVisible { isFindBarVisible = true }
        findFocusRequest &+= 1
    }

    func showReplace() {
        isReplaceMode = true
        if !isFindBarVisible { isFindBarVisible = true }
        replaceFocusRequest &+= 1
    }

    func closeFindBar() {
        isFindBarVisible = false
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
    }

    func prevMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
    }

    func replaceCurrent() {
        guard isEditable,
              !matches.isEmpty,
              currentMatchIndex >= 0,
              currentMatchIndex < matches.count else { return }
        let range = matches[currentMatchIndex]
        let replacement = computeReplacement(for: range)
        editorController.replace(range: range, with: replacement)
        // After the buffer mutates, $bufferContents triggers recomputeMatches.
        // currentMatchIndex stays put, so it now points to the next occurrence
        // (or gets clamped to -1 if none remain).
    }

    func replaceAll() {
        guard isEditable, !matches.isEmpty else { return }
        let ns = NSMutableString(string: bufferContents)
        for range in matches.reversed() {
            let replacement = computeReplacement(for: range)
            ns.replaceCharacters(in: range, with: replacement)
        }
        editorController.replaceAll(with: ns as String)
    }

    private func recomputeMatches(resetIndex: Bool) {
        guard isFindBarVisible, !findText.isEmpty else {
            clearMatches()
            return
        }
        let ranges = Self.findRanges(
            in: bufferContents,
            query: findText,
            caseSensitive: caseSensitive,
            useRegex: useRegex,
            wholeWord: wholeWord
        )
        matches = ranges
        if ranges.isEmpty {
            currentMatchIndex = -1
        } else if resetIndex || currentMatchIndex < 0 || currentMatchIndex >= ranges.count {
            currentMatchIndex = 0
        }
    }

    private func clearMatches() {
        if !matches.isEmpty { matches = [] }
        if currentMatchIndex != -1 { currentMatchIndex = -1 }
    }

    private func computeReplacement(for range: NSRange) -> String {
        guard useRegex else { return replaceText }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        var pattern = findText
        if wholeWord { pattern = "\\b" + pattern + "\\b" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return replaceText
        }
        let nsText = bufferContents as NSString
        guard range.location + range.length <= nsText.length else { return replaceText }
        let substring = nsText.substring(with: range)
        return re.stringByReplacingMatches(
            in: substring,
            range: NSRange(location: 0, length: (substring as NSString).length),
            withTemplate: replaceText
        )
    }

    static func findRanges(in text: String, query: String, caseSensitive: Bool, useRegex: Bool, wholeWord: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var pattern = useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b" + pattern + "\\b" }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let nsText = text as NSString
        var results: [NSRange] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            if let m = match, m.range.length > 0 { results.append(m.range) }
        }
        return results
    }
}

// MARK: - Editor controller (drives the NSTextView from state)

@MainActor
final class EditorController {
    weak var textView: NSTextView?

    func replace(range: NSRange, with replacement: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fullLen = storage.length
        guard range.location + range.length <= fullLen else { return }
        if tv.shouldChangeText(in: range, replacementString: replacement) {
            storage.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
            let after = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            tv.setSelectedRange(after)
            tv.scrollRangeToVisible(after)
        }
    }

    func replaceAll(with newText: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        if tv.shouldChangeText(in: fullRange, replacementString: newText) {
            storage.replaceCharacters(in: fullRange, with: newText)
            tv.didChangeText()
        }
    }

    func reveal(range: NSRange) {
        guard let tv = textView else { return }
        tv.scrollRangeToVisible(range)
        tv.setSelectedRange(range)
    }
}

// MARK: - Find / Replace bar

private struct FindReplaceBar: View {
    @ObservedObject var state: CodeEditorState
    @ObservedObject private var localization = LocalizationManager.shared
    @FocusState private var focused: Field?

    enum Field { case find, replace }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    state.isReplaceMode.toggle()
                    if state.isReplaceMode { state.replaceFocusRequest &+= 1 }
                } label: {
                    Image(systemName: state.isReplaceMode ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 18)
                        .foregroundStyle(LineyTheme.secondaryText)
                }
                .buttonStyle(.plain)

                fieldBox {
                    TextField(localized("editor.find.placeholder"), text: $state.findText)
                        .textFieldStyle(.plain)
                        .focused($focused, equals: .find)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { state.nextMatch() }
                }

                optionToggle(symbol: "textformat", on: $state.caseSensitive, help: localized("editor.find.caseSensitive"))
                optionToggle(symbol: "textformat.abc.dottedunderline", on: $state.wholeWord, help: localized("editor.find.wholeWord"))
                optionToggle(symbol: "asterisk", on: $state.useRegex, help: localized("editor.find.regex"))

                matchCount
                    .frame(minWidth: 64, alignment: .trailing)

                iconBtn("chevron.up", help: localized("editor.find.previous"), enabled: !state.matches.isEmpty) { state.prevMatch() }
                iconBtn("chevron.down", help: localized("editor.find.next"), enabled: !state.matches.isEmpty) { state.nextMatch() }
                iconBtn("xmark", help: localized("editor.find.close")) { state.closeFindBar() }
            }

            if state.isReplaceMode {
                HStack(spacing: 6) {
                    // Spacer to align with the chevron above.
                    Color.clear.frame(width: 14, height: 1)

                    fieldBox {
                        TextField(localized("editor.replace.placeholder"), text: $state.replaceText)
                            .textFieldStyle(.plain)
                            .focused($focused, equals: .replace)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { state.replaceCurrent() }
                    }

                    iconBtn("arrow.right.square",
                            help: localized("editor.find.replaceOne"),
                            enabled: state.isEditable && !state.matches.isEmpty) {
                        state.replaceCurrent()
                    }
                    iconBtn("text.append",
                            help: localized("editor.find.replaceAll"),
                            enabled: state.isEditable && !state.matches.isEmpty) {
                        state.replaceAll()
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(LineyTheme.paneHeaderBackground)
        .overlay(alignment: .bottom) {
            Divider().overlay(LineyTheme.border)
        }
        .onAppear { focused = state.isReplaceMode ? .replace : .find }
        .onChange(of: state.findFocusRequest) { _ in focused = .find }
        .onChange(of: state.replaceFocusRequest) { _ in focused = .replace }
    }

    @ViewBuilder
    private var matchCount: some View {
        if state.findText.isEmpty {
            EmptyView()
        } else if state.matches.isEmpty {
            Text(localized("editor.find.noResults"))
                .font(.system(size: 10))
                .foregroundStyle(LineyTheme.mutedText)
        } else {
            Text(String(format: localized("editor.find.matchCount"), state.currentMatchIndex + 1, state.matches.count))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LineyTheme.secondaryText)
        }
    }

    private func fieldBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(LineyTheme.subtleFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(LineyTheme.border.opacity(0.6), lineWidth: 0.5))
    }

    private func optionToggle(symbol: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .background(
                    on.wrappedValue ? LineyTheme.accent.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(on.wrappedValue ? LineyTheme.accent : LineyTheme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconBtn(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? LineyTheme.secondaryText : LineyTheme.mutedText.opacity(0.4))
        .disabled(!enabled)
        .help(help)
    }

    private func localized(_ key: String) -> String { localization.string(key) }
}

// MARK: - NSTextView wrapper

private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let language: String?
    let controller: EditorController
    let matches: [NSRange]
    let currentMatchIndex: Int

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

        let textView = GutteredTextView(frame: .zero, textContainer: textContainer)
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
        // NSTextView's built-in find bar would swallow Cmd+F before SwiftUI's
        // keyboardShortcut hidden Button can claim it; we render our own bar.
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Left inset = gutter width + visual padding before glyphs.
        textView.textContainerInset = NSSize(width: GutteredTextView.gutterWidth + 6, height: 12)
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

        controller.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        if let storage = textView.textStorage as? CodeAttributedString, storage.language != language {
            storage.language = language
        }
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
        }
        textView.isEditable = isEditable
        applyMatchHighlights(textView)
    }

    private func applyMatchHighlights(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let fullLen = (tv.string as NSString).length
        // Skip the no-op clear when there's nothing to clear — touching the
        // layout manager during the initial pass (before glyph layout has
        // finished) can defer the first draw.
        if matches.isEmpty {
            if fullLen > 0,
               lm.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: fullLen))
            }
            return
        }
        let fullRange = NSRange(location: 0, length: fullLen)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        let matchColor = NSColor.systemYellow.withAlphaComponent(0.30)
        let currentColor = NSColor.systemOrange.withAlphaComponent(0.55)
        for (idx, range) in matches.enumerated() {
            guard range.location >= 0,
                  range.length > 0,
                  range.location + range.length <= fullLen else { continue }
            lm.addTemporaryAttribute(
                .backgroundColor,
                value: idx == currentMatchIndex ? currentColor : matchColor,
                forCharacterRange: range
            )
        }
        if currentMatchIndex >= 0, currentMatchIndex < matches.count {
            let r = matches[currentMatchIndex]
            if r.location + r.length <= fullLen {
                tv.scrollRangeToVisible(r)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            (tv as? GutteredTextView)?.invalidateGutter()
        }
    }
}

// MARK: - Line-number gutter inside the text view
//
// We considered NSRulerView but it interacts badly with SwiftUI's NSScrollView
// hosting: installing a vertical ruler collapses the surrounding VStack
// (header / tab bar / content all vanished). Drawing the gutter inside the
// textView's own left textContainerInset sidesteps the scrollView's ruler
// pipeline entirely.
final class GutteredTextView: NSTextView {
    static let gutterWidth: CGFloat = 44
    static let gutterFill = NSColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    static let gutterSeparator = NSColor.black.withAlphaComponent(0.35)
    static let lineNumberColor = NSColor(red: 0.45, green: 0.48, blue: 0.55, alpha: 1)
    static let currentLineColor = NSColor(red: 0.85, green: 0.87, blue: 0.92, alpha: 1)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSelectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func handleSelectionChanged(_ note: Notification) {
        invalidateGutter()
    }

    func invalidateGutter() {
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: Self.gutterWidth, height: visibleRect.height))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGutter(dirtyRect: rect)
    }

    private func drawGutter(dirtyRect: NSRect) {
        guard let lm = layoutManager, let tc = textContainer else { return }

        let gutterRect = NSRect(x: 0, y: dirtyRect.minY, width: Self.gutterWidth, height: dirtyRect.height)
        Self.gutterFill.setFill()
        gutterRect.fill()
        Self.gutterSeparator.setFill()
        NSRect(x: Self.gutterWidth - 0.5, y: dirtyRect.minY, width: 0.5, height: dirtyRect.height).fill()

        let nsString = self.string as NSString
        let inset = textContainerInset.height
        // Map the dirty rect (textView coords) back to container coords for glyph lookup.
        let containerRect = NSRect(x: 0,
                                   y: dirtyRect.minY - inset,
                                   width: tc.size.width,
                                   height: dirtyRect.height)
        let glyphRange = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let cursorLine = Self.lineNumber(at: selectedRange().location, in: nsString)

        var paragraphIndex = Self.lineNumber(at: charRange.location, in: nsString)
        var charIndex = charRange.location

        while charIndex <= NSMaxRange(charRange), charIndex <= nsString.length {
            let paraRange = nsString.paragraphRange(for: NSRange(location: charIndex, length: 0))
            let paraGlyphRange = lm.glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
            let lineRect = lm.boundingRect(forGlyphRange: paraGlyphRange, in: tc)
            let yInTextView = lineRect.origin.y + inset

            let label = "\(paragraphIndex)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.labelFont,
                .foregroundColor: paragraphIndex == cursorLine ? Self.currentLineColor : Self.lineNumberColor
            ]
            let labelSize = label.size(withAttributes: attrs)
            let x = Self.gutterWidth - labelSize.width - 8
            let y = yInTextView + (lineRect.height - labelSize.height) / 2
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)

            paragraphIndex += 1
            charIndex = NSMaxRange(paraRange)
            if paraRange.length == 0 { break }
        }
    }

    static func lineNumber(at location: Int, in text: NSString) -> Int {
        let upper = min(max(location, 0), text.length)
        guard upper > 0 else { return 1 }
        var line = 1
        var idx = 0
        while idx < upper {
            let searchRange = NSRange(location: idx, length: upper - idx)
            let nl = text.range(of: "\n", options: [], range: searchRange)
            if nl.location == NSNotFound { break }
            line += 1
            idx = nl.location + nl.length
        }
        return line
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
