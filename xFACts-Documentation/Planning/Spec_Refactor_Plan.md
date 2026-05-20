# Spec Audit and Refactor Plan

## Background

Over the course of multiple sessions building out the Control Center File Format Standardization work, the four spec documents (CC_HTML_Spec.md, CC_CSS_Spec.md, CC_JS_Spec.md, CC_PS_Spec.md) have grown substantially. They have come to serve two purposes simultaneously:

1. A developer-facing rulebook describing how to write conformant xFACts code.
2. An implementation reference for the populators that catalog and validate that code.

These two purposes have started to conflict. The rulebook role wants concise, prescriptive statements developers can read and apply. The implementation reference role wants detailed mechanism descriptions, rationale, edge case handling, and drift code catalogs.

The result is specs that are too verbose to serve effectively as rulebooks. A developer asking "how do I write an engine card?" must wade through implementation detail to find the rule. Worse, in some cases the spec has been amended over time to accommodate patterns that already existed in the code rather than to describe the cleanest architectural choice. Each accommodation was reasonable in isolation; cumulatively they have moved the spec away from "one clean way to do each thing" toward "a catalog of patterns the code currently uses."

This was not the original intent of the spec work.

## Original Intent

The spec was meant to define, for each construct in each language:

- **The single, clean, prescriptive way to do that thing.**
- A short rationale only where the rule isn't self-evident.
- Nothing else.

The path to compliance was always: lock down the spec, then rewrite every file to match it. The work is in the files, not in the populators or the specs. The populator enforces one rule per concern. The spec describes one way per concern. A developer reads the spec and writes the right code.

## What Went Wrong

Several patterns emerged that we now want to correct:

1. **The specs grew to include mechanism, rationale, and edge case detail** beyond what a developer needs to write conformant code. The audience drifted from "developer" to "implementor of the populator."

2. **In some cases, the spec was amended to accommodate existing patterns** rather than to describe the cleanest path. The §7.4 compound modifier exemption in CC_CSS_Spec.md is one example identified during the session that produced this document. There may be others.

3. **The populators have grown commensurately complex** because they enforce these accommodations rather than enforcing clean rules. The HTML populator alone is over 5,500 lines, with significant portions dedicated to special cases and carve-outs that exist only because the spec allows multiple forms of the same construct.

4. **Each individual decision was justified in its own context** but the cumulative effect was lost. No single amendment "broke" the project; collectively, however, they shifted its trajectory.

## The Refactor

This project replaces the four current specs with four new, much smaller specs. The new specs are written from scratch but inform themselves heavily from the existing specs and supporting documentation in the Planning folder.

### Guiding Principles

1. **The new specs target developers, not populator implementors.** A developer should be able to read a section and immediately know what is and isn't allowed. Implementation mechanics, populator drift codes, and internal data structures do not belong in the spec.

2. **One rule per concern. No alternatives, no carve-outs.** If two patterns exist in the codebase today and we must pick one for the spec, pick the cleaner one. The other gets retired through file rewrites.

3. **Existing patterns are not justification.** When evaluating each rule, the question "is this how the code does it today?" is irrelevant. The question is "is this the cleanest path for a developer AND for the populator?" If the answer leads away from current code, the code gets rewritten — which was always part of the plan.

4. **Format is prescriptive and brief.** Each rule follows the pattern: Section A — the rule itself, stated definitively. Section B — short rationale only where the rule's purpose isn't obvious. Nothing else. No examples spanning pages, no internal mechanism descriptions, no exhaustive drift code catalogs.

5. **The four specs share patterns where possible.** A developer who learns the HTML spec should find familiar shape in the CSS, JS, and PowerShell specs. Where a convention applies across languages (e.g., file headers, prefix rules, naming conventions), the rule is stated similarly in each.

6. **Files and populators follow similar patterns.** Beyond the specs themselves, files within each language and the populator scripts processing them should be structurally consistent for ease of maintenance. This is downstream of the spec refactor but should be considered as the new specs are written.

### What the New Specs Include

For each construct in each language:

- The single prescribed way to write that construct.
- A brief statement of where it's required, where it's permitted, where it's forbidden.
- A short rationale only where needed.

### What the New Specs Exclude

- Drift code catalogs. Drift codes live in the populator and its own documentation, not in the spec.
- Implementation mechanism. The spec says what the rule is; the populator implements how to check it. The two are decoupled.
- Historical context. "We used to do this another way and changed to this" is interesting but doesn't help a developer writing new code today.
- Exhaustive examples. One or two good examples per rule, not a catalog of every variant.
- Discussions of alternatives that were considered and rejected. The spec states the chosen path. The rejected paths don't appear.

## Process

The refactor happens in four phases, applied to each of the four specs in sequence.

### Phase 1 — Discovery

For one spec at a time, walk through the current document and extract the actual decisions that have been made. Each decision is recorded with:

- A short statement of what the decision is.
- A reference to where in the current spec it lives.
- Any supporting evidence from change logs, planning docs, or other Planning-folder material that explains how the decision came to be.

The output is a flat list of decisions for the spec. No verdicts yet — just the inventory.

### Phase 2 — Curation

For each decision in the inventory, three questions:

1. **Is this a clean architectural decision, or an accommodation of existing code?**
2. **If we kept it, can we state it in one or two sentences a developer can read and apply?**
3. **If we wouldn't keep it, what would we do instead?**

The output is the inventory with verdicts per decision: keep, simplify, or replace.

### Phase 3 — Synthesis

Write the new spec from the curated decision set. The new spec is short, prescriptive, and developer-facing. It follows the format conventions described above.

### Phase 4 — Migration

Update the populators, files, CSS, JS, and PowerShell code to match the new spec. This is the work that was always going to happen — every file gets rewritten as part of the platform refactor — but it now happens against a clear small spec.

## Reference Material

All current documents in the Planning folder serve as reference material during the audit. They include:

- **CC_HTML_Spec.md, CC_CSS_Spec.md, CC_JS_Spec.md, CC_PS_Spec.md** — the current specs being audited.
- **CC_Initiative.md** — the active initiative tracking doc, which documents recent decisions and open questions.
- **CC_Session_Summary_1.md through CC_Session_Summary_5.md** — historical session summaries that may contain the reasoning behind specific decisions.
- **CC_Catalog_Pipeline_Working_Doc.md** — working notes on the catalog pipeline.
- **CC_HTML_Spec_Migration_Phase1.md** — the numbered backlog of migration tasks that have driven recent spec amendments.

Any planning document with a `CC_` prefix is in scope as reference material.

The current spec change logs are particularly valuable: they record when each rule was added and often capture the reasoning at the time. Decisions whose rationale traces back to "the existing code does this" are flagged candidates for the "accommodation" verdict. Decisions whose rationale traces to "this is the cleanest path" are flagged candidates for the "keep" verdict.

## Sequencing

The four specs are audited in this order:

1. **CC_HTML_Spec.md** — central spec, drives page structure, defines chrome shell, sets conventions other specs follow.
2. **CC_CSS_Spec.md** — depends on HTML's prefix rules and chrome conventions.
3. **CC_JS_Spec.md** — depends on HTML's data attribute conventions and ID conventions.
4. **CC_PS_Spec.md** — depends on conventions established in the other three for file structure and code emission.

Each spec moves through phases 1 and 2 to produce a decision inventory with verdicts. After all four inventories are complete, phase 3 happens for all four specs together to ensure cross-spec consistency in pattern application. Phase 4 (migration) is the implementation work that follows.

## Ground Rules During the Audit

To prevent the audit itself from drifting:

- **One section at a time during phase 1.** No batching. Each section gets focused attention.
- **Quote the current spec text.** Don't paraphrase rules. The exact wording matters because it shows what's actually written vs. what was intended.
- **Mark inferences clearly.** When stating "this section was added to accommodate X" without direct evidence, mark it as inference vs. a documented fact.
- **No spec changes during the audit.** Phase 1 produces an inventory. Phase 2 produces verdicts. Phase 3 writes new docs. The old docs are not edited until the new docs are stable.
- **No populator changes during the audit.** Phase 4 implementation work waits until phase 3 is done. Touching the populator during the audit risks reverting the same code twice.
- **The verdicts are the project owner's decision.** The auditor lays out evidence and a recommendation; the project owner decides whether each decision survives, simplifies, or is replaced.

## Out of Scope

The audit is of the four CC specs. It does not include:

- Auditing of the populator code (downstream of the spec refactor).
- Auditing of Development Guidelines, BDL Import docs, B2B docs, or other non-CC documentation.
- Auditing of existing pages, CSS files, JS files, or PowerShell route files (these are all subject to rewrite during phase 4).

If during the audit a question about another document or piece of code arises that genuinely requires looking at, we'll look — but the primary scope is the four CC specs.

## Expected Outcomes

When the project completes:

- Four new specs, each substantially shorter than the current versions, written prescriptively and developer-first.
- A clear inventory of which decisions from the old specs survived and which were retired.
- Populators rewritten to match the new specs, with the bloat that has accumulated through accommodation removed.
- Files (pages, CSS, JS, PowerShell) rewritten during the standard refactor pass to match the new specs.
- The old specs retire once the new specs and the codebase are aligned.

## Acknowledgment of Cost

This is real work. The audit and synthesis phases alone are likely multiple sessions per spec. The migration phase touches every file in the platform. Total scope is substantial.

The alternative is continuing to patch individual drift findings against an accumulating spec that the project owner cannot use as intended. That path is also expensive — and produces a result the project owner has explicitly said is not what they want.

The honest assessment: the refactor is the right work. The cost is real. The outcome is a foundation that supports the rest of the project's lifetime.
