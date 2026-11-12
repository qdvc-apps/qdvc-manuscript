import AppKit
import ManuscriptCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct ManuscriptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    init() {
        // Windows aren't restored from the last session (the sandbox would
        // have no access to their folders); the welcome window decides.
        Prefs.register()
    }

    var body: some Scene {
        Window("Welcome to QDVC Manuscript", id: WelcomeWindow.id) {
            WelcomeWindow()
                .environment(app)
                .onAppear { appDelegate.app = app }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Any number of windows, several of them on the same manuscript.
        WindowGroup("Manuscript", for: EditorWindowRef.self) { $ref in
            if let ref {
                EditorWindowView(ref: ref)
                    .environment(app)
                    .onAppear { appDelegate.app = app }
            }
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            ManuscriptCommands(app: app)
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than
        // from the .app bundle, so the app gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        app?.checkAllForOutsideChanges()
    }

    func applicationDidResignActive(_ notification: Notification) {
        app?.flushAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.flushAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Menus

struct ManuscriptCommands: Commands {
    let app: AppModel
    @FocusedValue(\.editorState) private var state
    @Environment(\.openWindow) private var openWindow

    private var controller: EditorController? { state?.controller }
    private var session: ManuscriptSession? { state?.session }
    private var hasEditor: Bool { controller != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Manuscript…") { open(app.newManuscript()) }
                .keyboardShortcut("n")
            Button("Open…") { open(app.chooseWorkspace()) }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.recents, id: \.path) { recent in
                    Button((recent.path as NSString).lastPathComponent) { open(app.open(recent)) }
                }
                Divider()
                Button("Clear Menu") { app.clearRecents() }
                    .disabled(app.recents.isEmpty)
            }
            Divider()
            Button("New Window on This Manuscript") {
                if let state, let controller {
                    openWindow(value: EditorWindowRef(path: state.ref.path, location: controller.textView.selectedRange().location))
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(!hasEditor)
            Divider()
            Button("Import Markdown or Word…") { open(app.importDocument()) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Now") { session?.flush() }
                .keyboardShortcut("s")
                .disabled(!hasEditor)
            Button("Export Word Document…") { exportDocx() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasEditor)
            Button("Export Markdown…") { exportMarkdown() }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(!hasEditor)
            Divider()
            Button("Show in Finder") {
                if let url = session?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(!hasEditor)
            Button("Reload from Disk") { session?.reload() }
                .disabled(!hasEditor)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { find(.showFindInterface) }
                .keyboardShortcut("f")
                .disabled(!hasEditor)
            Button("Find and Replace…") { find(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!hasEditor)
            Button("Find Next") { find(.nextMatch) }
                .keyboardShortcut("g")
                .disabled(!hasEditor)
            Button("Find Previous") { find(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!hasEditor)
            Button("Use Selection for Find") { find(.setSearchString) }
                .keyboardShortcut("e")
                .disabled(!hasEditor)
        }

        CommandGroup(after: .toolbar) {
            Toggle("Focus", isOn: binding(\.focus))
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!hasEditor)
            Menu("Topic Sentences") {
                Toggle("Off", isOn: topicBinding(.off))
                    .keyboardShortcut("0", modifiers: [.command, .control])
                Toggle("Accentuate", isOn: topicBinding(.accentuate))
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Toggle("Collapse", isOn: topicBinding(.collapse))
                    .keyboardShortcut("2", modifiers: [.command, .control])
            }
            .disabled(!hasEditor)
            Toggle("Typewriter Scrolling", isOn: binding(\.typewriter))
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!hasEditor)
            Toggle("Flag Long Sentences", isOn: binding(\.longSentences))
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!hasEditor)
            Toggle("Show Variable Names", isOn: binding(\.showVariableNames))
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(!hasEditor)
            Menu("Margins") {
                ForEach(Array(MarginPreset.allCases.enumerated()), id: \.element) { i, preset in
                    Toggle(preset.label, isOn: Binding(get: { state?.margins == preset }, set: { if $0 { state?.margins = preset } }))
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .control, .option])
                }
            }
            .disabled(!hasEditor)
            Divider()
            Button("Zoom In") { controller?.zoom(by: 1.1) }
                .keyboardShortcut("+")
                .disabled(!hasEditor)
            Button("Zoom Out") { controller?.zoom(by: 1 / 1.1) }
                .keyboardShortcut("-")
                .disabled(!hasEditor)
            Button("Actual Size") { controller?.zoom(by: nil) }
                .keyboardShortcut("0")
                .disabled(!hasEditor)
            Divider()
        }

        CommandMenu("Format") {
            Button("Bold") { controller?.toggleStyle(bold: true) }
                .keyboardShortcut("b")
                .disabled(!hasEditor)
            Button("Italic") { controller?.toggleStyle(bold: false) }
                .keyboardShortcut("i")
                .disabled(!hasEditor)
            Divider()
            Button("Body Text") { controller?.setKind(.body) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Title") { controller?.setKind(.title) }
            ForEach(1...4, id: \.self) { level in
                Button("Heading \(level)") { controller?.setKind(.heading(level)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(level))), modifiers: [.command, .option])
            }
            Divider()
            Button("Block Quote") { controller?.toggleKind(.quote) }
                .keyboardShortcut("'")
            Button("Bulleted List") { controller?.toggleKind(.bullet) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Numbered List") { controller?.toggleKind(.numbered) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Divider()
            Button("Unnumbered Heading") { controller?.toggleUnnumbered() }
            Toggle("Number Headings", isOn: Binding(get: { session?.settings.headingNumbers ?? true },
                                                     set: { session?.setHeadingNumbers($0) }))
                .disabled(!hasEditor)
        }

        CommandMenu("Insert") {
            Button("Citation…") { state?.sheet = .cite }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!hasEditor)
            Button("Footnote") { controller?.insertFootnote() }
                .keyboardShortcut("8", modifiers: [.command, .control])
                .disabled(!hasEditor)
            Button("Note to Self") { controller?.insertNote() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!hasEditor)
            Divider()
            Button("Figure…") { if let controller { FigurePicker.choose(kind: .figure, controller: controller) } }
                .disabled(!hasEditor)
            Button("Table…") { if let controller { FigurePicker.choose(kind: .table, controller: controller) } }
                .disabled(!hasEditor)
            Divider()
            if let session, let controller {
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
            } else {
                Button("Cross-reference") {}.disabled(true)
                Button("Variable") {}.disabled(true)
            }
            Button("New Variable from Selection…") { controller?.beginVariableFromSelection() }
                .keyboardShortcut("v", modifiers: [.command, .control])
                .disabled(!hasEditor)
            Divider()
            Button("Reference List") { controller?.insertReferenceList() }
                .disabled(!hasEditor || session?.analysis.hasReferenceList == true)
        }

        CommandGroup(before: .windowList) {
            Button("Welcome to QDVC Manuscript") {
                app.welcomeRequested = true
                openWindow(id: WelcomeWindow.id)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
    }

    private func open(_ ref: EditorWindowRef?) {
        if let ref { openWindow(value: ref) }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<EditorWindowState, Bool>) -> Binding<Bool> {
        Binding(get: { state?[keyPath: keyPath] ?? false }, set: { state?[keyPath: keyPath] = $0 })
    }

    private func topicBinding(_ mode: TopicMode) -> Binding<Bool> {
        Binding(get: { state?.topicMode == mode }, set: { if $0 { state?.topicMode = mode } else if mode != .off { state?.topicMode = .off } })
    }

    private func find(_ action: NSTextFinder.Action) {
        guard let textView = controller?.textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(item)
    }

    private func exportDocx() {
        guard let session else { return }
        session.flush()
        let panel = NSSavePanel()
        panel.title = "Export Word Document"
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        let name = session.title.slug()
        panel.nameFieldStringValue = (name.isEmpty ? "manuscript" : name) + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.docxData().write(to: url, options: .atomic)
        } catch {
            state?.errorMessage = "Couldn’t export: \(error.localizedDescription)"
        }
    }

    private func exportMarkdown() {
        guard let session else { return }
        session.flush()
        let panel = NSOpenPanel()
        panel.title = "Export Markdown"
        panel.message = "Choose a folder for the Markdown file and its figures (variables are filled in, notes left out)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let file = try session.exportMarkdown(to: folder)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            state?.errorMessage = "Couldn’t export: \(error.localizedDescription)"
        }
    }
}
