//
//  GitSourceControlPanel.swift
//  Liney
//
//  VS Code-style Source Control panel: branch picker, commit composer,
//  Pull/Push, collapsible Changes / Pull Requests / History sections.
//

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
    @Published var lastActionMessage: String?

    @Published var changesExpanded: Bool = true
    @Published var prsExpanded: Bool = false
    @Published var historyExpanded: Bool = true

    let diffState = DiffWindowState()
    let historyState = HistoryWindowState()
    private let svc = GitSourceControlService()
    private var pollTask: Task<Void, Never>?

    var stagedEntries: [GitStatusEntry] { entries.filter { $0.isStaged } }
    var unstagedEntries: [GitStatusEntry] { entries.filter { !$0.isStaged } }
    var changeCount: Int {
        // Unique paths
        var seen = Set<String>()
        var n = 0
        for e in entries where !seen.contains(e.path) { seen.insert(e.path); n += 1 }
        return n
    }

    func bind(worktreePath: String?, branchName: String) {
        self.worktreePath = worktreePath
        self.currentBranch = branchName
        diffState.load(
            worktreePath: worktreePath,
            branchName: branchName,
            emptyStateMessage: "Working directory is clean."
        )
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
            return
        }
        do {
            async let st = svc.status(in: cwd)
            async let br = svc.branches(in: cwd)
            async let ab = svc.aheadBehind(in: cwd)
            async let cur = svc.currentBranchName(in: cwd)
            self.entries = try await st
            self.branches = try await br
            let abv = try await ab
            self.ahead = abv.ahead
            self.behind = abv.behind
            self.currentBranch = (try? await cur) ?? self.currentBranch
            diffState.refresh()
        } catch {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        await runWriteOp(setBusy: true) {
            let out = try await self.svc.push(in: cwd)
            await MainActor.run { self.lastActionMessage = "Pushed.\n" + out }
        }
    }

    func pull() async {
        guard let cwd = worktreePath else { return }
        await runWriteOp(setBusy: true) {
            let out = try await self.svc.pull(in: cwd)
            await MainActor.run { self.lastActionMessage = "Pulled.\n" + out }
        }
    }

    func checkout(_ branch: String) async {
        guard let cwd = worktreePath else { return }
        await runWriteOp(setBusy: true) {
            try await self.svc.checkout(branch: branch, in: cwd)
        }
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
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    Divider()
                    changesSection
                    Divider()
                    prsSection
                    Divider()
                    historySection
                }
            }
        }
        .background(LineyTheme.appBackground)
        .overlay(alignment: .bottom) {
            if let err = vm.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Header (branch picker + create PR + tools)

    private var header: some View {
        HStack(spacing: 8) {
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
                                    Image(systemName: b.isCurrent ? "checkmark" : "")
                                    Text(b.name)
                                }
                            }
                        }
                    }
                    Section("Remote") {
                        ForEach(vm.branches.filter { $0.isRemote }) { b in
                            Button(b.name) {
                                Task { await vm.checkout(b.name) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                    Text(vm.currentBranch.isEmpty ? "—" : vm.currentBranch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)

            Button {
                // TODO: gh pr create
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                    Text("Create PR")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                Task { await vm.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LineyTheme.chromeBackground)
    }

    // MARK: - Commit composer

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.1))
                    .frame(minHeight: 70)
                if vm.commitMessage.isEmpty {
                    Text("Commit message (⌘↵ to commit on \(vm.currentBranch))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.commitMessage)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 70)
                    .onSubmit {
                        Task { await vm.commit() }
                    }
            }

            HStack(spacing: 6) {
                Button {
                    Task { await vm.commit() }
                } label: {
                    HStack { Image(systemName: "checkmark"); Text("Commit") }
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                .disabled(vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)

                Button {
                    Task { await vm.pull() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("Pull")
                        if vm.behind > 0 {
                            Text("\(vm.behind)").font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                    .frame(minWidth: 70, minHeight: 26)
                }
                .disabled(vm.isBusy)

                Button {
                    Task { await vm.push() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                        Text("Push")
                        if vm.ahead > 0 {
                            Text("\(vm.ahead)").font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                        }
                    }
                    .frame(minWidth: 70, minHeight: 26)
                }
                .disabled(vm.isBusy)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Changes section

    private var changesSection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                title: "Changes",
                count: vm.changeCount,
                expanded: $vm.changesExpanded,
                trailing: {
                    AnyView(
                        HStack(spacing: 8) {
                            Button {
                                Task { await vm.stageAll() }
                            } label: { Image(systemName: "plus") }
                                .buttonStyle(.plain)
                                .help("Stage all changes")
                        }
                    )
                }
            )
            if vm.changesExpanded {
                LazyVStack(spacing: 0) {
                    let unique = Array(Dictionary(grouping: vm.entries, by: { $0.path }).values
                        .map { $0.sorted { $0.isStaged && !$1.isStaged } }
                        .compactMap { $0.first }
                        .sorted { $0.path < $1.path })
                    ForEach(unique) { entry in
                        ChangeRow(entry: entry, vm: vm)
                    }
                }
            }
        }
    }

    // MARK: - PRs section

    private var prsSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "Pull Requests", count: 0, expanded: $vm.prsExpanded, trailing: { AnyView(EmptyView()) })
            if vm.prsExpanded {
                VStack(spacing: 8) {
                    Text("Pull requests not synced yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Sync now") {
                        // TODO: gh pr list
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - History section

    private var historySection: some View {
        VStack(spacing: 0) {
            sectionHeader(
                title: "History",
                count: vm.historyState.commits.count,
                expanded: $vm.historyExpanded,
                trailing: {
                    AnyView(
                        Button {
                            vm.historyState.refresh()
                        } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain)
                    )
                }
            )
            if vm.historyExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(vm.historyState.commits.prefix(50), id: \.id) { commit in
                        CommitRow(commit: commit)
                    }
                    if vm.historyState.commits.isEmpty && vm.historyState.isLoadingCommits {
                        ProgressView().padding(10)
                    }
                }
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        trailing: () -> AnyView
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.2), in: Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LineyTheme.chromeBackground.opacity(0.5))
    }
}

// MARK: - Change row

private struct ChangeRow: View {
    let entry: GitStatusEntry
    let vm: GitSourceControlViewModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.displayCode)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 14)
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(entry.path)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if hovering {
                if entry.isStaged {
                    Button {
                        Task { await vm.unstage([entry.path]) }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help("Unstage")
                } else {
                    Button {
                        Task { await vm.stage([entry.path]) }
                    } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                        .help("Stage")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(hovering ? Color.gray.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture {
            vm.diffState.selectedFileID = entry.path
            vm.diffState.updateDocumentSelection(for: entry.path)
        }
    }

    private var color: Color {
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

// MARK: - Commit row

private struct CommitRow: View {
    let commit: GitHistoryCommit

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(commit.authorName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(commit.relativeDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
