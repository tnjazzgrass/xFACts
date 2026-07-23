# Comment Bloat Inventory

Standing observation log maintained during the per-module metadata/documentation
audits. It is NOT a work list and NOTHING here is edited during an audit. Source
comments are read-only ground truth while auditing; this file only records what
was seen, so that a future comment-standards effort (backlog) has a coverage map
and a starting point.

## Rules for this file

- For every code file read as audit ground truth, add or update one row.
- A file with no significant bloat still gets a row ("reviewed - clean"), so the
  table doubles as a coverage map.
- On re-review, update the existing row (new date + note); do not add a duplicate.
- "Significant bloat" means rationale-heavy blocks, per-line narration, or
  comments that restate the adjacent code. Spec-mandated section banners and
  one-line function-purpose headers are NOT bloat.
- Observation only. Comment edits happen (if ever) under the future
  comment-standards effort, never inside an audit.

## Offense-type shorthand

- **rationale blocks** - multi-line "why we did it this way" prose
- **per-line narration** - a comment on nearly every line
- **code restating** - comments that just re-say what the code plainly does
- **clean** - none of the above at any meaningful scale

## Inventory

| File | Last reviewed | Scale of bloat | Dominant offense | Observed during |
|------|---------------|----------------|------------------|-----------------|
| xFACts-PowerShell/Execute-DBCC.ps1 | 2026-07-23 | Low (largely clean) | rationale blocks (minor; a couple of parse-format and backlog notes) | DBCC module-audit |
| xFACts-ControlCenter/scripts/routes/DBCCOperations-API.ps1 | 2026-07-23 | None | clean | DBCC module-audit |
| xFACts-ControlCenter/public/js/dbcc-operations.js | - | not yet reviewed | - (grep only this pass) | DBCC module-audit |
| xFACts-ControlCenter/public/css/dbcc-operations.css | - | not yet reviewed | - | DBCC module-audit |

"Not yet reviewed" rows are coverage-map placeholders: the file is part of the
module but was not read in full as audit ground truth this pass. They get a real
assessment when a future audit reads them.
