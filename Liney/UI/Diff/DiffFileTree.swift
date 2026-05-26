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

/// Intermediate builder node. Non-generic on purpose: a generic class holding a
/// dictionary of itself triggers a SIL optimizer crash (EarlyPerfInliner) in
/// the Release x86_64 cross-compile path on Xcode 26. Type-erase `Item` to
/// `Any` here, then cast back at snapshot time.
private final class PathTreeBuilderNode {
    let name: String
    let path: String
    var item: Any?
    var leafID: String?
    var childrenByName: [String: PathTreeBuilderNode] = [:]
    var orderedChildNames: [String] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

enum PathTree {
    static func build<Item>(
        items: [Item],
        path: (Item) -> String,
        leafID: (Item) -> String
    ) -> [PathTreeNode<Item>] {
        let root = PathTreeBuilderNode(name: "", path: "")
        for item in items {
            let segments = path(item)
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !segments.isEmpty else { continue }

            var current = root
            var accumulated = ""
            for (index, segment) in segments.enumerated() {
                accumulated = accumulated.isEmpty ? segment : accumulated + "/" + segment
                let next: PathTreeBuilderNode
                if let existing = current.childrenByName[segment] {
                    next = existing
                } else {
                    next = PathTreeBuilderNode(name: segment, path: accumulated)
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
        return snapshot(root, as: Item.self).children
    }

    private static func snapshot<Item>(_ node: PathTreeBuilderNode, as: Item.Type) -> PathTreeNode<Item> {
        let kids = node.orderedChildNames
            .compactMap { node.childrenByName[$0] }
            .map { snapshot($0, as: Item.self) }
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
            item: node.item as? Item,
            children: kids
        )
    }

    static func leafCount<Item>(in node: PathTreeNode<Item>) -> Int {
        if node.isLeaf { return 1 }
        return node.children.reduce(0) { $0 + leafCount(in: $1) }
    }
}
