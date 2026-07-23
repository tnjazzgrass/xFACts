# xFACts PM Current State

Convention: this file is a rolling session-orientation punch list, not a state
snapshot and not a history. It is rewritten in full (replaced, not appended) at
the close of every chat session. Keep it to one page. No item IDs anywhere --
reference work by component plus a short name.

## Current focus

Metadata audit rotation -- next up: the remaining ServerOps components.

## Hot items

- BIDATA / Teams / Jira -- enum-conformance follow-up (retro-apply the
  purpose-only enum-description rule to the three completed modules; migrate
  stripped glosses into status_value rows where coverage is missing).
- B2B -- execution census, design phase (investigation-first; sizing and
  linkage queries before any schema).
- B2B -- Sterling WORKFLOW_CONTEXT archive regression (restore table now
  empty; pending the Melissa conversation, whose outcome sets the census
  source-window assumption).
- B2B / Sterling -- GET_LIST v20 BPML fault-ticket fix (Sterling-side BPML
  edit; owner Dirk / ops).
- B2B -- Step 09 child-fault sweep, run manually on a recurring basis until the
  census ships.

## Corrections (Chat cross-session memory found wrong; keep until absorbed)

- sp_GenerateDDLReference does not exist. The DDL reference generation is
  inline in Generate-DDLReference.ps1 and has been since March 2026. Registry
  and metadata were already clean.
- There is no duplicate backlog file at any old root path. Only the copy under
  xFACts-Documentation/docs is real; treat root-path backlog search hits as
  stale index artifacts.
