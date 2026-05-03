# Control Center File Format Standardization

**Created:** May 2, 2026
**Status:** Active - scaffold only, content sections pending
**Owner:** Dirk
**Target File:** `xFACts-Documentation/Planning/CC_FileFormat_Standardization.md`

---

## Purpose

This document is the single source of truth for the Control Center file format standardization initiative. It establishes a strict, machine-parseable file format specification per file type, then drives the conversion of every CC source file to conform to that specification.

The initiative has two outputs:

1. **A complete, opinionated specification** that defines exactly how every CC source file must be structured, with no allowance for stylistic drift. The cataloging parser commits to extracting cleanly from any conforming file.
2. **A converted codebase** where every existing source file has been refactored to conform to the spec.

The Asset_Registry catalog is both the verification mechanism (does the parser see what the spec says it should see?) and the visible measure of progress (catalog completeness grows as files convert).

When this work is complete, this document and its peers in `Planning/` migrate to comprehensive HTML guide pages on the Control Center documentation site. The working documents themselves retire to `Legacy/`.

---

## Documents this consolidates

- `CC_FileFormat_Spec.md` (v0.2) — first-pass spec from April 2026. Content folds into this doc as we progress; original retires to `Legacy/` once obsolete.
- `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md` — observations from earlier parser work. Content folds into the relevant per-file-type sections of this doc; original retires to `Legacy/` once obsolete.

The `CC_Chrome_Standardization_Plan.md` is a related but distinct effort focused on visual/structural alignment of the page chrome. It stays in active execution as its own document. This format spec work and the chrome work share no dependency in either direction.

---

## Session Start Protocol

**If you are Claude starting a new session on this initiative, do exactly this in order. Do not ask Dirk to re-establish context that is captured below.**

1. Dirk provides a cache-busted manifest URL at session start (`https://raw.githubusercontent.com/tnjazzgrass/xFACts/main/manifest.json?v=<value>`). Fetch it.
2. From the top-level manifest, locate `manifest-documentation.json` and fetch it.
3. From the documentation manifest, locate the `raw_url` for `xFACts-Documentation/Planning/CC_FileFormat_Standardization.md` (this document) and fetch it.
4. Read the "Current State" subsection immediately below this protocol. That paragraph contains everything needed to know where work stands.
5. Read whichever file-type section is named as active in Current State (Part 2, 3, 4, 5, or 6).
6. Begin work in that section. Honor any "Blocked on" or "Queued next" items in Current State.

**Authoritative source rule:** This document is authoritative. If anything in Project Knowledge or Claude's memory contradicts what is written here, this document wins. Project Knowledge is summarized periodically and may lag the doc by a session or more. The doc reflects the most recent session-end state.

**End-of-session discipline:** Before ending any session that touches this initiative, Claude updates Current State (below) and adds an entry to the Session Log. This is not optional — the protocol only works if Current State is kept current.

### Current State

*Last updated: 2026-05-02 (end of session).*

**Active section:** Part 2 - CSS Files. Status `[OUTLINE]`. No content drafted yet; ready for the design discussion to begin next session.

**Last decisions made this session:**
- Initiative scope established: build a strict, opinionated, machine-parseable file format spec per file type, then convert every existing CC source file to conform.
- This document is the single source of truth for the initiative until eventual HTML guide migration. `CC_FileFormat_Spec.md` v0.2 and `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md` content folds in here over time; both originals retire to `Legacy/` once obsolete.
- File-type discussion order: CSS first (lowest risk, establishes the spec-section + decision-log pattern), then JS, then PowerShell route files, then PowerShell module files, then documentation HTML.
- "Canonical" terminology dropped — the spec text is authoritative; example code in the doc is illustrative only.
- Working approach for design discussions: Claude brings 2-3 reasonable options with tradeoffs to each meaningful decision rather than presenting a single strawman. Dirk's domain is structure and organization, not language-specific expertise. Decision logs capture both the decision and a sentence on the reasoning.

**Queued next:** Begin the CSS design discussion at the start of the next session. Claude opens by fetching `engine-events.css` (the largest, most representative shared CSS file) plus 2-3 page-specific CSS files for variety, then presents the structural questions to be decided as a list with recommended choices. Dirk reviews and we work through the list to populate Part 2.

**Blocked on:** Nothing. Ready to proceed.

**Files Claude should fetch at the start of next session, after this doc:**
- `xFACts-ControlCenter/public/css/engine-events.css` — the shared chrome CSS, largest CSS file, representative of the patterns we want to standardize around
- One or two page-specific CSS files for variety (e.g., `server-health.css`, `bdl-import.css`)

These give Claude concrete material to ground recommendations in. Without seeing the existing files, recommendations would be theoretical.

---

## How to use this document

### Status markers

Each major section carries a status marker showing where it is in the lifecycle:

| Marker | Meaning |
|---|---|
| `[OUTLINE]` | Section exists as a placeholder. No content drafted yet. |
| `[IN DISCUSSION]` | Active design discussion. Decisions being made; content in flux. |
| `[DRAFT]` | Decisions made and written down. Spec content present. Not yet locked in. |
| `[FINALIZED]` | Section is complete, locked, and ready for the eventual HTML guide migration. |

### Decision logs

Every per-file-type section has a "Decision Log" subsection. Decisions land there as they're made, with date, brief rationale, and any options considered but rejected. This captures *why* a rule exists, which matters when revisiting later.

### Illustrative examples

Where this document includes example code (a complete CSS file, a sample function declaration, etc.), the examples are illustrative — they show the spec applied. **The spec text is authoritative.** If an example and the spec text disagree, the example is wrong and gets corrected.

### Forbidden patterns

Each file-type section enumerates explicit forbidden patterns alongside the required ones. The format is "Don't do X — do Y instead." The forbidden examples are as important as the required ones, because they make implicit rules explicit.

---

## Session log

A running log of progress across sessions. Each session adds a dated entry describing what was decided, what was drafted, and what's queued next.

| Date | Activity |
|---|---|
| 2026-05-02 | Document created. Scaffold and structure established with nine major parts (universal conventions, five file-type sections, compliance reporting, conversion tracking, open questions). Session Start Protocol and Current State sections added at top of doc to make cross-session handoff seamless. Status marker conventions defined (`[OUTLINE]`, `[IN DISCUSSION]`, `[DRAFT]`, `[FINALIZED]`). Decision-log pattern established per file-type section. Discussion order set: CSS first, then JS, PS route files, PS module files, documentation HTML. CSS section queued for the next session's design discussion. |

---

## Part 1 - Universal Conventions  `[OUTLINE]`

Conventions that apply to every file type. Will be filled in as we work through individual file types — universal rules emerge from the per-file-type discussions and get promoted up to this section.

### 1.1 File header block

(To be filled in. Existing v0.2 spec content is the starting point but will be refined.)

### 1.2 Section banners

(To be filled in. Existing v0.2 spec content is the starting point but will be refined based on what we learned about banner detection during cataloger work.)

### 1.3 Sub-section markers

(To be filled in.)

### 1.4 File encoding and line endings

(To be filled in.)

### 1.5 Decision log

(Decisions affecting universal conventions land here.)

---

## Part 2 - CSS Files  `[OUTLINE]`

The first file-type spec under development. Current target for the next session.

### 2.1 Required structure

(To be filled in.)

### 2.2 What every CSS file contains

(To be filled in.)

### 2.3 Required patterns

(To be filled in.)

### 2.4 Forbidden patterns

(To be filled in.)

### 2.5 Illustrative example

(To be filled in.)

### 2.6 What the parser extracts

(To be filled in.)

### 2.7 Decision log

(Decisions affecting CSS spec land here.)

---

## Part 3 - JavaScript Files  `[OUTLINE]`

### 3.1 Required structure

(To be filled in.)

### 3.2 What every JS file contains

(To be filled in.)

### 3.3 Required patterns

(To be filled in.)

### 3.4 Forbidden patterns

(To be filled in.)

### 3.5 Illustrative example

(To be filled in.)

### 3.6 What the parser extracts

(To be filled in.)

### 3.7 Decision log

(Decisions affecting JS spec land here.)

---

## Part 4 - PowerShell Route Files  `[OUTLINE]`

Route files (page route handlers and API route handlers — `*.ps1` files in `scripts/routes/`).

### 4.1 Required structure

(To be filled in.)

### 4.2 What every route file contains

(To be filled in.)

### 4.3 HTML emission patterns

This is the section where the indirection issues observed during cataloger development get resolved. R1 and R2 from the recommendations doc fold in here, refined and made firm.

(To be filled in.)

### 4.4 Required patterns

(To be filled in.)

### 4.5 Forbidden patterns

(To be filled in.)

### 4.6 Illustrative example

(To be filled in.)

### 4.7 What the parser extracts

(To be filled in.)

### 4.8 Decision log

(Decisions affecting PS route file spec land here.)

---

## Part 5 - PowerShell Module Files  `[OUTLINE]`

Module files (`*.psm1` files — primarily `xFACts-Helpers.psm1` for now). Functions exported for use by route files and other modules.

### 5.1 Required structure

(To be filled in.)

### 5.2 Function organization

(To be filled in.)

### 5.3 HTML-emitting helper functions

The other place where R1 and R2 fold in — most of the indirection patterns observed in cataloger development came from helper modules.

(To be filled in.)

### 5.4 Required patterns

(To be filled in.)

### 5.5 Forbidden patterns

(To be filled in.)

### 5.6 Illustrative example

(To be filled in.)

### 5.7 What the parser extracts

(To be filled in.)

### 5.8 Decision log

(Decisions affecting PS module spec land here.)

---

## Part 6 - HTML in Documentation Pages  `[OUTLINE]`

The static HTML files in `xFACts-ControlCenter/public/docs/` (Confluence-published documentation pages, separate from the route-file inline HTML).

### 6.1 Required structure

(To be filled in.)

### 6.2 Required patterns

(To be filled in.)

### 6.3 Forbidden patterns

(To be filled in.)

### 6.4 Illustrative example

(To be filled in.)

### 6.5 What the parser extracts

(To be filled in.)

### 6.6 Decision log

(Decisions affecting documentation HTML spec land here.)

---

## Part 7 - Compliance Reporting  `[OUTLINE]`

How the parser reports spec violations. Existing v0.2 spec Part 6 is the starting point.

### 7.1 Severity levels

(To be filled in.)

### 7.2 Report structure

(To be filled in.)

### 7.3 Strict vs permissive mode

(To be filled in.)

---

## Part 8 - Conversion Tracking  `[OUTLINE]`

Per-file conversion progress. As file types finalize and we begin converting existing files to conform to the spec, this section tracks status per file.

### 8.1 CSS files

(File list and conversion status, populated when CSS spec finalizes.)

### 8.2 JS files

(File list and conversion status, populated when JS spec finalizes.)

### 8.3 PowerShell route files

(File list and conversion status, populated when route spec finalizes.)

### 8.4 PowerShell module files

(File list and conversion status, populated when module spec finalizes.)

### 8.5 Documentation HTML files

(File list and conversion status, populated when documentation HTML spec finalizes.)

---

## Part 9 - Open Questions and Known Tensions  `[OUTLINE]`

Items that surface during design discussions but don't fit cleanly into one section, or that need cross-cutting consideration. Captured here so they don't get lost.

(Items added as they arise.)

---

## Revision History

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-05-02 | Document created. Scaffold and structure only - all content sections marked `[OUTLINE]` pending design discussions. Consolidates `CC_FileFormat_Spec.md` v0.2 and `CC_FileFormat_Parser_Friendly_Conventions_Recommendations.md`; both will retire to `Legacy/` as content folds in. Session Start Protocol and Current State sections added near the top to support seamless cross-session handoff: a new session's first action is to read this doc and Current State, with no need to re-establish context through Q&A. End-of-session discipline mandates updating Current State and Session Log before stopping. |
