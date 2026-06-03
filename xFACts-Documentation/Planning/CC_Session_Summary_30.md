# CC Session Summary 30

## Applications & Integration page migration (prefix `aai`)

---

## 1. Scope

Migrated the **Applications & Integration** departmental page — the last departmental page in the chain — to the four CC file-format specs. Four source files refactored: page route (`ApplicationsIntegration.ps1`), API route (`ApplicationsIntegration-API.ps1`), CSS (`applications-integration.css`), JS (`applications-integration.js`). The page proved materially harder than prior pages because it is the first **partially-gated** page: an Administration section (plus a BDL Catalog slide-up dock and three DM job modals) that must be visible only to admins, sitting inside a page that non-admin departmental users also reach. This collided with how the HTML populator discovers and validates markup, which drove most of the session.

Final state: the page sits at its clean interim floor of **4 drift rows**, all of the allowable transitional kind (resolve on committed near-term work, not carve-outs).

---

## 2. Files delivered

- **`ApplicationsIntegration-API.ps1`** — zero drift. 15 endpoints; 10 admin endpoints keep the `$ctx.IsAdmin` 403 gate + `Test-ActionEndpoint` hook, 5 non-admin hook-only. All SQL here-strings byte-preserved; `"FAC\$($WebEvent.Auth.User.Username)"` on audit inserts. Unchanged after the first refactor.
- **`applications-integration.css`** — zero drift. Added a `CONTENT: UTILITIES` section with the page-local `.aai-hidden { display: none; }` modifier; element-reset props on `.aai-tool-card` so button/anchor/div tool cards render identically. CRLF / ASCII / no BOM.
- **`applications-integration.js`** — zero drift. Full dispatch-table model (click/change/keydown tables, delegated listeners on `document.body`). Static-modal job functions; all data attributes `data-aai-*`; no `let`/IIFE/`window.=`/inline-style/`createElement`/bare-data. LF / ASCII / no BOM.
- **`ApplicationsIntegration.ps1`** — 4 rows, all transitional (see §6). Single `$html` here-string; admin markup literal and unconditional inside it; admin-section visibility via the §6.2 array-join conditional class; three job modals carry `cc-dialog-close` buttons.

---

## 3. The core problem: partial gating vs. the HTML populator

Every clean page before this was either fully shared or fully admin-gated. A&I is the first page with an **admin section inside an otherwise-shared page**, which exposed a structural conflict in the toolchain. The diagnosis came from reading `Populate-AssetRegistry-HTML.ps1` directly rather than reasoning about expected behavior.

**What the populator source established:**

- **ID cataloging.** `Get-HtmlEmissions` discovers HTML from three patterns only: here-strings, StringBuilder chains, and string-literal returns *inside named functions*. `Get-StringLiteralEmissions` **explicitly skips string literals inside route ScriptBlocks** (`if ($insideRouteScriptBlock) { continue }`). Consequence: HTML built by **string concatenation inside the route** (`'...' + "`n" + '...'`) is invisible to the populator — its `id="..."` declarations are never cataloged, so every JS `getElementById` against them drifts `JS_HTML_ID_UNRESOLVED`.
- **DOCTYPE / document identification.** `Get-HereStringEmissions` catalogs **every** here-string that passes `Test-LooksLikeHtmlEmission` (true for anything with `class=`, `id=`, or matching tag pairs) as a separate "document," each validated for DOCTYPE. Consequence: any HTML-bearing here-string *other than* `$html` (e.g. a `@'...'@` admin block before it) draws `MALFORMED_DOCTYPE` because it lacks `<!DOCTYPE html>`.

**The forced structure.** For IDs to resolve, admin markup must be **literal text inside a here-string**; for DOCTYPE to stay clean there must be **exactly one** HTML here-string. The only construct satisfying both is the one every clean page uses: a single `$html` here-string with all markup literal inside it. PowerShell offers no way to make literal here-string content conditionally absent — so the admin markup is **physically present and unconditional**, and non-admin gating must be presentation-layer, not server-omission.

---

## 4. Decisions

- **Interim gating = hide-not-omit (approved).** Admin markup (Administration tool-card section, BDL Catalog dock, 3 DM job modals) is always emitted in the single `$html` here-string. The Administration section's class is built via the §6.2 array-join pattern: `$adminSectionClassList = @('cc-section','aai-admin-section'); if (-not $ctx.IsAdmin) { $adminSectionClassList += 'aai-hidden' }; $adminSectionClass = ($adminSectionClassList -join ' ')`, interpolated as `class="$adminSectionClass"`. Page-local `.aai-hidden { display: none; }` collapses the section out of layout for non-admins (no reserved space; sections below sit flush). The **API is the security boundary** — every admin endpoint independently 403s non-admins — so hiding is presentation only. Accepted trade-off: a non-admin could see the admin markup in raw page source but cannot use it.
- **No shared accommodation.** Rejected adding a `cc-is-admin` class to cc-shared.css — shared chrome is not bent to accommodate one page. The gate uses only the page-local `aai-hidden` class plus the spec's existing array-join pattern. Body cannot carry an admin flag: §1.1 fixes the body to exactly three attributes (`class`, `data-cc-page`, `data-cc-prefix`) and forbids page-prefixed body classes.
- **Single `$html` here-string** is the only clean structure (matches BS / BI / DmOps / Admin). No pre-`$html` HTML here-strings, no route-level string concatenation of HTML.
- **Admin tool-cards are `<button>`; BDL Import is `<a href="/bdl-import">`** (native nav, no JS handler) — interactive elements resolve `ACTION_ON_NON_INTERACTIVE_ELEMENT`.
- **DM job modals = static §11.5.2 pattern.** Three `cc-modal-overlay cc-hidden` shells; outer overlay carries `data-action-click="aai-job-close-modal"` + `data-aai-modal-id`. Each modal's `.cc-dialog.cc-dialog-modal` now contains header (title + **`cc-dialog-close` button**) + body + actions. The close button was the missing required child causing `MALFORMED_MODAL_STRUCTURE` (see §5).
- **Modal IDs (`aai-job-drools-modal` etc.) are correct as-is.** `Get-OverlayIdInfo`'s modal regex is `^<prefix>-modal-<purpose>$`; "modal" as a suffix doesn't match, so these are classified as modals by **class** (`cc-modal-overlay`), not by ID — no `MALFORMED_MODAL_ID`.

---

## 5. Drift progression

Full pipeline each pass (CSS → HTML → JS → PS), truncate-and-repopulate.

- **Pre-refactor:** css 164, js 97, API 17, page route 112.
- **First refactor:** css 0, js 0, API 0, page route 7 (2 shim + 4 `ACTION_ON_NON_INTERACTIVE_ELEMENT` + 1 `MALFORMED_DOCTYPE`).
- **String-concat detour (wrong turn):** DOCTYPE cleared but ~45 `JS_HTML_ID_UNRESOLVED` appeared — moving admin markup to route-level concatenation removed its IDs from the populator's catalog.
- **Single here-string rebuild:** page route 7 — 2 shim + 2 dock `ACTION_ON_NON_INTERACTIVE_ELEMENT` + 3 `MALFORMED_MODAL_STRUCTURE`. DOCTYPE clean, all catalog IDs resolved, js/css 0.
- **Modal close-button fix:** page route **4** — 2 shim + 2 dock action-div rows. js/css/API 0.

`MALFORMED_MODAL_STRUCTURE` root cause: the validator's "required child elements" clause. The modal `.cc-dialog` was missing the `cc-dialog-close` button that clean reference modals (BusinessServices, DmOps) carry. Added one to each header with `data-action-click="aai-job-close-modal"` matching the overlay's backdrop action (also satisfies `MISSING_OVERLAY_BACKDROP_CLOSE`). No JS change: `aai_jobCloseModalFromAction(target, event)`'s backdrop guard only applies when the action element *is* the overlay, so a close-button click closes correctly; the pattern matches the dynamically-injected Cancel/Close buttons already in the JS.

---

## 6. Final state — 4 rows, all transitional

| Rows | Code | Disposition |
|------|------|-------------|
| 2 | `MISPLACED_IMPORT` + `MISSING_RBAC_CHECK_PAGE` | CCShared import shim — platform-wide transitional drift, clears at module cutover. |
| 2 | `ACTION_ON_NON_INTERACTIVE_ELEMENT` (catalog dock backdrop + handle divs) | Page-local backdrop/handle divs get no §7.5 carve-out. Clears when the 4th overlay construct ships (next priority). |

Both are the allowable kind: drift that resolves on committed near-term work, not accepted exceptions or carve-outs.

---

## 7. Backlog items added

Two rows added under ControlCenter:

- **Build / Medium — 4th overlay construct (side-by-side slide-up dock).** Model the dock as a proper fourth `cc-` overlay (HTML §5.4 + §14, CSS spec, JS §11.5, all four populators, cc-shared.css/js) so its backdrop/handle become carve-out-eligible overlay containers. Resolves the 2 dock action-div rows on `aai`. First concrete consumer is the A&I catalog dock.
- **Enhance / Medium — Conditional server-side markup support for partially-gated pages.** Design populator + spec support so partially-gated pages can omit admin markup server-side without losing ID resolution or breaking DOCTYPE detection. Replaces the interim hide-not-omit approach once shipped.

---

## 8. Migration status

Departmental pages complete (A&I was the last). Migrated/reference pages now include: BIDATA, Backup, Business Services, Replication Monitoring, Business Intelligence (reference), DM Operations, Client Relations, Admin context, Applications & Integration.

---

## 9. Next session

- **Next page: JBoss Monitoring.** Standard migration of its four source files to the four specs.
- Session start: `project_knowledge_search` the active anchor docs; pull the JBoss source set via the GitHub manifest (cache-busted).
- Standing items still open: 4th overlay construct (next priority once page cadence allows), conditional-markup support, helper-module consolidation (blocked until all pages refactored), and the JS-populator performance investigation.
