# Workspace File Format

A QDVC Manuscript workspace is an ordinary folder of text files and
pictures, meant to be tracked with Git. Everything is plain pandoc
Markdown and YAML, so the manuscript reads well and builds without the app.
This document is the contract: the unit tests check it.

## 1. Files

| File | Holds |
| --- | --- |
| `manuscript.md` | The whole manuscript, when it has no top-level (`#`) headings. |
| `00-manuscript.md` | When it has: the frontmatter and whatever comes before the first `#` heading (an abstract, keywords). |
| `NN-slug.md` | One per top-level section, in order: `01-introduction.md`, `02-literature-review.md`… Subsections (`##`, `###`, `####`) stay in their section's file. |
| `variables.yml` | Variables (§5). |
| `citations.yml` | Citations and the cached reference list (§6). |
| `figures/*.png`, `tables/*.png` | Pictures of figures and tables. |
| `.gitignore` | Written once, with `.DS_Store`. |

`NN` is two digits (three from the 99th section). `slug` is the heading in
lower case with runs of anything but `a–z` and `0–9` turned into `-`, at
most 50 characters. When sections are added, removed, renamed or moved,
the files are renumbered and renamed; Git follows the content. When the
app saves, it writes only files whose content changed and removes only
files named like section files (`NN-*.md`, `manuscript.md`) that are no
longer part of the manuscript. Other files in the folder are left alone.

The app reads `NN-*.md` files in numeric order (and `manuscript.md` only
if there are none).

## 2. Frontmatter

At the top of `00-manuscript.md` (or `manuscript.md`):

```yaml
---
title: "Digital Twins at Work: How Maintenance Engineers Learn to Anticipate Failure"
author: A. Researcher
mustache: variables.yml
qdvc-manuscript:
  heading-numbers: true
  word-limit: 8000
  citation-style: apa7
---
```

- `title` is inline Markdown (§3.2).
- Keys the app doesn't use (`author`, `date`, `bibliography`…) are kept as
  they are, in order, after `title`.
- `mustache` names the variables file for pandoc-mustache; the app adds
  `mustache: variables.yml` once there are variables, and otherwise keeps
  what is there. If it lists several files, the app shows and edits the
  first.
- `qdvc-manuscript` holds the manuscript's own settings: `heading-numbers`
  (default true), `word-limit` (optional) and `citation-style` (`apa7` or
  `acis`).

## 3. Markdown

### 3.1 Blocks

- **One sentence per line**, never wrapped. Lines of a paragraph are
  joined with a space when read, so a file wrapped some other way reads
  the same and is rewritten one sentence per line when the app saves.
  Sentences end at `.`, `!`, `?` or `…` (and any closing quotes, brackets
  or footnote markers) followed by a space and something that can start a
  sentence; not after abbreviations (`e.g.`, `et al.`, `Fig.`, `p.`…) or
  initials (`J. Smith`).
- Paragraphs are separated by one blank line.
- Headings: `#` to `####`, on one line. `{-}` at the end marks a heading
  as unnumbered (pandoc's syntax); References, Abstract, Acknowledgements
  and Appendix headings are unnumbered anyway. Heading numbers are never
  written into the Markdown.
- Block quotes: each sentence line starts with `> `.
- Lists: `- ` for bullets, `1. `, `2. `… for numbered items (renumbered on
  save), continuation sentences indented to the text. Consecutive items
  have no blank line between them.
- A line that would otherwise read as Markdown structure is escaped:
  `1\. …`, `\- …`, `\# …`, `\> …`.

### 3.2 Inline

- `**bold**`, `_italic_` (`*italic*` inside a word), `**_both_**`.
- `\` escapes `*`, `_` at a word's edge, `` ` ``, `@` at a word's start,
  `{{`, `[^` and `<` before a letter.
- `{{name}}`: a variable (§5).
- `[^n]`: a footnote. Footnotes are numbered through the manuscript; each
  file ends with the definitions of its own footnotes,
  `[^n]: First sentence.` with further sentences indented four spaces.
- `<!-- text -->`: a note to self. Never exported, never counted.
- Citations and cross-references are plain text (§4, §6).

### 3.3 Figures and tables

A paragraph that is just a picture:

```markdown
![Figure 1. A process model of anticipatory maintenance](figures/research-model.png)
![Table 1. Characteristics of the participants](tables/sample-characteristics.png)
```

The alt text is "Figure n." or "Table n." and the caption (inline
Markdown, with `[` and `]` escaped); pandoc uses it as the caption. The
number is the figure's place among figures (or the table's among tables)
and is rewritten when they move. The path is the figure's identity; new
pictures are copied into `figures/` or `tables/` under a name made from
their file name.

## 4. Cross-references

"Figure 3", "Table 2" and "Section 3.2" are written as plain text. When a
workspace is read, these words are recognised again: "Figure 3" is
whatever figure was written as "Figure 3." in its caption, and "Section
3.2" whatever heading is numbered 3.2. In the app they are tokens that
follow their target when it is renumbered. A reference to a removed target
is written "Figure ??" (and shown in red). A section reference to an
unnumbered heading is written as its title in quotation marks.

## 5. Variables (`variables.yml`)

A flat YAML mapping, in the order the variables were made:

```yaml
n_interviews: 47 semi-structured interviews
mean_age: "41.30"
```

Names are letters, digits and underscores, not starting with a digit.
Values that a YAML 1.1 reader would type (numbers, booleans, dates) are
double-quoted, so pandoc-mustache prints them exactly. Nested mappings
aren't supported (they're skipped with a warning).

## 6. Citations (`citations.yml`)

In-text citations are written exactly as they read, "(Smith & Jones,
2025)", "Smith and Jones (2025, p. 4)". `citations.yml` says which QDVC
Bibliotheca records each one stands for, and caches the reference list:

```yaml
citations:
- text: (Orlikowski, 1992; Weick, 1995)
  sources: [Orlikowski1992_OS, Weick1995]
- text: (Weick, 1995, p. 43)
  sources: [Weick1995]
  locator: p. 43
- text: Smith and Jones (2025)
  sources: [SmithJones2025_MISQ]
  narrative: true
references:
- source: Weick1995
  entry: Weick, K. E. (1995). _Sensemaking in organizations_. Sage.
```

- `sources` are Bibliotheca IDs (the file stems of the library's `.bib`
  files). `narrative` (default false) and `locator` (default empty) record
  the citation's form. Each distinct `text` appears once, sorted.
- When a workspace is read, every occurrence of a citation's `text` in the
  manuscript becomes that citation again (longest texts first).
- With the library at hand, citation texts and the reference list are
  formatted afresh (APA 7 or ACIS, from the frontmatter), including
  year letters (2025a, 2025b) for works with the same authors and year,
  and the files are rewritten if anything changed. Without it, both stay as
  last written.
- The reference list is written as one paragraph per entry under the
  heading called References (also Reference List, Bibliography, Works Cited
  or Literature Cited), alphabetically. While `references` has entries, the
  paragraphs under that heading belong to the app; with none (say, after
  importing a Word file), they are ordinary paragraphs.

## 7. YAML style

Block style, sequences inside a mapping not indented, short lists of short
scalars in flow style (`[a, b]`), strings plain where that reads back the
same and double-quoted otherwise.
