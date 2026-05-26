//
//  WorkspaceCodeEditorView.swift
//  Liney
//

import AppKit
import Combine
import SwiftUI

/// Plain-text / source-code editor for the right-hand preview panel. Loads a
/// file from disk into an in-memory buffer, lets the user edit it (when not
/// locked), and writes the buffer back atomically on save. No syntax
/// highlighting in this Phase 1; that lives behind a follow-up that introduces
/// a TreeSitter / Highlightr dependency.
struct WorkspaceCodeEditorView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @StateObject private var state: CodeEditorState
    let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _state = StateObject(wrappedValue: CodeEditorState(url: url))
        self.onClose = onClose
    }

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
                    CodeTextView(
                        text: Binding(
                            get: { state.bufferContents },
                            set: { state.bufferContents = $0 }
                        ),
                        isEditable: state.isEditable
                    )
                case .failed(let message):
                    errorOverlay(message)
                }

                if let saveError = state.saveError {
                    saveErrorBanner(saveError)
                }
            }
        }
        .background(LineyTheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LineyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: state.url) { await state.load() }
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

            iconButton("xmark.circle.fill",
                       help: localized("editor.close"),
                       tint: LineyTheme.mutedText) {
                onClose()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(LineyTheme.paneHeaderBackground)
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
    @Published var isEditable: Bool = false
    @Published var saveError: String?

    var isDirty: Bool { bufferContents != diskContents }

    init(url: URL) { self.url = url }

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

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true
        textView.string = text

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
        }
        textView.isEditable = isEditable
        scrollView.verticalRulerView?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

// MARK: - Line number ruler

private final class LineNumberRulerView: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invalidate),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invalidate),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    @objc private func invalidate() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let borderX = bounds.width - 0.5
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        path.move(to: NSPoint(x: borderX, y: rect.minY))
        path.line(to: NSPoint(x: borderX, y: rect.maxY))
        path.stroke()

        let nsText = textView.string as NSString
        guard nsText.length > 0 else {
            drawNumber(1, atY: textView.textContainerInset.height - (scrollView?.contentView.bounds.origin.y ?? 0))
            return
        }

        let visibleOrigin = scrollView?.contentView.bounds.origin ?? .zero
        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        if charRange.location > 0 {
            nsText.enumerateSubstrings(
                in: NSRange(location: 0, length: charRange.location),
                options: [.byLines, .substringNotRequired]
            ) { _, _, _, _ in
                lineNumber += 1
            }
        }

        let inset = textView.textContainerInset.height

        nsText.enumerateSubstrings(
            in: charRange,
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.origin.y + inset - visibleOrigin.y
            self.drawNumber(lineNumber, atY: y)
            lineNumber += 1
        }
    }

    private func drawNumber(_ number: Int, atY y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let string = NSAttributedString(string: "\(number)", attributes: attrs)
        let size = string.size()
        string.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1))
    }
}
