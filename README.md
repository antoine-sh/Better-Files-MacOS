# Better Files (FileOS reproduction)

A native Swift/SwiftUI reproduction of **FileOS**, the macOS file manager described at
[fileosmac.com](https://fileosmac.com). This is an original implementation built from the public
feature description in [`FEATURES.md`](FEATURES.md). It uses no code or assets from the real app.

Its principles come from the original: nothing moves unless you ask, every change can be undone, cleaning
tools show a plan and move items to the Trash, and the only permanent delete is Empty Trash, which always
asks first.

## Requirements

- macOS 15 or later
- Xcode 16 / Swift 6 (Swift tools 6.0). No third-party packages.

## Run

```sh
swift run FileOSApp            # launches the app
scripts/bundle.sh              # builds a release FileOS.app in the repo root
```

Set `FILEOS_HOME=/some/folder` to run against a different home folder.

The **DMG** workflow (`.github/workflows/dmg.yml`) builds `FileOS.dmg` on pushes to `main`, on `v*` tags (attached to the GitHub release) and on demand. It is signed ad hoc, not notarized, so macOS asks before the first open (right-click > Open).

## Test

```sh
swift test                          # FileOSCore unit tests (also run on Linux)
swift run FileOSApp --self-test     # headless app smoke test (macOS); prints "SELFTEST PASS"
```

GitHub Actions (`.github/workflows/ci.yml`, `macos-15`) runs all three steps on every push: build, unit
tests and the self-test.

**Honest caveat:** the UI has been checked only by the CI self-test. That test builds the window
offscreen and drives the models, so it has not been looked at or used on a real screen. Behaviour that
depends on a real Mac is unverified: global hotkeys, panel focus, drag-start monitoring, ejecting drives,
and privacy (TCC) prompts.

## Architecture

- **`FileOSCore`** is all the logic, using Foundation only: listing, transfers with clash handling,
  trash and undo, rename rules, search, Tidy, Smart Clean, workspaces, bookmarks, git, the package
  managers and settings. It builds and is unit-tested on Linux and macOS. Shell-outs go through an
  injectable `CommandRunner` with an argument array and a timeout.
- **`FileOSApp`** is a thin SwiftUI + AppKit layer, built on macOS only. It holds the `@MainActor
  @Observable` models (`AppModel`, `PaneModel` and others), the views, and the `--self-test` runner.
  Folder listings, searches and scans run off the main actor; a few small reads (volume list, disk line) still run on it.

## Coverage of FEATURES.md

| Section | Status | Notes |
|---|---|---|
| F1 App shell & onboarding | Partial | Window, toolbar, status bar, menus, welcome, keeps running, restore state and What's New are built. F1.8, F1.9 and F1.11 are skipped (see below). |
| F2 Sidebar | Partial | Sections (with iCloud Drive, cloud drives and Finder tags via Spotlight), add/remove favourites, drops, disk line, eject, sidebar sizes, sidebar search and ⌃⌘S are built. Missing: hiding drives, the "?" for a moved favourite, and dragging a folder in. F2.7 is skipped. |
| F3 Browsing | Done | List, icon and column views, sizes, cards, grouping and sorting, filter, live updates, preview pane, Insights and the locked-folder screen. |
| F4 Path bar | Done | Crumbs, typed paths, near-miss errors, command words, git chip and Copy Path. |
| F5 File operations | Partial | Built except: no "Move with Finder" fallback when trashing fails, and archives cover .zip only (no .7z, .rar or .tar.gz). |
| F6 Peek & Markdown | Partial | Some Info drawer extras and full screen are missing. |
| F7 Search (⌘K) | Partial | No thumbnails in results and no PDF contents search. F7.4 OCR is skipped. |
| F8 Dual pane & layouts | Done | |
| F9 Smart Downloads | Done | |
| F10 Smart Clean | Partial | The disk breakdown in F10.1 (apps, system, snapshots) is deferred. Only free, used, total and the Trash are shown. |
| F11 Workspaces | Done | |
| F12 Bookmarks | Partial | Services > "Save Link to FileOS" (from FileOS.app built by scripts/bundle.sh). No Share extension. |
| F13 Folder symbols & colours | Done | |
| F14 Developer tools | Done | |
| F15 Drop Shelf & menu bar | Partial | Notch hover is not verified. F15.4 is skipped. |
| F16 Home | Done | Stickers come from a fixed emoji set. |
| F17 Settings | Done | Open at login needs the bundled `.app`. |
| F18 Keyboard map | Done | All shortcuts can be rebound in Settings > Shortcuts. |
| F19 Requirements | Done | macOS 15+, SwiftUI. Folder listings run off the main actor. |

### Skipped, and why

- **F1.8 Licensing:** a reproduction must not imitate the vendor's payment and licensing flow.
- **F1.9 Auto-update:** there is no update server.
- **F1.11 Six languages:** English only for now.
- **F2.7 iPhone in sidebar:** needs ImageCaptureCore.
- **F7.4 Screenshot OCR:** needs the Vision framework.
- **F15.4 Spotlight / Shortcuts / Siri:** needs App Intents in an app bundle.
- **F10.1 disk breakdown:** deferred. Sizing the whole disk is expensive, and the breakdown is display-only.
- **Share extension:** needs an app extension target, which this Swift package doesn't have. Services covers saving links from other apps.
