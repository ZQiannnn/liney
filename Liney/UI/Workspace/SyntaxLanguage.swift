//
//  SyntaxLanguage.swift
//  Liney
//

import Foundation

/// Maps a file URL to the Highlightr/highlight.js language identifier that
/// should drive syntax highlighting in the inline editor. Returns `nil` for
/// extensions we don't recognize so the editor falls back to plain text.
enum SyntaxLanguage {
    static func identifier(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if let id = byExtension[ext] {
            return id
        }
        let base = url.lastPathComponent.lowercased()
        return byBasename[base]
    }

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "swiftinterface": "swift",
        "m": "objectivec", "mm": "objectivec", "h": "objectivec", "hpp": "cpp",
        "c": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp",
        "py": "python", "pyi": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "ts": "typescript", "tsx": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "scala": "scala",
        "groovy": "groovy", "gradle": "groovy",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "ps1": "powershell",
        "lua": "lua",
        "pl": "perl",
        "php": "php",
        "r": "r",
        "dart": "dart",
        "ex": "elixir", "exs": "elixir",
        "json": "json", "jsonc": "json", "json5": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "ini",
        "ini": "ini", "cfg": "ini", "conf": "ini", "properties": "properties", "env": "ini",
        "xml": "xml", "plist": "xml", "svg": "xml",
        "html": "xml", "htm": "xml",
        "sql": "sql",
        "graphql": "graphql", "gql": "graphql",
        "proto": "protobuf",
        "csv": nil as String? ?? "",
        "md": "markdown", "markdown": "markdown", "mdown": "markdown",
        "mkd": "markdown", "mkdn": "markdown", "mdx": "markdown",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "tex": "latex", "bib": "bibtex",
        "rtf": nil as String? ?? "",
        "log": "accesslog"
    ].compactMapValues { $0.isEmpty ? nil : $0 }

    private static let byBasename: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "cmakelists.txt": "cmake",
        "rakefile": "ruby",
        "gemfile": "ruby",
        "podfile": "ruby",
        "fastfile": "ruby"
    ]
}
