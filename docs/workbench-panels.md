# Workbench Panels: File Tree, Preview, and Web

Liney can flank the terminal split tree with two optional panels. They are
workspace-level UI that wrap the terminal area — the terminal/session/persistence
core is untouched, so panels never participate in pane layout, zoom, or
restoration.

## Directory tree (left)

`WorkspaceFileTreeView` shows a lazy, recursive directory tree whose **root
follows the focused pane's working directory**. Liney's shell integration already
reports `cwd` via OSC 7 (`ShellSession.reportedWorkingDirectory`); the tree
observes the focused session and re-roots whenever you `cd`.

- Shown by default; the **Settings → General → "Show the file tree by default"**
  toggle (`AppSettings.directoryTreeEnabled`, default on) controls the initial
  state, seeded once per workspace the first time it appears so a manual toggle
  is never overridden.
- Toggle at runtime with the toolbar **file-tree** button or the "More actions" menu.
- Click a directory to expand/collapse; click a Markdown/HTML file to open it in
  the preview panel; click any other file to open it in the default app.
- Right-click for: open in preview, `cd` here (injects `cd '<path>'` into the
  focused terminal), reveal in Finder, open with default app, copy path.
- Header buttons: toggle hidden files, refresh, hide.

## Preview panel (right)

`WorkspacePreviewPanel` renders the workspace's current `WorkspacePreviewContent`
in a single reused `WKWebView` (`PreviewWebEngine`):

- **Markdown** files are converted to a styled, light/dark-aware HTML document by
  `MarkdownToHTMLRenderer` (a self-contained GFM-subset renderer — no bundled JS)
  and loaded with the file's folder as the base URL so relative images resolve.
- **HTML** files are loaded directly from disk.
- Files **live-reload** on disk changes (`FileChangeWatcher`), so AI-generated
  output refreshes as it is written.

## Web pages (right)

The same panel can load a live web page. Because the `WKWebView` runs in Liney's
process on the host machine, it uses the host's own network — opening
`http://localhost:3000` shows a dev server exactly as a browser on that machine
would. The toolbar **globe** menu lists ports detected by `ListeningPortInspector`
for the focused pane and offers "Open URL…" for anything else. Bare input is
normalized (`:3000` → `http://localhost:3000`).

`Info.plist` enables `NSAllowsLocalNetworking` so insecure `http://localhost`
dev servers load without disabling App Transport Security globally.

## Key types

| Concern | Type | Location |
| --- | --- | --- |
| Preview content model | `WorkspacePreviewContent` | `Liney/Domain/` |
| Markdown → HTML | `MarkdownToHTMLRenderer` | `Liney/Support/` |
| Directory listing | `DirectoryTreeLoader` / `DirectoryTreeEntry` | `Liney/Support/` |
| File live-reload | `FileChangeWatcher` | `Liney/Support/` |
| Web view host | `PreviewWebEngine` / `PreviewWebView` | `Liney/UI/Components/` |
| Preview panel UI | `WorkspacePreviewPanel` | `Liney/UI/Workspace/` |
| File tree UI | `WorkspaceFileTreeView` | `Liney/UI/Workspace/` |
| State | `WorkspaceModel.isFileTreePresented` / `.previewPanel` | `Liney/Domain/WorkspaceRuntime.swift` |
