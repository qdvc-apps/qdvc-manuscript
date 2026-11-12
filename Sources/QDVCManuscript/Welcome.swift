import AppKit
import ManuscriptCore
import SwiftUI

/// The window shown at launch, as in Xcode and the other QDVC apps: the
/// app on the left with New, Open and Import, recent manuscripts on the right.
struct WelcomeWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var selection: String?

    static let id = "welcome"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 28)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                Text("QDVC Manuscript")
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.top, 6)
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Spacer(minLength: 28)
                VStack(alignment: .leading, spacing: 6) {
                    WelcomeAction(symbol: "plus.square", title: "Start a New Manuscript…",
                                  detail: "A new workspace folder, ready for Git") {
                        open(app.newManuscript())
                    }
                    WelcomeAction(symbol: "folder", title: "Open a Manuscript…",
                                  detail: "Choose a manuscript’s workspace folder") {
                        open(app.chooseWorkspace())
                    }
                    WelcomeAction(symbol: "square.and.arrow.down", title: "Import Markdown or Word…",
                                  detail: "Make a manuscript from a .md or .docx file") {
                        open(app.importDocument())
                    }
                }
                .frame(width: 330)
                Spacer(minLength: 28)
                Toggle("Show this window when QDVC Manuscript opens", isOn: $app.showWelcomeAtLaunch)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
            .frame(width: 440)

            Divider()

            VStack(spacing: 0) {
                if app.recents.isEmpty {
                    ContentUnavailableView("No Recent Manuscripts", systemImage: "clock",
                                           description: Text("Manuscripts you open appear here."))
                } else {
                    List(selection: $selection) {
                        ForEach(app.recents, id: \.path) { recent in
                            RecentRow(path: recent.path).tag(recent.path)
                        }
                    }
                    .listStyle(.sidebar)
                    .contextMenu(forSelectionType: String.self) { paths in
                        if let path = paths.first, let recent = app.recents.first(where: { $0.path == path }) {
                            Button("Open") { open(app.open(recent)) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            Divider()
                            Button("Remove from List") { app.removeRecent(recent) }
                        }
                    } primaryAction: { paths in
                        if let path = paths.first, let recent = app.recents.first(where: { $0.path == path }) {
                            open(app.open(recent))
                        }
                    }
                }
                Divider()
                HStack {
                    Text(app.recents.isEmpty ? "" : "Double-click to open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear Recent List") {
                        app.clearRecents()
                        selection = nil
                    }
                    .disabled(app.recents.isEmpty)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: 340)
        }
        .frame(height: 460)
        .ignoresSafeArea()
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK") { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .onAppear {
            app.refresh()
            if !app.welcomeRequested && !app.showWelcomeAtLaunch, let recent = app.recents.first {
                open(app.open(recent))
            }
            app.welcomeRequested = false
        }
    }

    /// Opens an editor window and closes this one.
    private func open(_ ref: EditorWindowRef?) {
        guard let ref else { return }
        openWindow(value: ref)
        DispatchQueue.main.async { dismissWindow(id: Self.id) }
    }
}

struct WelcomeAction: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RecentRow: View {
    var path: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        let title = Workspace.summary(url)
        HStack(spacing: 10) {
            Image(systemName: title == nil ? "questionmark.folder" : "doc.richtext.fill")
                .font(.system(size: 22))
                .foregroundStyle(title == nil ? Color.secondary : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                if let title, !title.isEmpty {
                    Text(title).font(.caption).lineLimit(1)
                }
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .help(path)
    }
}
