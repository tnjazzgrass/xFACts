# Control Center PowerShell Module File Format Specification

*This spec is not yet drafted. The Pre-design observations below capture what the original retired Spec doc said about PS module conventions plus review notes flagging what needs to be reconsidered against the principles established during CSS and JS spec design (typed sections, three-character page prefixes, variants-as-rows catalog model, drift codes). When the design session for this spec lands, observation content moves into rule sections, with whatever revisions emerge.*

This specification will define the structural conventions every Control Center PowerShell module file must follow. Module files are `*.psm1` files that define PowerShell functions exported for use by route files and other modules — primarily `xFACts-Helpers.psm1` at the time of writing. The conventions exist for one reason: machine readability. Every rule will be justified by a specific extraction the catalog parser performs against the file.

---

## Pre-design observations

Harvested from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026). Each observation carries review notes flagging items the design session needs to evaluate. **None of the content below is authoritative.** When the design session lands, content moves out of this section into the appropriate rule sections, with whatever revisions emerge. This section gets deleted when it is empty.

### Observation 1 — Module files vs route files

The retired Spec doc identified module files as one of two flavors of PowerShell files in the codebase:

- **Type 1 — Route files** (page route + API route files). Covered in `CC_PS_Route_Spec.md`.
- **Type 2 — Module files** (helpers, e.g., `xFACts-Helpers.psm1`). Define PowerShell functions. Use `Export-ModuleMember` at the bottom. Parser extracts `PS_FUNCTION` rows.

This document covers Type 2. The structural rules (file header, section banners, sub-section markers) are largely identical to route files; this doc duplicates the rules rather than cross-referencing.

**Review notes:**

- The retired Spec doc deferred `xFACts-Helpers.psm1` reformatting to a separate post-chrome effort. Whether this spec applies to `xFACts-Helpers.psm1` immediately on finalization, or whether that file gets a delayed conversion, is a design session decision.

### Observation 2 — File header structure

The retired Spec doc proposed this PS1 file header template (same as route files):

```powershell
# ============================================================================
# xFACts Control Center - <Component Description> (<filename>)
# Location: E:\xFACts-ControlCenter\scripts\<full-path>
# Version: Tracked in dbo.System_Metadata (component: <Component>)
#
# <Purpose paragraph>
#
# CHANGELOG
# ---------
# YYYY-MM-DD  <Description>
# ============================================================================
```

**Review notes:**

- The CHANGELOG block needs to be reconsidered. The CSS and JS specs adopted "git is the source of truth for change history" and forbid CHANGELOG blocks. The same logic likely applies to PS module files, but the design session should make this an explicit decision.
- Module files might benefit from a FILE ORGANIZATION list listing the major function groupings — modules with many exported functions can be hard to navigate without one.

### Observation 3 — Required structure

The retired Spec doc proposed this top-level structure for module files:

```
File header block
[blank line]
Section banner: 1. <First section>
[content]
...
Section banner: N. <Last section>
[content]
[end of file]
```

For module files, the final section was conventionally `EXPORT` and contained the `Export-ModuleMember` call.

**Review notes:**

- The conventional final section pattern is reasonable. Whether `EXPORT` is mandated by name (analogous to JS's mandatory `STATE`, `PAGE LIFECYCLE HOOKS` sections) or just conventional is a design question.
- The CSS and JS specs adopted typed sections. For module files, possible candidates: `IMPORTS`, `INTERNAL HELPERS`, `EXPORTED FUNCTIONS`, `EXPORT`. The design session should evaluate against actual module files (primarily `xFACts-Helpers.psm1`) to see what natural groupings exist.

### Observation 4 — Section banner format

The retired Spec doc proposed this PS1 section banner template (same as route files):

```powershell
# ============================================================================
# N. <SECTION TITLE IN CAPS>
# ----------------------------------------------------------------------------
# <Free-form description, one or more lines, explaining the section's
# purpose and any cross-references.>
# ============================================================================
```

**Review notes:**

- Same considerations as PS route files. The CSS and JS specs use a 5-line `<TYPE>: <NAME>` format with a `Prefixes:` (CSS) or `Prefix:` (JS) declaration line. The design session should evaluate whether module files adopt the same shape.

### Observation 5 — Sub-section markers

The retired Spec doc proposed:

```powershell
# -- <Sub-section description> --
```

**Review notes:**

- Carries forward in principle. Same as the CSS spec's `/* -- label -- */` and JS spec's `/* -- label -- */` sub-section markers.

### Observation 6 — Function documentation

The retired Spec doc mandated that every top-level function declaration in a module file must have a comment-based help block:

```powershell
function Function-Name {
    <#
    .SYNOPSIS
        <One-line summary, mandatory>
    .DESCRIPTION
        <Optional longer description>
    .PARAMETER <name>
        <description>
    .RETURNS
        <description>
    .EXAMPLE
        <example usage>
    #>
    param( ... )
    ...
}
```

The parser uses:

- `.SYNOPSIS` content becomes `purpose_description`
- `param()` block becomes `signature`

Compliance violations proposed:

- Function with no comment-based help block
- Comment-based help block missing `.SYNOPSIS`

**Review notes:**

- The PowerShell comment-based help format is the platform-native convention and is the right starting point for module functions.
- Whether `.SYNOPSIS` alone is mandatory and the others optional, or whether a richer mandatory minimum makes sense, is a design question. The CSS and JS specs' purpose-comment requirements (one-sentence preceding comment) set a low bar; the PS module spec might choose a higher bar because PS functions take parameters and return values.
- Whether short utility functions can use a simpler format is worth deciding.

### Observation 7 — What the parser extracts from module files

The retired Spec doc proposed:

- **PS_FUNCTION** — every `function Verb-Noun { ... }` declaration. `component_name` = the function name. `signature` = extracted from `param()` block: `(Param1, Param2, ...)`. `purpose_description` = from `.SYNOPSIS`. `source_section` = section banner.

The parser also reads the `Export-ModuleMember -Function @( ... )` list and validates that every exported function exists in the file. Functions in the file but not in the export list are extracted with a flag indicating they're internal.

**Review notes:**

- The cross-validation between exported-functions list and actual function definitions is a nice tightening that catches a real class of error (forgotten exports, exports of nonexistent functions).
- The internal-vs-exported flag is consistent with the CSS and JS specs' scope concept (LOCAL vs SHARED). Whether to use the same `scope` column or a separate flag is a catalog model decision.

### Observation 8 — Internal functions and script-scope variables

The retired Spec doc proposed treatment for module files containing:

- `$script:VariableName = ...` declarations (script-scope variables) → become `PS_STATE` rows with `scope = LOCAL` (file-internal)
- `function Internal-Helper { ... }` declarations not exported → become `PS_FUNCTION` rows with a flag indicating internal-only

Compliance violations proposed:

- `$script:` variables outside any section
- Internal functions still subject to comment-based help requirement

**Review notes:**

- The treatment is consistent with the catalog model.
- The "internal functions still subject to comment-based help requirement" rule is sensible — internal-only doesn't mean undocumented.
- `PS_STATE` as a component_type matches the JS spec's similar concept (`JS_STATE`). Worth aligning the catalog vocabulary across PS and JS where the concepts are the same.

### Observation 9 — Component name extraction from Version line

The retired Spec doc identified that the `Version: Tracked in dbo.System_Metadata (component: <Component>)` line in the file header is the canonical source of the file's component name.

**Review notes:**

- Carries forward as a pattern. Same convention used in CSS and JS spec file headers.
