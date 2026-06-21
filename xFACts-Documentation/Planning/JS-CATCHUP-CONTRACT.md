# JS Catch-Up Contract — Docs Zone

Tracks every class name and state class the docs-zone JavaScript must emit or
toggle once the JS pass runs. The CSS+HTML refactor renamed/added these; the JS
still references the OLD names until updated. Until then, JS-driven content
renders unstyled or behaves on old classes.

## nav.js

### Breadcrumb nav (injected into `.doc-nav` and section-nav top rows)
Currently emits old classes; must emit:
- `nav-active-group`            -> `doc-nav-active-group`
- `nav-child-line`              -> `doc-nav-child-line`
- `nav-child-arrow`             -> `doc-nav-child-arrow`
- `current`                     -> `doc-section-nav-current`  (in section-nav context)
- `sep`                         -> `doc-section-nav-sep`
- breadcrumb links              -> add class `doc-section-nav-link`
(NOTE: the breadcrumb `doc-nav-*` family CSS is not yet built; pending JS pass.)

### Hub module-card grid (buildHubCards, injected into the grid)
Grid container selector: `.module-grid` -> `.doc-card-grid`
Must emit:
- `module-card`  -> `doc-card`
- `card-title`   -> `doc-card-title`
- `card-desc`    -> `doc-card-desc`
- (badge)        -> `doc-card-badge` + optional `doc-tag-<category>`

### Section-nav populated state (architecture pages)
When nav.js injects breadcrumb content into `.doc-section-nav-top`, it must ADD
the state class `doc-populated` to that element (replaces the old `:has(*)` CSS
selector, which is forbidden by spec).
Selector rename: `.section-nav-top` -> `.doc-section-nav-top`

### Sticky-nav / section-nav element selector renames (injectNav)
- `.sticky-nav-top` -> (reference-page equivalent, pending ref pass)
- `.sticky-nav`     -> (reference-page equivalent, pending ref pass)
- `.section-nav-top`-> `.doc-section-nav-top`
- `.section-nav`    -> `.doc-section-nav`

### Expand-card toggle (delegated handler)
- Selector `.expand-card-title` -> `.doc-expand-card-title`
- Selector `.expand-card`        -> `.doc-expand-card`
- BEHAVIOR CHANGE: the open state must be toggled as `doc-open` on BOTH the
  title (`.doc-expand-card-title`) AND the body (`.doc-expand-card-body`), not
  as `.open` on the card. (CSS uses `.doc-expand-card-title.doc-open::before`
  and `.doc-expand-card-body.doc-open` — no descendant selectors allowed.)

## docs-controlcenter.js (CC mockup guide pages — Phase C, deferred)
All `mock-*`, `marker-*`, `slideout-*`, `callout-marker`, `guide-slideout`,
`sidebar-item`, `key-flip-card`, `section-*` classes — to be reconciled when the
cc mockup pages are refactored (Phase C). Not part of the prose pass.

## ddl-erd.js / ddl-loader.js (ERD + reference DDL renderers — deferred)
Class contracts TBD when docs-erd.css and docs-reference.css are refactored.
