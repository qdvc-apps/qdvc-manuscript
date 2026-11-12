# Design

## Principles

- **The files are the manuscript.** Everything a co-author needs is in the
  workspace, in plain pandoc Markdown and YAML that diffs well: one
  sentence per line, one file per section. Per-Mac things (which
  Bibliotheca library, recent manuscripts, window settings) stay in the
  app's preferences.
- **Write the text as it reads.** Citations, cross-references and figure
  numbers are in the Markdown as a reader sees them; the app remembers the
  little it needs to keep them current (citations.yml) and recognises the
  rest when reading.
- **Nothing leaves the Mac.** Sandboxed, no network entitlement, no
  dependencies, outside services stripped from menus.
- **Familiar Mac.** A document-like window with a sidebar outline, a
  toolbar, an inspector and a status bar; standard menus and shortcuts
  (Pages and Word where there's a convention).

## The window

```
┌ toolbar: paragraph style │ B I │ Insert ▾ │ Focus │ Topic ▾ │ View ▾ │ Inspector ┐
├──────────────┬───────────────────────────────────────────┬─────────────────┤
│ Outline      │                                           │ Variables       │
│  Title       │      centred text column                  │ Citations       │
│  1. Intro    │      (three margin presets)               │ Notes           │
│  2. Lit…     │                                           │ Manuscript      │
│ Figures &    │                                           │                 │
│ Tables       │                                           │                 │
├──────────────┴───────────────────────────────────────────┴─────────────────┤
│ section · selection · sentence │ words · with references · limit ▓▓▓░       │
└──────────────────────────────────────────────────────────────────────────────┘
```

At launch a welcome window offers New, Open and Import and lists recent
manuscripts, as in the other QDVC apps.

**Per window**: Focus mode, topic-sentence mode, typewriter scrolling,
long-sentence flags, variable names, margins and zoom. **Per manuscript**
(and so shared by co-authors): heading numbering, citation style, word
limit. **Per Mac** (Settings): spelling, smart quotes, the long-sentence
threshold, typewriter position, and Word export (font, size, spacing, page).

## Choices

- **Heading numbers in the margin.** They're drawn, not typed, so they
  never get into the text or the Markdown, and switching them off is
  instant.
- **Figures as one object.** A figure is a single attachment (picture and
  caption, the caption edited by double-clicking), so it can't be half
  deleted or typed into. Captions go below figures and above tables.
- **The reference list as one object** under the References heading,
  drawn from the citations, so regenerating it never edits the text (and
  never fights Undo).
- **Collapse is read-only.** Editing folded paragraphs would be confusing;
  double-click a topic sentence to unfold and edit there.
- **Sentences by rule, not by model.** The same small splitter decides
  Focus mode's sentence and the Markdown's line breaks, so they always
  agree. Its rules are in `Sentences.swift`.
- **No Git inside the app.** The sandbox would have to go; commit with
  your usual tools.

## Data security

- App Sandbox with only user-selected read-write file access and
  app-scoped bookmarks; no network entitlement (checked by
  `scripts/build-app.sh` after signing).
- The Bibliotheca library is bookmarked read-only: the app never writes to it.
- No `URLSession`, WebKit, Combine networking or `NSWorkspace.open`; a unit
  test scans the sources.
- Writing Tools are disabled for every text view; Look Up, Translate,
  Share, Services and similar are removed from context menus; link and
  data detection are off.
