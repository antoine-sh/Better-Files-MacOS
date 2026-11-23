# FileOS Reproduction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. One implementer per task, then an independent reviewer, then commit. Steps use `- [ ]`.

**Goal:** A working macOS file manager ("Better Files") that reproduces the FileOS features marked **[R]** in `FEATURES.md`.

**Architecture:** Electron app. All logic lives in `src/core/` as plain Node ES modules with no Electron import, unit-tested with `node --test`. `src/main/` is a thin Electron shell that exposes core through one whitelisted RPC channel. `src/renderer/` is vanilla JS ES modules (no build step) drawing the UI. E2E tests drive the real app with Playwright's `_electron` under `xvfb-run`.

**Tech Stack:** Node 22, Electron 33.2.1, `marked` 15.0.6 (Markdown), Playwright (pre-installed, global) for E2E. Nothing else.

**Spec:** `FEATURES.md` (feature IDs `F<n>.<m>` below refer to it).

**Why not SwiftUI:** the real app is SwiftUI, but this build machine is Linux with no Swift toolchain (installing one was refused). Electron runs on macOS and can be built and tested here. The core is UI-independent, so it could be ported later.

## Global Constraints

- `package.json` has `"type": "module"`. Preload is `src/main/preload.cjs` (sandboxed preloads must be CommonJS).
- `src/core/**` must never import `electron`. Renderer may import only core files with no `node:` imports (`kinds.js`, `shortcuts.js`, `rename.js`).
- Every core function that touches disk takes paths as arguments (no hidden `os.homedir()` inside logic), so tests run on temp dirs. Home comes from `process.env.FILEOS_HOME ?? os.homedir()` in `src/main/main.js` only. User data dir: `process.env.FILEOS_USERDATA ?? app.getPath('userData')`.
- Nothing deletes for good except Empty Trash (always confirmed). Trash = move into `trashDir` (default `<home>/.Trash`, macOS's per-user Trash) with a unique name. `// shortcut: other volumes have their own .Trashes; upgrade to shell.trashItem + no-undo for those.`
- Every mutating action pushes onto the main-process `UndoStack` and the UI shows a toast with **Undo**. Undo never overwrites: it reports files it could not restore.
- Copy text verbatim from FEATURES.md (e.g. "untitled folder", "Moved 1 item to the Trash", "Keep Both").
- Renderer: `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`. Any file/HTML text inserted with `innerHTML` goes through `esc()`.
- RPC: renderer calls `window.fileos.call(method, ...args)`; main only dispatches names in the whitelist object in `src/main/rpc.js`.
- Commit messages end with the session's Co-Authored-By / Claude-Session lines.
- Commands: `npm test` = `node --test tests/core/`; `npm run e2e` = `xvfb-run -a node --test tests/e2e/` (tests launch Electron with `--no-sandbox --disable-gpu` on Linux).

## Review Focus

1. **Names with spaces, unicode, quotes, leading dots, and `.tar.gz`** in rename, unique-name and tidy. Expect `"a b.tar.gz"` → `"a b 2.tar.gz"`, and no crash. Pinned in Task 1 and Task 2 tests.
2. **Moving a folder into itself or its own child** (drag, F6, paste). Expect the refusal "Can't move “X” into itself" with nothing changed. Pinned in Task 2.
3. **Unreadable folder (EACCES/EPERM)**. Expect the locked-folder screen (F3.13), never a blank pane or an unhandled rejection. Pinned in Task 1 (`listDir` throws `{code:'EACCES'}`) and Task 4 (renderer shows the screen).
4. **Undo after the world changed** (the original path is now taken). Expect no overwrite, and the failure listed. Pinned in Task 1 `restore` and Task 2.
5. **Huge folders (10k files) and symlink loops** in search, sizes and smart clean. Expect bounded depth/limits and no infinite recursion. Pinned in Task 6 (search `maxDepth`, symlinks not followed) and Task 8.

---

### Task 1: Scaffold, kinds, filesystem ops, undo

**Files:** Create `package.json`, `.gitignore`, `src/core/kinds.js`, `src/core/fsops.js`, `src/core/undo.js`, `tests/core/kinds.test.js`, `tests/core/fsops.test.js`, `tests/core/undo.test.js`, `tests/helpers.js`.

**Interfaces — Produces:**
- `kinds.js`: `KINDS = ['PDFs','Images','Screenshots','Videos','Installers','Archives','Audio','Documents','Other']`; `kindOf(name: string): string`; `isDownloading(name): boolean` (`.crdownload .download .part .opdownload`); `splitExt(name): [base, ext]` (`.tar.gz .tar.bz2 .tar.xz` count as one extension; a leading-dot name has no extension); `formatBytes(n): string` ("1.2 GB", base 1000 like Finder).
- `fsops.js`: `listDir(dir, {showHidden=false}) → Entry[]` where `Entry = {name, path, isDir, isSymlink, size, mtimeMs, birthtimeMs, addedMs, kind, hidden}` (`kind` = `'Folder'` for dirs); `uniqueName(dir, name) → string`; `newFolder(dir) → path`; `duplicate(path) → path`; `makeAlias(path) → path`; `renameItem(path, newName) → newPath`; `trash(paths, trashDir) → Move[]` with `Move = {from, to}`; `restore(moves) → {restored: string[], failed: {path, reason}[]}`; `emptyTrash(trashDir) → {count, bytes}`; `trashSummary(trashDir) → {count, bytes}`; `dirSize(dir, {maxEntries=200000}) → {bytes, items}` (no symlink following); `diskInfo(path) → {total, free}` (`fs.statfs`).
- `undo.js`: `class UndoStack { push(label: string, undo: () => Promise<any>); undo() → Promise<{label, result}|null>; get canUndo(); peekLabel() }` (max 100).
- `tests/helpers.js`: `tmpdir() → Promise<string>` (fresh dir, removed `after`), `touch(dir, rel, content='x', mtimeMs?)`.

- [ ] Write failing tests: `kindOf('a.PDF')==='PDFs'`, `kindOf('Screenshot 2026-11-01 at 10.00.00.png')==='Screenshots'`, `kindOf('x.dmg')==='Installers'`, `kindOf('x.tar.gz')==='Archives'`, `kindOf('noext')==='Other'`; `splitExt('a b.tar.gz')` → `['a b','.tar.gz']`, `splitExt('.env')` → `['.env','']`; `uniqueName` gives `'a b 2.tar.gz'` then `'a b 3.tar.gz'`; `newFolder` twice gives `untitled folder`, `untitled folder 2`; `duplicate('report.pdf')` gives `report copy.pdf` then `report copy 2.pdf`; `trash` then `restore` round-trips; `restore` with the original path re-created reports it in `failed` and leaves both files; `listDir` on a `chmod 000` dir rejects with `code` `EACCES` (skip the test when running as root); hidden files are excluded unless `showHidden`; `UndoStack` runs undos LIFO and `undo()` on empty returns `null`.
- [ ] Run `npm test`. Expect failures.
- [ ] Implement. `addedMs` = `birthtimeMs` (`// shortcut: macOS "Date Added" lives in Spotlight metadata; birthtime is close enough for downloads`).
- [ ] Run `npm test`. Expect all to pass.
- [ ] Commit `feat(core): scaffold, file kinds, fs ops and undo stack`.

### Task 2: Transfers with name clashes, rename & batch rename

**Files:** Create `src/core/transfer.js`, `src/core/rename.js`, `tests/core/transfer.test.js`, `tests/core/rename.test.js`.

**Interfaces — Consumes:** Task 1 `uniqueName`, `trash`, `restore`, `splitExt`. **Produces:**
- `transfer(sources: string[], destDir, {mode:'copy'|'move', trashDir, resolve, onProgress, signal}) → {results: {from, to, action:'copied'|'moved'|'skipped'|'replaced'}[], stopped: boolean, undo: () => Promise<{restored, failed}>}`.
  - `resolve({name, destDir, remaining}) → Promise<{choice:'keepBoth'|'replace'|'skip'|'stop', applyToAll:boolean}>` is called on a clash. Keep Both uses `uniqueName`. Replace trashes the old item first (undo restores it).
  - `onProgress({currentName, bytesDone, bytesTotal, itemsDone, itemsTotal})`.
  - A move falls back to copy + remove on `EXDEV`. A source equal to destDir or an ancestor of it throws `Error("Can't move “X” into itself")` before touching anything. Moving to the source's own folder is a no-op.
  - Undo for a copy trashes the copies. Undo for a move moves the items back.
- `rename.js`: `validateName(name): string|null` with exact messages `"Name can't be empty"`, `"Names can't contain / or :"`, `"Names can't start with a dot"`, `"Name is too long"` (> 255 UTF-8 bytes); `extensionChange(oldName, newName): null | {from:'.pdf', to:'.docx'}`; `planBatchRename(names: string[], rule, existing: Set<string>) → {from, to, error}[]` where `rule` is `{type:'replace', find, with}` | `{type:'add', text, where:'before'|'after'}` | `{type:'number', name, start=1}` (pad to ≥2 digits: `Lisbon 01.jpg`). Extensions are always kept. Errors: validateName messages, `"Duplicate name"`, `"Already in this folder"`. Downloading files get `error: "Still downloading"`.
  - `applyBatchRename(dir, plan) → {renamed: number, undo}` applies only rows with no error.

- [ ] Write failing tests: copy into a dir with a clash and `keepBoth` gives `Brand-Guide 2.pdf`; `replace` puts the old file in trash and `undo()` brings it back; `applyToAll` asks only once for 3 clashes; `stop` sets `stopped` and leaves the rest; moving `a/` into `a/b/` throws "Can't move “a” into itself" and nothing moves; undo of a move restores the original paths; progress reports `itemsDone === itemsTotal` at the end. Rename: `validateName('a/b')`, `validateName('.x')`, `validateName('')`; `extensionChange('a.pdf','a.docx')` → `{from:'.pdf',to:'.docx'}`; number rule on `['x.jpg','y.jpg']` with `name:'Lisbon'` → `Lisbon 01.jpg`, `Lisbon 02.jpg`; replace rule producing two equal names → both `"Duplicate name"`; a name that is already in the folder → `"Already in this folder"`.
- [ ] Run, expect fail. Implement. Run `npm test`, expect pass.
- [ ] Commit `feat(core): transfers with clash handling, rename and batch rename`.

### Task 3: Path bar & Open In

**Files:** Create `src/core/pathbar.js`, `src/core/openin.js`, `tests/core/pathbar.test.js`, `tests/core/openin.test.js`.

**Interfaces — Produces:**
- `COMMANDS: Record<word, appId>` with `terminal, code, cursor, xed, zed, subl, iterm, warp, ghostty, nova, bbedit, idea, pycharm, webstorm, goland, clion, rider, phpstorm, rubymine, windsurf`.
- `parseInput(input, {cwd, home}) → {type:'command', appId, target} | {type:'path', raw}`. A command is `<word>` or `<word> <relative-or-.>`. If `cwd` has a child folder named exactly the input (e.g. `code`), it is a path.
- `resolvePath(raw, {cwd, home}) → {type:'folder', path} | {type:'file', path, dir} | {type:'missing', name, parent, suggestion: string|null}`. Handles `~`, `~/x`, absolute, relative to cwd, and a bare name that matches a child of cwd or home case-insensitively. `suggestion` is the closest child name of `parent` or home (Levenshtein ≤ 2), returned as `~/…` when under home.
- `complete(input, {cwd, home}) → string[]` (folders only, case-insensitive prefix, sorted, ≤ 20; keeps the user's `~` form).
- `missingMessage(name, parent, home)` → `There's no folder called “${name}” in ${basename(parent)}`.
- `openin.js`: `APPS: {id, name, kind:'terminal'|'editor', macName}[]` (Terminal, iTerm, Warp, Ghostty; VS Code, VS Code Insiders, Cursor, Windsurf, Zed, Xcode, Sublime Text, Nova, BBEdit, IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, PhpStorm, RubyMine, Android Studio, cmux); `openTarget(kind, selection: Entry[], cwd) → path` (terminal: selected folder or cwd; editor: first selected item or cwd); `openArgs(app, path) → ['-a', macName, path]` for `/usr/bin/open` (execFile, never a shell).

- [ ] Write failing tests: `~/Doc` + Tab completes to `~/Documents`; `parseInput('code .')` is a command; with a `code` folder in cwd, `parseInput('code')` is a path; `resolvePath('Documnts')` → missing with suggestion `~/Documents`; a file path → `{type:'file'}` with its dir; `openTarget('terminal', [file], cwd)` → cwd.
- [ ] Run, fail, implement, pass. Commit `feat(core): path bar parsing, completion and Open In`.

### Task 4: Electron shell & basic browser

**Files:** Create `src/core/store.js`, `src/main/main.js`, `src/main/rpc.js`, `src/main/preload.cjs`, `src/main/menu.js`, `src/renderer/index.html`, `src/renderer/styles.css`, `src/renderer/api.js`, `src/renderer/app.js`, `src/renderer/util.js`, `src/renderer/views/sidebar.js`, `src/renderer/views/pathbar.js`, `src/renderer/views/browser.js`, `src/renderer/views/dialogs.js`, `tests/core/store.test.js`, `tests/core/rpc.test.js`, `tests/e2e/helpers.js`, `tests/e2e/browse.test.js`.

**Interfaces — Consumes:** Tasks 1–3. **Produces:**
- `createStore(file) → {get(key, fallback), set(key, value)}` (JSON, write to tmp then rename).
- `createRpc({home, trashDir, store, undo, openApp, notify}) → {call(method, args): Promise}` with whitelist: `home, listDir, resolvePath, complete, parseInput, newFolder, duplicate, makeAlias, rename, batchRename, trash, emptyTrash, trashSummary, transfer (clash answers come back through notify/answer), answer, undo, dirSize, diskInfo, openPath, showInFinder, openIn, copyText, storeGet, storeSet`. Unknown method rejects with `Error('Unknown method')`. `notify(channel, payload)` sends `progress`, `clash`, `toast`, `fs-change`, `menu` events.
- `window.fileos = {call(method, ...args), on(channel, fn)}` from preload.
- `util.js`: `esc(s)`, `h(html)` → element, `fmtDate(ms)`, re-exports `formatBytes`.
- `app.js` state: `{panes:[{path, history, fwd, selection:Set, view:'list'|'icons'|'columns', sort, group, filter}], active:0, showHidden, page:'browser'|'home'|...}`. `navigate(path)`, `render()`.
- Toast API in `dialogs.js`: `toast(text, {undo:boolean})`, `confirmDialog({title, body, ok, cancel})`, `clashDialog({name, destName, remaining})`.

Window (F1.1–F1.3, F2.1, F2.4, F4.1–F4.3): sidebar with Favorites (Desktop, Documents, Downloads, Pictures, custom), Tools, Locations (home, `/`, `/Volumes/*`, Trash; folded by default); toolbar with Back/Forward; path bar crumbs + ⌘L edit mode with Tab completion, error with "Did you mean" and "Create This Folder"; list view (Name, Date Modified, Size, Kind; click header sorts); status bar "N items, M selected, X available"; locked-folder screen with "Try Again" for EACCES/EPERM. `fs.watch` on the open folder sends `fs-change` and the pane refreshes.

- `browser.js` exports pure `errorView(err, folderName) → html string` (no DOM use): EACCES/EPERM → "FileOS needs access to “<name>”" + body + buttons "Give FileOS Full Access", "Allow Just This Folder…", "Try Again"; ENOENT → "Can't find “<name>”".

- [ ] Write failing unit tests: store round-trip and survives a missing file; rpc rejects `'evil'`; rpc `listDir` works on a temp dir; `errorView({code:'EACCES'}, 'Desktop')` contains "FileOS needs access to “Desktop”" and "Try Again" (container runs as root, so `chmod 000` can't be used in E2E).
- [ ] Write failing E2E `browse.test.js`: launch with `FILEOS_HOME` = temp home containing `Documents/a.txt`; sidebar shows "Documents"; clicking it lists `a.txt`; ⌘L, type `~/Doc`, Tab, Return navigates to Documents; ⌘L `~/Nope` Return shows "There's no folder called “Nope”".
- [ ] Implement; run `npm test` and `npm run e2e`; both pass.
- [ ] Commit `feat(app): Electron shell with sidebar, path bar and list view`.

### Task 5: Views, selection, file operations UI, keyboard map

**Files:** Create `src/core/shortcuts.js`, `src/renderer/views/context-menu.js`, `src/renderer/views/preview-pane.js`, `src/renderer/views/batch-rename.js`, `tests/core/shortcuts.test.js`, `tests/e2e/fileops.test.js`. Modify `browser.js`, `app.js`, `menu.js`, `rpc.js`, `styles.css`.

**Interfaces — Produces:**
- `DEFAULT_SHORTCUTS: Record<actionId, accel>` covering every key in FEATURES.md §18 (accel format `'Cmd+Shift+N'`, `'Ctrl+Alt+Cmd+1'`, `'F5'`, `'Alt+Space'`); `FIXED: Set<actionId>`; `matchEvent(ev, accel): boolean` (Cmd = `metaKey`; also accepts `ctrlKey` for Cmd when `process.platform`-less renderer reports non-mac via `navigator.platform` not starting with "Mac"); `findConflict(map, actionId, accel) → actionId|null`; `mergeShortcuts(userMap) → map`.
- `app.js` `runAction(actionId)`, dispatched from keydown and from the menu.

Features: icons view (cards, sizes Tiny…Large with ⌘+/⌘−, glass folder item counts) and columns view (F3.1–F3.3); group by kind/date (headers, view-only) and sort incl. "Files First" (F3.4), persisted per folder in store; hidden files ⇧⌘.; filter ⌘F; selection (click, ⌘, Shift, arrows, Shift-arrows, ⌘A, box-drag); folders expand in place in list view (›, → / ←); context menu (F3.10 items that exist so far); preview pane ⇧⌘P with metadata, Open, Show in Finder; clipboard ⌘C/⌘X/⌘V/⌥⌘V with dimmed cut items and Esc to cancel; Duplicate; ⌃⌘A alias; Return rename inline (name selected without extension, extension-change confirm "Keep .pdf" / "Use .docx"); batch rename dialog with live preview and red errors; ⇧⌘N / F7 new folder then rename; ⌘⌫ / F8 trash with "Moved N items to the Trash" toast; Empty Trash confirm with exact copy; ⌘Z undo; drag to move (⌥ copies) onto folders and sidebar favourites; ⌥⌘C copy path; ⌘R Show in Finder; ⌃⌘T add to sidebar; Go shortcuts (⇧⌘O/D/H/A/I, ⌥⌘L, ⌘[ ⌘] ⌘↑ ⌘↓); F2 rename, F3 Peek placeholder, F4 open in editor.

- [ ] Failing unit tests: `matchEvent({metaKey:true, shiftKey:true, key:'N'}, 'Cmd+Shift+N')`; `findConflict` detects a duplicate; no two defaults share an accel; every `FIXED` id exists.
- [ ] Failing E2E: ⇧⌘N creates "untitled folder" and shows it in rename mode; renaming to `a/b` shows "Names can't contain / or :"; select a file, ⌘⌫, toast "Moved 1 item to the Trash", ⌘Z brings it back; ⌘2 switches to icons; ⌘C then ⌘V in another folder copies.
- [ ] Implement; `npm test && npm run e2e` pass. Commit `feat(app): views, selection, file operations and shortcuts`.

### Task 6: Dual pane, layouts, transfer queue, Search ⌘K

**Files:** Create `src/core/search.js`, `src/renderer/views/search.js`, `src/renderer/views/transfers.js`, `tests/core/search.test.js`, `tests/e2e/dualpane.test.js`. Modify `app.js`, `browser.js`, `rpc.js`.

**Interfaces — Produces:** `search({roots, query, contents=false, kind='All', limit=200, maxDepth=6, signal}) → {path, name, isDir, kind, line?: {number, text}}[]` (case-insensitive substring on names; contents searches text files ≤ 2 MB; folders first, then files grouped by `KINDS` order; skips `node_modules`, `.git`, hidden dirs; never follows symlinks). Chip→kind map: Images→Images+Screenshots, Videos, Music→Audio, Documents→PDFs+Documents.

Features: F8.1–F8.3 (⌘D, Tab, ⌘U, ⌥⌘1–⌥⌘6 layouts up to four panes, named saved layouts in store listed first in the Dual Pane menu, preview hidden in multi-pane), F5/F6 with bar buttons `Copy to “<dest>”` / `Move`, cross-pane drag always moves (⌥ copies), transfer strip with "1.2 GB of 3.4 GB · 12 of 40 items", Cancel, queued "Waiting: …", clash dialog "“X” is already in “Y”" + Keep Both / Replace / Skip / Stop + "Do the same for all N items…", done toast "Copied 3 items to “Documents”" with Undo (F5.4, F5.5). ⌘K switcher (F7.1–F7.3): input "Search everything", chips, Contents toggle showing the matching line, also matches workspaces/bookmarks/saved layouts from store, Return opens, ⌥Return shows in folder, Space peeks.

- [ ] Failing unit tests: folders before files; `contents:true` finds `"needle"` inside `b.md` with its line number; a symlink loop `a/link -> a` terminates; `maxDepth` respected; kind chip filters.
- [ ] Failing E2E: ⌘D shows two panes; F5 copies selected file to the other pane; a clash shows the dialog and Keep Both gives `x 2.txt`; ⌘K, type a name, Return navigates.
- [ ] Implement; all tests pass. Commit `feat(app): dual pane, layouts, transfer queue and search`.

### Task 7: Peek & Markdown page

**Files:** Create `src/core/markdown.js`, `src/core/fileinfo.js`, `src/renderer/views/peek.js`, `src/renderer/views/markdown.js`, `tests/core/markdown.test.js`, `tests/core/fileinfo.test.js`, `tests/e2e/peek.test.js`. Add dependency `marked@15.0.6`.

**Interfaces — Produces:** `renderMarkdown(src) → html` (marked with raw HTML escaped, headings get slug ids, `[x]` tasks rendered as checked and struck through); `outline(src) → {level, text, id}[]`; `isMarkdownName(name)` (.md .markdown .mdown .mkd); `canShowAsPage(stat, buffer) → true | {reason}` (> 5 MB or not UTF-8 → reason). `fileInfo(path) → {kind, size, ...}` with text `words`/`lines`, image `width`/`height` (PNG/JPEG/GIF header parse), and zip listing `entries[]` (central directory parse, no extraction). `unzip(path, destDir)` via `/usr/bin/ditto -x -k` on darwin, `unzip` elsewhere (execFile).

Features: F6.1–F6.3, F5.14 (browse and unpack zips): Peek overlay on Space with images, PDF (`<embed>`), video/audio (`<video>`/`<audio>` playing a `file://` URL), text/code, zip listing, folder summary; "7 of 10"; ← → (only through the selection when several are selected); Return opens; Space/Esc closes; Info drawer toggle remembered; buttons Open, Open With, Share (macOS share via `shell`), Show in Finder. Markdown page on double-click/⌘↓ of a .md: Preview / Edit / Split, "On this page" outline, "Edited" bar with Revert / Save (⌘S), leaving with edits asks "Save the changes to “…”?" Save / Don't Save / Cancel.

- [ ] Failing unit tests: `<script>` in markdown is escaped; `outline('# A\n## B')`; task list rendering; 6 MB buffer → reason; PNG header gives width/height; zip listing names entries.
- [ ] Failing E2E: Space on `a.txt` shows its contents and "1 of 2"; → moves to the next; Esc closes; opening `notes.md`, switching to Edit, typing, ⌘S writes the file.
- [ ] Implement; tests pass. Commit `feat(app): Peek and Markdown page`.

### Task 8: Smart Downloads, folder symbols, Smart Clean

**Files:** Create `src/core/tidy.js`, `src/core/symbols.js`, `src/core/smartclean.js`, `src/renderer/views/tidy.js`, `src/renderer/views/insights.js`, `src/renderer/views/clean.js`, `tests/core/tidy.test.js`, `tests/core/symbols.test.js`, `tests/core/smartclean.test.js`, `tests/e2e/tidy.test.js`.

**Interfaces — Produces:**
- `planTidy(dir, {now, screenshotsTo:'Images'|'Pictures/Screenshots', installersToTrash:false, picturesDir}) → {moves:{from, to, kind}[], left:{name, reason}[], byKind: Record<kind, {count, bytes, dest}>}`. Only loose files. `left` reasons: `"Still downloading"`, `"Added in the last 2 minutes"`. Destination folders are named by kind under `dir`; existing folders are reused; clashes use `uniqueName`.
- `applyTidy(plan, {skipKinds:Set, trashDir}) → {moved, undo}`. Undo moves files back, then removes the folders it created if they are empty.
- `groupByDate(entries, now) → {label, items}[]` with labels `Today, Yesterday, Earlier this week, Earlier this month, Older`; `groupByKind(entries) → {kind, items, bytes}[]` (biggest first, downloading last).
- `downloadSuggestions(entries, {installedAppNames: Set, now}) → {installers, duplicates, older}` (duplicate pattern `/ \(\d+\)(\.\w+)?$|copy( \d+)?(\.\w+)?$/`, older = 90 days).
- `folderSymbol(dir, {home}) → {symbol, label}` following F13.1 exactly in that priority order. Symbols are strings: `desktop, documents, downloads, movies, music, pictures, home, applications, receipt, coin, graduationcap, airplane, briefcase, archivebox, forkknife, code, mostly:<kind>, more:<kind>, folders, empty, mixed, lock`.
- `scanSmartClean({home, now, trashDir, isAppRunning:(name)=>boolean}) → Card[]` with `Card = {id, title, group:'safe'|'yourCall', reason, items:{path, bytes, ticked, note?}[], bytes}`, in order `devCaches, duplicates, installers, mailAttachments, appLeftovers, bigFiles, unusedApps, screenRecordings, oldDownloads`. Dev cache paths (under home): `Library/Developer/Xcode/DerivedData`, `Library/Developer/Xcode/iOS DeviceSupport`, `Library/Developer/CoreSimulator/Caches`, `.npm/_cacache`, `Library/Caches/Homebrew`, `Library/Caches/pip`, `Library/Caches/Yarn`, `Library/Caches/CocoaPods`; Xcode ones skipped when `isAppRunning('Xcode')`. Duplicates: same size + same SHA-1 in Downloads, Desktop, Documents (depth ≤ 4, files ≥ 1 KB); keep the oldest; tick a spare only if it is in Downloads/Desktop or named like a copy. Big files > 500 MB and untouched 180 days; screen recordings > 30 days (`Screen Recording *.mov`); old downloads untouched 90 days. "Your call" items are never ticked.
- `diskSummary(home) → {free, total, used, trash}`.

Features: F9.1–F9.4 (Group by kind/date in Downloads, Insights panel ⌥⌘I with space by kind and the three suggestions, Tidy plan sheet ⌥⌘T with per-kind untick, "Move 17 Files", "Left where they are"), F13.1–F13.2 (automatic symbol on folder icons, Choose Symbol… and colour stored in store, undoable), F10.1–F10.5 (Free Up Space page ⌥⌘K with disk summary, nine cards "Looking…" then filled, card detail with Tick all / Untick all / "< All suggestions", bottom bar "4 ticked · 24.2 GB" + "Move 4 to Trash", toast with Undo, "Look Again").

- [ ] Failing unit tests: a file with `mtime` now-30 s ends up in `left` with "Added in the last 2 minutes"; `.crdownload` → "Still downloading"; tidy then undo restores every path and removes created empty folders; `report.pdf` clash → `report 2.pdf`; date labels for now, now-1 day, now-40 days; `Invoices` → receipt; folder with `package.json` → code; 3 jpg + 1 txt → `mostly:Images`; empty → empty; two identical files in Downloads and Documents → Downloads copy ticked, Documents kept; dev cache dir is listed with its size; "Your call" items unticked.
- [ ] Failing E2E: in Downloads, ⌥⌘T shows the plan and "Move N Files" moves them, ⌘Z undoes; ⌥⌘K shows "Free Up Space" with nine cards.
- [ ] Implement; tests pass. Commit `feat: Smart Downloads, folder symbols and Smart Clean`.

### Task 9: Workspaces & Bookmarks

**Files:** Create `src/core/workspaces.js`, `src/core/bookmarks.js`, `src/renderer/views/workspace.js`, `src/renderer/views/bookmarks.js`, `tests/core/workspaces.test.js`, `tests/core/bookmarks.test.js`, `tests/e2e/workspaces.test.js`.

**Interfaces — Produces:**
- `workspaces.js` (pure, on a plain array from the store): `createWorkspace(list, {name, description, color}) → {list, ws}` (`ws = {id, name, description, color, items:{id, type:'folder'|'file'|'link', path?, url?, pinned:boolean}[], archived:false, createdAt}`); `addItems(list, id, items)` (dedupe by path/url); `removeItem`, `pinItem` (max 6, returns `Error('You can pin up to six files')`), `archive`, `restore`, `deleteWorkspace`, `editWorkspace`, `sampleWorkspace(home)` ("Acme Project" with five tips). Every mutator returns a new list, so undo = store the previous list.
- `itemStatus(item, {exists, volumesMounted}) → 'ok'|'disconnected'|'missing'` with copy "“T7 Shield” isn't connected" and "Can't find it".
- `bookmarks.js`: `normalizeUrl(s) → string|null`; `addLink(state, url, {collectionId}) → {state, link, already:boolean}` (`link = {id, url, title, site, icon, image, type:'article'|'video'|'image'|'file', tags:[], favourite:false, collections:[], addedAt}`); `linkType(url)` (youtube/vimeo/.mp4 → video; image exts → image; .pdf/.zip/.dmg → file; else article); `parseTags('design, #swift') → ['design','swift']`; `filterLinks(links, {filter, query, collectionId, tag, sort:'newest'|'oldest'|'name'|'site'})`; `createCollection`, `deleteCollection` (deletes its links everywhere); `extractMeta(html, url) → {title, image, icon}` (`og:title` / `<title>`, `og:image`, `link rel=icon`, relative URLs resolved). Main fetches the page once with a 5 s timeout and 1 MB cap.

Features: F11.1–F11.5 (sidebar section with ⌃1–⌃9, ⌥⌘N sheet with name/description/colour, page with tabs Overview/Folders/Images/Documents/Links, pinned row ⌃⌥1–6, "Search in <name>", views List/Tiles/Cards/Changed Lately, card ⋯ menus, Add via picker or drag or right-click "Add to Workspace", missing-item states with Locate…, Archive/Restore, Delete asks and is undoable, sample workspace with "Remove Sample"); F12.1–F12.3 (All Bookmarks ⌥⌘B, ⌘V saves a copied link with "Saved"/"Already saved" + Undo, ⇧⌘L Add Link, ⌃⌥⌘B saves the clipboard link from anywhere in the app, collections ⌥⇧⌘N with name and icon, Favourites, Unsorted, Tags in sidebar, views Grid/Headlines/Masonry/List, sorts, filters, search, link ··· menu).

- [ ] Failing unit tests: create → add same folder twice → one item; pin a 7th → error; delete then restoring the previous list works; `addLink` the same URL twice → `already:true`; `parseTags`; `linkType('https://youtu.be/x')==='video'`; `extractMeta` reads og tags and resolves `/icon.png`; deleting a collection removes its links.
- [ ] Failing E2E: ⌥⌘N, type "Taxes 2026", Return → sidebar shows it; right-click a folder > Add to Workspace > Taxes 2026 → listed on the page without moving on disk.
- [ ] Implement; tests pass. Commit `feat: Workspaces and Bookmarks`.

### Task 10: Developer tools — Git, Installed, AI Agents, About This Mac

**Files:** Create `src/core/git.js`, `src/core/packages.js`, `src/core/agents.js`, `src/core/sysinfo.js`, `src/renderer/views/git.js`, `src/renderer/views/installed.js`, `src/renderer/views/agents.js`, `src/renderer/views/about-mac.js`, tests for each core file.

**Interfaces — Produces:**
- `gitInfo(dir, {run}) → null | {error:'git-missing'} | {branch, tag|null, changed, added, deleted, files:{status:'changed'|'new'|'deleted', path}[]}` using `git -C dir status --porcelain=v1 -b` and `git describe --tags --exact-match` through `run(cmd, args) → {stdout}` (default execFile, 3 s timeout). Read-only.
- `packages.js`: `TOOLS` (homebrew, npm, pip, pipx, cargo, gem, go) each `{id, name, list: [cmd, args], parse(stdout), removeCommand(pkg), cacheClean}`; `listPackages({run, home}) → {tools:{id, available, packages:{name, version, source:'You installed'|'Came with <x>', app?:boolean}[]}[]}`; `twoOfTheSame(packages)` (`node` & `node@24`); `brewfile(packages) → string` (`brew "x"` / `cask "y"`).
- `agents.js`: `AGENT_FILES` (exact lists from FEATURES.md F14.4); `scanProject(dir) → {agent, files}[]`; `parseMcp(json) → {name, command|url, kind:'local'|'online'}[]`; `listeningPorts({run}) → {port, pid, command}[]` (parse `lsof -nP -iTCP -sTCP:LISTEN`); `claudeUsage(home, now) → {today, week, month}` (sum `message.usage` input+output tokens in `~/.claude/projects/**/*.jsonl`); `copySetupPlan(src, dest, agent) → {path, state:'new'|'already there'}[]` (never `CLAUDE.local.md`, `settings.local.json`).
- `sysinfo.js`: `aboutMac({run, home, hideNames}) → {groups:{title, rows:{label, value, status:'ok'|'warn'|'bad'}[]}[]}` from `os` + `diskInfo` (+ `pmset -g batt`, `sw_vers`, `fdesetup status`, `csrutil status`, `spctl --status` on darwin, each optional); `asText(info) → string`. Hide Names replaces user/host with `you@this-mac`.

Features: F14.1 (git chip at the end of the path bar + panel with Copy Branch Name, "Everything is committed.", `xcode-select --install` hint), F14.2 (Open In toolbar menu, ⌥⇧⌘T / ⌥⇧⌘E, Settings defaults, path-bar words wired to `openin`), F14.3 (Installed page with totals, filters, Copy Remove Command, Save List… Brewfile, Refresh), F14.4 (AI Agents page: projects from workspaces/favorites + "Your Mac", setup files with Preview/Edit/Save, MCP list, localhost ports with Stop (confirm, SIGINT), Claude Code token usage, Start an Agent Here), F14.5 (About This Mac from the sidebar disk line, Hide Names, Copy as Text).

- [ ] Failing unit tests with a fake `run`: porcelain `## main...origin/main\n M a\n?? b\n D c` → branch main, 1/1/1; ENOENT → git-missing; brew parse and Brewfile; `scanProject` on a temp dir with `CLAUDE.md` and `.cursorrules`; `copySetupPlan` skips `CLAUDE.local.md`; lsof parse; usage sums only lines from today for `today`; `hideNames` removes the username.
- [ ] Implement views; `npm test && npm run e2e` pass (add one E2E: a git repo folder shows the branch chip). Commit `feat: git chip, Installed, AI Agents and About This Mac`.

### Task 11: Home, Drop Shelf, Holding, menu bar, Quick actions

**Files:** Create `src/main/dropshelf.js`, `src/main/tray.js`, `src/renderer/dropshelf.html`, `src/renderer/dropshelf.js`, `src/renderer/views/home.js`, `src/renderer/views/quick-actions.js`, `tests/e2e/home.test.js`. Modify `main.js`, `rpc.js`.

**Interfaces — Produces:** store keys `dropShelf.pinned: string[]`, `holding: string[]`, `quickAccess: string[]`, `home.widgets: Record<id, boolean>`. RPC `dropShelfMove(paths, folder, {copy})` (uses `transfer`, pushes undo), `holdingAdd/Remove/Clear`. `globalShortcut` registers the Drop Shelf key from settings (default `Alt+Space`) and reports a conflict if registration fails.

Features: F15.1–F15.3 (frameless always-on-top shelf window at the top centre, pinned folders five per row with counts, keys 1–9, Esc, drop → "Move here" (⌥ copies), "Just now: Moved “…” to Clients" + Undo, "Pin a folder", right-click Open in FileOS / Show in Finder / Unpin; Holding well that keeps paths, survives quit, drag out with `webContents.startDrag`, Clear; Tray with latest 5 downloads, Quick access, Add Folder…, Open FileOS, Settings…); F1.6 (closing the last window keeps the app running; ⌘Q quits); F16.1 (Home ⇧⌘H: greeting by hour "Good morning/afternoon/evening", search field that opens ⌘K results, widgets World Clock, Today, Disk Space, Downloads Inbox, Photo Frame, Pinned Folder, Recent files, Customize toggles); F5.15 (⌘. or 0.5 s press opens up to six quick actions, order in settings).

- [ ] Failing E2E: ⇧⌘H shows "Good" greeting and Disk Space widget; Customize hides a widget and it stays hidden after reload; Holding add via RPC then clear.
- [ ] Implement; tests pass. Commit `feat: Home, Drop Shelf, Holding, menu bar and quick actions`.

### Task 12: Settings, appearance, motion & sound, welcome

**Files:** Create `src/renderer/views/settings.js`, `src/renderer/views/welcome.js`, `src/renderer/sounds.js`, `tests/e2e/settings.test.js`. Modify `styles.css`, `app.js`, `main.js`.

**Interfaces — Produces:** store key `settings` = `{appearance:'light'|'dark'|'system', accent, folderStyle:'glass'|'plain'|'flat'|'finder', folderColor, sidebarSize:'small'|'medium'|'large', motion:'none'|'quiet'|'glide'|'zoom', sound:null|'soft'|'click'|'wood'|'mac', backspaceTrashes:false, startInLastFolder:true, downloadsDir, terminalApp, editorApp, dropShelfKey:'Alt+Space', dropShelfOnDrag:true, menuBar:true, quickActions:string[], shortcuts:Record, welcomed:false}`.

Features: F17.1–F17.6 (window with search box filtering section rows; sections About (version, What's New, Guide link), General, Appearance, Window (toolbar items), Motion and Sound (sounds via WebAudio, generated, off by default; Reduce Motion → fade), Quick Actions (reorder), Shortcuts (search, click to record, Esc keeps, ⌫ removes, Reset, Restore Defaults, conflict dialog "Keep It There" / "Use It Here", FIXED ones disabled), Folder Access (Desktop/Documents/Downloads "Opens"/"Not allowed", Check Again, Open System Settings via `x-apple.systempreferences:`), Open In, Drop Shelf, Menu Bar); F1.5 welcome flow minus licensing (Get Started, tour Continue/Skip, Move to Applications prompt on darwin, Full Disk Access step with "Not now", Make it yours, "Start using FileOS"); F1.10 What's New; F1.7 restore panes/view on relaunch.

- [ ] Failing E2E: first launch shows "Get Started"; Skip → main window; ⌘, opens Settings; choosing Dark sets `data-theme="dark"` on `<html>` and persists after relaunch; recording ⌘1 for another action shows the conflict dialog.
- [ ] Implement; tests pass. Commit `feat: settings, appearance, motion and welcome flow`.

### Task 13: Whole-branch review, README, packaging

**Files:** Create `README.md` (what it is, run `npm start`, tests, feature coverage table linking FEATURES.md IDs to status, skipped items and why). Add `"build"` script docs for `electron-builder` only as text (not installed).

- [ ] Fresh reviewer runs the superpowers:requesting-code-review flow on the whole branch against FEATURES.md and this plan.
- [ ] Fix findings; `npm test && npm run e2e` pass. Commit `docs: README and final review fixes`; push.

## Skipped (from FEATURES.md, with reasons)

F1.8 licensing/payments (would imitate the vendor's payment flow), F1.9 auto-update (no server), F1.11 translations (v1 English), F2.7 iPhone import (ImageCaptureCore), F7.4 screenshot OCR (Vision), F15.4 Spotlight/Shortcuts/Siri (App Intents).
