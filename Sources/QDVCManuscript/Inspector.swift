import AppKit
import ManuscriptCore
import SwiftUI

/// The inspector (⌥⌘I): variables, citations, notes and footnotes, and the
/// manuscript's own settings.
struct InspectorView: View {
    @Bindable var state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $state.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch state.inspectorTab {
            case .variables: VariablesPane(session: session, controller: controller)
            case .citations: CitationsPane(state: state, session: session, controller: controller)
            case .notes: NotesPane(session: session, controller: controller)
            case .manuscript: ManuscriptPane(session: session)
            }
        }
    }
}

// MARK: - Variables

struct VariablesPane: View {
    let session: ManuscriptSession
    let controller: EditorController
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "curlybraces")
                } description: {
                    Text("Variables hold numbers and phrases you use in several places (sample sizes, statistics). Select text and choose Insert › Variable › New Variable from Selection, or add one here. They’re stored in \(session.variablesPath) for pandoc-mustache.")
                }
            } else {
                List(selection: $selection) {
                    ForEach(session.variables) { v in
                        VariableRow(variable: v, uses: session.analysis.variableUses[v.name] ?? 0, session: session) {
                            controller.insertToken(.variable(v.name))
                        }
                        .tag(v.name)
                        .contextMenu {
                            Button("Insert in Text") { controller.insertToken(.variable(v.name)) }
                            Divider()
                            Button("Delete Variable", role: .destructive) { session.removeVariable(v.name) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button {
                    selection = session.addVariable(value: "")
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a variable")
                Button {
                    if let selection { session.removeVariable(selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Delete the selected variable")
                Spacer()
                Text("{{name}} in Markdown").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }
}

struct VariableRow: View {
    var variable: Variable
    var uses: Int
    let session: ManuscriptSession
    var insert: () -> Void
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("name", text: $name)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit(rename)
                Spacer()
                Text(uses == 0 ? "unused" : "\(uses)×")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button(action: insert) {
                    Image(systemName: "arrow.down.left.circle")
                }
                .buttonStyle(.borderless)
                .help("Insert at the insertion point")
            }
            TextField("Value", text: $value, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onChange(of: value) { _, new in
                    if new != variable.value { session.setValue(new, of: variable.name) }
                }
        }
        .padding(.vertical, 3)
        .onAppear {
            name = variable.name
            value = variable.value
        }
        .onChange(of: variable) { _, v in
            if name != v.name { name = v.name }
            if value != v.value { value = v.value }
        }
    }

    private func rename() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard new != variable.name else { return }
        if !session.renameVariable(variable.name, to: new) {
            NSSound.beep()
            name = variable.name
        }
    }
}

// MARK: - Citations

struct CitationsPane: View {
    let state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                LibraryStatus(session: session)
                Picker("Style", selection: Binding(get: { session.settings.citationStyle }, set: { session.setCitationStyle($0) })) {
                    ForEach(CitationStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                referenceListStatus
            }
            .padding(10)
            Divider()
            if let library = session.library {
                TextField("Search the library", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List {
                    let results = library.search(query, limit: 150)
                    if !query.isEmpty || session.analysis.citedSources.isEmpty {
                        Section("Library") {
                            ForEach(results) { r in
                                RecordRow(record: r, count: session.analysis.citationCounts[r.id] ?? 0)
                                    .contextMenu {
                                        Button("Cite (Smith, 2020)") { controller.insertCitation(Citation(sources: [r.id])) }
                                        Button("Cite Narratively: Smith (2020)") { controller.insertCitation(Citation(sources: [r.id], narrative: true)) }
                                    }
                                    .onTapGesture(count: 2) { controller.insertCitation(Citation(sources: [r.id])) }
                            }
                        }
                    }
                    if query.isEmpty, !session.analysis.citedSources.isEmpty {
                        Section("Cited in this manuscript") {
                            ForEach(session.analysis.citedSources, id: \.self) { id in
                                if let r = library.records[id] {
                                    RecordRow(record: r, count: session.analysis.citationCounts[id] ?? 0)
                                        .onTapGesture(count: 2) { controller.insertCitation(Citation(sources: [id])) }
                                } else {
                                    Label("\(id) isn’t in the library", systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                Text("Double-click to cite; right-click for a narrative citation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(8)
            } else {
                CitedWithoutLibrary(session: session)
            }
        }
    }

    @ViewBuilder private var referenceListStatus: some View {
        let a = session.analysis
        if !a.citedSources.isEmpty && !a.hasReferenceList {
            HStack {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.orange)
                Text(a.referencesHeadingLocation == nil ? "No References heading yet." : "The References section has no list yet.")
                    .font(.caption)
                Spacer()
                Button(a.referencesHeadingLocation == nil ? "Add" : "Insert") { controller.insertReferenceList() }
                    .controlSize(.small)
            }
        }
    }
}

struct RecordRow: View {
    var record: LibraryRecord
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.shortLabel).fontWeight(.medium).lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)×").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(record.title).font(.caption).lineLimit(2)
            if !record.outlet.isEmpty {
                Text(record.outlet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Which library this manuscript cites from, on this Mac.
struct LibraryStatus: View {
    let session: ManuscriptSession

    var body: some View {
        if let url = session.libraryURL {
            HStack(alignment: .top) {
                Image(systemName: "books.vertical.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                    if session.libraryLoading {
                        Text("Reading the library…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(session.library?.records.count ?? 0) records").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Reload Library") { session.reloadLibrary() }
                    Button("Choose Another Library…") { LibraryPicker.choose(for: session) }
                    Divider()
                    Button("Disconnect") { session.forgetLibrary() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cite from a QDVC Bibliotheca library: choose its folder (the one with bibtex/ in it). It’s only read, never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Library…") { LibraryPicker.choose(for: session) }
            }
        }
    }
}

struct CitedWithoutLibrary: View {
    let session: ManuscriptSession

    var body: some View {
        let cited = session.analysis.citedSources
        if cited.isEmpty {
            Spacer()
        } else {
            List {
                Section("Cited in this manuscript") {
                    ForEach(cited, id: \.self) { id in
                        HStack {
                            Text(id).font(.system(.body, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text("\(session.analysis.citationCounts[id] ?? 0)×").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Text("Without the library, citations and the reference list are shown as last written.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(8)
        }
    }
}

@MainActor
enum LibraryPicker {
    static func choose(for session: ManuscriptSession) {
        let panel = NSOpenPanel()
        panel.title = "Choose a QDVC Bibliotheca Library"
        panel.message = "Choose the library’s folder (the one with the bibtex folder in it)."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard BibliothecaLibrary.isLibrary(url) else {
            let alert = NSAlert()
            alert.messageText = "That isn’t a QDVC Bibliotheca library"
            alert.informativeText = "“\(url.lastPathComponent)” has no bibtex folder. Choose the folder you open in QDVC Bibliotheca."
            alert.runModal()
            return
        }
        session.setLibrary(url)
    }
}

// MARK: - Notes

struct NotesPane: View {
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        let notes = session.analysis.notes
        if notes.isEmpty {
            ContentUnavailableView {
                Label("No Notes or Footnotes", systemImage: "note.text")
            } description: {
                Text("Insert › Note to Self (⇧⌘K) leaves yourself a reminder that’s never exported or counted. Insert › Footnote (⌃⌘8) adds a footnote.")
            }
        } else {
            List {
                ForEach(notes) { note in
                    Button {
                        controller.reveal(note.location, select: 1)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if note.isFootnote {
                                Text("\(note.number)").font(.caption.monospacedDigit().bold()).foregroundStyle(.tint)
                                    .frame(width: 22, alignment: .trailing)
                            } else {
                                Image(systemName: "pencil.and.scribble").foregroundStyle(.orange).frame(width: 22)
                            }
                            Text(note.text.isEmpty ? (note.isFootnote ? "Empty footnote" : "Empty note") : note.text)
                                .lineLimit(3)
                                .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Manuscript

struct ManuscriptPane: View {
    let session: ManuscriptSession
    @State private var limitText = ""

    var body: some View {
        let a = session.analysis
        Form {
            Section("Numbering") {
                Toggle("Number headings (1., 2.1, …)", isOn: Binding(get: { session.settings.headingNumbers },
                                                                     set: { session.setHeadingNumbers($0) }))
                Text("Format › Unnumbered Heading leaves one heading out. References, Abstract and Appendix headings are never numbered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Word limit") {
                TextField("Words", text: $limitText)
                    .onSubmit { session.setWordLimit(Int(limitText.filter(\.isNumber))) }
                Text("Counted without the reference list. Leave empty for none.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Counts") {
                LabeledContent("Words", value: a.counts.withoutReferences.formatted())
                LabeledContent("With references", value: a.counts.total.formatted())
                LabeledContent("Figures and tables", value: a.figures.count.formatted())
                LabeledContent("Footnotes", value: a.notes.filter(\.isFootnote).count.formatted())
                LabeledContent("Works cited", value: a.citedSources.count.formatted())
            }
            if a.brokenReferences > 0 || !a.missingSources.isEmpty {
                Section("Problems") {
                    if a.brokenReferences > 0 {
                        Label("\(a.brokenReferences) cross-reference(s) point to something removed (shown in red).",
                              systemImage: "exclamationmark.triangle")
                    }
                    if !a.missingSources.isEmpty {
                        Label("Not in the library: \(a.missingSources.joined(separator: ", "))", systemImage: "books.vertical")
                    }
                }
            }
            Section("Workspace") {
                Text((session.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { limitText = session.settings.wordLimit.map(String.init) ?? "" }
    }
}
