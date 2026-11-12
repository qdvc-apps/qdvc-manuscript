import AppKit
import ManuscriptCore
import SwiftUI

// MARK: - Popover editors (clicking a footnote, note, citation, variable or figure)

struct NoteEditor: View {
    var title: String
    var detail: String
    @State var text: String
    var onDone: (String) -> Void
    var onDelete: () -> Void
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(width: 360, height: 110)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete", role: .destructive) {
                    finished = true
                    onDelete()
                }
                Spacer()
                Button("Done") {
                    finished = true
                    onDone(text)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onDisappear {
            if !finished { onDone(text) }
        }
    }
}

struct CitationEditor: View {
    var sources: [(String, String)]
    @State var narrative: Bool
    @State var locator: String
    var onDone: (Bool, String) -> Void
    var onDelete: () -> Void
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sources.count == 1 ? "Citation" : "Citation of \(sources.count) works").font(.headline)
            ForEach(sources, id: \.0) { source in
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.1).lineLimit(3)
                    Text(source.0).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Toggle("Narrative: Smith (2020) rather than (Smith, 2020)", isOn: $narrative)
            TextField("Page or other locator, such as p. 12", text: $locator)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove Citation", role: .destructive) {
                    finished = true
                    onDelete()
                }
                Spacer()
                Button("Done") {
                    finished = true
                    onDone(narrative, locator)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onDisappear {
            if !finished { onDone(narrative, locator) }
        }
    }
}

struct VariableValueEditor: View {
    var name: String
    @State var value: String
    var exists: Bool
    var onDone: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("{{\(name)}}").font(.headline.monospaced())
            if !exists {
                Text("There’s no variable with this name yet; give it a value to create it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextField("Value", text: $value, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { onDone(value) }
            HStack {
                Text("Every use of the variable changes with it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onDone(value) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

struct CaptionEditor: View {
    @State var kind: FigureKind
    var path: String
    @State var caption: String
    var onDone: (FigureKind, String) -> Void
    var onDelete: () -> Void
    @State private var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                Text("Figure").tag(FigureKind.figure)
                Text("Table").tag(FigureKind.table)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            TextField("Caption", text: $caption, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
            Text("Use *italic* and **bold**. The number is added and kept up to date for you; a table’s caption goes above it, a figure’s below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 400, alignment: .leading)
            HStack {
                Text(path).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Remove", role: .destructive) {
                    finished = true
                    onDelete()
                }
                Button("Done") {
                    finished = true
                    onDone(kind, caption)
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: 400)
        }
        .padding(14)
        .onDisappear {
            if !finished { onDone(kind, caption) }
        }
    }
}

// MARK: - Sheets

struct SheetHost: View {
    let kind: WindowSheet
    let state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        switch kind {
        case .cite:
            CitationPicker(session: session) { citation in controller.insertCitation(citation) }
        case .newVariable(let text):
            NewVariableSheet(session: session, value: text) { name, value in
                controller.makeVariableFromSelection(name: name, value: value)
            }
        }
    }
}

/// Insert › Citation… (⇧⌘C): search the library, pick one or more works.
struct CitationPicker: View {
    let session: ManuscriptSession
    var onInsert: (Citation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var narrative = false
    @State private var locator = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert Citation").font(.title3.weight(.semibold))
            if let library = session.library {
                TextField("Search by author, year, title or journal", text: $query)
                    .textFieldStyle(.roundedBorder)
                let results = library.search(query, limit: 300)
                List(results, selection: $selection) { r in
                    RecordRow(record: r, count: session.analysis.citationCounts[r.id] ?? 0).tag(r.id)
                }
                .frame(minHeight: 260)
                HStack {
                    Toggle("Narrative", isOn: $narrative)
                        .help("Smith (2020) rather than (Smith, 2020)")
                    TextField("Page (optional)", text: $locator)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Spacer()
                }
                if let citation = candidate(results) {
                    let formatter = CitationFormatter(style: session.settings.citationStyle, library: library,
                                                      cited: session.analysis.citedSources + citation.sources)
                    Text(formatter.text(for: citation))
                        .font(.system(size: 14, design: .serif))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.1)))
                }
            } else {
                ContentUnavailableView {
                    Label("No Library", systemImage: "books.vertical")
                } description: {
                    Text("Choose the QDVC Bibliotheca library to cite from. It’s remembered for this manuscript on this Mac.")
                } actions: {
                    Button("Choose Library…") { LibraryPicker.choose(for: session) }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Insert") {
                    if let library = session.library, let c = candidate(library.search(query, limit: 300)) {
                        onInsert(c)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 580, height: 560)
        .modifier(NoWritingTools())
    }

    /// The selected works, in library order.
    private func candidate(_ results: [LibraryRecord]) -> Citation? {
        guard !selection.isEmpty, let library = session.library else { return nil }
        var ordered = results.map(\.id).filter { selection.contains($0) }
        for id in selection where !ordered.contains(id) && library.records[id] != nil { ordered.append(id) }
        guard !ordered.isEmpty else { return nil }
        return Citation(sources: ordered, narrative: narrative, locator: locator.trimmingCharacters(in: .whitespaces))
    }
}

struct NewVariableSheet: View {
    let session: ManuscriptSession
    @State var value: String
    var onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    init(session: ManuscriptSession, value: String, onCreate: @escaping (String, String) -> Void) {
        self.session = session
        _value = State(initialValue: value)
        self.onCreate = onCreate
        _name = State(initialValue: Variable.suggestedName(value, avoiding: Set(session.variables.map(\.name))))
    }

    private var nameIsValid: Bool {
        Variable.isValidName(name) && !session.variables.contains(where: { $0.name == name })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Variable").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                    .font(.system(.body, design: .monospaced))
                TextField("Value", text: $value, axis: .vertical)
                    .lineLimit(1...4)
            }
            Text(nameIsValid ? "Written as {{\(name)}} in the Markdown, and in \(session.variablesPath)."
                 : "A name has letters, digits and underscores, doesn’t start with a digit, and isn’t taken.")
                .font(.caption)
                .foregroundStyle(nameIsValid ? Color.secondary : Color.orange)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(name, value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
