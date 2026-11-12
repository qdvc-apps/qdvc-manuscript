import AppKit
import ManuscriptCore
import SwiftUI
import UniformTypeIdentifiers

enum WindowSheet: Identifiable {
    case cite
    case newVariable(String)

    var id: String {
        switch self {
        case .cite: return "cite"
        case .newVariable: return "newVariable"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case variables, citations, notes, manuscript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .variables: return "Variables"
        case .citations: return "Citations"
        case .notes: return "Notes"
        case .manuscript: return "Manuscript"
        }
    }
}

/// One editor window: which manuscript, its controller, and this window's
/// view settings (Focus mode and the rest are per window).
@Observable
@MainActor
final class EditorWindowState {
    let ref: EditorWindowRef
    private(set) var session: ManuscriptSession?
    private(set) var controller: EditorController?
    var openError: String?
    var errorMessage: String?

    var focus = false { didSet { controller?.focus = focus } }
    var topicMode: TopicMode = .off { didSet { controller?.topicMode = topicMode } }
    var typewriter = false { didSet { controller?.typewriter = typewriter } }
    var longSentences = false { didSet { controller?.longSentences = longSentences } }
    var showVariableNames = false { didSet { controller?.showVariableNames = showVariableNames } }
    var margins: MarginPreset = MarginPreset(rawValue: UserDefaults.standard.string(forKey: Prefs.margins) ?? "") ?? .medium {
        didSet {
            controller?.margins = margins
            UserDefaults.standard.set(margins.rawValue, forKey: Prefs.margins)
        }
    }
    var showInspector = false
    var inspectorTab: InspectorTab = .variables
    var columnVisibility: NavigationSplitViewVisibility = .all
    var sheet: WindowSheet?

    // Live, from the controller.
    var sentenceWords = 0
    var selectionWords = 0
    var caretLocation = 0
    var currentHeadingID: String?

    @ObservationIgnored private var closed = false

    init(ref: EditorWindowRef) {
        self.ref = ref
    }

    func open(app: AppModel) {
        do {
            let session = try app.acquireSession(ref.path)
            let controller = EditorController(session: session)
            controller.state = self
            controller.margins = margins
            self.session = session
            self.controller = controller
            if let location = ref.location {
                DispatchQueue.main.async { controller.reveal(location) }
            } else {
                DispatchQueue.main.async { controller.textView.window?.makeFirstResponder(controller.textView) }
            }
        } catch {
            openError = error.localizedDescription
        }
    }

    func close(app: AppModel) {
        guard !closed else { return }
        closed = true
        controller?.detach()
        if let session { app.releaseSession(session) }
    }

    var currentKind: ParaKind {
        _ = caretLocation
        return controller?.currentKind() ?? .body
    }
}

struct EditorStateKey: FocusedValueKey {
    typealias Value = EditorWindowState
}

extension FocusedValues {
    var editorState: EditorWindowState? {
        get { self[EditorStateKey.self] }
        set { self[EditorStateKey.self] = newValue }
    }
}

/// The content of an editor window.
struct EditorWindowView: View {
    let ref: EditorWindowRef
    @Environment(AppModel.self) private var app
    @State private var state: EditorWindowState?

    var body: some View {
        Group {
            if let state, let session = state.session, let controller = state.controller {
                EditorWorkspace(state: state, session: session, controller: controller)
            } else if let error = state?.openError {
                ContentUnavailableView("Couldn’t Open the Manuscript", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            if state == nil {
                let s = EditorWindowState(ref: ref)
                s.open(app: app)
                state = s
            }
        }
        .onDisappear { state?.close(app: app) }
    }
}

struct EditorWorkspace: View {
    @Bindable var state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            OutlineSidebar(state: state, session: session, controller: controller)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 380)
        } detail: {
            VStack(spacing: 0) {
                banners
                EditorHost(controller: controller)
                StatusBar(state: state, session: session)
            }
            .inspector(isPresented: $state.showInspector) {
                InspectorView(state: state, session: session, controller: controller)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 440)
            }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.url.lastPathComponent)
        .toolbar { EditorToolbar(state: state, session: session, controller: controller) }
        .sheet(item: $state.sheet) { sheet in
            SheetHost(kind: sheet, state: state, session: session, controller: controller)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .focusedSceneValue(\.editorState, state)
        .modifier(NoWritingTools())
    }

    @ViewBuilder private var banners: some View {
        if session.conflict {
            NoticeBanner(text: "The manuscript’s files changed outside QDVC Manuscript while you had unsaved edits here.",
                         actions: [("Reload from Disk", { session.reload() }), ("Keep My Version", { session.keepMine() })],
                         dismiss: { session.keepMine() })
        }
        if let error = session.saveError {
            NoticeBanner(text: error, dismiss: { session.saveError = nil })
        }
        if !session.warnings.isEmpty {
            NoticeBanner(text: session.warnings.joined(separator: " "), isWarning: false, dismiss: { session.warnings = [] })
        }
    }
}

/// The text view, hosted for SwiftUI. The scroll view fills exactly the
/// space offered (it never decides the window's size).
struct EditorHost: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> EditorHostView { controller.hostView }

    func updateNSView(_ nsView: EditorHostView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 500)
    }
}

// MARK: - Toolbar

struct EditorToolbar: ToolbarContent {
    @Bindable var state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach([ParaKind.body, .title, .h1, .h2, .h3, .h4, .quote, .bullet, .numbered], id: \.self) { kind in
                    Button {
                        controller.setKind(kind)
                    } label: {
                        if state.currentKind == kind { Label(kind.menuTitle, systemImage: "checkmark") } else { Text(kind.menuTitle) }
                    }
                }
            } label: {
                Label(state.currentKind.menuTitle, systemImage: "paragraphsign")
                    .labelStyle(.titleAndIcon)
            }
            .help("Paragraph style")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { controller.toggleStyle(bold: true) } label: { Label("Bold", systemImage: "bold") }
                    .help("Bold (⌘B)")
                Button { controller.toggleStyle(bold: false) } label: { Label("Italic", systemImage: "italic") }
                    .help("Italic (⌘I)")
            }
            InsertMenu(state: state, session: session, controller: controller)
            Toggle(isOn: $state.focus) { Label("Focus", systemImage: "scope") }
                .help("Focus: fade everything but the sentence you’re in (⇧⌘F)")
            Menu {
                Picker("Topic Sentences", selection: $state.topicMode) {
                    ForEach(TopicMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Topic Sentences", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(state.topicMode == .off ? Color.primary : Color.accentColor)
            }
            .help("Topic sentences: accentuate the first sentence of each paragraph, or collapse paragraphs to it")
            Menu {
                Toggle("Typewriter Scrolling", isOn: $state.typewriter)
                Toggle("Flag Long Sentences", isOn: $state.longSentences)
                Toggle("Show Variable Names", isOn: $state.showVariableNames)
                Divider()
                Picker("Margins", selection: $state.margins) {
                    ForEach(MarginPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Number Headings", isOn: Binding(get: { session.settings.headingNumbers },
                                                         set: { session.setHeadingNumbers($0) }))
            } label: {
                Label("View Options", systemImage: "slider.horizontal.3")
            }
            .help("View options for this window")
            Button {
                state.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Variables, citations, notes and manuscript settings (⌥⌘I)")
        }
    }
}

/// Insert ▸ citation, footnote, note, figure, table, cross-reference, variable.
struct InsertMenu: View {
    let state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        Menu {
            InsertMenuItems(state: state, session: session, controller: controller)
        } label: {
            Label("Insert", systemImage: "plus")
        }
        .help("Insert a citation, footnote, note, figure, table, cross-reference or variable")
    }
}

struct InsertMenuItems: View {
    let state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        Button("Citation…") { state.sheet = .cite }
        Button("Footnote") { controller.insertFootnote() }
        Button("Note to Self") { controller.insertNote() }
        Divider()
        Button("Figure…") { FigurePicker.choose(kind: .figure, controller: controller) }
        Button("Table…") { FigurePicker.choose(kind: .table, controller: controller) }
        Divider()
        Menu("Cross-reference") {
            CrossReferenceItems(session: session, controller: controller)
        }
        Menu("Variable") {
            ForEach(session.variables) { v in
                Button("\(v.name) — \(TextTools.excerpt(v.value, limit: 40))") { controller.insertToken(.variable(v.name)) }
            }
            if !session.variables.isEmpty { Divider() }
            Button("New Variable from Selection…") { controller.beginVariableFromSelection() }
        }
        Divider()
        Button(session.analysis.hasReferenceList ? "Reference List (already inserted)" : "Reference List") {
            controller.insertReferenceList()
        }
        .disabled(session.analysis.hasReferenceList)
    }
}

struct CrossReferenceItems: View {
    let session: ManuscriptSession
    let controller: EditorController

    var body: some View {
        let figures = session.analysis.figures
        let headings = session.analysis.outline.filter { $0.number != nil }
        if figures.isEmpty && headings.isEmpty {
            Text("No figures, tables or numbered headings yet")
        }
        ForEach(figures) { f in
            Button("\(f.label): \(TextTools.excerpt(f.caption, limit: 50))") { controller.insertToken(.figureRef(f.path)) }
        }
        if !figures.isEmpty && !headings.isEmpty { Divider() }
        ForEach(headings) { h in
            Button("Section \(h.number ?? ""): \(TextTools.excerpt(h.title, limit: 50))") { controller.insertToken(.sectionRef(h.id)) }
        }
    }
}

@MainActor
enum FigurePicker {
    /// Asks for a picture and inserts it as a figure or table.
    static func choose(kind: FigureKind, controller: EditorController) {
        let panel = NSOpenPanel()
        panel.title = kind == .figure ? "Insert Figure" : "Insert Table"
        panel.message = kind == .figure ? "Choose a picture of the figure (a PNG screenshot, say)." : "Choose a picture of the table (a PNG screenshot, say)."
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        _ = controller.insertImageData(data, name: url.deletingPathExtension().lastPathComponent, kind: kind)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let state: EditorWindowState
    let session: ManuscriptSession

    var body: some View {
        let counts = session.analysis.counts
        let section = session.analysis.outline.first(where: { $0.id == state.currentHeadingID })
        HStack(spacing: 14) {
            if let section {
                Text([section.number.map(Numbering.headingLabel), section.title].compactMap { $0 }.joined(separator: " "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state.selectionWords > 0 {
                Text("Selection \(state.selectionWords.formatted())")
            }
            Text("Sentence \(state.sentenceWords.formatted())")
                .foregroundStyle(state.longSentences && state.sentenceWords > UserDefaults.standard.integer(forKey: Prefs.longSentenceWords)
                                 ? Color.orange : Color.secondary)
            Divider().frame(height: 12)
            Text("\(counts.withoutReferences.formatted()) words")
                .help("Words without the reference list (notes to self never count)")
            Text("\(counts.total.formatted()) with references")
                .foregroundStyle(.secondary)
                .help("Words including the reference list")
            if let limit = session.settings.wordLimit {
                let over = counts.withoutReferences > limit
                HStack(spacing: 6) {
                    ProgressView(value: min(1, Double(counts.withoutReferences) / Double(max(1, limit))))
                        .progressViewStyle(.linear)
                        .tint(over ? .red : .accentColor)
                        .frame(width: 70)
                    Text("\(counts.withoutReferences.formatted()) / \(limit.formatted())")
                        .foregroundStyle(over ? Color.red : Color.secondary)
                }
                .help(over ? "\((counts.withoutReferences - limit).formatted()) words over the limit"
                      : "\((limit - counts.withoutReferences).formatted()) words left")
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
