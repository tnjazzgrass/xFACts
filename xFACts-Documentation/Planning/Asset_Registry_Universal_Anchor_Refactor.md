# Asset_Registry Universal Anchor-Row Refactor

**Status:** Planning. No code written yet.
**Created:** 2026-05-11
**Origin:** xFACts CC File Format Initiative, HTML populator Wave 2 session.

---

## Why this refactor exists

The Asset_Registry catalog has three populators today: CSS, JS, and HTML.
A future PS populator is planned. During the HTML populator Wave 2 work,
we found that the three populators were not consistent in how they
represent the file-level anchor row:

- CSS populator emits `FILE_HEADER` — dual-purpose: anchor AND parsed
  file-header block content (purpose_description, FILE ORGANIZATION list,
  header-shape drift codes).
- JS populator emits `FILE_HEADER` — same dual-purpose model.
- HTML populator emits `HTML_FILE` — pure anchor; HTML markup has no
  file-header construct to parse.

The CSS spec's §14.2 actually documents the dual-purpose definition
explicitly: *"FILE_HEADER ... carries header-level drift codes and serves
as the 'this file was scanned' anchor regardless of what else the file
contains."*

This dual-purpose model creates two problems:

1. **Cross-populator queries can't filter to "all file anchors" cleanly.**
   A query like "list every CSS / JS / HTML / PS file ever scanned"
   becomes structurally awkward. Some populators' anchor row is named
   `FILE_HEADER`; HTML's is named `HTML_FILE`. The universal pattern
   doesn't exist.

2. **The HTML side has no `FILE_HEADER` row at all** because HTML markup
   doesn't have a file-header construct. So when the HTML populator
   references a CSS file (via `<link href="...">`), there's nothing on
   the CSS side that's purely the anchor — the FILE_HEADER row carries
   parsed-header information unrelated to "this file exists, I reference
   it."

The universal model resolves both:

- **Every file gets a `<TYPE>_FILE` anchor row.** This is the universal
  "the file was scanned" row. Pure anchor. No parsed content.
  - `CSS_FILE` for CSS files
  - `JS_FILE` for JS files
  - `HTML_FILE` for HTML host files (PS files containing HTML emission)
  - `PS_FILE` for PowerShell files (future PS populator)

- **Languages that have a file-header construct ALSO emit a `FILE_HEADER`
  row.** This row catalogs the parsed header block's content and shape.
  Carries: purpose_description, the parsed FILE ORGANIZATION list,
  header-shape drift codes, the actual line range of the header block
  (not "the file" by proxy).
  - CSS files emit FILE_HEADER
  - JS files emit FILE_HEADER
  - PS files will emit FILE_HEADER (when the PS populator lands)
  - HTML host files do NOT emit FILE_HEADER (no such construct exists)

**Result:** "Find every scanned file" becomes a clean
`component_type IN ('CSS_FILE', 'JS_FILE', 'HTML_FILE', 'PS_FILE')`. The
FILE_HEADER concept becomes pure: it represents only the parsed
file-header construct, where one exists.

---

## State of the catalog when this session ends

The HTML populator was reverted from emitting `FILE_HEADER` for its
anchor back to emitting `HTML_FILE`. This is the universal-model-correct
state for HTML's anchor row. No other catalog changes were made.

**HTML side rows (current, universal-correct for HTML):**

| Row | component_type | Notes |
|-----|----------------|-------|
| HTML anchor row | `HTML_FILE` | One per HTML-emitting PS file. Universal-correct. |
| HTML's `<link>` ref | `CSS_FILE USAGE` | Reference to a CSS file. The component_name matches the bare filename. |
| HTML's `<script>` ref | `JS_FILE USAGE` | Reference to a JS file. Same shape. |
| HTML ID definition | `HTML_ID DEFINITION` | An `id="..."` attribute. |
| HTML data attribute | `HTML_DATA_ATTRIBUTE DEFINITION` | A `data-*` attribute. |
| Class usage in HTML | `CSS_CLASS USAGE` | A class name in `class="..."`. |
| Event handler | `JS_FUNCTION USAGE` | An `onclick="..."` etc. |

**CSS / JS side rows (current — to change in the universal session):**

| Row | component_type | Notes |
|-----|----------------|-------|
| CSS / JS anchor | `FILE_HEADER` | Currently dual-purpose. Needs split. |

**HTML populator's CSS_FILE / JS_FILE resolution today:**

The HTML populator's USAGE rows for `<link>` and `<script>` resolve their
scope and source_file fields against `FILE_HEADER` rows on the CSS / JS
side (because that's what the CSS / JS populators emit as their anchor
today). After the universal refactor, the HTML populator's resolver
queries change to look up `CSS_FILE` / `JS_FILE` rows instead.

---

## The universal refactor — work breakdown

### 1. CSS populator (~30 lines net change)

In `Populate-AssetRegistry-CSS.ps1`:

- Add `Add-CssFileRow` function — pure anchor row emitter. Emits one
  row with `component_type = 'CSS_FILE'`, `component_name = bare
  filename`, `scope = SHARED or LOCAL`, `line_start = 1`,
  `line_end = file's last source line`, `reference_type = DEFINITION`,
  no raw_text, no purpose_description.
- Modify `Add-FileHeaderRow` to emit only when a header construct
  exists, with its line range being the actual header block's line
  range (not the file's overall line range).
- Per-file walk emits both: `Add-CssFileRow` first, then
  `Add-FileHeaderRow` (only when present).
- Pass 3 cross-population checks: re-target which row gets which code.
  `FILE_ORG_MISMATCH` stays on FILE_HEADER (it's a header-shape concern).
  `EXCESS_BLANK_LINES` moves to CSS_FILE (it's a file-overall concern).

### 2. JS populator (~30 lines net change)

`Populate-AssetRegistry-JS.ps1`. Same shape of change as CSS:

- Add `Add-JsFileRow` function for the anchor.
- Modify `Add-FileHeaderRow` to emit only when present.
- Per-file walk emits both.
- Pass 3 attachment targets updated similarly.

### 3. HTML populator (small)

`Populate-AssetRegistry-HTML.ps1`:

- The anchor row is already `HTML_FILE` (reverted at end of this session).
  No change needed for the anchor.
- The CSS_FILE / JS_FILE pre-load queries currently target `FILE_HEADER`
  with file_type filter. These need to be updated to target `CSS_FILE`
  and `JS_FILE` respectively. Two small query changes.
- The CSS_CLASS pre-load query with `IN ('CSS_CLASS', 'CSS_VARIANT')` —
  no change. That fix is unrelated to this refactor.

### 4. Shared helpers file

`xFACts-AssetRegistryFunctions.ps1` — **no change**. The shared
infrastructure is already neutral. `Get-FileHeaderInfo` returns parsed
header data; each populator decides what row to emit with it.

### 5. CSS spec doc

`CC_CSS_Spec.md`:

- §14.2 — split the FILE_HEADER entry. New CSS_FILE entry describes the
  anchor. FILE_HEADER entry narrows to "the parsed file-header block
  construct."
- §15 — row-extraction table gets a CSS_FILE row added; FILE_HEADER's
  description narrows accordingly.

### 6. JS spec doc

`CC_JS_Spec.md`:

- §17.2 — split the FILE_HEADER entry. New JS_FILE entry describes the
  anchor.
- §18 — row-extraction table gets a JS_FILE row added; FILE_HEADER
  narrows accordingly.

### 7. HTML spec doc

`CC_HTML_Spec.md`:

- §13.2 / §14 — HTML_FILE is already documented as HTML's anchor.
  No change needed beyond clarifying language: HTML doesn't have a
  FILE_HEADER row because HTML markup has no header construct.
- §13.6 (cross-population) — the FILE_HEADER USAGE language we discussed
  during the session never landed in the spec. CSS_FILE USAGE / JS_FILE
  USAGE are still correct as the names of HTML's USAGE rows. After the
  refactor, the resolution targets `CSS_FILE` / `JS_FILE` definition rows
  on the other side. Update §13.6 if it mentions specific row types on
  the resolution-target side.

### 8. Object_Metadata version bumps

- Bump the version on `ControlCenter.AssetRegistry` component (covers
  shared helpers).
- Bump CSS populator's component version.
- Bump JS populator's component version.
- Bump HTML populator's component version.
- Entries describe the row split / query update.

### 9. Constraint table

`CSS_FILE`, `JS_FILE`, `HTML_FILE` are already in the constraint table.
No constraint change today. `PS_FILE` gets added when the PS populator
is built.

### 10. Verification

After all populators are updated and re-run:

- CSS catalog: 33 CSS_FILE rows + 33 FILE_HEADER rows (one of each per
  scanned .css file). Plus all existing CSS rows unchanged.
- JS catalog: 30 JS_FILE rows + 30 FILE_HEADER rows. Plus all existing
  JS rows unchanged.
- HTML catalog: 21 HTML_FILE rows (anchor only). All other HTML rows
  unchanged. Asset references (`CSS_FILE USAGE`, `JS_FILE USAGE`)
  resolve cleanly against the new `CSS_FILE` / `JS_FILE` definitions.

Sanity queries:

```sql
-- Every populator emits an anchor row per file
SELECT file_type, COUNT(*) AS anchor_rows
FROM dbo.Asset_Registry
WHERE component_type IN ('CSS_FILE','JS_FILE','HTML_FILE')
  AND reference_type = 'DEFINITION'
GROUP BY file_type;

-- FILE_HEADER is now pure header-construct (CSS and JS only, no HTML)
SELECT file_type, COUNT(*) AS header_rows
FROM dbo.Asset_Registry
WHERE component_type = 'FILE_HEADER'
GROUP BY file_type;

-- HTML's asset references resolve cleanly
SELECT component_type, reference_type,
       SUM(CASE WHEN source_file = '<undefined>' THEN 1 ELSE 0 END) AS unresolved,
       SUM(CASE WHEN source_file <> '<undefined>' THEN 1 ELSE 0 END) AS resolved
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
  AND component_type IN ('CSS_FILE','JS_FILE')
  AND reference_type = 'USAGE'
GROUP BY component_type, reference_type;
```

---

## Suggested session ordering

1. Read this doc + the two specs (CSS, JS) + the HTML populator's current
   state from GitHub.
2. CSS populator update + delivery.
3. JS populator update + delivery.
4. HTML populator pre-load query update + delivery.
5. CSS spec doc update + delivery.
6. JS spec doc update + delivery.
7. HTML spec doc update (small) + delivery.
8. Run all three populators in sequence: CSS, JS, HTML.
9. Run sanity queries. Confirm catalog shape matches the universal model.
10. Object_Metadata version bumps via Admin UI.
11. Continue HTML populator Wave 2.1 (Type A drift code attachment).

Items 2-7 can be delivered in any order. The populator re-runs (step 8)
require all three populators to be in their new state first.

---

## Things to remember from this session

### HTML populator state today

- Wave 1.1 produces 21 HTML_FILE anchor rows (one per Route, API, Module
  with HTML emission).
- Wave 2 produces ~3,067 total rows including HTML_ID definitions
  (618), CSS_CLASS usages (1992), HTML_DATA_ATTRIBUTE definitions
  (74), JS_FUNCTION usages (284), CSS_FILE usages (37), JS_FILE usages
  (41). All resolutions working correctly against current FILE_HEADER
  targets in CSS / JS.
- The content-sniff has been hardened (Option 3 structural check) and
  correctly rejects SQL `LIKE` patterns like `'%<SystemHealth>%'`.
- The CSS_CLASS pre-load includes `CSS_VARIANT` rows as legitimate
  definitions. Keep this fix.

### Decisions reached

- **Universal anchor-row model** for the catalog: each file gets a
  `<TYPE>_FILE` anchor row. FILE_HEADER becomes pure parsed-header.
- **Asymmetric is not the final state.** We considered keeping HTML
  asymmetric (HTML_FILE for anchor, CSS / JS keep dual-purpose
  FILE_HEADER) but rejected it after seeing the universal refactor's
  lift is small enough to justify the cleanup.
- **Pain of deferred consistency was a stated motivation.** Dirk has
  been bitten by this before; doing the work now while the populators
  are not in production (all dev work is parallel to live site, which
  uses the original architecture) is the right time.

### Drift work that still has to come

- **Wave 2.1** for the HTML populator: attach Type-A (single-row-evaluable)
  drift codes from spec §15.3 (asset references), §15.4 (IDs), §15.5
  (classes), §15.6 (event handlers), §15.7 (data-*). ~35 codes total.
  This was deferred from Wave 2 in favor of confirming row extraction
  was correct first. Confirmed clean.
- **Wave 2.2** for the HTML populator: Type-B structural drift codes
  (DUPLICATE_ID_DECLARATION, INCOMPLETE_OVERLAY_PAIR, etc.) that need
  row-to-row relationships. Deferred until 2.1 lands.
- **Wave 3, Wave 4** for HTML populator: per the existing plan.

### Things NOT changed in this session

- The 51 `HTML_ID DEFINITION` rows in CSS file_type (forbidden ID
  selectors in unrefactored CSS files) — these are legitimate drift
  evidence rows. Stay as-is.
- The 463 `CSS_CLASS USAGE` rows in CSS file_type (descendant /
  compound / sibling selectors that USE a class while defining
  something else) — also legitimate drift evidence. Stay as-is.
- The 185 unresolved CSS_CLASS USAGE rows on the HTML side — most are
  genuine CLASS_PREFIX_MISMATCH drift that Wave 2.1 will catch.

---

## What to NOT do in the next session

- Do not "patch" the populators with workarounds that leave the catalog
  in an inconsistent state. We took today's circuitous path because we
  kept making incremental decisions; the universal model is the clean
  endpoint we want to converge on directly.
- Do not get pulled back into the asymmetric debate. The universal
  model wins on consistency, and the lift is small enough.
- Do not try to combine the refactor with Wave 2.1 in the same session.
  The refactor is a contained piece of work; Wave 2.1 is a separate
  contained piece. Keep them separate.
