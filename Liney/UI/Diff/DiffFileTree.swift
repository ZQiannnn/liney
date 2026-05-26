//
//  DiffFileTree.swift
//  Liney
//

import Foundation

struct PathTreeNode<Item>: Identifiable {
    let id: String
    let name: String
    let path: String
    let item: Item?
    let children: [PathTreeNode<Item>]

    var isLeaf: Bool { item != nil }
}

enum PathTree {
    static func build<Item>(
        items: [Item],
        path: (Item) -> String,
        leafID: (Item) -> String
    ) -> [PathTreeNode<Item>] {
        let root = MutableNode<Item>(name: "", path: "")
        for item in items {
            let segments = path(item)
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !segments.isEmpty else { continue }

            var current = root
            var accumulated = ""
            for (index, segment) in segments.enumerated() {
                accumulated = accumulated.isEmpty ? segment : accumulated + "/" + segment
                let next: MutableNode<Item>
                if let existing = current.childrenByName[segment] {
                    next = existing
                } else {
                    next = MutableNode<Item>(name: segment, path: accumulated)
                    current.childrenByName[segment] = next
                    current.orderedChildNames.append(segment)
                }
                if index == segments.count - 1 {
                    next.item = item
                    next.leafID = leafID(item)
                }
                current = next
            }
        }
        return snapshot(root).children
    }

    private static func snapshot<Item>(_ node: MutableNode<Item>) -> PathTreeNode<Item> {
        let kids = node.orderedChildNames
            .compactMap { node.childrenByName[$0] }
            .map(snapshot)
            .sorted { lhs, rhs in
                if lhs.isLeaf != rhs.isLeaf { return !lhs.isLeaf }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        let id: String
        if let leafID = node.leafID {
            id = leafID
        } else {
            id = "dir:" + node.path
        }
        return PathTreeNode<Item>(
            id: id,
            name: node.name,
            path: node.path,
            item: node.item,
            children: kids
        )
    }

    static func leafCount<Item>(in node: PathTreeNode<Item>) -> Int {
        if node.isLeaf { return 1 }
        return node.children.reduce(0) { $0 + leafCount(in: $1) }
    }

    private final class MutableNode<Item> {
        let name: String
        let path: String
        var item: Item?
        var leafID: String?
        var childrenByName: [String: MutableNode<Item>] = [:]
        var orderedChildNames: [String] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
}
