# CC Session Summary 19 — PS Populator Spec Conformance + Role-Model Refinement

## Session focus

Starting the four-populator spec-compliance pass (per Session 18's plan), beginning with `Populate-AssetRegistry-PS.ps1`. Three threads, in order:

1. Landing the two spec amendments Session 18 identified (the §4.2 ordering swap and §5.1 chrome-prefix removal), plus a third that surfaced (§9.2 preference-variable clarification).
2. Bringing `Populate-AssetRegistry-PS.ps1` into full structural conformance with `CC_PS_Spec.md`.
3. A role-model refinement to §8 and §9 — restructuring function and declaration rules to be role-aware — that emerged from drift the conformant file produced.

Net result: the PS populator is spec-conformant down to two cross-cutting drift items that cannot be resolved in this file alone (both belong to the next file). Five spec amendments landed. The spec is now meaningfully better calibrated for the `standalone` role.

---

## Spec amendments landed this session

All applied by Dirk to `CC_PS_Spec.md` during the session.

### 1. §4.2 type ordering swap (Session 18 Defect 1)

`PARAMETERS` now precedes `IMPORTS` in the canonical order: `CHANGELOG, PARAMETERS, IMPORTS, INITIALIZATION, CONSTANTS, VARIABLES, FUNCTIONS, EXECUTION/ROUTE, EXPORTS`. Applied in three places for consistency: the §4.2 rule sentence, the §4 section-types table, and the §4.1 allowed-types-per-role table. Resolves PowerShell's requirement that `param()` be the first executable statement.

### 2. §5.1 chrome-prefix removal (Session 18 Defect 2)

The literal `cc` chrome-prefix form was removed from §5.1 entirely (unreachable — `Component_Registry.cc_prefix` requires exactly three lowercase letters, so `cc` can never appear). The §17 `MALFORMED_PREFIX_VALUE` description was trimmed to drop `cc`. Valid PS prefix forms are now exactly two: the registered page prefix, or `(none)`.

Note: the actual `cc`-acceptance enforcement lives in `Test-PrefixValueIsValid` in `xFACts-AssetRegistryFunctions.ps1`, NOT in the PS populator. The populator only carried `cc` in descriptive text (fixed). The enforcement removal is deferred to the AssetRegistryFunctions work (next session).

### 3. §9.2 preference-variable clarification

Added one line: setting a PowerShell preference variable (e.g., `$ErrorActionPreference`) at file scope is treated as a constant declaration and belongs in a CONSTANTS section; distinct from assignment to an automatic variable, which is forbidden. Resolves the ambiguity Session 18 hit with the resolver (and this populator).

### 4. §8 restructure — role-aware function rules

§8 was restructured from a single flat rule list into General + role-specific subsections, with a section preamble stating the assembly contract ("complete rule set = General + the one role subsection matching the file"). The split:

- **§8.1 General** (all roles with functions): `param()` block required even if empty; Verb-Noun naming with approved verb; prefix rules; no nested/conditional/filter functions; no cross-file name collision/duplication; calls resolve to a cataloged file; `[OutputType()]` optional; "every function is documented — form depends on role."
- **§8.2 page-route/api-route**: functions forbidden.
- **§8.3 shared-library/module**: `[CmdletBinding()]` mandatory (first in body); full comment-based-help docblock mandatory in canonical position (after CmdletBinding/param); `.SYNOPSIS`/`.DESCRIPTION` required, `.PARAMETER` 1:1 in order, other keywords forbidden. The canonical-form code block lives here.
- **§8.4 standalone**: `[CmdletBinding()]` permitted but not required; single-line `#` purpose comment required directly above the declaration (stating what the docblock's `.SYNOPSIS` would convey); comment-based-help docblock NOT used (a docblock in a standalone file is drift).

**Rationale (captured here, not in spec — appendix was eliminated in Session 6):** the docblock requirement was originally uniformity-driven and calibrated for route files, where functions are forbidden so the rule touches nothing. Standalone tool-scripts (the four populators) have dozens of internal helpers never consumed via `Get-Help`, so full comment-based-help is ceremony without payoff there; a single purpose comment delivers the only real benefit (the catalog's `purpose_description`). `param()` stays required for standalone because the block form is genuinely more readable than inline for multi-parameter functions (e.g., `New-PSRow` has 17 parameters). `[CmdletBinding()]` is permitted-but-not-required (not forbidden) because it occasionally has real functional use (e.g., `ShouldProcess`); its only dangerous misuse — CmdletBinding with inline params — is already caught by the retained `param()`-block requirement.

### 5. §9 restructure — role-aware declaration rules

§9 given the same General + role-specific treatment with the same preamble:

- **§9.1** declaration form ($script: lowercase).
- **§9.2 General**: $script: only; no $global:; no automatic-variable assignment; no chained assignment; purpose comment per declaration; prefix naming. Two single-home rules replacing the old "CONSTANTS or VARIABLES" wording: a constant (assigned once, not reassigned) lives in CONSTANTS; a mutable variable (reassigned/accumulated) lives in VARIABLES.
- **§9.3 standalone**: a top-level assignment that performs work as the script runs lives in the EXECUTION section — it is part of execution, not a file-scope declaration. (Replaces the old blanket "any assignment outside CONSTANTS/VARIABLES is misplaced," which mis-fired on the populator's EXECUTION working variables.)

### 6. Two new drift codes (§17)

Added to support §8.4 enforcement:

- `FORBIDDEN_DOCBLOCK_IN_STANDALONE` — a function in a standalone file has a comment-based-help docblock. → §8.4
- `MISSING_FUNCTION_PURPOSE_COMMENT` — a function in a standalone file has no single-line `#` purpose comment directly above its declaration. → §8.4

(`MISSING_FUNCTION_PURPOSE_COMMENT` deliberately distinct from the existing `MISSING_PURPOSE_COMMENT`, which governs constant/variable declarations.)

---

## Populator work — `Populate-AssetRegistry-PS.ps1`

**Delivery**: full file replacement (cumulative working copy in outputs). ~3,999 lines.

### Structural conformance (the main rebuild)

Converted the file from its pre-spec form to spec-conformant standalone structure:

- All ~21 `# ====` line-comment section banners → spec `<# ... #>` block banners (76-equals / 76-dashes / 3-space-indent / description / `Prefix: (none)` — Tools.Utilities has `cc_prefix = NULL`).
- Sections reordered to the amended canonical order: CHANGELOG → PARAMETERS → IMPORTS → INITIALIZATION → CONSTANTS (×4) → VARIABLES → FUNCTIONS (×8) → EXECUTION.
- The 9 former `EXECUTION: *` banners collapsed into ONE `EXECUTION: SCRIPT EXECUTION` (singleton per §4.4), with the 9 phases as `# -- <Label> --` sub-section markers.
- `CONFIGURATION` (not a valid TYPE) → `CONSTANTS`; `DOT-SOURCE SHARED INFRASTRUCTURE` → `IMPORTS`.
- `$ErrorActionPreference` moved into a CONSTANTS section; `Initialize-XFActsScript` into INITIALIZATION.
- VARIABLES trailing comments → leading purpose comments, grouped.
- A CHANGELOG section added, seeded with a single 2026-05-29 entry. (The 4-5 historical entries that should exist were never captured; not fabricated. History starts today by necessity — back-add by hand if recovered.)
- Header `.NOTES` rebuilt with File Name / Location / un-numbered FILE ORGANIZATION list matching the banners verbatim.
- Comment trim pass (middle-ground): cut spec references, downstream-mechanics narration, system-evolution prose, and examples the adjacent code already shows. **See open item — this pass was too conservative and needs a second pass.**

### Two logic fixes baked into the rebuild

- `$SectionTypeOrder` hashtable swapped to `PARAMETERS = 2, IMPORTS = 3` (clears the resolver's `SECTION_TYPE_ORDER_VIOLATION`).
- `MALFORMED_PREFIX_VALUE` drift-description text and surrounding comments updated to drop `cc`.

### Output format (binary-presentation fix)

Per Dirk: these files must be **no BOM, pure ASCII, CRLF, no trailing newline** to avoid GitHub presenting them as binary / web_fetch issues. The original had a BOM and one em dash (U+2014). The rebuild strips the BOM, normalizes the em dash to ` - `, and the build asserts zero bytes > 0x7F. This rule applies to all populator deliveries going forward.

### Role-aware populator changes (implementing §8/§9 amendments)

After the spec amendments, made the populator's own checks role-aware so it enforces the new rules:

- **`Add-PSFunctionRow`**: docblock/CmdletBinding logic branches on role. shared-library/module unchanged (docblock position drift + `MISSING_CMDLETBINDING`). standalone: fires `FORBIDDEN_DOCBLOCK_IN_STANDALONE` if a docblock is present, `MISSING_FUNCTION_PURPOSE_COMMENT` if no leading comment, suppresses `MISSING_CMDLETBINDING`. Docblock-content validation (MISSING_SYNOPSIS etc.) scoped to non-standalone so a stray standalone docblock gets the single clean flag.
- **`Add-PSAssignmentRow`**: standalone EXECUTION-section assignments no longer fire `WRONG_DECLARATION_SECTION`/`MISPLACED_DECLARATION` (§9.3), and consistently no longer require a purpose comment (they're execution statements, not declarations).
- Two new `$DriftDescriptions` entries added so the populator may emit the new codes.

### Verification method

Every delivery verified by extracting code-only lines (excluding comments/banners/blanks) and diffing against the prior version to prove logic byte-identical except intended changes. Final structural rebuild proved 2,659 code lines unchanged except the four intended edits. Format asserted each time.

---

## Final drift state for this file

Two empirical populator runs drove the cleanup. Starting drift (~95 rows) reduced to **7 rows in two buckets, both unresolvable in this file alone**:

### Deferred — belong to the next file

- **2 × `DUPLICATE_FUNCTION_DEFINITION`**: `Invoke-PSParse` (also in `Populate-AssetRegistry-HTML.ps1`) and `Format-SingleLine` (also in `Populate-AssetRegistry-CSS.ps1`). These are copy-pasted-or-same-named helpers across the four populators. Fix = centralize into `xFACts-AssetRegistryFunctions.ps1` and delete local copies — but ONLY after reading the CSS/HTML populators and diffing the bodies to confirm they are truly identical vs. merely same-named. `Invoke-PSParse` appearing in the HTML populator is suspicious and warrants scrutiny.
- **5 × `FORBIDDEN_WRITE_HOST`**: the populator's per-file console progress (`Parsing X... ok`, `Walking X...`, `-> N rows`) at lines ~2820, 2823, 2826, 2944, 3788. The file already uses `Write-Log` for phase-level milestones (those land in the PS log correctly); `Write-Host` carries only per-file console detail. Disposition deferred until `Write-Log` in `xFACts-OrchestratorFunctions.ps1` is read. Three options on the table: (a) convert to `Write-Log` — adds ~250 per-file lines to the log, loses console color/inline; (b) exempt this file in §15.1; (c) relax the §15.1 ban platform-wide (likely means dropping the check, since a "cosmetic-only" Write-Host rule isn't machine-enforceable). Leaning (a) convert, to keep the platform-wide enforcement intact. NOT to be left as permanent drift.

### Fixed this session (Bucket 1)

Four declarations were missing per-declaration purpose comments (caused by one comment shared above a *pair* of declarations): `$IdentifierFreeSectionTypes`, `$DriftDescriptions`, `$script:dedupeKeys`, `$script:sharedSourceFile`. Each given its own leading comment.

---

## Open items / next session

### Primary: `xFACts-AssetRegistryFunctions.ps1` (shared-library file)

This is the next file, and three threads converge on it:

1. Its own work: `Test-PrefixValueIsValid` `cc`-removal (the deferred §5.1 enforcement fix — this is where `cc` acceptance actually lives, shared by all four populators), plus structural spec-alignment and comment trim.
2. Resolves PS Bucket 3: centralize `Invoke-PSParse` / `Format-SingleLine` (and any other duplicated populator helpers) here, then delete local copies from the populators.
3. Resolves PS Bucket 2: reading `Write-Log` (in `xFACts-OrchestratorFunctions.ps1`, dot-sourced alongside) settles the Write-Host disposition.

Note: when structurally aligning this file, the `Test-PrefixValueIsValid` cc-fix (done first) must be preserved by the later structural rewrite — cumulative state.

### Second comment-trim pass on `Populate-AssetRegistry-PS.ps1`

The Session 19 comment trim was deliberately conservative and left blocks that are still too long. Example: the ~30-line comment above `Get-PSFunctionDocblock` narrating the 5-step detection algorithm and the full return-shape contract — the code states this more precisely than the prose. **Standard for the next pass: "what is this and why" in ≤2-3 lines. Cut (a) algorithm walkthroughs, (b) return-shape field narration, (c) anything the adjacent code states precisely. Keep only genuine "PowerShell/AST does a surprising thing here" notes (the rare exception).** This applies to all four populators, not just PS.

### The remaining three populators

`Populate-AssetRegistry-CSS.ps1`, `-HTML.ps1`, `-JS.ps1` — same structural-conformance + comment-trim pass, now against a spec that's properly role-aware. All are standalone-role, so the §8.4/§9.3 standalone rules apply to all three. The CSS/HTML reads also feed the Bucket 3 dedup investigation.

### Carryforward from Session 18 (still open)

- CDN → local `chart.js` swap in `PlatformMonitoring.ps1` and `ServerHealth.ps1` (clears the last 2 `HTML_JS_FILE_UNRESOLVED`). Rides along on the next refactor of those pages.
- End-to-end resolver validation run (the rewritten `Resolve-AssetRegistryReferences.ps1` wasn't yet validated as a complete orchestrator).

---

## Standing rules reaffirmed / lessons from this session

- **Read the actual file before amending it — do not reconstruct from memory.** Mid-session, drafted §8/§9 amendments from a *reconstruction* of those sections (assembled from the drift table and general knowledge) rather than the real spec text. The reconstruction silently dropped real General rules (`SHADOWS_SHARED_FUNCTION`, `DUPLICATE_FUNCTION_DEFINITION`, `ORPHAN_FUNCTION_CALL`, `FORBIDDEN_CONDITIONAL_DEFINITION`) and invented structure that wasn't there. Caught by Dirk. Corrected by fetching and reading the real §8/§9 in full. This is the same "never speculate about file contents" rule — it applies to spec sections too, not just code.
- **Rules are gospel and checkable; rationale and drift codes do not belong in rule text.** Repeatedly drifted toward putting drift-code references and "rationale:" lines into draft rule text. The Session 6 rewrite removed exactly that bloat. Rules state what is true, in the fewest words that stay unambiguous. The drift table maps violations to codes. Rationale (with the appendix gone) lives in session summaries, not the spec.
- **No hedges in rules — "or", "exempt", "permitted... when necessary" are wiggle.** A rule says where a thing *goes*, definitively. "CONSTANTS or VARIABLES" → two single-home rules. "Exempt from the placement rule" → "lives in the EXECUTION section." Each kind of thing has exactly one home, stated flat.
- **Prefer principled spec refinement over file-bending — but only when the role model genuinely warrants it.** The §8/§9 role split wasn't bending the spec to dodge work; it corrected a real mis-calibration (rules priced for route files, applied to standalone tool-scripts). The tell that it was principled: it helps all four populators (all standalone), and the populator already had `$CurrentFileRole` in scope, so enforcement was natural, not forced.
- **The populator running against itself is the real test.** Every claim of conformance was validated by an actual catalog run, not by reasoning. Two runs this session; each surfaced real, specific drift that reasoning alone would have missed or mis-estimated.
- **Output format for populators: no BOM, pure ASCII, CRLF, no trailing newline** — to keep GitHub presenting them as text and avoid web_fetch binary-detection issues. Asserted at build.
- **Comment-trim conservatism has a cost too.** Under-trimming to avoid cutting something load-bearing left genuine bloat (the 30-line algorithm narration). The standard is ≤2-3 lines; the only protected exception is non-obvious language/AST behavior, not procedure or contract narration.

---

## Files delivered this session

Working copy (cumulative state) in `/mnt/user-data/outputs/`:

- `Populate-AssetRegistry-PS.ps1` — full spec-conformant rebuild + two logic fixes + role-aware checks + Bucket 1 purpose-comment fixes. ~3,999 lines. No BOM, ASCII, CRLF.

Spec amendments (§4.2, §5.1, §9.2, §8 restructure, §9 restructure, two §17 drift codes) applied by Dirk to `CC_PS_Spec.md` inline during the session.
