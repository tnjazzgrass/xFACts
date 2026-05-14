# xFACts Asset_Registry — Component Type Consolidation Plan

## Status

**Planning** — execution scheduled as the first action item of the session
following completion of the PS populator. Precedes resumption of HTML
populator development.

## Purpose

The Asset_Registry catalog's `component_type` vocabulary has grown
organically across four populator implementations (CSS, JS, HTML, PS).
This growth has introduced redundancy: file-type prefixes on component
types that are emitted from only one file type duplicate the
`file_type` column, and forbidden-pattern violations have been encoded
as component types rather than as drift codes on the underlying
artifact type. The CK constraint on `component_type` currently admits
59 values; a substantial fraction of these can be consolidated without
loss of expressiveness.

This document captures the principles, mappings, and execution sequence
for consolidating the vocabulary. The goal is a smaller, more
consistent catalog taxonomy that scales cleanly as new file types are
added.

## Principles

Three columns in `dbo.Asset_Registry` carry artifact identity. Each
has its own role; they should not duplicate each other.

**`file_type`** discriminates *what language the artifact lives in* (CSS,
HTML, JS, PS, Config). One row, one file_type. Already a column;
should not be re-encoded as a prefix on component_type.

**`component_type`** describes *what category of artifact this row
represents* (a function, a constant, a section banner, a route). Should
be universal across file_types wherever the artifact's semantics are
homogeneous. Should carry a file-type prefix only when the component
represents a *target artifact type* that is referenced from multiple
file types (e.g., `HTML_ID` referenced from CSS, JS, and HTML files).

**`variant_type`** sub-classifies *within a component_type* (a regular
function vs. a filter function, a constant vs. a constant array, a
section banner vs. a subsection banner). Already a column; underused
in the current schema. Should be the discrimination mechanism when an
artifact category has structurally similar sub-kinds that differ in
applicable rules.

**`drift_codes`** describes *what rules are being violated by this
specific row*. Forbidden patterns (Write-Host calls, inline dividers,
removed-code headstones, eval calls, document.write calls) should be
encoded as drift codes attached to the underlying artifact type, not
as separate component types of their own.

## Litmus tests

When deciding whether two component_types should be folded together:

> "If I ran a query for all rows of component_type X across the whole
> catalog, would the results be a homogeneous set of artifacts that
> share parse logic, applicable rules, and downstream consumers?"

- Yes → fold them. The categorical name describes what the thing is;
  file_type discriminates which language it's in.
- No → keep distinct. The category itself is different.

When deciding whether a forbidden-pattern row should be its own
component_type or a drift code on a more general type:

> "Without the violation, what is this thing? A function call? A
> comment? A string literal?"

- Answer is a real artifact category → fold into that category and
  encode the violation as a drift code.
- Answer is "nothing useful without the violation context" → it may
  genuinely deserve its own component_type, but this case should be
  rare.

When deciding whether to use a new component_type vs. a new
variant_type:

> "Does this differ from the existing category in structure, parse
> logic, or what rules apply? Or is it a sub-kind that shares those
> things with a small variation?"

- Structurally different → new component_type
- Sub-kind with rule variation → new variant_type within the existing
  component_type

## Consolidation mappings

### Universal types (drop file-type prefix)

These artifacts are semantically the same across file_types and should
have a single, universal component_type. The `file_type` column
discriminates which language the row's artifact lives in.

| New name              | Replaces                                                  | Notes                              |
|-----------------------|-----------------------------------------------------------|------------------------------------|
| `FILE_HEADER`         | already universal                                         | Keep as-is                         |
| `COMMENT_BANNER`      | already universal                                         | Keep as-is                         |
| `LINE_COMMENT`        | `JS_LINE_COMMENT`, `PS_INLINE_BANNER`, `PS_REMOVED_CODE_COMMENT` | Violations become drift codes |
| `BLOCK_COMMENT`       | `PS_COMMENT_BLOCK`                                        | Free-standing block comments       |
| `DOCBLOCK`            | `PS_DOCBLOCK`                                             | Function-attached doc comment      |
| `FUNCTION`            | `JS_FUNCTION`, `PS_FUNCTION`                              | Top-level named function           |
| `FUNCTION_VARIANT`    | `JS_FUNCTION_VARIANT`, future `PS_FUNCTION_VARIANT`       | Filters, arrow functions, etc.     |
| `FUNCTION_CALL`       | `PS_FUNCTION_CALL`; absorbs `PS_WRITE_HOST`               | Forbidden calls become drift codes |
| `CONSTANT`            | `JS_CONSTANT`                                             |                                    |
| `CONSTANT_VARIANT`    | `JS_CONSTANT_VARIANT`                                     |                                    |
| `VARIABLE`            | `PS_VARIABLE`                                             |                                    |
| `PARAMETER`           | `PS_PARAMETER`                                            |                                    |
| `IMPORT`              | `JS_IMPORT`, `MODULE_IMPORT`                              | Single concept across languages    |
| `EXPORT`              | `PS_EXPORT`                                               |                                    |
| `ROUTE`               | `PS_ROUTE`                                                |                                    |
| `MIDDLEWARE`          | `PS_MIDDLEWARE`                                           |                                    |
| `WEBSOCKET_ROUTE`     | `PS_WEBSOCKET_ROUTE`                                      |                                    |
| `CHANGELOG`           | `PS_CHANGELOG`                                            |                                    |
| `STATE`               | `JS_STATE`                                                |                                    |
| `HOOK`                | `JS_HOOK`                                                 |                                    |
| `HOOK_VARIANT`        | `JS_HOOK_VARIANT`                                         |                                    |
| `EVENT`               | `JS_EVENT`                                                |                                    |
| `TIMER`               | `JS_TIMER`                                                |                                    |
| `METHOD`              | `JS_METHOD`                                               |                                    |
| `METHOD_VARIANT`      | `JS_METHOD_VARIANT`                                       |                                    |
| `IIFE`                | `JS_IIFE`                                                 | Keep specific - it's a real pattern |
| `WINDOW_ASSIGNMENT`   | `JS_WINDOW_ASSIGNMENT`                                    |                                    |
| `CLASS`               | `JS_CLASS`                                                |                                    |

Note: `FILE` was originally proposed for inclusion here but has been
moved to the cross-file types section. The `*_FILE` types are emitted
in two roles -- as the anchor row for the file being scanned (where
file_type matches the prefix) and as USAGE rows referencing external
files (where file_type is the *referring* language and the prefix
identifies the *referenced* language). Because of this dual role, the
prefix carries information that file_type alone cannot. They are
treated the same way as `CSS_CLASS` and `HTML_ID` -- cross-file
reference types.

### Cross-file types (keep prefix)

These component_types describe a *target artifact type* that is
referenced from multiple file types. The prefix tells you what kind
of artifact the row points at, not what file_type the row lives in.
Keep all of these unchanged.

- `CSS_CLASS` — referenced from CSS, JS, HTML
- `CSS_FILE` — anchor row in CSS files; USAGE reference from HTML `<link>` tags
- `HTML_ID` — referenced from CSS, JS, HTML
- `HTML_FILE` — anchor row in HTML files; may be USAGE reference from
  other HTML files (page navigation) or from PS files (route handlers
  serving HTML)
- `HTML_DATA_ATTRIBUTE` — referenced from JS, HTML
- `HTML_EVENT_HANDLER` — referenced from HTML
- `HTML_COMMENT`, `HTML_SVG`, `HTML_TEXT`, `HTML_ENTITY` — HTML-specific structural
- `JS_FILE` — anchor row in JS files; USAGE reference from HTML `<script>` tags
- `PS_FILE` — anchor row in PS files; no current cross-file references
  but the prefix is kept for consistency with the other `*_FILE` types
  and to leave room for future cross-references (e.g., a PS file
  referencing another PS file via dot-source might warrant a USAGE row)

### File-type-specific structural types (keep prefix)

These component_types describe artifacts that exist only in one file
type and have file-type-specific structure that doesn't generalize.
Keep all of these unchanged.

- `CSS_RULE`, `CSS_KEYFRAME`, `CSS_VARIABLE`, `CSS_VARIANT`

### Universal cross-language reference types (already correct)

- `SQL_QUERY`
- `GLOBALCONFIG_REF`
- `RBAC_CHECK`

### Forbidden patterns becoming drift codes

These component_types encode rule violations into the type name. They
should be folded into the underlying artifact's component_type, with
the violation expressed as a drift code on the row.

| Currently               | Becomes                                          | Drift code on the row            |
|-------------------------|--------------------------------------------------|----------------------------------|
| `PS_WRITE_HOST`         | `FUNCTION_CALL` (with command name 'Write-Host') | `FORBIDDEN_WRITE_HOST`           |
| `PS_INLINE_BANNER`      | `LINE_COMMENT`                                   | `FORBIDDEN_INLINE_DIVIDER`       |
| `PS_REMOVED_CODE_COMMENT` | `LINE_COMMENT`                                 | `FORBIDDEN_REMOVED_CODE_COMMENT` |
| `JS_EVAL`               | `FUNCTION_CALL` (with command name 'eval')       | `FORBIDDEN_EVAL`                 |
| `JS_DOCUMENT_WRITE`     | `FUNCTION_CALL`                                  | `FORBIDDEN_DOCUMENT_WRITE`       |
| `JS_INLINE_SCRIPT`      | (review during pass — likely a HTML row context) | `FORBIDDEN_INLINE_SCRIPT`        |
| `JS_INLINE_STYLE`       | (review during pass — likely a HTML row context) | `FORBIDDEN_INLINE_STYLE`         |
| `JS_INLINE_EVENT`       | (review during pass — likely a HTML row context) | `FORBIDDEN_INLINE_EVENT`         |

The JS_INLINE_* triplet needs review during the consolidation session
to determine whether they catalog HTML inline patterns or JS-side
patterns, and what the cleanest landing place is for them.

## Estimated post-consolidation CK constraint size

Pre-consolidation: 59 admitted values
Post-consolidation: approximately 35-40 admitted values

The exact final count will be determined during the session as the
mappings are reviewed and edge cases resolved.

## Execution sequence

1. **Review and finalize mappings.** Re-read this document at session
   start; resolve any open questions (especially around JS_INLINE_*
   triplet and any cross-file types not yet identified).

2. **Draft the spec updates.** All four spec documents
   (`CC_CSS_Spec.md`, `CC_JS_Spec.md`, `CC_HTML_Spec.md`,
   `CC_PS_Spec.md`) need the new component_type vocabulary documented
   and any deprecated names removed.

3. **Draft the CK constraint ALTER.** Single ALTER that DROPs the
   constraint and re-creates it with the new admitted value list.
   Validate value count and review for any missed entries.

4. **Update populators in order**: CSS, JS, PS, HTML (in-flight).
   Each populator's row emitters and DriftDescriptions table need
   updating to emit the new names. Helper functions in
   `xFACts-AssetRegistryFunctions.ps1` that reference component types
   by name (e.g. validation gates) also need updating.

5. **Wipe and re-populate.** Truncate Asset_Registry, re-run all four
   populators. Verify row counts are sensible and no orphaned
   component_type values remain.

6. **Spot-check the catalog.** Run sanity queries to verify the
   consolidation worked as expected:
   - Count of rows by component_type — should match approximate
     pre-consolidation counts after folding
   - Drift code distribution — should reflect new drift codes for
     formerly-forbidden component types
   - Cross-file reference rows — should be unchanged

7. **Resume HTML build** against the cleaned-up taxonomy.

## Open questions to resolve at session start

- **`JS_INLINE_*` triplet**: Where do these rows live? In JS files
  parsing HTML strings, in HTML files cataloging inline content, or
  both? Determines the right consolidation target.

- **PSD1 / Config files**: Currently `server.psd1` is cataloged as a
  PS_FILE row (will stay as PS_FILE per the *_FILE keep-prefix rule).
  Should there be a separate `CONFIG_FILE` component_type, or does
  PS_FILE remain appropriate? The `file_type` column already
  discriminates ('PS' for .psm1/.ps1, 'Config' for .psd1), so PS_FILE
  with file_type='Config' is probably sufficient. Confirm at session
  start.

- **Subkind discrimination via variant_type**: Are there current
  component_types where we should be using variant_type instead of a
  separate component_type? Worth reviewing each
  `_VARIANT`-suffixed type to confirm the variant_type column is
  being populated and the discrimination is consistent.

## Reference: design rationale for future readers

This consolidation is not just cleanup; it establishes a pattern for
how the catalog grows. As new file types are added (Python, SQL, R,
Markdown, configuration languages), the goal is that they fit into
the existing component_type vocabulary by setting their `file_type`
column appropriately. New component_types should only be introduced
when a genuinely new category of artifact appears — not when the same
conceptual artifact appears in a new language.

Similarly, when new file-format rules are introduced via the spec,
they should generally land as new drift codes attached to existing
component_types, not as new component_types in their own right. The
drift code vocabulary is allowed to grow freely; the component_type
vocabulary should grow slowly and deliberately.
