# CC Session Summary 3 — §11.2 Spec Amendments

*Session date: 2026-05-18. Spans three chat conversations (compaction-driven splits); conceptually one continuous session implementing the four §11.2 decisions from `CC_Migration_Phase1.md`.*

---

## 1. Purpose

This session implemented the four spec amendments queued in `CC_Migration_Phase1.md` §11.2 as "spec ambiguities and open questions" surfaced by the Backup page migration. Each amendment was decided first, then applied as a full drop-in replacement to the relevant spec(s).

The session was prefaced by a separate decision-making conversation (the first of the three chats) that locked all four §11.2 decisions and their downstream implications before any spec text was changed. Subsequent conversations delivered the spec amendments one file at a time, with review between each.

---

## 2. What was done

### 2.1 The four §11.2 decisions, locked

#### 2.1.1 PS inline comment dividers (§11.2.1)

**Decision:** Free-standing `# ====` and `# ----` divider lines outside section banners remain forbidden. The PS spec's `FORBIDDEN_INLINE_DIVIDER` rule is correct as written.

The original §11.2.1 question proposed allowing dividers inside function bodies for readability. On reflection, the rule's intent is structural — section banners are the platform's section markers; inline dividers compete with banners for the reader's attention and weaken the banner-as-section-marker principle. The PS spec did not require change for this decision; the populator change to support it was the alternative, which was also abandoned.

**Spec impact:** No change to PS spec body. The decision is recorded here and in `CC_Migration_Phase1.md` §11.2.1 as resolved.

#### 2.1.2 Modal structure (§11.2.2)

**Decision:** Modals are a single-element nested construct. The outer element carries class `xf-modal-overlay` and exactly one ID (`<prefix>-modal-<purpose>`); the nested `.xf-modal` child carries no ID.

The original modal ID convention required separate IDs for the overlay and the dialog (`<prefix>-modal-<purpose>-overlay` and `<prefix>-modal-<purpose>`). That pattern made modals look like slideouts/slide-up panels (which are genuine pair constructs with overlay AND panel both surfacing in JavaScript) — but modals are structurally different. The nested form is required for flex-centering, and the dialog is never addressed independently from the overlay at runtime. One construct, one ID.

**Spec impact:** HTML spec §4.3.2 rewritten; §4.3.4 pair rule scoped to slideouts and slide-up panels only; new drift code `MALFORMED_MODAL_STRUCTURE` for missing `.xf-modal` child; §10.5.1 categorical name derivation trigger updated.

#### 2.1.3 CSS compound modifier classes (§11.2.3)

**Decision:** Adopted Option B (CSS populator recognizes compound-only modifiers) plus B1 (no carve-outs for `cc-shared.css`; every base class is `cc-`-prefixed; modifiers themselves remain unprefixed).

A compound modifier is a class token defined in CSS only as the rightmost component of a compound selector (e.g., `.cc-engine-bar.disabled`, `.cc-button.disabled`). It has no standalone `.disabled { ... }` rule anywhere. The CSS populator recognizes a token as a compound modifier by observing that no standalone definition exists.

Compound modifiers are exempt from the unified prefix rule. Their validity in HTML markup is enforced at the HTML populator's USAGE-resolution step: a compound modifier on an element is valid only when the element's companion class is registered as a compound base for that modifier (via an existing `CSS_VARIANT DEFINITION` row).

**Spec impact:** CSS spec new §7.4 (Compound modifier classes); §16.3 `PREFIX_MISMATCH` description tightened; HTML spec §5.1.1 references the compound modifier exemption; new HTML drift code `INVALID_MODIFIER_CONTEXT` for usage outside registered compound contexts.

#### 2.1.4 Unified `cc-`/`cc_` prefix and chrome ID exemption (§11.2.4)

**Decision:** Every identifier in the codebase is prefixed. Page-local identifiers carry the page's `cc_prefix` from `Component_Registry`. Shared chrome identifiers carry `cc-` (HTML/CSS) or `cc_` (JS). No `(none)` sentinel in CSS, HTML, or JS. No exemption list, no contract identifiers that escape the rule.

The original §11.2.4 question was narrower — how to exempt chrome IDs in JS populator's `JS_HTML_ID_MALFORMED` check. The decision broadened to address the underlying inconsistency: chrome was unmarked (unprefixed) and pages were prefixed, which meant "is this a chrome thing or page-local thing?" required knowing the source file. With unified prefixing, the prefix IS the source marker. `cc-engine-bar` is unambiguously chrome; `bch-pipeline-card` is unambiguously batch-monitoring page.

The unified rule extends to:
- **HTML:** all IDs, classes, page-emitted `data-*` attribute names. Body attributes `data-page` and `data-prefix` renamed to `data-cc-page` and `data-cc-prefix`.
- **CSS:** all class definitions. Chrome classes in `cc-shared.css` use `cc-` prefix. Anchor file sections declare `Prefix: cc` (replacing `Prefix: (none)`).
- **JS:** all top-level identifiers. Hooks become `<prefix>_onPageRefresh` (not `onPageRefresh`). `ENGINE_PROCESSES` becomes `<prefix>_ENGINE_PROCESSES`. Chrome dispatch tables become `cc_clickActions` (not `sharedClickActions`). The bootloader uses computed-name lookup (`window[pageKey + '_<name>']`) for every page-module reference — same pattern that already resolved `<prefix>_init`.
- **PS:** PS-specific deviation; see §2.2 below.

**Spec impact:** All four specs amended. New drift codes: `MISSING_DATA_CC_PAGE`, `MISSING_DATA_CC_PREFIX`, `ANCHOR_SECTION_INVALID_PREFIX` (CSS), `CHROME_FILE_INVALID_PREFIX` (JS), plus drift code description updates across all four. The §5.5 "Contract identifiers" exemption in the JS spec was deleted entirely.

### 2.2 PS spec deviation — `(none)` retained

The PS spec is the one place where the unified prefix model did not extend cleanly. The decision to retain `(none)` was made deliberately, not by oversight, based on two genuine structural differences between PowerShell and the other three file types:

1. **PS has section types containing no prefixable identifiers.** CHANGELOG entries are dates; IMPORTS are dot-source statements; PARAMETERS is a single `param()` block; INITIALIZATION is bootstrap calls; ROUTE registrations contain anonymous ScriptBlocks; EXPORTS is a single `Export-ModuleMember` call. There is nothing to validate against a prefix in these sections.

2. **PowerShell has a language-level naming convention.** `Verb-Noun` is enforced by `Get-Verb`, `Get-Command`, tab completion, and the entire PowerShell tooling ecosystem. Renaming `Get-PageBrowserTitle` to `cc_GetPageBrowserTitle` would conflict with PowerShell idiom and tooling. CSS class names, HTML IDs, and JS function names are author-chosen — they don't have ecosystem conventions to honor.

The PS spec's Appendix A.5 was rewritten to make this explicit: the `(none)` retention is not an exemption from the unified prefix model; it is a recognition that PowerShell plays by different rules at the language level. The platform's prefix discipline applies where it fits; PowerShell's own conventions apply where the platform's would conflict.

### 2.3 Spec Authoring Conventions block — added to all four specs

A new "Spec Authoring Conventions" section was added at the top of every spec, verbatim across all four. Eight conventions govern how specs are written:

1. Rules state what, not why
2. One rule per bullet, where possible
3. No introductory framing
4. Rationale lives in the Appendix
5. Drift codes live in a consolidated reference at the end of the spec, not inline with rules
6. Examples earn their place
7. No status, history, or progress information
8. Inline SQL or script query blocks do not belong in the spec

The disclaimer at the end acknowledges that new content conforms to these conventions immediately, but existing prose predating them will be cleaned up in a dedicated pass (see §6.2 below).

### 2.4 Migration completeness analysis — the downstream payoff

A late-session discussion explored whether the unified prefix model meaningfully improves the chrome standardization analysis that will follow the migration. The answer is yes: with prefix as the universal source marker, two recurring query patterns become trivial:

- **Migration miss detection.** Find page-prefixed identifiers whose suffixes match `cc-` identifiers — these are things that should have been migrated to shared during the conversion but were left page-local.
- **Promotion candidate detection.** Find suffixes appearing under multiple page prefixes with no `cc-` equivalent — these are things multiple pages reinvented that want to be shared.

A related thought experiment surfaced: separating `prefix` and `base_name` into independent catalog columns (as opposed to extracting them on the fly via LIKE patterns or `SUBSTRING` calls on `component_name`). The discussion concluded with no action — the LIKE-based queries are adequate at 50K-row scale, and the columns can be added later if operational use confirms the ergonomics matter. Recorded here for future revisit, not on any active list.

### 2.5 Workflow validation — mid-session sync confirmed

Dirk and Claude validated the mid-session Project Knowledge sync workflow end-to-end. The cycle is:

1. Push to GitHub (after Claude produces spec amendments in `/mnt/user-data/outputs`)
2. Manually trigger Sync to GitHub from Project Knowledge
3. Project Knowledge re-indexes from the updated GitHub state
4. Subsequent `project_knowledge_search` calls return the updated content

The sync is **not** automatic. The manual Sync step is required for the round trip to work. This is durable workflow knowledge that should be reflected in session-start documentation going forward.

---

## 3. Decisions reached

1. **All four §11.2 decisions are locked and implemented in the relevant specs.** No further amendment debate; the rules now stand and the implementation work follows from them.
2. **PS spec is the one deliberate deviation from the unified prefix model.** The deviation is justified by PowerShell's language ecosystem conventions; documented explicitly in Appendix A.5 so it doesn't read as a forgotten carve-out.
3. **The cleanup session is a separately scoped follow-up.** Existing prose in all four specs predates the Spec Authoring Conventions and needs to be reworked; that's its own session, not bundled with the §11.2 amendments.
4. **Surfacing drift is an ongoing effort; not all drift is breakage.** Dirk's framing: "if drift fires on it we address it, but as long as it doesn't cause the page itself to break that's OK." The populator surfacing inconsistencies is the goal; perfect zero-drift on first pass is not. The rules we're defining today are starting points based on what we expect going forward and what we know today.
5. **The session-start workflow now includes a sync step when mid-session pushes occur.** Push → Sync → search. The manifest URL workflow remains useful for files not in Project Knowledge and for verifying current state of source files.

---

## 4. Files modified this session

### 4.1 Spec documents (production-ready, in Project Knowledge)

| File | Status | Location | Notes |
|---|---|---|---|
| `CC_HTML_Spec.md` | DEPLOYED | `xFACts-Documentation/Planning/CC_HTML_Spec.md` | 2273 lines (up from 2213). All §11.2 amendments applied. New drift codes: `MISSING_DATA_CC_PAGE`, `MISSING_DATA_CC_PREFIX`, `MALFORMED_MODAL_STRUCTURE`, `INVALID_MODIFIER_CONTEXT`. |
| `CC_CSS_Spec.md` | DEPLOYED | `xFACts-Documentation/Planning/CC_CSS_Spec.md` | 919 lines (up from 882). §5 rewritten for two-form prefix system. New §7.4 (compound modifier classes). New drift code: `ANCHOR_SECTION_INVALID_PREFIX`. |
| `CC_JS_Spec.md` | DEPLOYED | `xFACts-Documentation/Planning/CC_JS_Spec.md` | 1420 lines (up from 1415). §5 rewritten; §5.5 contract identifier exemption deleted. Hooks renamed to `<prefix>_<hookSuffix>`. ENGINE_PROCESSES renamed to `<prefix>_ENGINE_PROCESSES`. Chrome dispatch tables renamed to `cc_<event>Actions`. New drift code: `CHROME_FILE_INVALID_PREFIX`. |
| `CC_PS_Spec.md` | DEPLOYED | `xFACts-Documentation/Planning/CC_PS_Spec.md` | 1938 lines (up from 1912). Spec Authoring Conventions added. §5.1 dropped 3-character rule. §5.2 rewritten to explain `(none)` retention. Appendix A.5 expanded with PowerShell-vs-other-specs rationale. Embedded HTML example in §20.1 updated to use `cc-` prefixed chrome forms. |

All four specs now share an identical "Spec Authoring Conventions" block at the top.

### 4.2 Documentation alignment

The four specs are aligned on:
- Authoring conventions (verbatim across all four)
- Registry as source of truth for prefix shape (no length or character constraints in the spec)
- Two-form prefix system (HTML/CSS/JS) or two-form-plus-`(none)` system (PS, with explicit rationale)
- Compound modifier class concept (CSS-defined, HTML-validated, JS limitation documented as a known boundary)

### 4.3 Files not modified (but affected by the amendments)

The spec amendments imply substantial downstream rename work that has **not yet been done**. Each of the following requires updates in the implementation phases to follow:

- `cc-shared.css` — every chrome class definition becomes `cc-` prefixed (e.g., `header-bar` → `cc-header-bar`)
- `cc-shared.js` — every top-level identifier becomes `cc_` prefixed; dispatch tables rename to `cc_<event>Actions`; bootloader switches to computed-name lookup for all page-module references
- Every page's CSS file — references to chrome classes update to `cc-` prefixed forms
- Every page's HTML emission (in `.ps1` files) — body attributes, chrome class refs, modal structure updates
- Every page's JS file — hooks rename to `<prefix>_<hookSuffix>`, `ENGINE_PROCESSES` rename to `<prefix>_ENGINE_PROCESSES`, calls to chrome utilities update for `cc_` prefix
- All four populators — implement the new drift codes and the unified prefix rule's recognition logic

---

## 5. Open items from this session

### 5.1 Resolved during this session

- All four §11.2 questions from `CC_Migration_Phase1.md` (PS dividers, modal structure, compound modifiers, unified prefix and chrome ID exemption). Each can be marked resolved in the migration doc.
- The "chrome ID exemption in JS populator" gap from §11.1.7 (false positive on `document.getElementById('last-update')` calls) — resolved by the unified prefix rule, which makes chrome IDs valid prefixed names rather than malformed ones.

### 5.2 Deferred / recorded for later

- **Spec cleanup session.** Existing prose in all four specs predates the Spec Authoring Conventions and needs to be reworked. The HTML spec needs the most attention; PS spec is in the best shape going in. This is a separately scoped session, not part of the amendment work.
- **Prefix / base_name catalog columns.** Discussed near the end of the session; deferred to post-migration revisit. No action taken; recorded here so it isn't forgotten.
- **CC_Migration_Phase1.md updates.** The §11.2 backlog items are now resolved; the doc should be updated to mark them complete and to reflect the spec changes. The §11.1.7 chrome ID gap is also resolved by the unified prefix work and should be marked complete.

---

## 6. Next session

### 6.1 Decision: what comes next

Several paths are viable for the next session. Each has its own merit:

**Option A — Implementation phase begins.** Start the cc-shared.css and cc-shared.js rename pass. This is the largest single piece of work the amendments imply: every chrome identifier in those two files renames, and every page that consumes them updates its references. The rename has to happen before any page can be migrated under the new rules.

**Option B — Populator updates.** Bring the four populators in line with the amended specs before any further file changes. The populators currently enforce the pre-amendment rules; after the rename pass starts, they need to recognize the new patterns. Updating populators first means files renamed under Option A immediately validate correctly.

**Option C — Spec cleanup session.** Address the prose-bloat in the existing specs to align with the Spec Authoring Conventions. This is independent of the rename work and could be a fast win that improves spec readability before further amendments.

**Option D — Single-page test migration under the new rules.** Pick one small page (Home is the canonical "minimal page" candidate) and run it through the migration end-to-end under the amended rules, before applying the rename pass platform-wide. Surfaces unexpected gaps on a small surface area.

Dirk's preference will determine sequencing. The recommendation here is a layered approach: do enough of B (populator updates) and C (cleanup) to make the implementation phase smooth, then start A (the rename pass) with confidence that the tooling validates correctly.

### 6.2 Starting points for next session

- `CC_Session_Summary_3.md` (this document) — what was decided and where the spec amendments landed
- The four amended specs (`CC_HTML_Spec.md`, `CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_PS_Spec.md`) — current authority on conventions
- `CC_Migration_Phase1.md` §11 — backlog with the resolved items still listed (update pending)
- The four populators (`Populate-AssetRegistry-*.ps1`) and `xFACts-AssetRegistryFunctions.ps1` — what needs to be updated for the new rules
- `cc-shared.css` and `cc-shared.js` — the rename targets for the implementation phase

All available via Project Knowledge (GitHub sync) without manifest URLs.

### 6.3 Workflow note

The mid-session sync workflow is now confirmed: push to GitHub, manually trigger Sync to GitHub from Project Knowledge, then continue. This is the reliable path for getting updated content into Claude's context mid-session. The manifest URL workflow remains useful for files not in Project Knowledge.

---

## 7. Notes for consolidation

When this summary's content is consolidated into `System_Metadata` or longer-term documentation:

- The four locked §11.2 decisions stay as permanent platform history — they're durable spec rules now, not session ephemera.
- The PS spec deviation rationale (PowerShell ecosystem conventions vs. unified prefix model) belongs in `xFACts_Development_Guidelines.md` as a cross-language design principle worth preserving.
- The migration-completeness query patterns from §2.4 belong in either `CC_Migration_Phase1.md` or a successor doc — they're useful operationally beyond this session.
- The mid-session Sync workflow belongs in session-start documentation or `xFACts_Development_Guidelines.md` workflow notes.
- The prefix/base_name catalog column thought experiment stays archived here, not promoted to active backlog. If post-migration operations confirm the need, it can be re-examined then.
- This document itself gets deleted once consolidation is complete, per the precedent from CC_Session_Summary_2.
