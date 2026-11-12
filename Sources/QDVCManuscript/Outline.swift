import ManuscriptCore
import SwiftUI

/// The sidebar: the title, the headings (numbered, with word counts) and
/// the figures and tables; click one to go there.
struct OutlineSidebar: View {
    let state: EditorWindowState
    let session: ManuscriptSession
    let controller: EditorController
    @State private var selection: String?

    var body: some View {
        let analysis = session.analysis
        List(selection: $selection) {
            Section("Outline") {
                Label {
                    Text(analysis.titleText.isEmpty ? "Untitled manuscript" : analysis.titleText)
                        .lineLimit(2)
                        .foregroundStyle(analysis.titleText.isEmpty ? .secondary : .primary)
                } icon: {
                    Image(systemName: "doc.text")
                }
                .tag("top")
                ForEach(analysis.outline) { entry in
                    OutlineRow(entry: entry, showNumber: session.settings.headingNumbers,
                               isCurrent: entry.id == state.currentHeadingID)
                        .tag("h:" + entry.id)
                }
                if analysis.outline.isEmpty {
                    Text("Headings you add appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }
            if !analysis.figures.isEmpty {
                Section("Figures & Tables") {
                    ForEach(analysis.figures) { f in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.label).fontWeight(.medium)
                                if !f.caption.isEmpty {
                                    Text(f.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        } icon: {
                            Image(systemName: f.kind == .figure ? "photo" : "tablecells")
                        }
                        .tag("f:" + f.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, new in
            guard let new else { return }
            go(to: new)
            DispatchQueue.main.async { selection = nil }
        }
    }

    private func go(to tag: String) {
        if tag == "top" {
            controller.reveal(0)
        } else if tag.hasPrefix("h:") {
            let id = String(tag.dropFirst(2))
            if let e = session.analysis.outline.first(where: { $0.id == id }) { controller.reveal(e.location) }
        } else if tag.hasPrefix("f:") {
            let path = String(tag.dropFirst(2))
            if let f = session.analysis.figures.first(where: { $0.path == path }) { controller.reveal(f.location, select: 1) }
        }
    }
}

struct OutlineRow: View {
    var entry: OutlineEntry
    var showNumber: Bool
    var isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showNumber, let n = entry.number {
                Text(Numbering.headingLabel(n))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .lineLimit(1)
                .fontWeight(entry.level == 1 ? .semibold : .regular)
            Spacer(minLength: 4)
            Text(entry.words.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("Words in this section")
        }
        .padding(.leading, CGFloat(max(0, entry.level - 1)) * 12)
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(Color.accentColor).frame(width: 3).offset(x: -8)
            }
        }
    }
}
