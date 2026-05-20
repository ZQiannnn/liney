//
//  WorkspaceFileTreeView.swift
//  Liney
//
//  Author: everettjf
//

import AppKit
import SwiftUI

/// Left-hand directory tree column. Its root follows the focused terminal pane's
/// current working directory, so a `cd` in the terminal automatically re-roots
/// the tree. Clicking a Markdown or HTML file opens it in the preview panel.
struct WorkspaceFileTreeView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var sessionController: WorkspaceSessionController

    var body: some View {
        if let paneID = sessionController.focusedPaneID,
           let session = sessionController.session(for: paneID) {
            FileTreeFollowingSession(workspace: workspace, session: session)
        } else {
            FileTreeContent(workspace: workspace, rootPath: workspace.activeWorktreePath)
        }
    }
}

/// Observes the focused session so a reported working-directory change re-roots
/// the tree.
private struct FileTreeFollowingSession: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var session: ShellSession

    var body: some View {
        FileTreeContent(workspace: workspace, rootPath: session.effectiveWorkingDirectory)
    }
}

private struct FileTreeContent: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject var workspace: WorkspaceModel
    let rootPath: String

    @State private var selectedPath: String?
    @State private var showsHidden = false
    @State private var reloadToken = UUID()

    private func localized(_ key: String) -> String { localization.string(key) }

    private var rootURL: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LineyTheme.border)

            if DirectoryTreeLoader.isReadableDirectory(rootPath) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FileTreeDirectoryChildren(
                            directoryURL: rootURL,
                            depth: 0,
                            showsHidden: showsHidden,
                            selectedPath: $selectedPath,
                            onOpen: open(entry:),
                            onCommand: handle(command:for:),
                            reloadToken: reloadToken
                        )
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState
            }
        }
        .background(LineyTheme.sidebarBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LineyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LineyTheme.localAccent)

            Text(rootURL.lastPathComponent.isEmpty ? rootPath : rootURL.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LineyTheme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .help(rootPath)

            Spacer(minLength: 2)

            headerButton("eye\(showsHidden ? ".fill" : "")", help: localized("fileTree.toggleHidden")) {
                showsHidden.toggle()
            }
            headerButton("arrow.clockwise", help: localized("fileTree.refresh")) {
                reloadToken = UUID()
            }
            headerButton("xmark", help: localized("fileTree.hide")) {
                workspace.isFileTreePresented = false
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(LineyTheme.paneHeaderBackground)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(LineyTheme.secondaryText)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(LineyTheme.mutedText)
            Text(localized("fileTree.unavailable"))
                .font(.system(size: 12))
                .foregroundStyle(LineyTheme.mutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Actions

    private func open(entry: DirectoryTreeEntry) {
        selectedPath = entry.url.path
        guard !entry.isDirectory else { return }
        if let content = WorkspacePreviewContent.makeFile(entry.url) {
            workspace.openPreview(content)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    private func handle(command: FileTreeCommand, for entry: DirectoryTreeEntry) {
        switch command {
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        case .openExternal:
            NSWorkspace.shared.open(entry.url)
        case .openInPreview:
            if let content = WorkspacePreviewContent.makeFile(entry.url) {
                workspace.openPreview(content)
            }
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        case .changeDirectory:
            changeDirectory(to: entry.url)
        }
    }

    private func changeDirectory(to url: URL) {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard let paneID = workspace.sessionController.focusedPaneID,
              let session = workspace.sessionController.session(for: paneID) else { return }
        let escaped = directory.path.replacingOccurrences(of: "'", with: "'\\''")
        session.sendShellCommand("cd '\(escaped)'")
    }
}

enum FileTreeCommand {
    case reveal
    case openExternal
    case openInPreview
    case copyPath
    case changeDirectory
}

/// Lazily lists and renders the children of one directory.
private struct FileTreeDirectoryChildren: View {
    let directoryURL: URL
    let depth: Int
    let showsHidden: Bool
    @Binding var selectedPath: String?
    let onOpen: (DirectoryTreeEntry) -> Void
    let onCommand: (FileTreeCommand, DirectoryTreeEntry) -> Void
    let reloadToken: UUID

    @State private var entries: [DirectoryTreeEntry] = []
    @State private var didLoad = false

    var body: some View {
        ForEach(entries) { entry in
            FileTreeRow(
                entry: entry,
                depth: depth,
                showsHidden: showsHidden,
                selectedPath: $selectedPath,
                onOpen: onOpen,
                onCommand: onCommand,
                reloadToken: reloadToken
            )
        }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: reloadToken) { _, _ in reload() }
        .onChange(of: showsHidden) { _, _ in reload() }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        reload()
    }

    private func reload() {
        let url = directoryURL
        let hidden = showsHidden
        Task.detached(priority: .userInitiated) {
            let loaded = DirectoryTreeLoader.entries(at: url, includesHidden: hidden)
            await MainActor.run { entries = loaded }
        }
    }
}

private struct FileTreeRow: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let entry: DirectoryTreeEntry
    let depth: Int
    let showsHidden: Bool
    @Binding var selectedPath: String?
    let onOpen: (DirectoryTreeEntry) -> Void
    let onCommand: (FileTreeCommand, DirectoryTreeEntry) -> Void
    let reloadToken: UUID

    @State private var isExpanded = false
    @State private var isHovered = false

    private func localized(_ key: String) -> String { localization.string(key) }

    private var isSelected: Bool { selectedPath == entry.url.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if entry.isDirectory, isExpanded {
                FileTreeDirectoryChildren(
                    directoryURL: entry.url,
                    depth: depth + 1,
                    showsHidden: showsHidden,
                    selectedPath: $selectedPath,
                    onOpen: onOpen,
                    onCommand: onCommand,
                    reloadToken: reloadToken
                )
            }
        }
    }

    private var row: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LineyTheme.mutedText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
                .opacity(entry.isDirectory ? 1 : 0)

            Image(systemName: entry.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 15)

            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : LineyTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(depth) * 12 + 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { activate() }
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if entry.isPreviewable {
            Button(localized("fileTree.menu.openInPreview")) { onCommand(.openInPreview, entry) }
            Divider()
        }
        if entry.isDirectory {
            Button(localized("fileTree.menu.cdHere")) { onCommand(.changeDirectory, entry) }
        }
        Button(localized("fileTree.menu.reveal")) { onCommand(.reveal, entry) }
        Button(localized("fileTree.menu.openExternal")) { onCommand(.openExternal, entry) }
        Button(localized("fileTree.menu.copyPath")) { onCommand(.copyPath, entry) }
    }

    private func activate() {
        if entry.isDirectory {
            withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            selectedPath = entry.url.path
        } else {
            onOpen(entry)
        }
    }

    private var iconColor: Color {
        if entry.isDirectory { return LineyTheme.localAccent }
        if entry.isPreviewable { return LineyTheme.accent }
        return LineyTheme.mutedText
    }

    private var rowBackground: Color {
        if isSelected { return LineyTheme.accentMuted.opacity(0.55) }
        if isHovered { return LineyTheme.subtleFill }
        return .clear
    }
}
