//
//  GitSourceControlPanel.swift
//  Liney
//
//  VS Code-style Source Control panel with inline mini-tabs.
//

import Combine
import SwiftUI

// MARK: - Tab model

enum SourceControlTab: Hashable {
    case changes
    case history
    case fileDiff(path: String)
    case commitDetail(hash: String, shortHash: String, subject: String)

    var title: String {
        switch self {
        case .changes: return "Changes"
        case .history: return "History"
        case .fileDiff(let p): return (p as NSString).lastPathComponent
        case .commitDetail(_, let s, _): return s
        }
    }
    var icon: String {
        switch self {
        case .changes: return "list.bullet.indent"
        case .history: return "clock.arrow.circlepath"
        case .fileDiff: return "doc.text.magnifyingglass"
        case .commitDetail: return "scroll"
        }
    }
    var isClosable: Bool {
        switch self {
        case .changes, .history: return false
        default: return true
        }
    }
}

@MainActor
final class GitSourceControlViewModel: ObservableObject {
    @Published var worktreePath: String?
    @Published var currentBranch: String = ""
    @Published var branches: [GitBranchInfo] = []
    @Published var entries: [GitStatusEntry] = []
    @Published var commitMessage: String = ""
    @Published var ahead: Int = 0
    @Published var behind: Int = 0
    @Published var isBusy: Bool = false
    @Published var errorMessage: String?
    @Published var fileStats: [String: (Int, Int)] = [:]
    @Published var refsMap: [String: [String]] = [:]

    @Published var selectedHistoryCommitID: String?
    @Published var openTabs: [SourceControlTab] = [.changes, .history]
    @Published var activeTab: SourceControlTab = .changes

    /// Cache of working-tree per-file patches (raw text).
    @Published var patchCache: [String: String] = [:]
    /// Cache of commit details (file list).
    @Published var commitFiles: [String: [DiffChangedFile]] = [:]
    /// Selected file per commit-detail tab.
    @Published var commitSelectedFile: [String: String] = [:]
    /// Per-(commit,file) patch cache.
    @Published var commitFilePatch: [String: String] = [:]

    let historyState = HistoryWindowState()
    private let svc = GitSourceControlService()
    private let repoSvc = GitRepositoryService()
    private var patchTasks: [String: Task<Void, Never>] = [:]

    var uniqueChanges: [GitStatusEntry] {
        var seenPath = Set<String>()
        var out: [GitStatusEntry] = []
        for e in entries.sorted(by: { ($0.isStaged ? 0 : 1) < ($1.isStaged ? 0 : 1) }) {
            if seenPath.insert(e.path).inserted { out.append(e) }
        }
        return out.sorted { $0.path < $1.path }
    }
    var changeCount: Int { uniqueChanges.count }

    func bind(worktreePath: String?, branchName: String) {
        self.worktreePath = worktreePath
        self.currentBranch = branchName
        self.selectedHistoryCommitID = nil
        // Clear caches scoped to old workspace
        patchCache = [:]
        commitFiles = [:]
        commitSelectedFile = [:]
        commitFilePatch = [:]
        // Drop non-pinned tabs (Changes/History stay)
        openTabs = openTabs.filter { !$0.isClosable }
        if !openTabs.contains(activeTab) { activeTab = .changes }
        historyState.load(
            worktreePath: worktreePath,
            branchName: branchName,
            emptyStateMessage: "No commit history."
        )
        Task { await self.refresh() }
    }

    func refresh() async {
        guard let cwd = worktreePath else {
            entries = []; branches = []; fileStats = [:]; refsMap = [:]; return
        }
        do {
            async let st = svc.status(in: cwd)
            async let br = svc.branches(in: cwd)
            async let ab = svc.aheadBehind(in: cwd)
            async let cur = svc.currentBranchName(in: cwd)
            async let ns = svc.numstat(in: cwd)
            async let rm = svc.refsMap(in: cwd)
            self.entries = try await st
            self.branches = try await br
            let abv = try await ab
            self.ahead = abv.ahead
            self.behind = abv.behind
            self.currentBranch = (try? await cur) ?? self.currentBranch
            self.fileStats = (try? await ns) ?? [:]
            self.refsMap = (try? await rm) ?? [:]
            // Bust working-tree patch cache (working-tree may have changed)
            patchCache = [:]
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Tabs

    func openFileDiffTab(_ path: String) {
        let tab = SourceControlTab.fileDiff(path: path)
        if !openTabs.contains(tab) { openTabs.append(tab) }
        activeTab = tab
        loadPatchIfNeeded(path)
    }

    func openCommitTab(_ commit: GitHistoryCommit) {
        let tab = SourceControlTab.commitDetail(hash: commit.hash, shortHash: commit.shortHash, subject: commit.subject)
        if !openTabs.contains(tab) { openTabs.append(tab) }
        activeTab = tab
        loadCommitFilesIfNeeded(commit.hash)
    }

    func closeTab(_ tab: SourceControlTab) {
        openTabs.removeAll { $0 == tab }
        if activeTab == tab {
            activeTab = openTabs.last ?? .changes
        }
    }

    // MARK: Loaders

    func loadPatchIfNeeded(_ path: String) {
        guard let cwd = worktreePath, patchCache[path] == nil else { return }
        patchTasks[path]?.cancel()
        patchTasks[path] = Task { @MainActor in
            do {
                let p = try await self.svc.diffPatch(for: path, in: cwd)
                self.patchCache[path] = p.isEmpty ? "(no diff)" : p
            } catch {
                self.patchCache[path] = "Error: \(error.localizedDescription)"
            }
        }
    }

    func loadCommitFilesIfNeeded(_ hash: String) {
        guard let cwd = worktreePath, commitFiles[hash] == nil else { return }
        Task { @MainActor in
            do {
                let raw = try await self.repoSvc.diffNameStatusBetweenCommits(
                    for: cwd, fromCommit: "\(hash)^", toCommit: hash
                )
                self.commitFiles[hash] = DiffChangedFile.parseNameStatus(raw)
            } catch {
                // First commit has no parent — diff against empty tree
                if let r2 = try? await self.repoSvc.diffNameStatusBetweenCommits(
                    for: cwd, fromCommit: "4b825dc642cb6eb9a060e54bf8d69288fbee4904", toCommit: hash
                ) {
                    self.commitFiles[hash] = DiffChangedFile.parseNameStatus(r2)
                } else {
                    self.commitFiles[hash] = []
                }
            }
        }
    }

    func loadCommitFilePatchIfNeeded(commit: String, path: String) {
        let key = commit + "\u{0000}" + path
        guard let cwd = worktreePath, commitFilePatch[key] == nil else { return }
        Task { @MainActor in
            do {
                let p = try await self.repoSvc.diffPatchBetweenCommits(
                    for: cwd, filePath: path, fromCommit: "\(commit)^", toCommit: commit
                )
                self.commitFilePatch[key] = p.isEmpty ? "(no diff)" : p
            } catch {
                self.commitFilePatch[key] = "Error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Git ops

    func stage(_ paths: [String]) async {
        guard let cwd = worktreePath else { return }
        await runWriteOp { try await self.svc.stage(paths: paths, in: cwd) }
    }
    func unstage(_ paths: [String]) async {
        guard let cwd = worktreePath else { return }
        await runWriteOp { try await self.svc.unstage(paths: paths, in: cwd) }
    }
    func stageAll() async {
        guard let cwd = worktreePath else { return }
        await runWriteOp { try await self.svc.stageAll(in: cwd) }
    }
    func commit() async {
        guard let cwd = worktreePath else { return }
        let msg = commitMessage
        await runWriteOp(setBusy: true) {
            try await self.svc.commit(message: msg, autoStageIfEmpty: true, in: cwd)
            await MainActor.run { self.commitMessage = "" }
        }
    }
    func push() async {
        guard let cwd = worktreePath else { return }
        await runWriteOp(setBusy: true) { _ = try await self.svc.push(in: cwd) }
    }
    func pull() async {
        guard let cwd = worktreePath else { return }
        await runWriteOp(setBusy: true) { _ = try await self.svc.pull(in: cwd) }
    }
    func checkout(_ branch: String) async {
        guard let cwd = worktreePath else { return }
        await runWriteOp(setBusy: true) { try await self.svc.checkout(branch: branch, in: cwd) }
    }

    private func runWriteOp(setBusy: Bool = false, _ op: @escaping () async throws -> Void) async {
        if setBusy { isBusy = true }
        errorMessage = nil
        do {
            try await op()
            await refresh()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if setBusy { isBusy = false }
    }
}

// MARK: - Panel

struct GitSourceControlPanel: View {
    @ObservedObject var vm: GitSourceControlViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            commitComposer
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)
            Divider()
            tabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LineyTheme.appBackground)
        .overlay(alignment: .bottom) {
            if let err = vm.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                if vm.branches.isEmpty {
                    Text("No branches")
                } else {
                    Section("Local") {
                        ForEach(vm.branches.filter { !$0.isRemote }) { b in
                            Button {
                                Task { await vm.checkout(b.name) }
                            } label: {
                                HStack {
                                    if b.isCurrent { Image(systemName: "checkmark") }
                                    Text(b.name)
                                }
                            }
                        }
                    }
                    Section("Remote") {
                        ForEach(vm.branches.filter { $0.isRemote }) { b in
                            Button(b.name) { Task { await vm.checkout(b.name) } }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(vm.currentBranch.isEmpty ? "—" : vm.currentBranch)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 200, alignment: .leading)
            Spacer()
            Button {
                Task { await vm.refresh() }
            } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(LineyTheme.chromeBackground)
    }

    // MARK: Commit composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.1)).frame(minHeight: 56)
                if vm.commitMessage.isEmpty {
                    Text("Commit message (⌘↵ to commit on \(vm.currentBranch))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6).allowsHitTesting(false)
                }
                TextEditor(text: $vm.commitMessage)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(4).frame(minHeight: 56)
            }
            HStack(spacing: 5) {
                Button { Task { await vm.commit() } } label: {
                    HStack(spacing: 4) { Image(systemName: "checkmark"); Text("Commit") }
                        .font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 22)
                }
                .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)
                Button { Task { await vm.pull() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                        Text("Pull")
                        if vm.behind > 0 { CountChip(n: vm.behind) }
                    }
                    .font(.system(size: 11)).frame(minWidth: 56, minHeight: 22)
                }.disabled(vm.isBusy)
                Button { Task { await vm.push() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                        Text("Push")
                        if vm.ahead > 0 { CountChip(n: vm.ahead) }
                    }
                    .font(.system(size: 11)).frame(minWidth: 56, minHeight: 22)
                }.disabled(vm.isBusy)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(vm.openTabs, id: \.self) { tab in
                    TabChip(tab: tab, active: vm.activeTab == tab) {
                        vm.activeTab = tab
                    } onClose: {
                        vm.closeTab(tab)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 26)
        .background(LineyTheme.chromeBackground.opacity(0.6))
    }

    // MARK: Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch vm.activeTab {
        case .changes:
            ChangesTabContent(vm: vm)
        case .history:
            HistoryTabContent(vm: vm)
        case .fileDiff(let path):
            FileDiffTabContent(path: path, vm: vm)
        case .commitDetail(let hash, _, _):
            CommitDetailTabContent(commitHash: hash, vm: vm)
        }
    }
}

// MARK: Tab chip

private struct TabChip: View {
    let tab: SourceControlTab
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tab.icon).font(.system(size: 9))
            Text(tab.title).font(.system(size: 10, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            if tab.isClosable && (hovering || active) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain)
                .opacity(0.7)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(active ? LineyTheme.appBackground : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(active ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .frame(maxWidth: 180)
    }
}

private struct CountChip: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.25), in: Capsule())
    }
}

// MARK: - Changes tab

private struct ChangesTabContent: View {
    @ObservedObject var vm: GitSourceControlViewModel
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("\(vm.changeCount) changed")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await vm.stageAll() }
                    } label: { Image(systemName: "plus").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("Stage all")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                ForEach(vm.uniqueChanges) { entry in
                    ChangeRow(entry: entry, vm: vm)
                }
                if vm.uniqueChanges.isEmpty {
                    Text("Working directory is clean.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(20)
                }
            }
        }
    }
}

private struct ChangeRow: View {
    let entry: GitStatusEntry
    @ObservedObject var vm: GitSourceControlViewModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.displayCode)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor).frame(width: 12)
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(entry.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let stats = vm.fileStats[entry.path] {
                Text("+\(stats.0)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.green)
                Text("-\(stats.1)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.red)
            }
            if hovering {
                if entry.isStaged {
                    Button { Task { await vm.unstage([entry.path]) } } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11))
                    }.buttonStyle(.plain).help("Unstage")
                } else {
                    Button { Task { await vm.stage([entry.path]) } } label: {
                        Image(systemName: "plus.circle").font(.system(size: 11))
                    }.buttonStyle(.plain).help("Stage")
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(hovering ? Color.gray.opacity(0.10) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture { vm.openFileDiffTab(entry.path) }
    }

    private var statusColor: Color {
        switch entry.displayCode {
        case "M": return .yellow
        case "A": return .green
        case "D": return .red
        case "U": return .green
        case "R": return .blue
        default: return .secondary
        }
    }
}

// MARK: - History tab

private struct HistoryTabContent: View {
    @ObservedObject var vm: GitSourceControlViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("\(vm.historyState.commits.count) commits")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { vm.historyState.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)

                ForEach(vm.historyState.commits.prefix(200), id: \.id) { commit in
                    CommitRow(
                        commit: commit,
                        refs: vm.refsMap[commit.hash] ?? [],
                        isSelected: vm.selectedHistoryCommitID == commit.id
                    )
                    .onTapGesture(count: 2) { vm.openCommitTab(commit) }
                    .onTapGesture(count: 1) { vm.selectedHistoryCommitID = commit.id }
                    .contextMenu {
                        Button("Open commit") { vm.openCommitTab(commit) }
                    }
                }
                if vm.historyState.commits.isEmpty && vm.historyState.isLoadingCommits {
                    ProgressView().padding(10).controlSize(.small)
                }
            }
        }
    }
}

private struct CommitRow: View {
    let commit: GitHistoryCommit
    let refs: [String]
    let isSelected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(Color.accentColor.opacity(0.6)).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).font(.system(size: 11)).lineLimit(1)
                if !refs.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(refs.prefix(4), id: \.self) { ref in RefChip(ref: ref) }
                    }
                }
                HStack(spacing: 5) {
                    Text(commit.authorName).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(commit.relativeDate).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct RefChip: View {
    let ref: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text(refDisplay).font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }
    private var icon: String {
        if ref.contains("/") { return "cloud" }
        if ref.hasPrefix("tag:") { return "tag" }
        if ref == "HEAD" { return "arrow.right" }
        return "arrow.triangle.branch"
    }
    private var refDisplay: String { ref.hasPrefix("tag:") ? String(ref.dropFirst(4)) : ref }
    private var tint: Color {
        if ref == "HEAD" { return .blue }
        if ref.contains("/") { return .purple }
        if ref.hasPrefix("tag:") { return .orange }
        return .green
    }
}

// MARK: - File diff tab content (working tree file)

private struct FileDiffTabContent: View {
    let path: String
    @ObservedObject var vm: GitSourceControlViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(LineyTheme.chromeBackground.opacity(0.5))
            DiffPatchView(patch: vm.patchCache[path])
                .onAppear { vm.loadPatchIfNeeded(path) }
        }
    }
}

// MARK: - Commit detail tab content

private struct CommitDetailTabContent: View {
    let commitHash: String
    @ObservedObject var vm: GitSourceControlViewModel

    private var files: [DiffChangedFile] { vm.commitFiles[commitHash] ?? [] }
    private var selectedFile: String? { vm.commitSelectedFile[commitHash] }

    var body: some View {
        VSplitView {
            // Top: file list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if files.isEmpty && vm.commitFiles[commitHash] == nil {
                        HStack { ProgressView().controlSize(.small); Spacer() }
                            .padding(10)
                    } else if files.isEmpty {
                        Text("No file changes in this commit.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
                    } else {
                        ForEach(files) { file in
                            CommitFileRow(
                                file: file,
                                isSelected: selectedFile == file.id
                            )
                            .onTapGesture {
                                vm.commitSelectedFile[commitHash] = file.id
                                vm.loadCommitFilePatchIfNeeded(commit: commitHash, path: file.newPath ?? file.oldPath ?? "")
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 100, idealHeight: 150)
            // Bottom: diff
            if let sel = selectedFile, let f = files.first(where: { $0.id == sel }) {
                let key = commitHash + "\u{0000}" + (f.newPath ?? f.oldPath ?? "")
                DiffPatchView(patch: vm.commitFilePatch[key])
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text",
                                       description: Text("Pick a file above to view its diff."))
                    .frame(minHeight: 80)
            }
        }
        .onAppear { vm.loadCommitFilesIfNeeded(commitHash) }
    }
}

private struct CommitFileRow: View {
    let file: DiffChangedFile
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(file.statusSymbol)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(diffStatusColor(file.status)).frame(width: 12)
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(file.displayName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Patch renderer

private struct DiffPatchView: View {
    let patch: String?
    var body: some View {
        if let patch {
            ScrollView([.horizontal, .vertical]) {
                Text(makeAttributed(patch))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Loading diff…").font(.system(size: 10)).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func makeAttributed(_ patch: String) -> AttributedString {
        var result = AttributedString()
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            var seg = AttributedString(line + "\n")
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("# ") {
                seg.foregroundColor = .secondary
            } else if line.hasPrefix("+") {
                seg.foregroundColor = .green
            } else if line.hasPrefix("-") {
                seg.foregroundColor = .red
            }
            result.append(seg)
        }
        return result
    }
}

private func diffStatusColor(_ s: DiffFileStatus) -> Color {
    switch s {
    case .modified: return .yellow
    case .added: return .green
    case .deleted: return .red
    case .renamed, .copied: return .blue
    case .unknown: return .secondary
    }
}
