# FileOS Reproduction — Implementation Plan (Swift)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. One implementer per task, then an independent reviewer, then commit. Steps use `- [ ]`.

**Goal:** A native macOS file manager ("Better Files") written in Swift and SwiftUI. It reproduces the FileOS features marked **[R]** in `FEATURES.md`.

**Architecture:** One Swift package.
- `FileOSCore` is a library that uses only Foundation (plus Glibc/Darwin). It holds all logic, builds on Linux and macOS, and is unit-tested with XCTest.
- `FileOSApp` is a SwiftUI + AppKit executable target, included only on macOS (`#if os(macOS)` in `Package.swift`). It is a thin UI over `FileOSCore`.
- A macOS GitHub Actions workflow builds everything, runs the tests, and runs `FileOSApp --self-test`. That flag builds the main window offscreen, runs a scripted smoke flow, and exits non-zero on failure.

**Tech Stack:** Swift 6 language mode (tools 6.0), macOS 15+, SwiftUI, AppKit, QuickLook / QuickLookThumbnailing, XCTest. No third-party packages.

**Spec:** `FEATURES.md` (IDs `F<n>.<m>`).

**Reference:** an abandoned Electron prototype of the Task 1–2 logic is in git history (`git show b36e5a8:src/core/fsops.js`, `transfer.js`, `rename.js`, `kinds.js`). Port its behavior and tests, not its structure.

## Global Constraints

- `Package.swift`: `// swift-tools-version: 6.0`, `platforms: [.macOS(.v15)]`, products `FileOSCore` (library) and `FileOSApp` (executable, macOS only). The test target is `FileOSCoreTests`.
- `Sources/FileOSCore/**` never imports SwiftUI, AppKit, QuickLook or Combine. A macOS-only API (e.g. `FileManager.trashItem`, `NSWorkspace`) goes behind `#if os(macOS)` with a working Linux fallback, or lives in `FileOSApp`.
- Core functions take URLs/paths as parameters. There is no hidden `homeDirectoryForCurrentUser` inside the logic, so tests run on temp dirs. The app gets home from `ProcessInfo.processInfo.environment["FILEOS_HOME"] ?? NSHomeDirectory()`.
- Nothing is deleted for good except Empty Trash, which always asks first.
  - macOS: trash with `FileManager.trashItem(at:resultingItemURL:)` and record the resulting URL for undo.
  - Linux/tests: move into a `trashDir` with a unique name.
- Every mutating action registers an undo on the app's `UndoStack` (core). The UI shows a toast with **Undo**. Undo never overwrites, and it reports files it could not restore (`RestoreResult.failed`). An undo never throws midway; it collects failures.
- Copy text is used verbatim from FEATURES.md (e.g. "untitled folder", "Moved 1 item to the Trash", "Keep Both").
- Shell-outs (`git`, `brew`, `open`, `lsof`) go through `Process` with an argument array (never `/bin/sh -c`), a timeout, and an injectable `CommandRunner` for tests.
- Concurrency: core types are `Sendable` value types or `actor`s. UI state lives in `@MainActor @Observable` models.
- Commands: `swift build` and `swift test` (this Linux container: `/opt/swift/usr/bin`); CI on `macos-15` runs `swift build`, `swift test`, and `swift run FileOSApp --self-test`.
- Commit messages end with the session's Co-Authored-By / Claude-Session lines.

## Review Focus

1. **Names with spaces, unicode, quotes, leading dots, `.tar.gz`, and case-only renames on case-insensitive APFS.** Expect `"a b.tar.gz"` → `"a b 2.tar.gz"`, and `a.txt` → `A.txt` to work. Pinned in Task 1 and Task 2.
2. **Moving a folder into itself or its own child.** Expect "Can't move “X” into itself" with nothing changed. Pinned in Task 2.
3. **Unreadable folder (EACCES/EPERM).** Expect the locked-folder screen (F3.13), never a blank pane. Pinned in Task 1 (`listDirectory` throws a typed `FileOSError.accessDenied`) and Task 4 (view state).
4. **Undo after the world changed** (original path taken, copy already deleted). Expect no overwrite, the failure listed, and the rest still restored. Pinned in Task 1 and Task 2.
5. **Huge folders and symlink loops** in search, sizes and smart clean. Expect bounded depth/limits and no symlink following. Pinned in Task 1 (`directorySize`), Task 6 and Task 8.

---

### Task 1: Package, CI, kinds, file operations, undo

**Files:** Create `Package.swift`, `.gitignore`, `.github/workflows/ci.yml`, `Sources/FileOSCore/Kinds.swift`, `Sources/FileOSCore/FileOps.swift`, `Sources/FileOSCore/UndoStack.swift`, `Sources/FileOSApp/FileOSApp.swift` (minimal `@main` SwiftUI app with an empty window and `--self-test` handling that exits 0), `Tests/FileOSCoreTests/KindsTests.swift`, `FileOpsTests.swift`, `UndoStackTests.swift`, `TestHelpers.swift`. Delete the Electron prototype (`package.json`, `package-lock.json`, `src/`, `tests/`).

**Interfaces — Produces:**
- `enum FileKind: String, CaseIterable, Sendable { case pdfs = "PDFs", images = "Images", screenshots = "Screenshots", videos = "Videos", installers = "Installers", archives = "Archives", audio = "Audio", documents = "Documents", other = "Other" }`; `static func of(_ name: String) -> FileKind`; `func isDownloading(_ name: String) -> Bool` (`.crdownload .download .part .opdownload`); `func splitExtension(_ name: String) -> (base: String, ext: String)` (`.tar.gz .tar.bz2 .tar.xz` count as one extension; a leading-dot name has no extension); `func formatBytes(_ n: Int64) -> String` ("1.2 GB", base 1000).
- `struct Entry: Sendable, Hashable, Identifiable { url, name, isDirectory, isSymlink, size: Int64, modified: Date, created: Date, added: Date, kind: FileKind?, isHidden }` (`kind` is nil for folders; `id` = path).
- `enum FileOSError: Error, Equatable { case accessDenied(path), notFound(path), alreadyExists(name), intoItself(name), invalidName(String) }` with `LocalizedError` copy from FEATURES.md (`intoItself` → "Can't move “X” into itself").
- `enum FileOps` (static funcs): `listDirectory(_ dir: URL, showHidden: Bool = false) throws -> [Entry]`; `uniqueName(in dir: URL, for name: String) -> String`; `newFolder(in dir: URL) throws -> URL`; `duplicate(_ url: URL) throws -> URL`; `makeAlias(_ url: URL) throws -> URL` (macOS: Finder alias via `URL.bookmarkData(options: .suitableForBookmarkFile)` + `writeBookmarkData`; Linux: symlink); `rename(_ url: URL, to newName: String) throws -> URL` (case-only rename allowed); `trash(_ urls: [URL], trashDir: URL?) throws -> [Move]` with `struct Move: Sendable, Hashable { from: URL; to: URL }` (`trashDir == nil` on macOS uses `trashItem`); `restore(_ moves: [Move]) -> RestoreResult` with `struct RestoreResult { restored: [URL]; failed: [(url: URL, reason: String)] }`; `move(_ from: URL, to: URL) throws` (cross-volume fallback: copy, then remove); `emptyTrash(_ trashDir: URL) throws -> (count: Int, bytes: Int64)`; `trashSummary(_ trashDir: URL) -> (count: Int, bytes: Int64)`; `directorySize(_ dir: URL, maxEntries: Int = 200_000) -> (bytes: Int64, items: Int)` (no symlink following); `diskInfo(for url: URL) -> (total: Int64, free: Int64)`.
- `final class UndoStack: @unchecked Sendable` (lock-protected): `push(_ label: String, _ undo: @escaping @Sendable () async -> RestoreResult)`; `undo() async -> (label: String, result: RestoreResult)?`; `var canUndo: Bool`; `var topLabel: String?` (max 100).
- `TestHelpers`: `makeTempDir() -> URL`, `touch(_ dir: URL, _ rel: String, _ content: String = "x", modified: Date? = nil) -> URL`.
- `ci.yml`: on push/PR, `runs-on: macos-15`; steps: checkout, `swift build`, `swift test`, `swift run FileOSApp --self-test`.

- [ ] Port and extend the prototype tests as XCTest: kinds (`a.PDF`, `Screenshot 2026-11-01 at 10.00.00.png`, `Screenshot x.PNG`, `x.dmg`, `x.tar.gz`, `noext`); `splitExtension`; `uniqueName` → `a b 2.tar.gz`, `a b 3.tar.gz`; `newFolder` twice → `untitled folder`, `untitled folder 2`; `duplicate` → `report copy.pdf`, `report copy 2.pdf`; rename `a.txt` → `A.txt` succeeds; trash then restore round-trips; restore with the original path re-created reports `failed` and keeps both; hidden excluded unless `showHidden`; `directorySize` terminates on a symlink loop; `listDirectory` on a `chmod 000` dir throws `.accessDenied` (skip with `XCTSkipIf(getuid() == 0)`); `UndoStack` is LIFO and empty `undo()` → nil.
- [ ] `swift test` fails (RED). Implement. `swift build && swift test` pass (GREEN).
- [ ] Commit `feat(core): Swift package, CI, file kinds, file ops and undo`.

### Task 2: Transfers with name clashes, rename & batch rename

**Files:** Create `Sources/FileOSCore/Transfer.swift`, `Sources/FileOSCore/Rename.swift`, `Tests/FileOSCoreTests/TransferTests.swift`, `RenameTests.swift`.

**Interfaces — Consumes:** Task 1. **Produces:**
- `enum ClashChoice: Sendable { case keepBoth, replace, skip, stop }`; `struct Clash: Sendable { name; destination: URL; remaining: Int }`; `struct TransferProgress: Sendable { currentName; bytesDone, bytesTotal: Int64; itemsDone, itemsTotal: Int }`; `enum TransferMode { case copy, move }`.
- `struct TransferResult: Sendable { results: [(from: URL, to: URL, action: Action)]; stopped: Bool; undo: @Sendable () async -> RestoreResult }` with `enum Action { case copied, moved, replaced }`.
- `func transfer(_ sources: [URL], to dest: URL, mode: TransferMode, trashDir: URL?, resolve: @Sendable (Clash) async -> (ClashChoice, applyToAll: Bool), progress: @Sendable (TransferProgress) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }) async throws -> TransferResult`.
  - Throws `.intoItself` before touching anything (compare standardized, symlink-resolved paths, case-insensitively on macOS).
  - Keep Both uses `uniqueName`. Replace trashes the old item first; undo restores it.
  - A move whose source already sits in `dest` is a no-op.
  - An error mid-batch stops the batch, returns the partial result with `stopped = true` and a working `undo`, and puts the error in a `failure: Error?` field.
  - Undo of a copy trashes each copy separately and collects failures. Undo of a move moves items back. Replaced items are always restored last.
- `enum Rename`: `validate(_ name: String) -> String?` with messages `"Name can't be empty"`, `"Names can't contain / or :"`, `"Names can't start with a dot"`, `"Name is too long"` (> 255 UTF-8 bytes); `extensionChange(from: String, to: String) -> (from: String, to: String)?`; `enum BatchRule { case replace(find: String, with: String), add(text: String, before: Bool), number(name: String, start: Int) }` (pad ≥ 2 digits: `Lisbon 01.jpg`); `plan(_ names: [String], rule: BatchRule, existing: Set<String>) -> [BatchRow]` with `struct BatchRow { from, to: String; error: String? }`. Extensions are kept. Errors are the validate messages, `"Duplicate name"`, `"Already in this folder"` (both compared case-insensitively), and `"Still downloading"`. `apply(_ rows: [BatchRow], in dir: URL) -> (renamed: Int, failed: [(String, String)], undo: @Sendable () async -> RestoreResult)` continues past individual failures.

- [ ] Tests (port the prototype's and add the reviewer's): Keep Both → `Brand-Guide 2.pdf`; Replace → old item trashed, undo restores it; `applyToAll` asks once for 3 clashes; `stop` halts; `a` → `a/b` throws `.intoItself` and nothing changed; move-undo restores; copy-undo after the user deleted one copy reports it in `failed` and still restores the replaced original; move-undo when the original path is now taken reports `failed` and does not overwrite; progress ends with `itemsDone == itemsTotal`. Rename: validate cases; `extensionChange("a.pdf","a.docx")`; number rule; duplicates; `"Already in this folder"` matched case-insensitively (`A.txt` vs existing `a.txt`).
- [ ] RED, implement, GREEN. Commit `feat(core): transfers with clash handling, rename and batch rename`.

### Task 3: Path bar & Open In

**Files:** Create `Sources/FileOSCore/PathBar.swift`, `Sources/FileOSCore/OpenIn.swift`, `Sources/FileOSCore/CommandRunner.swift`, tests `PathBarTests.swift`, `OpenInTests.swift`.

**Interfaces — Produces:**
- `protocol CommandRunner: Sendable { func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (status: Int32, stdout: String) }`; `struct ProcessRunner: CommandRunner` (Process + argument array + timeout kill); `exe` is resolved through `/usr/bin/env`-free PATH lookup of `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`.
- `enum PathBar`: `static let commands: [String: String]` (word → app id: `terminal, code, cursor, xed, zed, subl, iterm, warp, ghostty, nova, bbedit, idea, pycharm, webstorm, goland, clion, rider, phpstorm, rubymine, windsurf`); `enum Parsed { case command(appID: String, target: URL); case path(String) }`; `parse(_ input: String, cwd: URL, home: URL) -> Parsed` (if `cwd` has a child folder named exactly the input, it is a path); `enum Resolved { case folder(URL), file(URL, dir: URL), missing(name: String, parent: URL, suggestion: String?) }`; `resolve(_ raw: String, cwd: URL, home: URL) -> Resolved` (`~`, `~/x`, absolute, relative, bare name matching a child of cwd or home case-insensitively; suggestion = closest child name of parent or home with Levenshtein ≤ 2, shown as `~/…`); `complete(_ input: String, cwd: URL, home: URL) -> [String]` (folders only, case-insensitive prefix, sorted, ≤ 20, keeps `~`); `missingMessage(name:parent:)` → `There's no folder called “NAME” in PARENTNAME`.
- `struct ExternalApp: Sendable, Identifiable { id, name: String; kind: Kind; bundleName: String }` with `enum Kind { case terminal, editor }`; `enum OpenIn { static let apps: [ExternalApp]` (Terminal, iTerm, Warp, Ghostty; VS Code, VS Code Insiders, Cursor, Windsurf, Zed, Xcode, Sublime Text, Nova, BBEdit, IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, PhpStorm, RubyMine, Android Studio, cmux); `target(kind:selection:cwd:) -> URL` (terminal: selected folder or cwd; editor: first selected item or cwd); `openArguments(app:url:) -> [String]` → `["-a", bundleName, path]` for `/usr/bin/open` }.

- [ ] Tests: `~/Doc` completes to `~/Documents`; `parse("code .")` is a command; with a `code` folder in cwd, `parse("code")` is a path; `resolve("Documnts")` → missing with suggestion `~/Documents`; a file path → `.file` with its dir; `target(.terminal, [file], cwd)` → cwd; `ProcessRunner` runs `/bin/echo hi` → `"hi\n"`; a timeout kills `/bin/sleep 5` with a 0.2 s timeout.
- [ ] RED, implement, GREEN. Commit `feat(core): path bar parsing, completion, Open In and command runner`.

### Task 4: App shell — window, sidebar, path bar, list view

**Files:** Create `Sources/FileOSCore/Store.swift`, `Tests/FileOSCoreTests/StoreTests.swift`, `Sources/FileOSApp/AppModel.swift`, `PaneModel.swift`, `Views/MainWindow.swift`, `Views/SidebarView.swift`, `Views/PathBarView.swift`, `Views/FileListView.swift`, `Views/StatusBar.swift`, `Views/LockedFolderView.swift`, `Views/Toasts.swift`, `DirectoryWatcher.swift`, `SelfTest.swift`, `scripts/bundle.sh` (builds release and wraps it in `FileOS.app` with `Info.plist`, `LSMinimumSystemVersion` 15.0). Modify `FileOSApp.swift`.

**Interfaces — Produces:**
- `final class Store: @unchecked Sendable` (JSON file, atomic write, lock): `init(url: URL)`; `func get<T: Codable>(_ key: String, default: T) -> T`; `func set<T: Codable>(_ key: String, _ value: T)`.
- `@MainActor @Observable final class PaneModel { var url: URL; var entries: [Entry]; var selection: Set<Entry.ID>; var view: ViewMode (.list, .icons, .columns); var sort: SortOrder; var group: Grouping (.none, .kind, .date); var filter: String; var error: FileOSError?; history/forward stacks; func navigate(to:), back(), forward(), up(), reload() }`.
- `@MainActor @Observable final class AppModel { home: URL; store: Store; undo: UndoStack; panes: [PaneModel]; activePane: Int; showHidden: Bool; page: Page; toasts; func toast(_ text: String, undoable: Bool) }` with `enum Page: Hashable { case browser, home, bookmarks, freeUpSpace, installed, agents, workspace(UUID), aboutMac }`.
- `SelfTest.run(model: AppModel) async -> Bool`: makes a temp home with `Documents/a.txt`, navigates to it, checks `entries` has `a.txt`, navigates to a missing path and checks the error, then hosts `MainWindow` in an offscreen `NSHostingView` and lays it out. Later tasks append checks to it.

Features: F1.1–F1.3, F2.1 (Favorites Desktop/Documents/Downloads/Pictures + custom, Tools, Locations: home, `/`, mounted volumes from `FileManager.mountedVolumeURLs`, Trash; Locations folded by default), F2.4 disk line, F4.1–F4.3 (crumbs; ⌘L / ⇧⌘G edit field with Tab completion; error with "Did you mean ~/…?" and "Create This Folder"), list view with `Table` (Name, Date Modified, Size, Kind; sortable headers), status bar "N items, M selected, X available", locked-folder screen with exact copy and "Try Again" (and "Give FileOS Full Access" opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), live refresh via `DispatchSource.makeFileSystemObjectSource`, Back/Forward ⌘[ ⌘], ⌘↑, ⌘↓/double-click opens, path-bar command words through `OpenIn` + `NSWorkspace`. Accessibility labels on icon-only buttons.

- [ ] Tests: `StoreTests` (round-trip, missing file → default, corrupt file → default). Extend `SelfTest`.
- [ ] Linux: `swift build && swift test` green. Push; the macOS CI job (build + test + `--self-test`) must be green; read its logs with the GitHub MCP actions tools.
- [ ] Commit `feat(app): SwiftUI shell with sidebar, path bar and list view`.

### Task 5: Views, selection, file operations UI, keyboard map

**Files:** Create `Sources/FileOSCore/Shortcuts.swift`, `Tests/FileOSCoreTests/ShortcutsTests.swift`, `Sources/FileOSApp/Views/IconGridView.swift`, `ColumnBrowserView.swift`, `ContextMenu.swift`, `PreviewPane.swift`, `BatchRenameSheet.swift`, `ClashDialog.swift`, `Commands.swift`, `Thumbnails.swift`, `Clipboard.swift`. Modify the pane, model and window files.

**Interfaces — Produces:** `struct KeyCombo: Codable, Hashable, Sendable { key: String; command, shift, option, control: Bool }` with `init?(_ s: String)` parsing `"Cmd+Shift+N"`, `"Ctrl+Alt+Cmd+1"`, `"F5"`, `"Alt+Space"`; `description` gives `⇧⌘N`; `enum Shortcuts { static let defaults: [String: KeyCombo]` (action id → combo, covering every key in FEATURES.md §18), `static let fixed: Set<String>`, `static func conflict(in map: [String: KeyCombo], action: String, combo: KeyCombo) -> String?`, `static func merged(_ user: [String: KeyCombo]) -> [String: KeyCombo]` }. `Commands.swift` builds SwiftUI `Commands` whose shortcuts come from `Shortcuts.merged(store)`.

Features: icons view (`LazyVGrid` cards, sizes Tiny…Large with ⌘+/⌘−, QuickLookThumbnailing previews, glass folder with item count), columns view (F3.1–F3.3), group/sort incl. "Files First" persisted per folder (F3.4), ⇧⌘. hidden, ⌘F filter, selection (click, ⌘, ⇧, arrows, ⌘A), list folders expand in place (`OutlineGroup` / disclosure), context menu (F3.10), preview pane ⇧⌘P (F3.11), clipboard ⌘C/⌘X/⌘V/⌥⌘V via `NSPasteboard` file URLs (cut items dimmed, Esc cancels), Duplicate, ⌃⌘A alias, Return inline rename (name selected without the extension; extension-change alert "Keep .pdf" / "Use .docx"), batch rename sheet with live preview and red errors, ⇧⌘N / F7 new folder then rename, ⌘⌫ / F8 trash with "Moved N items to the Trash", Empty Trash alert with exact copy, ⌘Z undo, drag & drop (`.draggable` / `.dropDestination`; ⌥ copies), ⌥⌘C copy path, ⌘R Show in Finder (`NSWorkspace.activateFileViewerSelecting`), ⌃⌘T add to sidebar, Go shortcuts (⇧⌘O/D/H/A/I, ⌥⌘L), F2 rename, F4 open in editor, ⌥⇧⌘T / ⌥⇧⌘E Open In.

- [ ] Tests: `KeyCombo("Cmd+Shift+N")` round-trips to `⇧⌘N`; no two defaults share a combo; every `fixed` id exists in `defaults`; `conflict` detects a duplicate. SelfTest: new folder → "untitled folder" exists; trash → undo restores.
- [ ] Linux green, CI green. Commit `feat(app): views, selection, file operations and shortcuts`.

### Task 6: Dual pane, layouts, transfer queue, ⌘K search

**Files:** Create `Sources/FileOSCore/Search.swift`, `Tests/FileOSCoreTests/SearchTests.swift`, `Sources/FileOSApp/Views/PaneLayoutView.swift`, `TransferQueue.swift`, `SearchPalette.swift`.

**Interfaces — Produces:** `struct SearchHit: Sendable, Hashable { url, name, isDirectory, kind: FileKind?; line: (number: Int, text: String)? }` (Hashable on url+line number); `enum SearchChip: String, CaseIterable { case all = "All", workspaces = "Workspaces", folders = "Folders", images = "Images", videos = "Videos", music = "Music", documents = "Documents", bookmarks = "Bookmarks" }`; `func search(roots: [URL], query: String, contents: Bool = false, chip: SearchChip = .all, limit: Int = 200, maxDepth: Int = 6, isCancelled: @Sendable () -> Bool = { false }) -> [SearchHit]`. It does a case-insensitive name match. With `contents`, it reads text files ≤ 2 MB and returns the first matching line. Folders come first, then files in `FileKind.allCases` order. It skips `node_modules`, `.git` and hidden dirs, and never follows symlinks. Images include screenshots, Music = audio, Documents = PDFs + documents. `@MainActor @Observable final class TransferQueue` runs one `transfer` at a time with the queued "Waiting: …", progress "1.2 GB of 3.4 GB · 12 of 40 items", Cancel, and a clash sheet.

Features: F8.1–F8.3 (⌘D, Tab, ⌘U, ⌥⌘1–⌥⌘6 layouts up to four panes, named saved layouts in the store listed first in the Dual Pane menu, preview hidden with several panes), F5/F6 with the bar buttons `Copy to “<dest>”` / `Move`, drag across panes moves (⌥ copies), clash sheet "“X” is already in “Y”" with Keep Both / Replace / Skip / Stop and "Do the same for all N items…", done toast "Copied 3 items to “Documents”" with Undo (F5.4, F5.5). ⌘K palette (F7.1–F7.3): field "Search everything", chips, Contents toggle showing the line, workspace/bookmark/layout matches from the store keys `workspaces`, `bookmarks` and `layouts` (empty until Task 9), Return opens, ⌥Return shows in folder, Space peeks.

- [ ] Tests: folders before files; contents finds `needle` in `b.md` with its line number; a symlink loop terminates; `maxDepth`; chip filters. SelfTest: ⌘D model action makes 2 panes; F5 copies a file to the other pane.
- [ ] Green on both. Commit `feat(app): dual pane, layouts, transfer queue and search`.

### Task 7: Peek, Markdown page, file info, zips

**Files:** Create `Sources/FileOSCore/Markdown.swift`, `FileInfo.swift`, `ZipReader.swift`, tests `MarkdownTests.swift`, `FileInfoTests.swift`, `ZipReaderTests.swift`, `Sources/FileOSApp/Views/PeekView.swift`, `MarkdownPage.swift`.

**Interfaces — Produces:** `enum Markdown { static func outline(_ src: String) -> [(level: Int, text: String, id: String)]` (ATX headings; ignores fenced code); `isMarkdown(_ name:)` (.md .markdown .mdown .mkd); `canShowAsPage(size: Int64, data: Data) -> String?` (reason if > 5 MB or not UTF-8) }`; `struct FileInfoSummary { kind; size; words: Int?; lines: Int?; pixelSize: (Int, Int)?; zipEntries: [String]? }` from `FileInfo.summary(_ url:)` (PNG/JPEG/GIF header parse, text counts); `ZipReader.entries(_ url:) throws -> [String]` (central directory parse); `ZipReader.unzip(_ url:, to:) async throws` via `CommandRunner` (`/usr/bin/ditto -x -k` on macOS, `unzip` elsewhere).

Features: F6.1–F6.3, F5.14: Peek overlay on Space (`QLPreviewView` for PDF/Office/images, `AVPlayerView` for audio/video, text view, zip listing with Unpack, folder summary), "7 of 10", ← → (only through the selection when several are selected), Return opens, Space/Esc closes, Info drawer (remembered), buttons Open, Open With, Share (`ShareLink`), Show in Finder, ⌘Y system Quick Look (`QLPreviewPanel`). Markdown page on double-click of a .md: Preview (`AttributedString(markdown:)` rendering per block) / Edit (`TextEditor`) / Split, "On this page" outline that scrolls to a heading, "Edited" bar with Revert / Save ⌘S, leaving with edits asks "Save the changes to “…”?" Save / Don't Save / Cancel.

- [ ] Tests: outline of `# A\n## B` and a fenced `# not`; 6 MB → reason; invalid UTF-8 → reason; PNG header → width/height; zip entries from a fixture created with `/usr/bin/zip` (skip if missing) or bytes built in the test; text word/line counts.
- [ ] Green on both. Commit `feat(app): Peek and Markdown page`.

### Task 8: Smart Downloads, folder symbols, Smart Clean

**Files:** Create `Sources/FileOSCore/Tidy.swift`, `FolderSymbol.swift`, `SmartClean.swift`, tests for each, `Sources/FileOSApp/Views/TidySheet.swift`, `InsightsPanel.swift`, `FreeUpSpaceView.swift`.

**Interfaces — Produces:**
- `struct TidyPlan { moves: [(from: URL, to: URL, kind: FileKind)]; left: [(name: String, reason: String)]; byKind: [FileKind: (count: Int, bytes: Int64, destination: URL)] }`; `Tidy.plan(_ dir: URL, now: Date, screenshotsToPictures: URL? = nil, installersToTrash: Bool = false) throws -> TidyPlan` (loose files only; reasons `"Still downloading"`, `"Added in the last 2 minutes"`; destination folders named by `FileKind.rawValue` under `dir`; existing folders reused; clashes → `uniqueName`); `Tidy.apply(_ plan:, skip: Set<FileKind>, trashDir: URL?) throws -> (moved: Int, undo: @Sendable () async -> RestoreResult)` (undo also removes the folders it created once they are empty); `Tidy.groupByDate(_ entries: [Entry], now: Date, calendar: Calendar) -> [(label: String, items: [Entry])]` with labels `Today, Yesterday, Earlier this week, Earlier this month, Older`; `Tidy.groupByKind(_:) -> [(kind: FileKind, items: [Entry], bytes: Int64)]` (biggest first, downloading last); `Tidy.suggestions(_ entries:, installedApps: Set<String>, now:) -> (installers: [Entry], duplicates: [Entry], older: [Entry])` (duplicate names match ` (n).ext` or ` copy[ n].ext`; older = 90 days).
- `FolderSymbol.automatic(for dir: URL, home: URL) -> String` returns an SF Symbol name and follows F13.1 exactly in that priority order: special folders → `menubar.dock.rectangle` (Desktop), `doc` (Documents), `arrow.down.circle` (Downloads), `film`, `music.note`, `photo`, `house`, `app` (Applications); names → `receipt`, `dollarsign.circle`, `graduationcap`, `airplane`, `briefcase`, `archivebox`, `fork.knife`; code project → `chevron.left.forwardslash.chevron.right`; "Mostly/More <kind>" → the kind's symbol; folders only → `folder.fill`; empty → `folder`; mixed → `square.grid.2x2`; unreadable → `lock`.
- `struct CleanCard: Identifiable { id: CardID; title, reason: String; group: Group (.safe, .yourCall); items: [CleanItem] }`, `struct CleanItem { url; bytes: Int64; ticked: Bool; note: String? }`, `enum CardID: String, CaseIterable { devCaches, duplicates, installers, mailAttachments, appLeftovers, bigFiles, unusedApps, screenRecordings, oldDownloads }`; `SmartClean.scan(home: URL, now: Date, isAppRunning: (String) -> Bool) -> [CleanCard]`.
  - Dev cache paths under home: `Library/Developer/Xcode/DerivedData`, `Library/Developer/Xcode/iOS DeviceSupport`, `Library/Developer/CoreSimulator/Caches`, `.npm/_cacache`, `Library/Caches/Homebrew`, `Library/Caches/pip`, `Library/Caches/Yarn`, `Library/Caches/CocoaPods`. The Xcode ones are skipped while Xcode runs.
  - Duplicates: same size and byte-identical, in Downloads, Desktop and Documents (depth ≤ 4, files ≥ 1 KB). Keep the oldest. Tick a spare only if it is in Downloads/Desktop or named like a copy.
  - Big files: > 500 MB and untouched 180 days. Screen recordings: > 30 days. Old downloads: 90 days.
  - "Your call" items are never ticked.
  - `SmartClean.diskSummary(home:) -> (free, total, used, trash: Int64)`.

Features: F9.1–F9.4, F13.1–F13.2 (symbol on folder icons; Choose Symbol… / colour stored per path in the store; undoable), F10.1–F10.5 (Free Up Space ⌥⌘K with disk summary, nine cards shown "Looking…" then filled, card detail with Tick all / Untick all / "< All suggestions", bar "4 ticked · 24.2 GB" + "Move 4 to Trash", toast with Undo, "Look Again").

- [ ] Tests: a file modified 30 s ago → left "Added in the last 2 minutes"; `.crdownload` → "Still downloading"; tidy then undo restores all and removes the empty created folders; `report.pdf` clash → `report 2.pdf`; date labels; `Invoices` → `receipt`; `package.json` → code symbol; 3 jpg + 1 txt → image symbol; empty → `folder`; identical files in Downloads and Documents → the Downloads copy ticked and the Documents one kept; a dev cache dir is listed with its size; yourCall items unticked.
- [ ] Green on both. Commit `feat: Smart Downloads, folder symbols and Smart Clean`.

### Task 9: Workspaces & Bookmarks

**Files:** Create `Sources/FileOSCore/Workspaces.swift`, `Bookmarks.swift`, tests, `Sources/FileOSApp/Views/WorkspacePage.swift`, `NewWorkspaceSheet.swift`, `BookmarksPage.swift`.

**Interfaces — Produces:**
- `struct Workspace: Codable, Identifiable, Hashable { id: UUID; name, description: String; color: String; items: [WorkspaceItem]; archived: Bool; created: Date }`, `struct WorkspaceItem: Codable, Identifiable, Hashable { id: UUID; kind: Kind (.folder, .file, .link); path: String?; url: String?; pinned: Bool }`. `enum Workspaces` has pure functions returning new arrays: `create(_:name:description:color:)`, `add(_:to:items:)` (dedupe by path/url), `remove`, `pin` (throws `"You can pin up to six files"` past 6), `archive`, `restore`, `delete`, `edit`, `sample(home:)` ("Acme Project" with five tips), `status(of:fileExists:volumeMounted:) -> ItemStatus (.ok, .disconnected(volume), .missing)` (copy "“T7 Shield” isn't connected", "Can't find it"). Undo = keep the previous array.
- `struct Bookmark: Codable, Identifiable, Hashable { id; url; title; site; icon; image: String?; type: LinkType (.article, .video, .image, .file); tags: [String]; favourite: Bool; collections: [UUID]; added: Date }`, `struct Collection: Codable, Identifiable { id; name; icon }`. `enum Bookmarks` provides `normalize(_:) -> URL?`, `add(_ state: BookmarkState, url:, collection:) -> (BookmarkState, Bookmark, already: Bool)`, `linkType(_:)` (YouTube/Vimeo/.mp4 → video; image extensions → image; .pdf/.zip/.dmg → file; else article), `parseTags("design, #swift") → ["design","swift"]`, `filter(_:filter:query:collection:tag:sort:)` (sort `.newest .oldest .name .site`; the query matches title/address/site/tag), `createCollection`, `deleteCollection` (deletes its links everywhere), and `extractMeta(html:base:) -> (title, image, icon)` (og:title / `<title>`, og:image, `link rel=icon`, relative URLs resolved). The app fetches each page once with `URLSession` (5 s timeout, 1 MB cap).

Features: F11.1–F11.5, F12.1–F12.3, with the details listed in FEATURES.md.
- Workspaces: sidebar section with ⌃1–⌃9 and ⌥⌘N; the page has tabs, a pinned row (⌃⌥1–6), "Search in <name>", the List/Tiles/Cards/Changed Lately views, ⋯ menus, Add via `fileImporter`, drag or right-click "Add to Workspace", missing states with Locate…, Archive/Restore, Delete with a confirm and Undo, and the sample workspace with "Remove Sample".
- Bookmarks: ⌥⌘B; ⌘V saves a copied link ("Saved" / "Already saved" + Undo); ⇧⌘L Add Link; ⌃⌥⌘B; collections ⌥⇧⌘N; Favourites, Unsorted, Tags; the Grid/Headlines/Masonry/List views; sorts, filters and search; the ··· menu.

- [ ] Tests: adding the same folder twice → one item; a 7th pin throws; delete then restoring the previous array works; `add` of the same URL twice → `already`; `parseTags`; `linkType("https://youtu.be/x") == .video`; `extractMeta` reads og tags and resolves `/icon.png`; deleting a collection removes its links. SelfTest: create "Taxes 2026" and add a folder → the folder is still on disk at its path.
- [ ] Green on both. Commit `feat: Workspaces and Bookmarks`.

### Task 10: Developer tools — Git, Installed, AI Agents, About This Mac

**Files:** Create `Sources/FileOSCore/Git.swift`, `Packages.swift`, `Agents.swift`, `SystemInfo.swift`, tests with a fake `CommandRunner`, `Sources/FileOSApp/Views/GitChip.swift`, `InstalledView.swift`, `AgentsView.swift`, `AboutMacView.swift`.

**Interfaces — Produces:**
- `struct GitStatus { branch: String; tag: String?; changed, added, deleted: Int; files: [(status: String, path: String)] }`; `Git.status(_ dir: URL, runner:) async -> GitResult (.notRepo, .gitMissing, .status(GitStatus))` from `git -C dir status --porcelain=v1 -b` and `git describe --tags --exact-match`. Read-only.
- `Packages`: tools homebrew, npm, pip, pipx, cargo, gem, go, each with a list command, a parser, `removeCommand(name)` (e.g. `brew uninstall node`, `npm uninstall -g typescript`; Go has none), and a cache clean command. `Packages.list(runner:home:) async -> [ToolPackages]` with `Package { name, version, source: "You installed" | "Came with X", isApp }`; `twoOfTheSame` (`node` & `node@24`); `brewfile(_:) -> String`.
- `Agents`: `files: [Agent: [String]]` with the exact lists in FEATURES.md F14.4; `scanProject(_ dir:) -> [(agent, files)]`; `parseMCP(_ json: Data) -> [MCPServer]`; `listeningPorts(runner:) async -> [(port, pid, command)]` (parse `lsof -nP -iTCP -sTCP:LISTEN`); `claudeUsage(home:now:) -> (today, week, month: Int)` (sum `message.usage` input+output tokens in `~/.claude/projects/**/*.jsonl`); `copySetupPlan(from:to:agent:) -> [(path, state: "new"|"already there")]` (never `CLAUDE.local.md` or `settings.local.json`).
- `SystemInfo.collect(runner:home:hideNames:) async -> [InfoGroup]` with `InfoGroup { title; rows: [(label, value, status: .ok/.warn/.bad)] }`. It reads `ProcessInfo` and `diskInfo`, and on macOS optionally `pmset -g batt`, `sw_vers`, `fdesetup status`, `csrutil status` and `spctl --status`. `asText(_:)`. Hide Names → `you@this-mac`.

Features: F14.1 (git chip at the end of the path bar and its panel: Copy Branch Name, "Everything is committed.", the `xcode-select --install` hint), F14.2 (Open In toolbar menu and Settings defaults), F14.3 (Installed page), F14.4 (AI Agents page: projects, setup files with Preview/Edit/Save, MCP list, localhost ports with Stop (confirm, then SIGINT), Claude Code usage, Start an Agent Here), F14.5 (About This Mac from the sidebar disk line, Hide Names, Copy as Text).

- [ ] Tests with the fake runner: porcelain `## main...origin/main\n M a\n?? b\n D c` → main, 1/1/1; a runner that throws ENOENT → `.gitMissing`; brew parse and the Brewfile; `scanProject` with `CLAUDE.md` + `.cursorrules`; `copySetupPlan` skips `CLAUDE.local.md`; the lsof parse; usage counts today only for `today`; `hideNames` removes the user name. Plus one real-`git` test in a temp repo (skip if git is missing).
- [ ] Green on both. Commit `feat: git chip, Installed, AI Agents and About This Mac`.

### Task 11: Home, Drop Shelf, Holding, menu bar, quick actions

**Files:** Create `Sources/FileOSApp/Views/HomeView.swift`, `DropShelf.swift` (an `NSPanel` at the top centre, floating, non-activating), `HotKey.swift` (Carbon `RegisterEventHotKey` for the global shortcut), `MenuBarPanel.swift` (`MenuBarExtra`), `QuickActions.swift`. Modify `AppModel.swift` and `FileOSApp.swift`.

**Interfaces — Produces:** store keys `dropShelf.pinned: [String]`, `holding: [String]`, `quickAccess: [String]`, `home.widgets: [String: Bool]`, `quickActions: [String]`; `AppModel.dropShelfMove(_ urls: [URL], to folder: URL, copy: Bool) async` (uses `transfer`, registers an undo, result line "Just now: Moved “…” to <folder>").

Features:
- F15.1–F15.3: ⌥Space (configurable, must include ⌘/⌥/⌃; a conflict is reported) and showing on drag start; pinned folders five per row with counts; keys 1–9 and Esc; drop → "Move here" (⌥ copies) with Undo; "Pin a folder"; right-click Open in FileOS / Show in Finder / Unpin.
- Holding well: keeps paths, survives quit, drag out with `NSItemProvider`, Clear.
- Menu bar: latest 5 downloads, Quick access, Add Folder…, Open FileOS, Settings….
- F1.6: closing the last window keeps the app running (`applicationShouldTerminateAfterLastWindowClosed` = false).
- F16.1 Home ⇧⌘H: greeting by hour "Good morning/afternoon/evening", a search field that opens the ⌘K results, widgets (World Clock, Today, Disk Space, Downloads Inbox, Photo Frame, Pinned Folder), Recent files, and Customize toggles.
- F5.15: ⌘. or a 0.5 s press shows up to six quick actions, in the order set in Settings.

- [ ] Tests: `Greeting.text(hour:)` in core (`5→"Good morning"`, `14→"Good afternoon"`, `20→"Good evening"`); SelfTest: holding add + clear persists in the store.
- [ ] Green on both. Commit `feat: Home, Drop Shelf, Holding, menu bar and quick actions`.

### Task 12: Settings, appearance, motion & sound, welcome

**Files:** Create `Sources/FileOSCore/Settings.swift` (`struct AppSettings: Codable` with defaults), its tests, `Sources/FileOSApp/Views/SettingsView.swift` (`Settings` scene), `WelcomeView.swift`, `Sounds.swift`.

**Interfaces — Produces:** `AppSettings { appearance: .light/.dark/.system; accent: String; folderStyle: .glass/.plain/.flat/.finder; folderColor; sidebarSize: .small/.medium/.large; motion: .none/.quiet/.glide/.zoom; sound: nil/.soft/.click/.wood/.mac; backspaceTrashes = false; startInLastFolder = true; downloadsPath; terminalApp = "Terminal"; editorApp = "VS Code"; dropShelfKey = "Alt+Space"; dropShelfOnDrag = true; menuBar = true; quickActions; shortcuts: [String: KeyCombo]; welcomed = false }`. Decoding a partial JSON fills defaults, so old settings files keep working.

Features:
- F17.1–F17.6: a search field filters rows. Sections: About (version, What's New, Guide link), General, Appearance, Window (toolbar items), Motion and Sound (`NSSound` / generated tones, off by default; Reduce Motion → fade), Quick Actions (reorder), Shortcuts, Folder Access, Open In, Drop Shelf, Menu Bar.
  - Shortcuts: search, click to record, Esc keeps, ⌫ removes, Reset, Restore Defaults, conflict alert "Keep It There" / "Use It Here"; fixed rows are disabled.
  - Folder Access: Desktop/Documents/Downloads "Opens" / "Not allowed", Check Again, Open System Settings.
- F1.5 welcome without licensing: Get Started; tour with Continue/Skip; "Move and Reopen" prompt if not in /Applications; Full Disk Access step with "Not now"; Make FileOS yours; "Start using FileOS".
- F1.10 What's New.
- F1.7: panes and view restored on relaunch.

- [ ] Tests: decoding `{}` → all defaults; decoding `{"motion":"zoom"}` keeps the other defaults; round-trip. SelfTest: settings appearance `.dark` maps to `ColorScheme.dark`.
- [ ] Green on both. Commit `feat: settings, appearance, motion and welcome flow`.

### Task 13: Whole-branch review, README

**Files:** Create `README.md`: what it is, `swift run FileOSApp`, `scripts/bundle.sh`, tests, a coverage table mapping FEATURES.md IDs to status, and the skipped items with reasons.

- [ ] A fresh reviewer runs the superpowers:requesting-code-review flow on the whole branch against FEATURES.md and this plan.
- [ ] Fix the findings; Linux and CI green. Commit `docs: README and final review fixes`; push.

## Skipped (from FEATURES.md, with reasons)

- F1.8 licensing/payments: would imitate the vendor's payment flow.
- F1.9 auto-update: no update server.
- F1.11 translations: v1 is English only.
- F2.7 iPhone import: needs ImageCaptureCore.
- F7.4 screenshot OCR: needs Vision.
- F15.4 Spotlight/Shortcuts/Siri: needs App Intents, later.
