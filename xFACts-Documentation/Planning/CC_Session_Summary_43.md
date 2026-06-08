# CC Session Summary 43 - CSS Literal Inventory & Purpose-Aware Drift

## Session focus

Stood up a platform-wide CSS literal inventory in the asset-registry CSS populator,
with purpose-aware Tier-1 drift detection. What began as clearing Server Health's six
retained literal-drift rows (punch-list 6.2) became the full mechanism: every page-local
color and dimensional-size literal now gets a catalog row, and literal drift fires only
when a shared token of matching value AND matching purpose exists.

---

## Completed this session

### Populator: `Populate-AssetRegistry-CSS.ps1` (in production, verified)

- **Literal inventory.** Every color (hex, rgb/rgba, hsl/hsla) and dimensional-size
  (px, rem, em, vh, vw, %) literal in a non-`:root` declaration now emits one
  `CSS_LITERAL` row per occurrence. Column mapping: `component_name` = the literal,
  `variant_type` = coarse family (color/size/font-size), `variant_qualifier_1` = the
  declaration property, `parent_function` = owning selector, `reference_type` = LITERAL.
  Bare unitless numbers (line-height, font-weight, z-index, flex, opacity) are excluded.
- **Line-key bug fixed.** Literals are now cataloged directly from the declaration node
  during the walk, not reconstructed in a later pass. Single-line and multi-line rules
  behave identically. Server Health went from 6 visible literal rows to 102.
- **Purpose-aware Tier-1.** A literal is drift only when a shared token of the same
  family AND same value exists. Color matching is sub-family aware (see below); size and
  font-size match by coarse family + exact value.
- **Color sub-family classifier (two-tier model, data-validated).**
  - Property-specific color tokens (`--color-bg-*`, `--color-border-*`, `--color-text-*`)
    match only literals of the same color purpose.
  - Role/state color tokens (`--color-accent-*`, `--color-status-*`, `--color-tint-*`,
    `--color-glow-*`, `--color-banner-*`, `--color-button-*`) form a cross-property pool
    that matches a literal of any color property.
  - Validated against the live drift set: of 95 color drift rows, 92 stayed drift (90
    role/state + 2 clean property-specific) and exactly the 3 cross-purpose false
    positives flipped to inventory (`#333`-as-background vs `--color-border-divider`;
    `#ce9178`-as-border-color x2 vs `--color-text-pre`). Confirmed against production:
    color drift dropped 95 -> 92.
- **Helpers added:** `Get-PropertyTokenFamily`, `Get-TokenNameFamily`,
  `Test-LiteralTokenFamilyMatch`, `ConvertTo-ColorKey`, `Get-LiteralsInDeclaration`,
  `Add-CssLiteralRow`. Removed `Get-HexLiterals`/`Get-PxLiterals` and the dead Pass-3
  literal blocks. Shared-variable map enriched in place to carry each token's value and
  family; the one existing reader (USAGE resolution) changed to read `.SourceFile`. No
  dead code left behind. Byte discipline confirmed (no BOM on output, ASCII, CRLF,
  single trailing newline).

### Spec: `CC_CSS_Spec.md` (edits applied locally, NOT yet pushed to GitHub)

- Tightened the literal-drift wording in section 10.2, the section 14 forbidden-pattern
  rows, and the section 15 `DRIFT_HEX_LITERAL`/`DRIFT_PX_LITERAL` descriptions to
  "matching value and purpose."
- Added the color-token naming rule (the populator's sub-family matching depends on it):
  color tokens are named by purpose; `--color-bg-*`/`--color-border-*`/`--color-text-*`
  are property-specific and apply only to their respective properties; the role/state
  prefixes are usable across properties; a property-specific value must not be named as
  role/state or vice versa.

### Schema

- `CSS_LITERAL` added to `CK_Asset_Registry_component_type` (applied).

---

## Key decisions & principles reaffirmed

- **Zero-interpretation drift.** `drift_codes IS NOT NULL` must mean a real signal with no
  mental footnotes. Every drift row is either (a) fixable and will be fixed, or (b) a
  signal deliberately retained by conscious decision. There is no "acceptable drift" that
  requires re-interpreting a row each time it is seen.
- **Drift is a signal, not a wound.** New drift from sharpening the populator is the
  catalog seeing more, not regression - acceptable as long as site functionality is intact.
  The populator is offline analysis, not a runtime dependency.
- **Data before granularity.** The color sub-family layer was deferred until the real
  catalog could prove it was warranted, then built once the data showed the convention was
  consistent and the false-positive class was real. Same discipline applies to the size
  question below: investigate, then act.
- **Files conform to the spec; the spec is the authority.** A populator dependency on a
  naming convention is a developer rule and belongs in the spec.
- **Tiering for drift resolution:** anything resolvable by file edits today is first-tier;
  anything requiring a populator change is second-tier.

---

## Current total cc-zone drift - categorized

### First-tier (resolvable today by file edits)

1. **Color literal tokenization (`DRIFT_HEX_LITERAL`).** The large, clean win. Pages
   hardcode values that already have tokens - chiefly the alpha tints/banners:
   `rgba(86,156,214,0.15)` (= `--color-banner-reconnecting-bg`), `rgba(244,135,113,0.15)`
   (= `--color-banner-disconnected-bg`), `rgba(78,201,176,0.15)` (= `--color-banner-reloading-bg`),
   `rgba(220,220,170,0.15)` (= `--color-banner-session-bg`), the `*-0.3` border companions,
   and `rgba(220,220,170,0.08)`/`rgba(244,135,113,0.08)` (= `--color-tint-warning`/`-critical`).
   Resolution: replace literal with the existing `var()`. Zero design decisions.
   A small remainder are one-off colors matching a token of a different role
   (`#22c55e`, `#444`, `#ce9178`, `#6d3030`, `#f48771`, `#4ec9b0`) - each needs a per-case
   call: use the token, promote a new purpose-named token, or accept as a deliberate local
   value.

2. **`cc-toggle-*` shared chrome construct (punch-list 6.1).** The admin doc-toggle cluster
   (admin.css ~2733-2931) carries `FORBIDDEN_DESCENDANT`, `FORBIDDEN_ADJACENT_SIBLING`,
   `FORBIDDEN_GENERAL_SIBLING`, `FORBIDDEN_ATTRIBUTE_SELECTOR`, and `MISSING_PURPOSE_COMMENT`
   from native-checkbox toggle markup that does not fit the class-only model. The same
   toggle pattern recurs across pages (`aai-toggle-knob`, `dbc-edit-toggle-knob`,
   `clp-toggle-switch`), so a shared construct clears drift on several pages at once.

4. **ServerHealth-API.ps1 `MISSING_PARAMETER_DECLARATION` (~14 rows).** Inline
   `Invoke-Sqlcmd` calls with `DECLARE @x = $(...)` string interpolation and `@parameter`
   placeholders but no `-Parameters @{...}`. Investigate-then-act: determine whether each
   is safe (server-controlled values) or should move to proper parameterization. Also
   `ServerHealth.ps1 MISSING_HEADER_BAR` (the HTML route is missing the header bar after
   `$navHtml`).

(Sequence intent for next session: 1, then 2, then 4. No cap - continue past these into
whatever else is resolvable.)

### Second-tier (requires a populator change)

6. **Size literal sub-classification decision (`DRIFT_PX_LITERAL` - the largest bucket).**
   This is the size-side of the question color just resolved. Many size literals match a
   size token of unrelated purpose by value coincidence: `padding: 2px` vs
   `--size-radius-xs: 2px`; `font-size: 24px` vs `--font-size-h1: 24px`; `width: 60px` vs
   `--size-page-padding-top: 60px`; the very common `1px`/`2px` values vs
   `--size-border-thin`/`--size-radius-xs`. Decision needed: does size warrant the same
   two-tier treatment color got (spacing / radius / font-size / layout-dimension
   sub-families), or are some of these better resolved file-side by adopting the correct
   `var()`? Investigate-then-act, exactly as color was - do not blanket-tokenize or
   blanket-suppress. Note `font-size` is already its own family, so the open question is
   really about splitting the generic `size` family.

### Deliberately retained (NOT to be "fixed")

- **Engine-card registry drift** - `ENGINE_CARD_ORDER_MISMATCH` and
  `ENGINE_SLUG_REGISTRY_MISMATCH` on DmOperations.ps1 (archive, shell) and
  IndexMaintenance.ps1 (sync, scan, execute, stats). These engines are registered but not
  yet active, and this drift is a WANTED operational signal ("ready to go, not yet turned
  on"). Retained by conscious decision; not a defect and not a deferral. This is the
  sanctioned exception to zero-interpretation: a row kept on purpose, not re-interpreted.

- **Home.ps1** - the one unconverted CC page, a self-contained single-file landing page
  (inline `<style>`, no shared chrome substitutions, 12 unresolved local classes, plus
  PS-side header/RBAC/subsection-marker drift; ~35 rows total). Architectural question
  open: keep as a 1-file landing page or convert to the full 4-file set. Not yet worked.
  Retained drift-bearing pending that discussion; the carry-forward item is the decision,
  not a conversion.

---

## Standing items

- **Spec not yet pushed.** The `CC_CSS_Spec.md` literal-drift wording + color-token naming
  rule are applied locally but not committed to GitHub. Push before next session start so
  GitHub remains authoritative.
- **Byte discipline / BOM.** Output is delivered BOM-free; the ISE-on-network save path may
  reacquire a BOM repo-side (known workflow issue, not an output issue).
- The four-helper sub-family pattern is available if HTML/JS populators ever grow
  comparable literal/token awareness, but those are different enough to warrant a fresh
  look rather than assuming it ports.

---

## Carry-forward priority (next session launch point)

1. Color literal tokenization - replace hardcoded values with existing `var()` tokens
   (first-tier, file edits, highest volume / lowest risk).
2. `cc-toggle-*` shared chrome construct (punch-list 6.1) - clears the toggle
   combinator/attribute/purpose-comment cluster across multiple pages.
3. ServerHealth-API parameterization review + `ServerHealth.ps1` header bar
   (first-tier, file edits, investigate-then-act on the SQL params).
4. Size literal sub-classification decision (second-tier, populator change,
   investigate-then-act).

Deliberately retained, not on the worklist: engine-card registry drift (wanted signal),
Home.ps1 (architectural decision pending).

Remaining older punch-list items still open from prior sessions (keyframe naming/dedup,
populator comment-block condensation, `cc-last` dup, RBAC_ActionRegistry rows, DBCC
disk-alert suppression during CHECKDB, B2B investigation-first) carry forward as before -
not displaced by the above, just lower in the immediate sequence.
