import SwiftUI
import AppKit
import FileOSCore

/// An open setup file: what's on disk and what's being typed.
@MainActor @Observable
final class SetupEditor {
    let url: URL
    var text: String
    private(set) var saved: String
    var editing = false
    /// "Too large to preview" / "Can't read": shown instead of the text, and Edit is off.
    let problem: String?

    init(url: URL, text: String, problem: String? = nil) {
        self.url = url
        self.text = text
        saved = text
        self.problem = problem
    }

    var isEdited: Bool { text != saved }
    func revert() { text = saved }
    func markSaved(_ s: String) { saved = s }
    func undoSave(to previous: String, from written: String) {
        if text == written { text = previous }
        saved = previous
    }
}

struct PortToStop: Equatable {
    let port: ListeningPort
}

struct SetupCopy {
    let agent: Agent
    let from: URL
    let to: URL
    let plan: [SetupPlanItem]
    var newCount: Int { plan.filter { (i: SetupPlanItem) -> Bool in i.state == "new" }.count }
    var thereCount: Int { plan.count - newCount }
}

/// F14.4 AI Agents state. Reads only; writes a setup file only on Save or Copy Setup, each undoable.
@MainActor @Observable
final class AgentsModel {
    private(set) var projects: [URL] = []
    var selected: URL?
    private(set) var setup: [AgentFiles] = []
    private(set) var mcp: [MCPServer] = []
    private(set) var ports: [ListeningPort] = []
    private(set) var usage: (today: Int, week: Int, month: Int)?
    private(set) var loaded = false
    var editor: SetupEditor?
    var stopping: PortToStop?
    var showStop = false
    var copying: SetupCopy?
    var showCopy = false

    /// Projects, ports and usage; off the main actor.
    func load(runner: any CommandRunner, home: URL, current: URL) async {
        let found = await Task.detached(priority: .utility) { () -> (projects: [URL], usage: (today: Int, week: Int, month: Int)) in
            (Agents.projects(home: home), Agents.claudeUsage(home: home, now: Date()))
        }.value
        var list: [URL] = found.projects
        if !list.contains(current) { list.insert(current, at: 0) }
        projects = list
        usage = found.usage
        if selected == nil { selected = current }
        await refreshPorts(runner: runner)
        await select(selected ?? current, home: home)
        loaded = true
    }

    func refreshPorts(runner: any CommandRunner) async {
        ports = await Agents.listeningPorts(runner: runner)
    }

    func select(_ project: URL, home: URL) async {
        if editor?.isEdited == true { return } // keep unsaved edits; the page says Save or Revert first
        selected = project
        editor = nil
        let read = await Task.detached(priority: .utility) { () -> (setup: [AgentFiles], mcp: [MCPServer]) in
            var servers: [MCPServer] = []
            for rel in [".mcp.json", ".cursor/mcp.json"] {
                if let data = try? Data(contentsOf: project.appendingPathComponent(rel)) { servers += Agents.parseMCP(data) }
            }
            servers += Agents.userMCP(home: home)
            return (Agents.scanProject(project), servers)
        }.value
        guard selected == project else { return }
        setup = read.setup
        mcp = read.mcp
    }

    /// Files to show for one agent: setup folders open into their files.
    func files(_ group: AgentFiles) -> [String] {
        guard let project = selected else { return [] }
        return group.files.flatMap { (rel: String) -> [String] in Agents.regularFiles(rel, in: project) }
    }

    func open(_ rel: String) {
        guard let project = selected, editor?.isEdited != true else { return }
        let url: URL = project.appendingPathComponent(rel)
        editor = Self.load(url)
    }

    // shortcut: setup files are small; read on the main actor, checking the size before reading.
    static func load(_ url: URL) -> SetupEditor {
        let size: Int = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 2 << 20 { return SetupEditor(url: url, text: "", problem: "Too large to preview") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return SetupEditor(url: url, text: "", problem: "Can't read")
        }
        return SetupEditor(url: url, text: text)
    }
}

extension AppModel {
    func loadAgents() async {
        await agents.load(runner: runner, home: home, current: pane.currentFolder)
    }

    /// Save: atomic. Undo puts back what the file really held just before (even if another app changed it
    /// since it was opened), unless it changed again after the save.
    func saveSetupFile() {
        guard let editor = agents.editor, editor.isEdited, editor.problem == nil else { return }
        let written: String = editor.text
        let name: String = editor.url.lastPathComponent
        do {
            let write: SetupWrite = try Agents.write(Data(written.utf8), to: editor.url)
            let previous: String = write.previous.map { (d: Data) -> String in String(decoding: d, as: UTF8.self) } ?? ""
            let changedElsewhere: Bool = previous != editor.saved
            editor.markSaved(written)
            let trashDir: URL? = self.trashDir
            undo.push("Save") {
                let result: RestoreResult = Agents.undo([write], trashDir: trashDir)
                if result.failed.isEmpty { await editor.undoSave(to: previous, from: written) }
                return result
            }
            toast(changedElsewhere ? "Saved “\(name)” over changes made elsewhere" : "Saved “\(name)”", undoable: true)
        } catch {
            toast("Couldn't save “\(name)”: \(error.localizedDescription)", undoable: false)
        }
    }

    /// Stop: asks first. Pids ≤ 1 and FileOS itself are refused.
    func askStop(_ port: ListeningPort) {
        guard Agents.canStop(pid: port.pid) else {
            toast("FileOS won't stop that process", undoable: false)
            return
        }
        agents.stopping = PortToStop(port: port)
        agents.showStop = true
    }

    static func stopTitle(_ p: ListeningPort) -> String { "Stop “\(p.command)” on port \(p.port)?" }

    /// Confirmed: SIGINT to the listed pid only, and only if it still listens on that port (pids get reused).
    func stopConfirmed() async {
        guard let target = agents.stopping?.port else { return }
        agents.stopping = nil
        await agents.refreshPorts(runner: runner)
        guard agents.ports.contains(target) else {
            toast("“\(target.command)” already stopped", undoable: false)
            return
        }
        if Agents.stop(pid: target.pid) {
            toast("Stopped “\(target.command)”", undoable: false)
        } else {
            toast("Couldn't stop “\(target.command)”", undoable: false)
        }
        try? await Task.sleep(for: .milliseconds(500))
        await agents.refreshPorts(runner: runner)
    }

    /// Start an Agent Here: opens the terminal there and copies the agent's command; FileOS runs nothing.
    func startAgent(_ agent: Agent, in folder: URL) {
        openIn(kind: .terminal, at: folder)
        Pasteboard.write(agent.command)
        toast("Copied “\(agent.command)”. Paste it in the terminal to start \(agent.name)", undoable: false)
    }

    func askCopySetup(_ agent: Agent) {
        guard let from = agents.selected else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Copy Setup Here"
        guard panel.runModal() == .OK, let to = panel.url else { return }
        planCopySetup(agent, from: from, to: to)
    }

    func planCopySetup(_ agent: Agent, from: URL, to: URL) {
        guard FileOps.canonical(from) != FileOps.canonical(to) else {
            toast("Choose another project", undoable: false)
            return
        }
        let plan: [SetupPlanItem] = Agents.copySetupPlan(from: from, to: to, agent: agent)
        guard !plan.isEmpty else {
            toast("No \(agent.name) setup files to copy", undoable: false)
            return
        }
        agents.copying = SetupCopy(agent: agent, from: from, to: to, plan: plan)
        agents.showCopy = true
    }

    /// Copies the new files; already-there files only with `replace` ("Replace Them").
    func copySetup(replace: Bool) {
        guard let c = agents.copying else { return }
        agents.copying = nil
        do {
            let writes: [SetupWrite] = try Agents.copySetup(c.plan, from: c.from, to: c.to, replace: replace)
            guard !writes.isEmpty else {
                toast("Nothing copied", undoable: false)
                return
            }
            let trashDir: URL? = self.trashDir
            undo.push("Copy Setup") { Agents.undo(writes, trashDir: trashDir) }
            toast("Copied \(writes.count == 1 ? "1 file" : "\(writes.count) files") to “\(c.to.lastPathComponent)”", undoable: true)
        } catch {
            toast("Couldn't copy the setup: \(error.localizedDescription)", undoable: false)
        }
    }
}

// MARK: - Views

struct AgentsView: View {
    let agents: AgentsModel
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ProjectList(agents: agents)
                .frame(width: 220)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProjectSetup(agents: agents)
                    MCPSection(servers: agents.mcp)
                    PortsSection(agents: agents)
                    UsageSection(usage: agents.usage)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("AI Agents")
        .toolbar { toolbar }
        .task { if !agents.loaded { await model.loadAgents() } }
    }

    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            StartAgentMenu(agents: agents)
            IconButton(symbol: "arrow.clockwise", label: "Refresh", help: "Refresh", disabled: false,
                       action: { Task { await model.loadAgents() } })
        }
    }
}

private struct StartAgentMenu: View {
    let agents: AgentsModel
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(Agent.allCases, id: \.self) { (a: Agent) in
                Button(a.name, action: { start(a) })
            }
        } label: {
            Label("Start an Agent Here", systemImage: "play")
        }
        .help("Start an Agent Here")
        .disabled(agents.selected == nil)
    }

    private func start(_ a: Agent) {
        if let folder = agents.selected { model.startAgent(a, in: folder) }
    }
}

private struct ProjectList: View {
    let agents: AgentsModel
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Projects") {
                ForEach(agents.projects, id: \.self) { (url: URL) in
                    Button(action: { pick(url) }) {
                        Label(url.lastPathComponent, systemImage: "folder")
                            .fontWeight(url == agents.selected ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .help(model.displayPath(url))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func pick(_ url: URL) {
        if agents.editor?.isEdited == true {
            model.toast("Save or revert “\(agents.editor?.url.lastPathComponent ?? "")” first", undoable: false)
            return
        }
        Task { await agents.select(url, home: model.home) }
    }
}

private struct ProjectSetup: View {
    let agents: AgentsModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(agents.selected?.lastPathComponent ?? "No project").font(.title2.weight(.semibold))
            if agents.setup.isEmpty {
                Text("No agent setup files here.").foregroundStyle(.secondary)
            }
            ForEach(agents.setup, id: \.agent) { (group: AgentFiles) in
                AgentGroup(agents: agents, group: group)
            }
            if let editor = agents.editor {
                SetupEditorView(editor: editor)
            }
        }
    }
}

private struct AgentGroup: View {
    let agents: AgentsModel
    let group: AgentFiles
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(group.agent.name).font(.headline)
                Spacer()
                Button("Copy Setup to Another Project…", action: { model.askCopySetup(group.agent) })
                    .controlSize(.small)
            }
            ForEach(agents.files(group), id: \.self) { (rel: String) in
                SetupFileRow(agents: agents, rel: rel)
            }
        }
    }
}

private struct SetupFileRow: View {
    let agents: AgentsModel
    let rel: String
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(rel).font(.callout.monospaced())
            Spacer()
            Button("Preview", action: { open(edit: false) }).controlSize(.small)
            Button("Edit", action: { open(edit: true) }).controlSize(.small)
        }
    }

    private func open(edit: Bool) {
        guard let project = agents.selected else { return }
        let url: URL = project.appendingPathComponent(rel)
        if agents.editor?.url != url { agents.open(rel) }
        if let editor = agents.editor, editor.url == url {
            editor.editing = edit && editor.problem == nil
        } else {
            model.toast("Save or revert “\(agents.editor?.url.lastPathComponent ?? "")” first", undoable: false)
        }
    }
}

private struct SetupEditorView: View {
    @Bindable var editor: SetupEditor
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editor.url.lastPathComponent).font(.headline)
                if editor.isEdited { Text("Edited").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Toggle("Edit", isOn: $editor.editing).toggleStyle(.switch).controlSize(.small)
                    .disabled(editor.problem != nil)
                Button("Revert", action: { editor.revert() }).disabled(!editor.isEdited)
                Button("Save", action: { model.saveSetupFile() }).disabled(!editor.isEdited)
            }
            content
                .frame(minHeight: 200, maxHeight: 360)
                .border(Color.secondary.opacity(0.3))
        }
    }

    @ViewBuilder private var content: some View {
        if let problem = editor.problem {
            Text(problem).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if editor.editing {
            TextEditor(text: $editor.text).font(.body.monospaced())
        } else {
            ScrollView {
                Text(editor.text).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
}

private struct MCPSection: View {
    let servers: [MCPServer]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP Servers").font(.headline)
            if servers.isEmpty { Text("None set up.").foregroundStyle(.secondary) }
            ForEach(Array(servers.enumerated()), id: \.offset) { (pair: (offset: Int, element: MCPServer)) in
                HStack {
                    Text(pair.element.name).fontWeight(.medium)
                    Text(pair.element.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct PortsSection: View {
    let agents: AgentsModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Localhost").font(.headline)
            if agents.ports.isEmpty { Text("Nothing is listening.").foregroundStyle(.secondary) }
            ForEach(agents.ports) { (p: ListeningPort) in
                HStack {
                    Text(verbatim: "localhost:\(p.port)").font(.callout.monospaced())
                    Text(verbatim: "\(p.command) (\(p.pid))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop…", action: { model.askStop(p) }).controlSize(.small)
                }
            }
        }
    }
}

private struct UsageSection: View {
    let usage: (today: Int, week: Int, month: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code Usage").font(.headline)
            if let usage {
                Text("Today: \(Self.tokens(usage.today))")
                Text("Last 7 days: \(Self.tokens(usage.week))")
                Text("Last 30 days: \(Self.tokens(usage.month))")
            } else {
                Text("Looking…").foregroundStyle(.secondary)
            }
        }
    }

    static func tokens(_ n: Int) -> String { "\(n.formatted()) tokens" }
}

/// Open In defaults, Stop (asks first) and Copy Setup (never replaces without "Replace Them").
struct DevDialogs: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var agents: AgentsModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showOpenInDefaults) {
                OpenInDefaultsSheet().environment(model)
            }
            .alert(stopTitle, isPresented: $agents.showStop) {
                Button("Stop", role: .destructive, action: { stop() })
                Button("Cancel", role: .cancel, action: { agents.stopping = nil })
            } message: {
                Text("FileOS sends it Ctrl-C (SIGINT), as if you pressed Ctrl-C where it runs.")
            }
            .sheet(isPresented: $agents.showCopy, onDismiss: { agents.copying = nil }) {
                CopySetupSheet().environment(model)
            }
    }

    private var stopTitle: String { agents.stopping.map { (s: PortToStop) -> String in AppModel.stopTitle(s.port) } ?? "" }

    private func stop() { Task { await model.stopConfirmed() } }
}

private struct CopySetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let c = model.agents.copying {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy \(c.agent.name) Setup to “\(c.to.lastPathComponent)”").font(.headline)
                Text("Personal files (CLAUDE.local.md, settings.local.json) are never copied.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(c.plan) { (item: SetupPlanItem) in
                    HStack {
                        Text(item.path).font(.callout.monospaced())
                        Spacer()
                        Text(item.state).foregroundStyle(item.state == "new" ? Color.green : Color.orange)
                    }
                }
                buttons(c)
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func buttons(_ c: SetupCopy) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: { dismiss() })
            if c.thereCount > 0 {
                Button("Replace Them", action: { run(replace: true) })
            }
            Button(c.thereCount > 0 ? "Copy New Only" : "Copy", action: { run(replace: false) })
                .keyboardShortcut(.defaultAction)
                .disabled(c.newCount == 0)
        }
    }

    private func run(replace: Bool) {
        model.copySetup(replace: replace)
        dismiss()
    }
}
