//
//  GitSourceControlService.swift
//  Liney
//
//  Source-control write ops (stage, commit, push, pull, checkout) and the
//  porcelain-v2 status parser used by the right-side Source Control panel.
//

import Foundation

struct GitStatusEntry: Identifiable, Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        case index
        case worktree
        case untracked
        case conflict
    }
    var id: String { "\(origin):\(path)" }
    let path: String
    let oldPath: String?
    let xy: String       // raw 2-char status code from porcelain v1
    let origin: Origin
    var displayCode: String {
        if origin == .untracked { return "U" }
        if origin == .conflict { return "!" }
        return String(xy.first ?? Character(" "))
    }
    var isStaged: Bool { origin == .index || origin == .conflict }
}

struct GitBranchInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
}

actor GitSourceControlService {
    private let runner = ShellCommandRunner()

    private func git(_ args: [String], cwd: String) async throws -> ShellCommandResult {
        try await runner.run(
            executable: "/usr/bin/env",
            arguments: ["git"] + args,
            currentDirectory: cwd,
            environment: ["LC_ALL": "en_US.UTF-8"]
        )
    }

    // MARK: - Status

    /// Parses `git status --porcelain=v1 -z` so renames are unambiguous.
    func status(in cwd: String) async throws -> [GitStatusEntry] {
        let r = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: cwd)
        guard r.exitCode == 0 else {
            throw GitServiceError.commandFailed(r.stderr.nonEmptyOrFallback("git status failed."))
        }
        return Self.parsePorcelainV1Z(r.stdout)
    }

    nonisolated static func parsePorcelainV1Z(_ raw: String) -> [GitStatusEntry] {
        var out: [GitStatusEntry] = []
        let records = raw.split(separator: "\u{0000}", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let rec = records[i]
            guard rec.count >= 3 else { i += 1; continue }
            let xy = String(rec.prefix(2))
            let path = String(rec.dropFirst(3))
            let x = xy.first!
            let y = xy.last!
            if x == "?" && y == "?" {
                out.append(.init(path: path, oldPath: nil, xy: xy, origin: .untracked))
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                out.append(.init(path: path, oldPath: nil, xy: xy, origin: .conflict))
            } else {
                // Renames in -z form: next record is the old path
                var oldPath: String?
                if x == "R" || y == "R" || x == "C" || y == "C" {
                    if i + 1 < records.count {
                        oldPath = records[i + 1]
                        i += 1
                    }
                }
                if x != " " { // staged
                    out.append(.init(path: path, oldPath: oldPath, xy: xy, origin: .index))
                }
                if y != " " { // worktree
                    out.append(.init(path: path, oldPath: oldPath, xy: xy, origin: .worktree))
                }
            }
            i += 1
        }
        return out
    }

    // MARK: - Stage / Unstage

    func stage(paths: [String], in cwd: String) async throws {
        guard !paths.isEmpty else { return }
        let r = try await git(["add", "--"] + paths, cwd: cwd)
        try Self.requireOK(r, "git add")
    }

    func stageAll(in cwd: String) async throws {
        let r = try await git(["add", "-A"], cwd: cwd)
        try Self.requireOK(r, "git add -A")
    }

    func unstage(paths: [String], in cwd: String) async throws {
        guard !paths.isEmpty else { return }
        let r = try await git(["reset", "HEAD", "--"] + paths, cwd: cwd)
        try Self.requireOK(r, "git reset HEAD")
    }

    func discard(paths: [String], in cwd: String) async throws {
        guard !paths.isEmpty else { return }
        let r = try await git(["checkout", "--"] + paths, cwd: cwd)
        try Self.requireOK(r, "git checkout --")
    }

    // MARK: - Commit / Push / Pull

    /// If nothing is staged, falls back to `commit -a -m` (matches VS Code behavior).
    func commit(message: String, autoStageIfEmpty: Bool = true, in cwd: String) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitServiceError.commandFailed("Commit message is empty.")
        }
        let st = try await status(in: cwd)
        let hasStaged = st.contains { $0.isStaged }
        var args = ["commit", "-m", trimmed]
        if !hasStaged && autoStageIfEmpty {
            args.insert("-a", at: 1)
        }
        let r = try await git(args, cwd: cwd)
        try Self.requireOK(r, "git commit")
    }

    func push(in cwd: String) async throws -> String {
        let r = try await git(["push"], cwd: cwd)
        try Self.requireOK(r, "git push")
        return r.stdout + r.stderr
    }

    func pull(in cwd: String) async throws -> String {
        let r = try await git(["pull", "--ff-only"], cwd: cwd)
        try Self.requireOK(r, "git pull --ff-only")
        return r.stdout + r.stderr
    }

    // MARK: - Branches

    func branches(in cwd: String) async throws -> [GitBranchInfo] {
        let current = try? await currentBranchName(in: cwd)
        async let locals: ShellCommandResult = git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: cwd)
        async let remotes: ShellCommandResult = git(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], cwd: cwd)
        let l = try await locals
        let r = try await remotes
        var out: [GitBranchInfo] = []
        if l.exitCode == 0 {
            for name in l.stdout.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
                out.append(.init(name: name, isRemote: false, isCurrent: name == current))
            }
        }
        if r.exitCode == 0 {
            for name in r.stdout.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && !name.hasSuffix("/HEAD") {
                out.append(.init(name: name, isRemote: true, isCurrent: false))
            }
        }
        return out
    }

    func currentBranchName(in cwd: String) async throws -> String {
        let r = try await git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        try Self.requireOK(r, "git rev-parse")
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkout(branch: String, in cwd: String) async throws {
        let r = try await git(["checkout", branch], cwd: cwd)
        try Self.requireOK(r, "git checkout")
    }

    // MARK: - Ahead / Behind

    struct AheadBehind: Sendable { let ahead: Int; let behind: Int }
    func aheadBehind(in cwd: String) async throws -> AheadBehind {
        let r = try await git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: cwd)
        if r.exitCode != 0 { return .init(ahead: 0, behind: 0) }
        let parts = r.stdout.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
        if parts.count == 2 { return .init(ahead: parts[1], behind: parts[0]) }
        return .init(ahead: 0, behind: 0)
    }

    // MARK: - Helpers

    private static func requireOK(_ r: ShellCommandResult, _ label: String) throws {
        guard r.exitCode == 0 else {
            throw GitServiceError.commandFailed(r.stderr.nonEmptyOrFallback("\(label) failed (exit \(r.exitCode))."))
        }
    }
}
