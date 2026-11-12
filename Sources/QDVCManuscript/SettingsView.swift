import ManuscriptCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            ExportSettings()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 480)
        .modifier(NoWritingTools())
    }
}

struct EditorSettings: View {
    @AppStorage(Prefs.spellChecking) private var spellChecking = true
    @AppStorage(Prefs.smartQuotes) private var smartQuotes = true
    @AppStorage(Prefs.longSentenceWords) private var longSentenceWords = 40
    @AppStorage(Prefs.typewriterPosition) private var typewriterPosition = 0.42
    @AppStorage(Prefs.margins) private var margins = MarginPreset.medium.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Check spelling while typing", isOn: $spellChecking)
                Toggle("Smart quotes and dashes", isOn: $smartQuotes)
                Text("Spelling is checked by macOS on this Mac; nothing is sent anywhere. Applies to windows opened afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("New windows") {
                Picker("Margins", selection: $margins) {
                    ForEach(MarginPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Long sentences") {
                Stepper("Flag sentences over \(longSentenceWords) words", value: $longSentenceWords, in: 15...120, step: 5)
                Text("View › Flag Long Sentences underlines them in orange.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Typewriter scrolling") {
                Slider(value: $typewriterPosition, in: 0.25...0.6) {
                    Text("Line you’re typing")
                } minimumValueLabel: {
                    Text("Higher")
                } maximumValueLabel: {
                    Text("Lower")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

struct ExportSettings: View {
    @AppStorage(Prefs.exportFont) private var font = "Times New Roman"
    @AppStorage(Prefs.exportSize) private var size = 12.0
    @AppStorage(Prefs.exportSpacing) private var spacing = 1.5
    @AppStorage(Prefs.exportPage) private var page = DocxOptions.PageSize.a4.rawValue

    var body: some View {
        Form {
            Section("Word documents") {
                TextField("Font", text: $font)
                Picker("Size", selection: $size) {
                    ForEach([10.0, 11.0, 12.0, 13.0, 14.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Picker("Line spacing", selection: $spacing) {
                    Text("Single").tag(1.0)
                    Text("1.5 lines").tag(1.5)
                    Text("Double").tag(2.0)
                }
                Picker("Page size", selection: $page) {
                    ForEach(DocxOptions.PageSize.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                Text("Exports use Word’s own styles (Title, Heading 1–4, Quote, Caption, Bibliography), so a journal template can restyle them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
