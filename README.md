# QDVC Manuscript for macOS

A calm word processor for writing a research article, that keeps the
manuscript in a Git-friendly folder of Markdown files: one file per
section, one sentence per line, so that `git diff` shows exactly which
sentences changed.

A native SwiftUI and AppKit app for macOS 14 (Sonoma) and later, in the
family of [QDVC Mac apps](https://github.com/qdvc-apps/) (QDVC Response
Letter, Progress, Empirics, Bibliotheca). See
[Build and run](#build-and-run) to get started.

![The app icon: a typewriter that happens to be the shape of a macOS icon](Resources/AppIcon.svg)

## What it does

- **A page that's easy on the eyes.** New York (the serif of QDVC Empirics'
  reading view) with generous leading, a gap between paragraphs instead of
  empty lines, and a centred column with **three margin presets** (View ›
  Margins, ⌃⌥⌘1–3). ⌘B and ⌘I for bold and italic; ⌘+ and ⌘− zoom each
  window.
- **Title and headings.** Format › Title marks the first line as the title;
  ⌥⌘1–4 make Heading 1–4, ⌥⌘0 body text. Headings can be **numbered**
  (1., 2.1, 3.2.1…, drawn in the margin; Format › Number Headings);
  References, Abstract and Appendix headings never are, and Format ›
  Unnumbered Heading leaves out any other.
- **Block quotes and lists** (⌘', ⇧⌘7, ⇧⌘8), for interview excerpts and the like.
- **An outline** in the sidebar: the headings with their numbers and word
  counts, then the figures and tables. Click to go there.
- **Variables** (Insert › Variable, ⌃⌘V makes one from the selection):
  sample sizes, statistics, anything you repeat. They show their values in
  the text (View › Show Variable Names shows `{{name}}`) and are stored as
  `{{name}}` with a `variables.yml`, exactly as
  [pandoc-mustache](https://github.com/michaelstepner/pandoc-mustache) reads them.
- **Figures and tables** (Insert › Figure… / Table…, or paste a screenshot):
  a PNG with a caption, numbered for you (a table's caption above it, a
  figure's below). **Cross-references** (Insert › Cross-reference) to
  figures, tables and sections read "Figure 3", "Table 1" or "Section 3.2"
  and renumber themselves.
- **Citations from QDVC Bibliotheca** (Insert › Citation…, ⇧⌘C): search the
  library, pick one or more works, parenthetical or narrative, with a page.
  They're written as they read, "(Smith & Jones, 2025)", in APA 7 or ACIS
  style, and the **reference list** under the References heading is made
  and kept up to date for you. Without the library at hand, everything stays
  as last written.
- **Footnotes** (⌃⌘8) and **notes to self** (⇧⌘K): click one to edit it.
  Notes are yellow tags in the text, `<!-- … -->` in the Markdown, and are
  never exported or counted.
- **Focus mode** (⇧⌘F): everything but the sentence you're in fades to
  grey. Per window.
- **Topic sentences** (⌃⌘1, ⌃⌘2): *accentuate* the first sentence of every
  paragraph, or *collapse* each paragraph to it (like code folding), to check
  that skimming the topic sentences still tells the story. Double-click a
  sentence to unfold there. Per window.
- **Typewriter scrolling** (⌃⌘T) keeps the line you're typing at the same
  height; **long sentences** (⌃⌘L) are underlined in orange (the threshold
  is in Settings).
- **Counts** in the status bar: words without the reference list, with it,
  in the current sentence and in the selection, and progress towards a
  **word limit** (Inspector › Manuscript).
- **Several windows on one manuscript** (File › New Window on This
  Manuscript, ⌥⌘N), each at its own place, each with its own Focus, topic
  and view settings; typing in one shows in all.
- **Import and export**: Markdown (a file, or a folder of files) and Word
  (.docx) in; Word (with real footnotes, embedded figures and Word's own
  styles) and a single Markdown file out.

## The workspace

Each manuscript is a folder; track it with Git. The format is documented in
[docs/FILE_FORMAT.md](docs/FILE_FORMAT.md); in short:

```
00-manuscript.md          frontmatter (title…) and anything before the first heading
01-introduction.md        one file per top-level section, renumbered as sections come and go
02-literature-review.md
03-research-design.md     ## subsections stay in their section's file
04-references.md          the reference list, generated
variables.yml             pandoc-mustache variables
citations.yml             what each citation stands for in QDVC Bibliotheca
figures/  tables/         the PNGs
```

A manuscript without sections is a single `manuscript.md`. Every sentence
is on a line of its own, never re-wrapped. The app saves as you type (and
when you switch away), and reloads if the files change on disk (a
`git pull`, say). It never runs Git itself: commit as you usually do.

`sample-workspace/` is a small worked example; open it to look around.

Since the Markdown is plain pandoc Markdown, you can also build it outside
the app, for example:

```sh
pandoc 0*.md -o manuscript.docx --filter pandoc-mustache
```

## No network, ever

The app is sandboxed without any network entitlement, so macOS itself
refuses any connection; it has no dependencies (its YAML, Markdown, ZIP,
DEFLATE and DOCX code are its own); link detection is off; Look Up,
Translate, Share, Services and Writing Tools are removed; spelling is
checked by macOS on the Mac; and a unit test fails if a networking API
appears anywhere in the sources.

## Build and run

Requirements: macOS 14 or later and **full Xcode** (not just the Command
Line Tools: from Xcode 27, SwiftUI's `@State` is a macro whose plugin ships
only with Xcode). Build with Xcode 26 or later for the Liquid Glass look.

```sh
scripts/build-app.sh             # build/QDVC Manuscript.app (release, ad-hoc signed, sandboxed)
scripts/build-app.sh --install   # …and copy it to ~/Applications
scripts/build-app.sh --universal # arm64 + x86_64
```

The script picks the newest installed Xcode if `xcode-select` points at the
Command Line Tools, prints the compiler and SDK, and records the real macOS
SDK in the binary (so AppKit uses Liquid Glass; see docs/MAINTENANCE.md).
No Apple Developer account is needed.

For development: `swift run QDVCManuscript` and `swift test` (with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if
`xcode-select` points at the Command Line Tools). The core library
(`ManuscriptCore`) also builds and tests on Linux.

The icon is generated by `tools/make_icon.py` (needs `rsvg-convert`).
