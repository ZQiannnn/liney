//
//  GitSourceControlPanel.swift
//  Liney
//
//  VS Code-style Source Control panel.
//

import Combine
import SwiftUI

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
    @Published var selectedPath: String?
    @Published var selectedHistoryCommitID: String?

    @Published var changesExpanded: Bool = true
    @Published var historyExpanded: Bool = true

    let historyState = HistoryWindowState()
    private let svc = GitSourceControlService()

    var uniqueChanges: [GitStatusEntry] {
        var seenPath = Set<String>()
        var out: [GitStatusEntry] = []
        // Sort so staged variant comes first per path
        for e in entries.sorted(by: { ($0.isStaged ? 0 : 1) < ($1.isStaged ? 0 : 1) }) {
            if seenPath.insert(e.path).inserted { out.append(e) }
        }
        return out.sorted { $0.path < $1.path }
    }
    var changeCount: Int { uniqueChanges.count }

    func bind(worktreePath: String?, branchName: String) {
        self.worktreePath = worktreePath
        self.currentBranch = branchName
        self.selectedPath = nil
        self.selectedHistoryCommitID = nil
        historyState.load(
            worktreePath: worktreePath,
            branchName: branchName,
            emptyStateMessage: "No commit history."
        )
        Task { await self.refresh() }
    }

    func refresh() async {
        guard let cwd = worktreePath else {
            entries = []
            branches = []
            fileStats = [:]
            refsMap = [:]
            return
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
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Open the standalone Diff window (auto-tabbed via macOS window grouping)
    /// with the given file pre-selected.
    func openDiffWindow(selecting path: String?) {
        selectedPath = path
        DiffWindowManager.shared.show(
            worktreePath: worktreePath,
            branchName: currentBranch,
            emptyStateMessage: "Working directory is clean."
        )
        if let path {
            // Wait briefly for the file list to load, then select.
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if DiffWindowManager.shared.state.changedFiles.contains(where: { $0.id == path }) {
                        DiffWindowManager.shared.state.selectedFileID = path
                        DiffWindowManager.shared.state.updateDocumentSelection(for: path)
                        return
                    }
                }
            }
        }
    }

    /// Select a commit inline (loads its file list via historyState).
    func selectHistoryCommit(_ id: String?) {
        if selectedHistoryCommitID == id {
            selectedHistoryCommitID = nil
            historyState.selectedCommitID = nil
            historyState.updateCommitSelection(for: nil)
            return
        }
        selectedHistoryCommitID = id
        historyState.selectedCommitID = id
        historyState.updateCommitSelection(for: id)
    }

    /// Open the standalone History window pre-positioned to the commit/file.
    func openHistoryWindow(commit: String?, file: String?) {
        HistoryWindowManager.shared.show(
            worktreePath: worktreePath,
            branchName: currentBranch,
            emptyStateMessage: "No commit history."
        )
        guard let commit else { return }
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if HistoryWindowManager.shared.state.commits.contains(where: { $0.id == commit }) {
                    HistoryWindowManager.shared.state.selectedCommitID = commit
                    HistoryWindowManager.shared.state.updateCommitSelection(for: commit)
                    if let file {
                        for _ in 0..<20 {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if HistoryWindowManager.shared.state.changedFiles.contains(where: { $0.id == file }) {
                                HistoryWindowManager.shared.state.selectedFileID = file
                                HistoryWindowManager.shared.state.updateDocumentSelection(for: file)
                                return
                            }
                        }
                    }
                    return
                }
            }
        }
    }

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

struct GitSourceControlPanel: View {
    @ObservedObject var vm: GitSourceControlViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    commitComposer
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                    Divider()
                    changesSection
                    Divider()
                    historySection
                }
            }
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
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(LineyTheme.chromeBackground)
    }

    // MARK: Commit composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.gray.opacity(0.1))
                    .frame(minHeight: 56)
                if vm.commitMessage.isEmpty {
                    Text("Commit message (⌘↵ to commit on \(vm.currentBranch))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.commitMessage)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 56)
            }

            HStack(spacing: 5) {
                Button {
                    Task { await vm.commit() }
                } label: {
                    HStack(spacing: 4) { Image(systemName: "checkmark"); Text("Commit") }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)

                Button {
                    Task { await vm.pull() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                        Text("Pull")
                        if vm.behind > 0 {
                            Text("\(vm.behind)").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                    .font(.system(size: 11))
                    .frame(minWidth: 56, minHeight: 22)
                }
                .disabled(vm.isBusy)

                Button {
                    Task { await vm.push() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                        Text("Push")
                        if vm.ahead > 0 {
                            Text("\(vm.ahead)").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                    .font(.system(size: 11))
                    .frame(minWidth: 56, minHeight: 22)
                }
                .disabled(vm.isBusy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Changes

    private var changesSection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                title: "Changes",
                count: vm.changeCount,
                expanded: $vm.changesExpanded
            ) {
                AnyView(
                    Button {
                        Task { await vm.stageAll() }
                    } label: { Image(systemName: "plus").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Stage all")
                )
            }
            if vm.changesExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(vm.uniqueChanges) { entry in
                        ChangeRow(entry: entry, vm: vm, isSelected: vm.selectedPath == entry.path)
                    }
                }
            }
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                title: "History",
                count: vm.historyState.commits.count,
                expanded: $vm.historyExpanded
            ) {
                AnyView(
                    Button {
                        vm.historyState.refresh()
                    } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                )
            }
            if vm.historyExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(vm.historyState.commits.prefix(80), id: \.id) { commit in
                        VStack(spacing: 0) {
                            CommitRow(
                                commit: commit,
                                refs: vm.refsMap[commit.hash] ?? [],
                                isSelected: vm.selectedHistoryCommitID == commit.id
                            )
                            .onTapGesture { vm.selectHistoryCommit(commit.id) }
                            if vm.selectedHistoryCommitID == commit.id {
                                CommitFileListView(vm: vm)
                                    .background(LineyTheme.chromeBackground.opacity(0.35))
                            }
                        }
                    }
                    if vm.historyState.commits.isEmpty && vm.historyState.isLoadingCommits {
                        ProgressView().padding(8).controlSize(.small)
                    }
                }
            }
        }
    }

    private func sectionHeader(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> AnyView
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.22), in: Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(LineyTheme.chromeBackground.opacity(0.5))
    }
}

// MARK: Change row

private struct ChangeRow: View {
    let entry: GitStatusEntry
    let vm: GitSourceControlViewModel
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.displayCode)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 12)
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(entry.path)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let stats = vm.fileStats[entry.path] {
                Text("+\(stats.0)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
                Text("-\(stats.1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if hovering {
                if entry.isStaged {
                    Button { Task { await vm.unstage([entry.path]) } } label: {
                        Image(systemName: "minus.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Unstage")
                } else {
                    Button { Task { await vm.stage([entry.path]) } } label: {
                        Image(systemName: "plus.circle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Stage")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.18) : (hovering ? Color.gray.opacity(0.10) : Color.clear))
        .onHover { hovering = $0 }
        .onTapGesture {
            vm.openDiffWindow(selecting: entry.path)
        }
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

// MARK: Inline file list for a selected history commit

private struct CommitFileListView: View {
    @ObservedObject var vm: GitSourceControlViewModel

    var body: some View {
        VStack(spacing: 0) {
            if vm.historyState.isLoadingFiles {
                HStack { ProgressView().controlSize(.small); Spacer() }
                    .padding(.horizontal, 22).padding(.vertical, 4)
            } else if vm.historyState.changedFiles.isEmpty {
                Text("No file changes in this commit.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.vertical, 4)
            } else {
                ForEach(vm.historyState.changedFiles) { file in
                    HStack(spacing: 6) {
                        Text(file.statusSymbol)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(diffStatusColor(file.status))
                            .frame(width: 12)
                        Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(file.displayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        vm.openHistoryWindow(commit: vm.selectedHistoryCommitID, file: file.id)
                    }
                    .background(Color.clear)
                }
            }
        }
    }
}

// MARK: Commit row

private struct CommitRow: View {
    let commit: GitHistoryCommit
    let refs: [String]
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: 11))
                    .lineLimit(1)
                if !refs.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(refs.prefix(4), id: \.self) { ref in
                            RefChip(ref: ref)
                        }
                    }
                }
                HStack(spacing: 5) {
                    Text(commit.authorName).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(commit.relativeDate).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}

private func diffStatusColor(_ s: DiffFileStatus) -> Color {
    switch s {
    case .modified: return .yellow
    case .added: return .green
    case .deleted: return .red
    case .renamed: return .blue
    case .copied: return .blue
    case .unknown: return .secondary
    }
}

private struct RefChip: View {
    let ref: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8))
            Text(refDisplay).font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }
    private var icon: String {
        if ref.contains("/") { return "cloud" }
        if ref.hasPrefix("tag:") { return "tag" }
        if ref == "HEAD" { return "arrow.right" }
        return "arrow.triangle.branch"
    }
    private var refDisplay: String {
        ref.hasPrefix("tag:") ? String(ref.dropFirst(4)) : ref
    }
    private var tint: Color {
        if ref == "HEAD" { return .blue }
        if ref.contains("/") { return .purple }
        if ref.hasPrefix("tag:") { return .orange }
        return .green
    }
}
