# FileOS — Feature Inventory

Source: every public page of https://fileosmac.com (home, /docs/ and its 25 sub-pages,
/docs/shortcuts/, /changelog/, /reviews/, /download/), explored 2026-11-23.
Not readable: the homepage's Pricing / Compare / FAQ tail (truncated), legal pages, localized homepages.
All of this is the vendor's own description, not verified against the real binary.

FileOS is a paid, native macOS file manager ("A native file manager for your Mac.").
It opens the same folders Finder does and adds tidying, project grouping, dual panes,
rich previews and developer tools. Principles from the guide:

- Nothing moves unless you ask. Every action has Undo.
- New downloads are left alone (still downloading / added < 2 min ago).
- Works without Full Disk Access (asks per protected folder).
- Tools that "clean" always show a plan first and move to Trash, never delete.

Legend: each feature has an ID used by PLAN.md. **[R]** = to reproduce, **[S]** = skipped (reason given).

---

## 1. App shell & onboarding

| ID | Feature | Details |
|----|---------|---------|
| F1.1 [R] | Window layout | Six parts: sidebar, toolbar, path bar, file area, preview pane or Insights panel, status bar. |
| F1.2 [R] | Toolbar | L→R: Back/Forward (⌘[ ⌘]), Share, AirDrop (⇧⌘R), Open In, Group (None/Kind/Date), View (List/Icons/Columns), Preview (⇧⌘P), Insights (⌥⌘I), Dual Pane (⌘D) with Swap Panes (⌘U), Filter this folder (⌘F). Tool pages (Bookmarks, Free Up Space, Installed, AI Agents, workspaces) swap in their own buttons. Toolbar is customizable; New Folder and Move to Trash buttons optional (Settings > Window > Toolbar). |
| F1.3 [R] | Status bar | Item count, selected count, free space; icon size buttons (S/M/L); hidden-files state; copy/move progress with Cancel. |
| F1.4 [R] | Menus | File (Pin to Drop Shelf, Add to Quick Access, Add to Workspace, Tidy Folder…, Copy/Move to Other Pane), Edit (Move Item Here, Search), View (Open This Folder in the Other Pane), Go (Go to Workspace or Folder…, Go to Folder…), Help (Report a Bug…, Suggest a Feature…, Show the Sample Workspace). |
| F1.5 [R] | Welcome flow | Demo screen ("Turn into FileOS" → "Get Started"), language globe, tour (Continue/Skip), license step, "Move and Reopen" if not in /Applications, Full Disk Access step ("Not now"), "Make FileOS yours" (accent colour, view, sounds, menu bar icon, open at login), "Start using FileOS". |
| F1.6 [R] | Keeps running | Closing the last window does not quit (Drop Shelf ⌥Space keeps working). ⌘Q quits (also stops Drop Shelf and menu bar icon). |
| F1.7 [R] | Restore state | Panes, view, icon size, sort/group are restored after relaunch. Settings > Window: start in last folder. |
| F1.8 [S] | Licensing | $9.99/$11.99 one-time via Dodo Payments, 1 or 2 Macs, daily check, deactivate, red key errors. Skipped: a reproduction must not imitate the vendor's payment/licensing flow. |
| F1.9 [S] | Auto-update | Daily check from fileosmac.com, asks before installing. Skipped: no update server. |
| F1.10 [R] | What's New screen | Shown after an update; reachable from Settings > About. |
| F1.11 [S] | 6 languages | en, es, fr, de, ja, zh-Hans. Skipped for v1: English only (strings kept in one place). |

## 2. Sidebar

| ID | Feature | Details |
|----|---------|---------|
| F2.1 [R] | Sections | Workspaces (+ / ⌥⌘N), Bookmarks (All Bookmarks, Favourites, collections), Favorites (Desktop, Documents, Downloads, Pictures, custom), Tools (Free Up Space, Installed, AI Agents), Locations (iCloud Drive, cloud drives, home, disk, connected drives, Trash). Locations starts folded; others remember folded state. Tags (Red/Yellow/Orange…, "All Tags…"). |
| F2.2 [R] | Add / remove favourite | Right-click > Add to Sidebar, ⌃⌘T, or drag a folder in. Remove from Sidebar only removes the shortcut. Moved favourite shows "?"; click to relocate. |
| F2.3 [R] | Drops | Onto favourite/location: move (same disk) or copy (⌥). Onto workspace: add (no move). Links onto bookmarks/collection: saved. Trash takes no drops. |
| F2.4 [R] | Disk line | Bottom: Mac name, disk bar (orange ≥ 90% full), free space. Hover summary; click = About This Mac. |
| F2.5 [R] | Sizes | Sidebar size Small/Medium/Large. Show/hide ⌃⌘S. Sidebar search (1.1.1). |
| F2.6 [R] | Eject | ⏏ button, right-click, or ⌘E; refuses while copying to that drive. Hide cloud drives/disks from sidebar. |
| F2.7 [S] | iPhone in sidebar | Photos/videos/screenshots by day, copy to Mac, "On Mac" marks. Skipped: needs Apple's ImageCaptureCore. |

## 3. Browsing

| ID | Feature | Details |
|----|---------|---------|
| F3.1 [R] | Views | List ⌘1, Icons ⌘2, Columns ⌘3. List: click a column title to sort; folders open in place (disclosure ›, → / ←). Column: ↑↓ move, → enter, ← leave, Space Peek, Return rename; last column is the preview. |
| F3.2 [R] | Sizes | ⌘+ / ⌘−: Tiny, Extra Small, Small, Medium, Large. One size for all folders; remembered. List row sizes. |
| F3.3 [R] | Cards | Icons at Medium/Large show real previews (first page, photo, video frame), kind badge, name, kind, size, ⋯ menu. Glass folders show item count; ⓘ selects a folder. |
| F3.4 [R] | Group & sort | Group by Kind ⌃⌘K / Date added ⌃⌘D / None ⌃⌘0 (view-only, nothing moves). Sort name ⌃⌥⌘1, date modified ⌃⌥⌘3; toolbar Sort button with "Files First". Persisted per folder. |
| F3.5 [R] | Folder sizes | "Calculating folder sizes…" while sizing; counts iCloud files. |
| F3.6 [R] | Hidden files | ⇧⌘. toggles. |
| F3.7 [R] | Filter | ⌘F filters the current folder; clear restores. |
| F3.8 [R] | Selection | ⌘-click, Shift-click, Shift-arrows, box-drag, ⌘A. Shift-↓ in columns. |
| F3.9 [R] | Live updates | Folders refresh when files change elsewhere; stays quick while another app writes into it. |
| F3.10 [R] | Context menu | Open With, Peek, Quick Look, Choose Symbol…, Colour, Add to Workspace, Pin to Drop Shelf, Add to Quick Access, AirDrop…, Show in Finder, Copy Path, Move to Trash. |
| F3.11 [R] | Preview pane | ⇧⌘P. Kind, size, created/modified/added, location, Open, Show in Finder; folders show contents two levels deep; rename in preview. Hidden in dual pane and column view. |
| F3.12 [R] | Insights panel | ⌥⌘I. Space by kind, suggestions (see Smart Downloads). |
| F3.13 [R] | Locked folders | "FileOS needs access to “Desktop”" screen with "Give FileOS Full Access", "Allow Just This Folder…", "Try Again". |

## 4. Path bar

| ID | Feature | Details |
|----|---------|---------|
| F4.1 [R] | Crumbs | Click a crumb to go there. Drop a file on it to jump to its folder. Git chip at the end. |
| F4.2 [R] | Type a path | ⌘L or ⇧⌘G. Tab completes, ↑↓ choose, Return go, Esc cancel. Accepts `~`, absolute paths and bare folder names. A file path opens its folder with the file selected. |
| F4.3 [R] | Errors | "There's no folder called “…” in sam" + "Did you mean ~/…?" + "Create This Folder". |
| F4.4 [R] | Command words | `terminal`, `code .`, `cursor .`, `xed .`, `zed Sources` (subfolder), `subl .`, `iterm`, `warp`, `ghostty`, `nova`, `bbedit`, JetBrains (`idea`, `pycharm`, `webstorm`…). Only opens installed apps; runs no shell command. A folder really named `code` still opens as a folder. |
| F4.5 [R] | Copy path | ⌥⌘C, right-click > Copy Path (optional quotes). |

## 5. File operations

| ID | Feature | Details |
|----|---------|---------|
| F5.1 [R] | Clipboard | ⌘C / ⌘X / ⌘V; ⌥⌘V moves copied items here; Esc cancels a cut; cut items dimmed. "Paste into “folder”". |
| F5.2 [R] | Duplicate / Alias | Duplicate → "report copy.pdf". Make Alias ⌃⌘A. |
| F5.3 [R] | Drag & drop | Same disk moves, other disk copies, ⌥ copies; drag to sidebar or other apps. |
| F5.4 [R] | Name clash | "“Brand-Guide.pdf” is already in “Documents”": Keep Both (→ "Brand-Guide 2.pdf"), Replace (old to Trash, undoable), Skip, Stop; "Do the same for all N items…". |
| F5.5 [R] | Progress queue | "Copying “Team-Photos.zip”", "1.2 GB of 3.4 GB · 12 of 40 items", Cancel; "Waiting: …" queue; done toast "Copied 3 items to “Documents”" with Undo. |
| F5.6 [R] | Rename | Return; name selected without extension. Extension change asks "Keep .pdf" / "Use .docx". Rejects `/`, `:`, leading dot. |
| F5.7 [R] | Batch rename | Return with several selected / "Rename 4 Items…": Replace Text, Add Text, Name and Number ("Lisbon 01.jpg", chosen start). Live preview, invalid rows red with reason (duplicate, already in folder, `/` or `:`, leading dot, empty, too long). Extensions kept; downloading files skipped. Toast "Renamed 4 items" + Undo. |
| F5.8 [R] | New folder | ⇧⌘N (also F7) → "untitled folder", then rename. |
| F5.9 [R] | Trash | ⌘⌫ (or ⌫ if enabled), F8. Toast "Moved 1 item to the Trash". Failure says why (locked, protected, security software) and offers "Move with Finder". |
| F5.10 [R] | Empty Trash | Always asks: "Empty the Trash? 12 items (1.9 GB) will be deleted for good. This can't be undone." |
| F5.11 [R] | Undo | ⌘Z or toast Undo. Covers rename, new folder, trash, copy/move/paste, drags, F5/F6, Tidy, Smart Clean, folder symbol/colour, Drop Shelf drops, workspace edits. Never overwrites: reports files it couldn't restore. |
| F5.12 [R] | Commander keys | F2 Rename, F3 View, F4 Edit, F5 Copy to other pane, F6 Move, F7 New Folder, F8 Trash. |
| F5.13 [R] | Misc | AirDrop ⇧⌘R (dimmed when empty/downloading), Show in Finder ⌘R, Share. |
| F5.14 [R] | Archives | Zips browse in Peek and unpack in FileOS (.zip, .7z, .rar, .tar.gz); password zips go to Archive Utility. |
| F5.15 [R] | Quick actions | Hold a file 0.5 s or ⌘. → up to six actions, ordered in Settings > Quick Actions. |

## 6. Peek & Markdown

| ID | Feature | Details |
|----|---------|---------|
| F6.1 [R] | Peek | Space. PDFs, images, video/audio (plays), text, Office/iWork. "7 of 10"; with a multi-selection moves through just those; ← → navigate, Return open, Space/Esc close. Buttons: Open, Open With, Share, Add to Workspace, Show in Finder, Info (remembered). "Still downloading" / "In iCloud only". ⌘Y = macOS Quick Look. |
| F6.2 [R] | Info drawer | Photos: dimensions, camera, profile, date taken. PDFs: pages, title, author. Videos: duration, resolution, fps. Text: words, lines. Apps: version. "Where from" for downloads. Finder tags. |
| F6.3 [R] | Markdown page | .md/.markdown/.mdown/.mkd (≤ 5 MB, UTF-8). Preview / Edit / Split; "On this page" outline; task lists; "Edited" bar with Revert / Save ⌘S; leaving asks Save / Don't Save / Cancel; full screen; cheat sheet with copy buttons (1.4). |

## 7. Search (⌘K)

| ID | Feature | Details |
|----|---------|---------|
| F7.1 [R] | Switcher | "Search everything": workspaces, folders first, then files by kind, bookmarks, saved layouts. Chips: All, Workspaces, Folders, Images, Videos, Music, Documents, Bookmarks. Picture thumbnails and video length. |
| F7.2 [R] | Contents | "Contents" toggle searches inside documents/PDFs/code and shows the matching line. |
| F7.3 [R] | Keys | Space Peek, Return open, ⌥Return show in folder. |
| F7.4 [S] | Screenshot OCR | Needs Vision framework; skipped. |

## 8. Dual pane & layouts

| ID | Feature | Details |
|----|---------|---------|
| F8.1 [R] | Dual pane | ⌘D toggles; active pane underlined; Tab switches; ⌘U swaps; menus act on active pane. |
| F8.2 [R] | Transfer | F5 copy / F6 move to other pane; bar buttons "Copy to “Invoices 2026”" / "Move"; right-click "Copy to “…”"; drag across panes always moves, ⌥ copies. |
| F8.3 [R] | Layouts | One Pane ⌥⌘1, Side by Side ⌥⌘2, Stacked ⌥⌘3, Three Columns ⌥⌘4, One Big Two Small ⌥⌘5, Four ⌥⌘6. Named saved layouts ("Month end"), listed first in the Dual Pane button and in ⌘K. |

## 9. Smart Downloads (Tidy)

| ID | Feature | Details |
|----|---------|---------|
| F9.1 [R] | Kinds | PDFs, Images, Screenshots, Videos, Installers, Archives, Audio, Documents, Other. Biggest first; downloading files last in own group. |
| F9.2 [R] | Date groups | Today, Yesterday, Earlier this week, Earlier this month, Older. |
| F9.3 [R] | Suggestions | "Installers already installed" (Move to Trash…), "Likely duplicates" ("invoice (1).pdf", "notes copy.txt"), "Older than 90 days". |
| F9.4 [R] | Tidy plan | ⌥⌘T, "Tidy Downloads…" / "Tidy Folder…". Plan lists each kind's destination; untick to skip; screenshots with Images or Pictures > Screenshots; installers optionally to Trash. Button "Move 17 Files". Skips downloading or < 2 min old files ("Left where they are"); only loose files; reuses existing folders; clashes numbered ("report 2.pdf"). Undo also removes created folders once empty. |

## 10. Smart Clean (Free Up Space, ⌥⌘K)

| ID | Feature | Details |
|----|---------|---------|
| F10.1 [R] | Disk summary | "8.8 GB free of 245 GB on Macintosh HD · 236 GB used"; Your files, Apps, macOS & system, Snapshots & system data, Free, In the Trash. |
| F10.2 [R] | Nine cards | Appear at once grey with "Looking…"; "Look Again" rescans. |
| F10.3 [R] | Safe to clear (ticked) | Developer caches (strict list: Xcode DerivedData, device support, Simulator caches, npm, Homebrew, pip, Yarn, CocoaPods; Xcode's skipped while Xcode open; stale node_modules listed apart unticked). Duplicates (one copy always kept, oldest by default; ticked only if spare is in Downloads/Desktop or named like a copy; "Tick These Too"). Installers for installed apps (downloaded, not newer than app, > 1 week, in Downloads/Desktop). |
| F10.4 [R] | Your call (unticked) | Mail attachments, app leftovers (3 months), big files (> 500 MB, untouched 6 months), unused apps (6 months), screen recordings (> 30 days), old downloads (90 days). |
| F10.5 [R] | Act | Card detail Tick all / Untick all, "< All suggestions"; bar "4 ticked · 24.2 GB" + "Move 4 to Trash"; toast with Undo. Read-only until you click. |

## 11. Workspaces

| ID | Feature | Details |
|----|---------|---------|
| F11.1 [R] | Create | ⌥⌘N / + ; name, description, colour; start Empty, Folders and Files…, or Paste Link. |
| F11.2 [R] | Contents | References only ("Nothing is copied or moved"): folders, files, links from anywhere. Add via picker, drag, right-click > Add to Workspace, ⌘V links. |
| F11.3 [R] | Page | Tabs Overview / Folders / Images / Documents / Links; pinned up to six (⌃⌥1–6); search "Search in …"; views List / Tiles / Cards / "Changed Lately"; card ⋯ menus; Remove only unlists. |
| F11.4 [R] | Missing items | "T7 Shield isn't connected", "Can't find it" + Locate…. |
| F11.5 [R] | Manage | Open ⌃1–⌃9; Edit Workspace…, Colour, Archive (Restore), Delete (asks, undoable). Sample "Acme Project" workspace with tips + Remove Sample. |

## 12. Bookmarks

| ID | Feature | Details |
|----|---------|---------|
| F12.1 [R] | Save links | ⌘V on Bookmarks ("Saved" + Undo, "Already saved"), Add Link ⇧⌘L, ⌃⌥⌘B saves copied link, Share > FileOS, Services. Reads title, icon and picture once. |
| F12.2 [R] | Organise | Collections (⌥⇧⌘N, name + icon, delete asks), Favourites, Unsorted, Tags (comma or # separated). |
| F12.3 [R] | Browse | Views Grid / Headlines / Masonry / List (grouped by day); sort Newest, Oldest, Name, Site; search title/address/site/tag; filters All, Articles, Videos, Images, Files, Favourites. Link ··· menu: Open in Browser, Copy Link, Edit Title…, Add to Favourites, Tags…, Collections, In Workspace, Remove. |

## 13. Folder symbols & colours

| ID | Feature | Details |
|----|---------|---------|
| F13.1 [R] | Automatic symbol | Priority: (1) special folders (Desktop, Documents, Downloads, Movies, Music, Pictures, home, Applications); (2) name words (Invoices/Bills receipt, Taxes/Budget coin, School cap, Travel/Trip plane, Clients/Work briefcase, Backup/Archive box, Recipes fork-knife); (3) code project (.git, package.json, Package.swift, Cargo.toml, go.mod, .xcodeproj); (4) "Mostly <kind>" ≥ 3 files and ≥ 60% one kind; (5) more of one kind; (6) folders only; (7) empty; (8) mixed; (9) lock if unreadable. |
| F13.2 [R] | Manual | Choose Symbol… (multi-select), "Back to Automatic Symbol", colour dots, × resets, undoable. |
| F13.3 [R] | Folder style | Glass, Plain, Flat, Finder; folder colour (purple default + 8). |

## 14. Developer tools

| ID | Feature | Details |
|----|---------|---------|
| F14.1 [R] | Git chip | Branch (or tag) + uncommitted count. Panel: changed/new/deleted with file list, Open in Terminal, Copy Branch Name, "Everything is committed.". If git missing suggest `xcode-select --install`. Read-only. |
| F14.2 [R] | Open In | Right-click, toolbar menu (Choose Defaults…), ⌥⇧⌘T terminal / ⌥⇧⌘E editor, path-bar words. Terminals: Terminal, iTerm, Warp, Ghostty. Editors: VS Code (+ Insiders), Cursor, Windsurf, Zed, Xcode, Sublime, Nova, BBEdit, JetBrains IDEs, cmux; add any app. Terminal opens selected or current folder; editor opens selection or current folder. |
| F14.3 [R] | Installed | Homebrew, npm, pip, pipx, Cargo, RubyGems, Go: totals, share bar, filters (All, Apps, You installed, Came with others, Left behind), source + last run, Tidy-up chips (Caches with clean command, Two of the same, Not run lately), Copy Remove Command, Save List… (Brewfile), Refresh. Read-only. |
| F14.4 [R] | AI Agents | Projects for Claude Code, Codex, Cursor, Gemini CLI, Copilot, Antigravity, OpenCode; setup-file lists per agent (CLAUDE.md, .mcp.json, AGENTS.md, .cursorrules, GEMINI.md…); edit with Save/Revert; MCP server list; localhost ports with Stop; token usage from logs; Start an Agent Here; copy setup to another project (never personal files). |
| F14.5 [R] | About This Mac | Uptime, in use since, battery, memory, chip, disk, displays, security, software; Hide Names, Copy as Text. Reads only while visible. |

## 15. Drop Shelf, menu bar, Spotlight

| ID | Feature | Details |
|----|---------|---------|
| F15.1 [R] | Drop Shelf | ⌥Space (must include ⌘/⌥/⌃), on drag start, or notch hover. Pinned folders (5 per row, counts, keys 1–9), "Move here" (⌥ copies), result line with Undo, right-click Open/Show/Unpin. "Pin a folder". |
| F15.2 [R] | Holding | Amber well; remembers files without moving; drag out to apps or onto a folder to move all; Clear; survives quit. |
| F15.3 [R] | Menu bar panel | Latest 5 downloads, Quick access (6 folders + 2 recents + 4 workspaces), Add Folder…, drop to Holding, Open FileOS, Settings…. |
| F15.4 [S] | Spotlight / Shortcuts / Siri | Eight App Intents. Skipped: needs native App Intents. |

## 16. Home (1.4)

| ID | Feature | Details |
|----|---------|---------|
| F16.1 [R] | Home page | ⇧⌘H / house icon. Greeting ("Good evening") with one search field, widgets (World Clock, Today, Disk Space, Downloads Inbox, Photo Frame, Pinned Folder), Recent files, stickers; Customize shows/hides parts. |

## 17. Settings (⌘,)

| ID | Feature | Details |
|----|---------|---------|
| F17.1 [R] | Structure | Search box; changes apply at once. Sections: About, General, Appearance, Window, Motion and Sound, Quick Actions, Shortcuts, Folder Access, Open In, Drop Shelf, Menu Bar, Spotlight, License. |
| F17.2 [R] | General | Open at login, sound effects, Downloads folder choice, ⌫ alone trashes. |
| F17.3 [R] | Appearance | Light / Dark / As the Mac; accent (Mac's, purple, 8, custom); folder style + colour; sidebar size. |
| F17.4 [R] | Motion & Sound | Motion None / Quiet / Glide / Zoom (Reduce Motion → fade); folder-open sound Soft / Click / Wood / Mac (off by default). |
| F17.5 [R] | Shortcuts | Search, click and press new keys, Esc keeps, ⌫ removes, Reset, Restore Defaults; conflicts "Keep It There" / "Use It Here". Fixed: ⌘C ⌘V ⌘A ⌘Z Return Space Tab ⌃1–9 ⌘,. |
| F17.6 [R] | Folder Access | Desktop/Documents/Downloads "Opens" / "Not allowed", Check Again, Open System Settings. |

## 18. Full keyboard map (docs/shortcuts)

View ⌘1 ⌘2 ⌘3 · ⌘+ ⌘− · ⌃⌘K ⌃⌘D ⌃⌘0 · ⌃⌥⌘1 ⌃⌥⌘3 · ⇧⌘P · ⌥⌘I · ⇧⌘. · ⌃⌘S · ⌘F
Go ⌘[ ⌘] ⌘↑ · ⌘L / ⇧⌘G · ⌘↓ · ⌘K · ⇧⌘O Documents · ⌥⌘L Downloads · ⇧⌘D Desktop · ⇧⌘H Home · ⇧⌘A Applications · ⇧⌘I iCloud Drive · ⌥⌘B Bookmarks · ⌥⌘K Smart Clean
Files Space/⌘Y · Return rename · ⇧⌘N · ⌘C ⌘X ⌘V ⌥⌘V · ⌘A · ⌥⌘C · ⌃⌘A · ⇧⌘R · ⌘R · ⌃⌘T · ⌥⇧⌘T · ⌥⇧⌘E · ⌥⌘T · ⌘⌫ · ⌘Z · ⌘. quick actions
Two panes ⌘D · Tab · F5 · F6 · ⌘U · ⌥⌘1–⌥⌘6 layouts
Workspaces ⌃1–⌃9 · ⌥⌘N · ⌃⌥1–6 pinned · Bookmarks ⌥⇧⌘N · ⇧⌘L · ⌃⌥⌘B
Drop Shelf ⌥Space, 1–9, Esc · App ⌘, ⌘Q · Peek ← → Return Space Esc · Path bar Tab ↑↓ Return Esc

## 19. Requirements & claims

macOS 15+, SwiftUI, Apple silicon & Intel. Performance: no waiting for slow network drives / sleeping disks / iCloud on return; fast in big folders. Changelog 1.0 (12 Nov 2026) → 1.4 (23 Nov 2026).
