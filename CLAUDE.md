# CLAUDE.md - xFACts Project Rules

These rules are mandatory for every session in this repository. They are not
suggestions. When any rule conflicts with speed or convenience, the rule wins.

## Who you are working with

Dirk is a T-SQL and SQL Server DBA expert. He is NOT fluent in PowerShell,
CSS, JavaScript, or HTML internals. Explanations, questions, and summaries
must be in plain English, not language-specific jargon. He can follow logic
and architecture at a high level; do not assume he can spot a subtle PS/JS/CSS
mistake in a diff, so your own verification carries the full weight.

## Specs are the sole source of truth

- The spec documents in this repository strictly define file structure and
  content for all xFACts files. Before writing or editing ANY file, read the
  relevant spec end to end in the same session. Do not skim, do not rely on
  prior familiarity, do not assume.
- The four file-format specs live in xFACts-Documentation: xFACts_PS_Spec.md,
  xFACts_CSS_Spec.md, xFACts_JS_Spec.md, and xFACts_HTML_Spec.md. Also
  authoritative: xFACts_Development_Guidelines and xFACts_Platform_Registry
  (locate their exact paths in the repository before relying on them). If a
  needed spec cannot be found, STOP and ask.
- Parsers and populators catalog every file and flag spec violations as
  drift requiring remediation. Non-conformant output is not a style issue;
  it creates real work. Verify conformance before delivering.

## Never guess

- Never guess at table names, column names, file paths, function names,
  API shapes, or configuration values. Verify by reading the actual file,
  spec, or registry entry. If it cannot be verified from the repository,
  ask Dirk. "I assumed" and "I guessed" are unacceptable.
- When modifying an existing script, study its existing patterns first and
  follow them. If existing components each have a dedicated function or
  converter, new components get one too.

## Banned words

- The words "canonical" and "corpus" are BANNED from all source files and
  all new documentation. Do not introduce them. If found in a file being
  edited, remove them as part of the edit. Historical document entries
  (e.g. old changelog lines) are the only exception.
- Never treat any page or script as a template to build from. There is no
  such thing in this site. The spec defines correctness, not any
  existing file.

## Byte discipline (all xFACts files)

- Pure ASCII. No Unicode characters of any kind, including smart quotes,
  em dashes, ellipsis characters, and non-breaking spaces.
- CRLF line endings everywhere. No BOM. Exactly one trailing CRLF at end
  of file.
- Verify byte discipline AND brace/paren/here-string balance before every
  delivery. Beware: Python .replace() edits can strip CRLF; re-normalize
  after any scripted edit.

## File integrity

- Every delivered file is a full, complete, current file reflecting ALL
  cumulative edits from the session. Never deliver a file that silently
  drops an earlier in-session change.
- Never rename files. Exact production filenames only.
- Remove dead and obsolete code when editing; do not leave commented-out
  remnants. Scripts stay streamlined and clearly organized.
- Full headers with CHANGELOGs only on permanent objects (stored procs,
  triggers, functions, PS scripts). PS scripts keep CHANGELOGs but no
  version numbers (version lives in System_Metadata). Build and enrichment
  SQL scripts skip headers: just SQL with section separators and
  verification queries.

## SQL and database boundaries

- NEVER execute SQL against any server. Do not use sqlcmd, Invoke-Sqlcmd,
  or any other database connection mechanism. Write .sql files for Dirk to
  review and execute in SSMS himself.
- DDL scripts are structured for step-through execution: separately
  runnable sections with verification queries. Do not comment out
  destructive operations; Dirk steps through as-is.
- Build one object at a time: table DDL, then verify, then Object_Registry,
  then Object_Metadata, then System_Metadata bump. Never bundle DDL
  creation and Object_Metadata into a single deliverable unless the design
  is finalized and Dirk has agreed.
- All new DB objects validate against xFACts_Development_Guidelines before
  DDL generation. Object_Registry in xFACts_Platform_Registry is the source
  of truth for component classification; script header component pointers
  may disagree - flag mismatches, do not trust headers.

## Deployment boundary

- GitHub is the source of truth for authored content, and committing and
  pushing to GitHub from this clone is the standard flow. Commit and push
  are gated - the harness prompts for approval on each - so push only when
  the work is ready and you have approval. The flow is: edit here, commit
  and push to GitHub, then the deploy step of the pipeline pulls GitHub into
  a staging clone on FA-SQLDBB and copies the changed authored files to
  their live locations. Generated content flows the other way,
  live -> GitHub, via the publisher. Dirk runs the pipeline.
- Before any commit/push sequence, first pull (this clone is configured for
  rebase - pull.rebase true) to absorb the pipeline's generated-content
  commits, then commit and push. The publisher/manifest steps create commits
  on GitHub after every run, so this clone is perpetually behind at push time;
  the API commits touch only generated paths and ours touch authored paths, so
  the rebase is always trivial. With a fresh pull first, the push should
  succeed on the first try - the old push-fail-then-rebase-retry cycle should
  no longer occur. If a push still fails after a fresh pull, STOP and report;
  never force-push or otherwise force history.
- Never edit the live production folders directly. The live folders on
  FA-SQLDBB (any path under \\FA-SQLDBB\E$, such as xFACts-PowerShell and
  xFACts-ControlCenter) are populated by the deploy pipeline, not by hand.
  Never read from or write to any network path from this clone - it is the
  only writable workspace, and authored changes reach live through GitHub
  and the deploy step, never by touching the live folders. Use
  git checkout . and git pull to re-sync the clone with what has been
  published.

## Working style

- Ask questions before proceeding when anything is unclear. When a question
  needs Dirk's answer to shape the work, ask and STOP - do not generate the
  code in the same reply.
- Nothing is out of scope and work is not deferred to future sessions;
  surface architectural forks to Dirk rather than silently choosing.
- Investigation-first on all new areas: read before proposing, verify
  before writing.
