# Control Center PowerShell Module File Format Specification

**Status:** `[DRAFT — design session not yet held]`
**Owner:** Dirk

> Part of the Control Center File Format initiative. For initiative direction, current state, session log, and the platform-wide prefix registry, see `CC_Initiative.md`.

---

## Purpose

This specification will define the structural conventions every Control Center PowerShell module file must follow. Module files are `*.psm1` files that define PowerShell functions exported for use by route files and other modules — primarily `xFACts-Helpers.psm1` at the time of writing. The conventions exist for one reason: machine readability. Every rule will be justified by a specific extraction the catalog parser performs against the file.

**This document is currently in pre-design state.** The spec body sections below are stubs. The "Pre-design observations" section holds harvested content from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026) that predates the CSS-era principles established during the CSS spec design. The harvested content has not been validated against those principles. The PS module spec design session will review every harvested item, decide what survives, and draft the actual spec body.

---

## Pre-design observations

Harvested from the retired `CC_FileFormat_Spec.md` (v0.2, April 2026). Each observation carries review notes flagging items the design session needs to evaluate. **None of the content below is authoritative.** When the design session lands, content moves out of this section into the appropriate numbered sections, with whatever revisions emerge. This section gets deleted when it is empty.

### Observation 1 — Module files vs route files

The retired Spec doc identified module files as one of two flavors of PowerShell files in the codebase:

- **Type 1 — Route files** (page route + API route files). Covered in `CC_PS_Route_Spec.md`.
- **Type 2 — Module files** (helpers, e.g., `xFACts-Helpers.psm1`). Define PowerShell functions. Use `Export-ModuleMember` at the bottom. Parser extracts `PS_FUNCTION` rows.

This document covers Type 2. The structural rules (file header, section banners, sub-section markers) are largely identical to route files; this doc duplicates the rules rather than cross-referencing.

**Review notes:**

- The retired Spec doc deferred `xFACts-Helpers.psm1` reformatting to a separate post-chrome effort (Q2 in its open questions). Whether this spec applies to `xFACts-Helpers.psm1` immediately on finalization, or whether that file gets a delayed conversion, is a design session decision.

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

- The CHANGELOG block needs to be reconsidered. The CSS spec adopted "git is the source of truth for change history" and forbids CHANGELOG blocks. The same logic likely applies to PS module files, but the design session should make this an explicit decision.
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

- The conventional final section pattern is reasonable. Whether `EXPORT` is mandated by name (analogous to JS's mandatory `STATE`, `PAGE HOOKS` sections) or just conventional is a design question.
- The CSS spec adopted typed sections. For module files, possible candidates: `IMPORTS`, `INTERNAL HELPERS`, `EXPORTED FUNCTIONS`, `EXPORT`. The design session should evaluate against actual module files (primarily `xFACts-Helpers.psm1`) to see what natural groupings exist.

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

- Same considerations as PS route files. The CSS spec's 5-line `<TYPE>: <NAME>` format with `Prefixes:` declaration is an alternative the design session should evaluate.

### Observation 5 — Sub-section markers

The retired Spec doc proposed:

```powershell
# -- <Sub-section description> --
```

**Review notes:**

- Carries forward in principle. Same as the CSS spec's `/* -- label -- */` sub-section markers.

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
- Whether `.SYNOPSIS` alone is mandatory and the others optional, or whether a richer mandatory minimum makes sense, is a design question. The CSS spec's purpose-comment requirement (one-sentence preceding comment) sets a low bar; the PS module spec might choose a higher bar because PS functions take parameters and return values.
- Whether short utility functions can use a simpler format (analogous to JS's plain-block-comment alternative for short functions) is worth deciding.

### Observation 7 — What the parser extracts from module files

The retired Spec doc proposed:

- **PS_FUNCTION** — every `function Verb-Noun { ... }` declaration. `component_name` = the function name. `signature` = extracted from `param()` block: `(Param1, Param2, ...)`. `purpose_description` = from `.SYNOPSIS`. `source_section` = section banner.

The parser also reads the `Export-ModuleMember -Function @( ... )` list and validates that every exported function exists in the file. Functions in the file but not in the export list are extracted with a flag indicating they're internal.

**Review notes:**

- The cross-validation between exported-functions list and actual function definitions is a nice tightening that catches a real class of error (forgotten exports, exports of nonexistent functions).
- The internal-vs-exported flag is consistent with the CSS spec's scope concept (LOCAL vs SHARED). Whether to use the same `scope` column or a separate flag is a catalog model decision.

### Observation 8 — Internal functions and script-scope variables

The retired Spec doc proposed treatment for module files containing:

- `$script:VariableName = ...` declarations (script-scope variables) → become `PS_STATE` rows with `scope = LOCAL` (file-internal)
- `function Internal-Helper { ... }` declarations not exported → become `PS_FUNCTION` rows with a `notes` flag indicating internal-only

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

- Carries forward as a pattern. Same convention used in CSS spec's file header.

---

## 1. Required structure  *[stub]*

(To be defined during PS module spec design.)

---

## 2. File header  *[stub]*

(To be defined during PS module spec design.)

---

## 3. Section banners  *[stub]*

(To be defined during PS module spec design.)

---

## 4. Section types  *[stub]*

(To be defined during PS module spec design.)

---

## 5. Function definitions  *[stub]*

(To be defined during PS module spec design.)

---

## 6. Comment-based help requirements  *[stub]*

(To be defined during PS module spec design.)

---

## 7. Internal functions and script-scope variables  *[stub]*

(To be defined during PS module spec design.)

---

## 8. Module exports  *[stub]*

(To be defined during PS module spec design. Will cover the `Export-ModuleMember` requirement, the export-list-vs-function-definition cross-validation, and how the catalog distinguishes exported from internal functions.)

---

## 9. Comments  *[stub]*

(To be defined during PS module spec design.)

---

## 10. Required patterns summary  *[stub]*

(To be defined during PS module spec design.)

---

## 11. Forbidden patterns  *[stub]*

(To be defined during PS module spec design.)

---

## 12. Illustrative example  *[stub]*

(To be defined during PS module spec design.)

---

## 13. Catalog model essentials  *[stub]*

(To be defined during PS module spec design.)

---

## 14. What the parser extracts  *[stub]*

(To be defined during PS module spec design.)

---

## 15. Drift codes reference  *[stub]*

(To be defined during PS module spec design. PS-module-specific drift codes only.)

---

## 16. Compliance queries  *[stub]*

(To be defined during PS module spec design.)

---

## Revision history

| Version | Date | Description |
|---|---|---|
| 0.1 | 2026-05-04 | Initial scaffold. Pre-design observations harvested from the retired `CC_FileFormat_Spec.md` Part 4 (module portions) plus universal Section 1.1 / 1.2 PS portions, awaiting review during PS module spec design session. |
