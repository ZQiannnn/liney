//
//  DiffFileTree.swift
//  Liney
//

import Foundation

struct DiffFileTreeNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let file: DiffChangedFile?
    let children: [DiffFileTreeNode]

    var isFile: Bool { file != nil }
}

enum DiffFileTree {
    static func build(from files: [DiffChangedFile]) -> [DiffFileTreeNode] {
        let root = MutableNode(name: "", path: "")
        for file in files {
            let segments = file.displayPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !segments.isEmpty else { continue }

            var current = root
            var accumulated = ""
            for (index, segment) in segments.enumerated() {
                accumulated = accumulated.isEmpty ? segment : accumulated + "/" + segment
                let next: MutableNode
                if let existing = current.childrenByName[segment] {
                    next = existing
                } else {
                    next = MutableNode(name: segment, path: accumulated)
                    current.childrenByName[segment] = next
                    current.orderedChildNames.append(segment)
                }
                if index == segments.count - 1 {
                    next.file = file
                }
                current = next
            }
        }
        return snapshot(root).children
    }

    private static func snapshot(_ node: MutableNode) -> DiffFileTreeNode {
        let kids = node.orderedChildNames
            .compactMap { node.childrenByName[$0] }
            .map(snapshot)
            .sorted { lhs, rhs in
                if lhs.isFile != rhs.isFile { return !lhs.isFile }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let id: String
        if let file = node.file {
            id = file.id
        } else {
            id = "dir:" + node.path
        }
        return DiffFileTreeNode(
            id: id,
            name: node.name,
            path: node.path,
            file: node.file,
            children: kids
        )
    }

    private final class MutableNode {
        let name: String
        let path: String
        var file: DiffChangedFile?
        var childrenByName: [String: MutableNode] = [:]
        var orderedChildNames: [String] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
}
