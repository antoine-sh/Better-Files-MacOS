import SwiftUI
import FileOSCore

/// F13: folder symbols and colours. Chosen ones are stored per canonical path ("folder.symbols",
/// "folder.colors") and undoable; automatic ones are worked out off the main actor and cached.
extension AppModel {
    static let symbolsKey = "folder.symbols"
    static let colorsKey = "folder.colors"
    /// Purple is the default; the other eight follow it (F13.3).
    static let folderColors: [String] = ["purple", "blue", "teal", "green", "yellow", "orange", "red", "pink", "gray"]
    static let symbolChoices: [String] = [
        "folder.fill", "star", "heart", "flag", "bookmark", "tag", "doc", "doc.text", "doc.richtext", "photo", "film",
        "music.note", "camera.viewfinder", "shippingbox", "doc.zipper", "archivebox", "receipt", "dollarsign.circle",
        "graduationcap", "airplane", "briefcase", "fork.knife", "house", "app", FolderSymbol.code, "hammer", "paintbrush",
        "gamecontroller", "book", "cart", "leaf", "pawprint", "lock",
    ]

    private static func key(_ url: URL) -> String { FileOps.canonical(url).path }
    private static func cacheKey(_ entry: Entry) -> String { "\(key(entry.url))|\(entry.modified.timeIntervalSince1970)" }

    func folderSymbol(_ entry: Entry) -> String {
        symbolOverrides[Self.key(entry.url)] ?? autoSymbols[Self.cacheKey(entry)] ?? FolderSymbol.foldersOnly
    }

    func hasChosenSymbol(_ url: URL) -> Bool { symbolOverrides[Self.key(url)] != nil }

    func folderColor(_ url: URL) -> Color? { colorOverrides[Self.key(url)].map { (name: String) -> Color in Self.color(name) } }

    static func color(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "teal": return .teal
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        case "pink": return .pink
        case "gray": return .gray
        default: return .purple
        }
    }

    /// Works out the automatic symbol once per folder version (views call this from `.task`).
    func loadSymbol(_ entry: Entry) async {
        let cache: String = Self.cacheKey(entry)
        guard autoSymbols[cache] == nil else { return }
        let url: URL = entry.url
        let home: URL = self.home
        let symbol: String = await Task.detached(priority: .utility) { () -> String in
            // Packages such as .app show their own icon ("" here), not a folder symbol.
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return "" }
            return FolderSymbol.automatic(for: url, home: home)
        }.value
        if autoSymbols.count > 5_000 { autoSymbols.removeAll() } // stale versions pile up in long sessions
        autoSymbols[cache] = symbol
    }

    /// Choose Symbol… (multi-select).
    func chooseSymbol(_ urls: [URL]) {
        symbolTargets = urls
        showSymbolChooser = true
    }

    /// nil: "Back to Automatic Symbol".
    func setSymbol(_ symbol: String?, for urls: [URL]) {
        setOverride(symbol, for: urls, colours: false, label: "Choose Symbol")
        toast(symbol == nil ? "Back to the automatic symbol" : "Changed the symbol of \(Self.folders(urls))", undoable: true)
    }

    /// nil: × resets the colour.
    func setColor(_ name: String?, for urls: [URL]) {
        setOverride(name, for: urls, colours: true, label: "Folder Colour")
        toast(name == nil ? "Reset the colour of \(Self.folders(urls))" : "Changed the colour of \(Self.folders(urls))", undoable: true)
    }

    private static func folders(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) folders"
    }

    private func setOverride(_ value: String?, for urls: [URL], colours: Bool, label: String) {
        let keys: [String] = urls.map { (u: URL) -> String in Self.key(u) }
        var old: [String: String] = [:]
        for k in keys {
            if let previous = colours ? colorOverrides[k] : symbolOverrides[k] { old[k] = previous }
        }
        applyOverrides(keys.map { (k: String) -> (String, String?) in (k, value) }, colours: colours)
        let before: [(String, String?)] = keys.map { (k: String) -> (String, String?) in (k, old[k]) }
        undo.push(label) {
            await self.applyOverrides(before, colours: colours)
            return RestoreResult(restored: urls)
        }
    }

    func applyOverrides(_ values: [(String, String?)], colours: Bool) {
        var map: [String: String] = colours ? colorOverrides : symbolOverrides
        for (k, v) in values { map[k] = v }
        if colours {
            colorOverrides = map
            store.set(Self.colorsKey, map)
        } else {
            symbolOverrides = map
            store.set(Self.symbolsKey, map)
        }
    }
}

/// A folder's symbol in its colour (or the accent colour), loading the automatic symbol as it appears.
struct FolderGlyph: View {
    let entry: Entry
    let size: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        glyph
            .task(id: entry) { await model.loadSymbol(entry) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        let symbol: String = model.folderSymbol(entry)
        // Settings > Appearance "Finder" style: the system folder icon, unless a symbol was chosen for it.
        let finder: Bool = model.settings.folderStyle == .finder && !model.hasChosenSymbol(entry.url)
        if symbol.isEmpty || finder {
            FileIcon(url: entry.url, side: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(model.folderColor(entry.url) ?? model.defaultFolderColor)
        }
    }
}

/// Choose Symbol…: a grid of symbols, colour dots and × (F13.2). Every pick is applied and undoable.
struct SymbolChooser: View {
    let urls: [URL]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let columns: [GridItem] = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(urls.count == 1 ? "Choose a Symbol for “\(urls[0].lastPathComponent)”" : "Choose a Symbol for \(urls.count) Folders")
                .font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AppModel.symbolChoices, id: \.self) { (symbol: String) in symbolButton(symbol) }
            }
            colourRow
            HStack {
                Button("Back to Automatic Symbol", action: { model.setSymbol(nil, for: urls) })
                Spacer()
                Button("Done", action: { dismiss() }).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func symbolButton(_ symbol: String) -> some View {
        Button(action: { model.setSymbol(symbol, for: urls) }) {
            Image(systemName: symbol).font(.title3).frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .help(symbol)
        .accessibilityLabel(symbol)
    }

    private var colourRow: some View {
        HStack(spacing: 8) {
            ForEach(AppModel.folderColors, id: \.self) { (name: String) in
                Button(action: { model.setColor(name, for: urls) }) {
                    Circle().fill(AppModel.color(name)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name.capitalized)
            }
            Button(action: { model.setColor(nil, for: urls) }) { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .help("Reset the colour")
                .accessibilityLabel("Reset Colour")
        }
    }
}
