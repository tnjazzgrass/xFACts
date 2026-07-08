# B-019 Comment Trim Guidelines

Working guideline for the B-019 comment-verbosity trim. Temporary; retire when the
four populators are done. Carries the calibration agreed during the session that
trimmed `Populate-AssetRegistry-CSS.ps1`, so the standard survives across sessions.

## Goal

Trim changelog entries and inline comments to only what's necessary. The four
asset-registry populators (CSS, JS, HTML, PS) are the heaviest offenders: their
comments grew into multi-paragraph rationale and how-it-works essays, adding
hundreds of removable lines per file. The rule is general and applies to any file
touched, but the populators are the priority.

## The core rule

**Keep exactly the facts a reader can't cheaply recover from the code. Drop
everything else.**

A comment earns its place only when it tells the reader something the adjacent
code does not show: a cross-reference (handled elsewhere), a non-obvious pairing,
or a non-derivable behavior. Anything that narrates what the next lines plainly do,
or why they're written that way, gets cut.

Detail may vary per entry (one line to a few). There is no fixed length. The test
is always recoverability, not line count.

## What to cut

- **Mechanism / how it works.** The code is the how. Cut "via a paren-depth walk
  that keeps nested stops interior," "the match loop collects every token rather
  than breaking on the first," etc.
- **Rationale / justification.** Why the code is structured a certain way is
  recoverable or belongs in the backlog. Cut "handling it here is what makes
  single- and multi-line rules behave identically."
- **Examples.** Cut every "e.g. `#4ade80` in a toggle-handle gradient." The code
  and data carry the examples.
- **Spec references.** Remove all of them, especially section numbers (the second
  half of B-019). Code always conforms to the spec or the populator catches it, so
  naming the spec is extra words. Section numbers also strand on spec renumbering.
- **Verification asides.** Cut "verified against the registry: all 13 rows were
  coincidental."
- **Forward-references** (B-NNN). Those live in the backlog.
- **Embedded dates inside a dated changelog entry.** Redundant by definition, and
  they trip the changelog matcher. Refer to a prior change by name, not date.
- **Invented vocabulary that nothing defines.** See the tier example below.

## What to keep

- A **cross-reference** the code doesn't reveal: ":root declarations are skipped
  (cataloged as CSS_VARIABLE definitions)" -- the local code shows the skip, not
  that the thing is captured elsewhere.
- A **non-obvious pairing**: "gradient color stops are cataloged but never drift" --
  without it, a `continue` looks like the literal is dropped entirely.
- A **non-derivable behavior**: "all matches are collected, so a value held by
  multiple same-purpose tokens surfaces as a list" -- not obvious from the loop.
- A **distinct behavioral fact** a summary would otherwise lose: "token-less
  literals emit non-drift inventory rows" -- a real behavior the shorter phrasing
  dropped.
- A **column/field mapping table** (which row column gets which value). Not
  derivable without tracing every assignment, so keep it even when it makes a
  comment longer.
- **Structural section dividers** like `# -- EMPTY_SECTION --` or `# -- Pass 3 --`.
  These are navigation, not prose -- they mark where each phase or check lives and
  a reader can't recover them from the code. Do NOT trim them. They are closer to
  mini-banners than to explanations; B-019 trims explanatory prose, not signposts.
  A prose comment sitting under such a divider still gets trimmed; the divider
  stays.

## Invented vocabulary

If comments lean on a term that nothing in the code or spec defines, the term is
usually fluff. Drop it and describe the behavior plainly rather than preserving
shorthand a reader can't decode.

Example from the CSS populator: "Tier-1 / Tier-2" was comment-only shorthand for
"a literal is either drift (a matching token exists) or inventory (none)." It was
dropped; comments now say drift-vs-inventory in plain terms. Caution: a real,
unrelated concept may share the word -- the CSS populator's `scope_tier` /
`ScopeTier` (the SHELL/page classification, a genuine Object_Registry column) was
left untouched. Check before cutting a term globally.

## Worked examples

From `Populate-AssetRegistry-CSS.ps1`.

### Changelog entry (~50 lines to ~4)

Before (excerpt): a single dated entry running ~85 lines, merging three distinct
changes plus orphaned fragments, with spec references, mechanism, examples, and
verification prose.

After:
```
# 2026-06-23  Three literal-matcher false-positive carve-outs: gradient color
#             stops, page-padding size tokens, and banner/glow color tokens no
#             longer fire literal drift on coincidental value matches. Matched
#             token names now recorded on match_reference.
```
Notes: the three real changes are named; the spec reference and examples are gone;
a buried adjacent-date entry that had been swallowed was recovered as its own line.

### Inline block: literal capture (13 lines to 3)

Before: 13 lines explaining the drift decision, the skip, and why per-occurrence
handling unifies single- and multi-line rules.

After:
```
# Literal capture: every color/size literal in a non-:root declaration
# becomes a CSS_LITERAL row. :root declarations are skipped (cataloged as
# CSS_VARIABLE definitions).
```
Kept: the :root cross-reference (captured elsewhere). Cut: the drift-decision
narration (the code below is that logic) and the per-occurrence rationale.

### Inline block: gradient carve-out (9 lines to 2)

After:
```
# Gradient color stops are cataloged (row above) but never drift;
# only the match is suppressed.
```
Kept: the cataloged-but-not-drift pairing. Cut: the spec reference, the
"because gradients are tokenized as whole values" rationale, and the
NULL-column detail (visible in code).

## Workflow

Comment trimming is a judgment pass. The approach that worked best on the CSS
populator was **driven, one block at a time, with eyes on each change** -- more
tedious than a mechanical sweep, but far more effective: every trim is reviewed,
and it caught the structural dividers before they were wrongly stripped.

Preferred method:

1. Assistant walks the file **sequentially, top to bottom**, and for each excessive
   comment presents the location, the proposed trim, and a one-line cut/keep
   reason. Dirk applies each edit to his own copy (so the before/after is judged
   directly in the editor) and says "next" to continue.
2. The **changelog** is trimmed first and reviewed as a before/after -- it's the
   highest-risk part (entries can be merged or orphaned and need reconstruction,
   not just trimming).
3. Anchor each candidate by **comment text + function context**, not just line
   number -- line numbers drift as edits are applied on one side but not the other.
4. Touch **comments only, never code.** Verify every changed line is a comment or
   blank. Confirm byte discipline (BOM-free, uniform line ending per convention).
5. Run the populator afterward to confirm the file's drift findings clear and no
   new drift was introduced.

## Progress

- **`Populate-AssetRegistry-CSS.ps1`** -- DONE. Changelog trimmed (164 to 35 lines,
  buried prior-date entry recovered) and all 45 inline comment blocks walked and
  trimmed. BOM stripped. File went 2,871 to 2,541 lines (comments only, no code
  touched). All three drift findings cleared; populator run clean. This is the
  validated template for the remaining three.
- **`Populate-AssetRegistry-JS.ps1`** -- not started.
- **`Populate-AssetRegistry-HTML.ps1`** -- not started (heaviest; ~1,000 removable
  comment lines).
- **`Populate-AssetRegistry-PS.ps1`** -- not started.
