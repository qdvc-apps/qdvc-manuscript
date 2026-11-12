# QDVC Manuscript for macOS — Maintenance Guide

The one rule that matters most: **the workspace is the contract.** The
files the app writes are documented in [FILE_FORMAT.md](FILE_FORMAT.md) and
checked by the unit tests. Any change to a file name or to the bytes of a
file is a format change: update FILE_FORMAT.md and the tests with it.

## 1. Layout

```
Package.swift                 SwiftPM manifest (no Xcode project, no dependencies)
Sources/ManuscriptCore/       the model: Foundation only, no AppKit/SwiftUI
Sources/QDVCManuscript/       the SwiftUI/AppKit app
Tests/ManuscriptCoreTests/    unit tests (including the no-network check)
tools/make_icon.py            regenerates Resources/AppIcon.{svg,icns}
scripts/build-app.sh          builds (with the newest Xcode) and ad-hoc signs the app
Resources/                    Info.plist (org.qdvc.manuscript.mac), entitlements, icon
sample-workspace/             a worked example
docs/                         DESIGN, FILE_FORMAT, this guide
```

`ManuscriptCore` builds and tests on Linux (Swift 5.10 or later); the app
target is declared on macOS only.

### 1.1 Toolchain

Build with full Xcode. From Xcode 27, SwiftUI's `@State` is a macro whose
implementation (the SwiftUIMacros compiler plugin) ships with Xcode, so the
Command Line Tools or a swift.org toolchain fail with "plugin for module
'SwiftUIMacros' not found". `scripts/build-app.sh` therefore sets
`DEVELOPER_DIR` to the newest installed Xcode when `xcode-select` points at
the Command Line Tools, runs `xcrun swift`, prints the compiler and SDK
versions, and warns when the SDK is older than 26 (no Liquid Glass). An
explicit `DEVELOPER_DIR` is respected. The same block is used in the other
QDVC macOS apps; keep them in step.

AppKit decides on Liquid Glass from the SDK version recorded in the
executable's `LC_BUILD_VERSION`. `swift build` records the deployment target
there (`sdk 14.0`), so after copying the executable into the bundle the
script rewrites that field with `vtool -set-build-version macos <minos>
<sdk> -replace`, before signing. Check with `vtool -show-build`. Use only
standard SwiftUI chrome (toolbar, NavigationSplitView, inspector, `.bar`
backgrounds) so the system can apply the glass.

### 1.2 App icon

`tools/make_icon.py` writes `Resources/AppIcon.svg` and
`Resources/AppIcon.icns` (needs `rsvg-convert`): a typewriter whose body is
Apple's icon tile, with the family's glow, sheen and tinted shadows.
`--preview` also writes `build/icon-preview.png`.

## 2. Modules

`ManuscriptCore`:

| File | Responsibility |
| --- | --- |
| `Model.swift` | `Inline`, `Token`, `Citation`, `Block`, `Heading`, `Figure`, `Manuscript`, `ManuscriptSettings`, `Variable` |
| `Sentences.swift` | the sentence splitter (UTF-16 offsets; U+FFFC for tokens) and `WordCount` |
| `InlineMarkdown.swift` | inline parsing (a reduced CommonMark emphasis algorithm) and writing |
| `BlockMarkdown.swift` | frontmatter, blocks, one sentence per line, footnote definitions, line-start escapes |
| `Numbering.swift` | heading, figure and table numbers; `Recognizer` (citations and cross-references from text) |
| `Workspace.swift` | finding, loading, rendering and saving the files; section file names |
| `Variables.swift` | `variables.yml`; `WordCounts` |
| `Citations.swift` | `citations.yml`, the Bibliotheca library, `CitationFormatter` (APA 7, ACIS) |
| `BibTeX.swift`, `Builtin.swift`, `APA7.swift`, `ACIS.swift` | from QDVC Bibliotheca for macOS; keep in step (APA 7 gained a disambiguator) |
| `Docx.swift`, `Zip.swift` | Word export (styles, numbering, footnotes, pictures), stored-entry ZIP writer; `ImageInfo` |
| `DocxImport.swift`, `ZipReader.swift` | Word import; ZIP reader and DEFLATE decoder (after puff.c) |
| `YAML.swift` | the YAML subset (from QDVC Response Letter), plus `quoteTyped` for pandoc-mustache |

Core type names avoid SwiftUI's and AppKit's (`Heading`, not `Section`;
`Recognizer`): QDVC Progress once hit a clash with SwiftUI's `GridRow`.

The app (`QDVCManuscript`):

| File | Responsibility |
| --- | --- |
| `ManuscriptApp.swift` | scenes (welcome, editor `WindowGroup(for: EditorWindowRef.self)`, Settings), delegate, menus |
| `AppModel.swift` | `DeviceStore` (bookmarks, recents, library per manuscript), `AppModel` (open sessions, New/Open/Import) |
| `Session.swift` | `ManuscriptSession`: the shared `NSTextStorage`, undo manager, variables, citations, library, analysis, saving |
| `Converter.swift` | `DocumentBuilder` (model → attributed string) and `DocumentReader` (back) |
| `Attachments.swift` | `DisplayInfo` and the attachment cells: tokens, figures, the reference list |
| `LayoutManager.swift` | `ManuscriptLayoutManager` (margin numbers, list markers, quote bars, fold marks) and `CollapseHider` |
| `EditorController.swift` | one window's editor: text view, temporary attributes, collapse, formatting, inserting, pasting, popovers |
| `EditorTextView.swift` | the `NSTextView` subclass (Return, copy, paste, drops) and the host view |
| `EditorWindow.swift` | `EditorWindowState`, the window's SwiftUI content, toolbar, status bar |
| `Outline.swift`, `Inspector.swift`, `Sheets.swift`, `SettingsView.swift`, `Welcome.swift`, `Style.swift` | the rest of the UI |

## 3. The editor

- **One text storage, many windows.** A `ManuscriptSession` owns the
  `NSTextStorage` and the `UndoManager`; each window adds its own
  `NSLayoutManager` (TextKit 1) to the storage, so an edit in one window
  shows in all, while Focus mode (temporary attributes) and Collapse
  (glyph generation) belong to one layout manager only. Text views share
  the session's undo manager (`undoManager(for:)`).
- **Attributes.** Each paragraph's kind is `.msKind` on all its
  characters; bold and italic are `.msBold`/`.msItalic` (the font follows
  from kind, bold and italic: `EditorStyle`); headings carry `.msHeadingID`
  (for Section cross-references) and `.msUnnumbered`.
- **Attachments draw themselves** from `DisplayInfo`, which the session
  updates after each analysis; when numbers, citation texts or footnote
  numbers change, the session invalidates layout in every layout manager.
  So renumbering never edits text (and never disturbs Undo). Programmatic
  text changes go through `shouldChangeText`/`didChangeText` so Undo stays
  consistent.
- **Block attachments** (figures, the reference list) must be alone in
  their paragraph; `textView(_:shouldChangeTextIn:replacementString:)`
  refuses edits that would break that (deleting into a figure selects it
  instead).
- **Analysis** (`ManuscriptSession.analyze`, 0.3 s after edits) reads the
  storage back into a `Manuscript` and works out numbering, citation texts,
  the reference list, the outline, counts and each paragraph's sentences.
  Saving (1 s after edits, on switching apps, on closing) renders the
  workspace and writes what changed.
- **Collapse mode** hides characters with null glyphs and makes the
  newlines inside a hidden run zero-width (`CollapseHider`); the last
  newline of a run stays a paragraph break.
- **Layout.** The scroll view is hosted in an `EditorHostView` sized by
  SwiftUI (`sizeThatFits` returns what's offered), so the editor never
  decides the window's size. Margins are `textContainerInset`, from the
  clip view's width and the preset; zoom is the scroll view's
  magnification.

## 4. Network

Nothing may touch the network. `NetworkTests` fails if a networking API
appears in the sources or a dependency in Package.swift; the entitlements
have no network keys and the build script checks the signed app.
