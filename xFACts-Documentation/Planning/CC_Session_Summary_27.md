# CC Session Summary 27

**Focus:** Site-wide overlay-close consistency pass across all migrated Control Center pages, plus three spec amendments codifying the resulting standard.

---

## 1. What this session was

Not a page migration. A focused consistency pass: every migrated CC page was brought onto a single, uniform overlay-close pattern (modals and slideouts alike), and the pattern was then written into the specs so future pages inherit it by rule rather than by precedent.

The trigger was an observation on BIDATA — its build-detail slideout closed only via the X button, while Backup and Business Intelligence closed their overlays on an outside (backdrop) click. That surfaced a site-wide inconsistency: three different close mechanisms were in use across the clean pages, and one page (Business Services) had no backdrop-close at all.

---

## 2. The investigation that set the standard

Before changing anything, the three existing mechanisms were read from source and compared:

- **`cc-shared.js` has no centralized overlay backdrop-close.** Its only document-level click handler opens/closes the *engine popup*. Modal and slideout backdrop-close is entirely page-local. (This is why "everything seems to close on outside click" — the engine popup does, globally; the modals/slideouts do not, except per-page.)
- **Backup modal** used a two-action pattern: `bkp-modal-close` (X, unconditional) + `bkp-modal-close-on-overlay` (backdrop, `event.target === target`).
- **Backup retention slideouts** used a third pattern: the close action + a type argument on both the backdrop and the X, with no inside-click guard — meaning a click on non-interactive content *inside* the dialog bubbled to the backdrop action and closed the panel (a latent bug).
- **Business Intelligence slideout** used the cleanest pattern: one guarded handler wired to backdrop + X, guarding with `closest('.cc-dialog-close')` + `dialog.contains(event.target)`.

BI's guarded approach was the most robust, but its specific guard (`insideDialog && !onCloseButton`) breaks any dialog that has in-body buttons such as Cancel — it would suppress the Cancel click. BIDATA's date-range modal has exactly such a Cancel button, which forced the question and produced the final, generalized guard.

### The unified pattern (the standard)

One close action per overlay, wired to the backdrop **and** every explicit close control (X, Cancel, etc.). One guarded handler:

```javascript
function <prefix>_close<Thing>(target, event) {
    if (event && target.id === '<overlay-id>' && event.target !== target) {
        return;
    }
    // ...close (cc-hidden toggle for modal; transitionend slide-out for slideout)
}
```

In plain terms: **close on an explicit control or a direct backdrop click; ignore clicks that bubbled up from inside the dialog.** When the dispatcher matched the overlay element (not a button) but the click did not land directly on it, the click came from dialog content — bail. This is correct for both overlay types and any number of in-body buttons, and needs no dependency on control class names. Programmatic/no-event closes (e.g. close-on-apply) pass through because the guard is skipped when `event` is absent. The dynamic-modal lifecycle (created/removed, not toggled) is exempt.

---

## 3. Pages brought onto the pattern

All delivered as full drop-in replacements (exact production names). JS = LF + pure ASCII; PS = CRLF + pure ASCII.

| Page | Files | Conversion |
|---|---|---|
| **BIDATA** (`bidata-monitoring.js`, `BIDATAMonitoring.ps1`) | slideout + date-range modal | Built guarded slideout close first, then collapsed the modal from a separate `*-on-overlay` action to the unified guarded handler. Now the single-page reference exercising **both** overlay types on one pattern. |
| **Backup** (`backup.js`, `Backup.ps1`) | detail modal + two retention slideouts | Modal: merged two handlers into one guarded `bkp_closeDetailModal`; deleted `bkp_closeDetailModalOnOverlay` + dispatch entry. Slideouts: added the guard, deriving the overlay id from the existing type argument (type mechanism preserved). **Fixed the latent inside-click-dismiss bug.** Also stripped a UTF-8 BOM and normalized 5 bare-LF lines a prior changelog *claimed* but had not done. |
| **Business Services** (`business-services.js`, `BusinessServices.ps1`) | slideout + request modal | Purely additive — page was X-only, gained backdrop-close on both overlays. Confirmed safe: both views are read-only (no forms/inputs), and the modal-over-slideout case is non-conflicting because the two overlays are DOM siblings (modal backdrop closes only the modal). |
| **Replication Monitoring** (`replication-monitoring.js`, `ReplicationMonitoring.ps1`) | help/info slideout | Found by explicit check (almost overlooked, as BIDATA's modal had been). Was on the `*-on-overlay` pattern; merged to the guarded handler, deleted the extra handler + dispatch entry. Also stripped a UTF-8 BOM and normalized mixed line endings. |

**Business Intelligence** was already the reference (guarded slideout); unchanged.

Net: all five migrated pages now share one overlay-close pattern. Modals and slideouts use the identical guard; only the close mechanics differ (`cc-hidden` toggle vs. `transitionend` slide-out).

Each conversion was cross-audited: dispatch keys reconcile with emitted actions (static PS markup + JS-rendered markup), all handlers defined, no orphaned references, line-ending/ASCII verified.

---

## 4. Spec amendments (the standard, codified)

Three amendments, all delivered as paste-ready blocks for application on the authoring side. Kept to rule-plus-one-example density per the standing "spec states the rule and the accepted method, nothing more" discipline.

**4.1 HTML spec (§5.4 Overlay constructs)**
- Added `data-action-click="<prefix>-close-<construct>"` to the outer overlay element in all three templates (§5.4.1/.2/.3).
- One new rule in §5.4.4: the outer overlay carries the same close action as its `.cc-dialog-close` button so a backdrop click dismisses the construct.
- Consistent with the pre-existing §7.5 carve-out, which already *permits* overlay containers to carry action attributes for the click-outside-to-close pattern; this amendment makes it mandatory and shows it in the templates.

**4.2 JS spec (§11.5 Overlay open/close handler patterns)**
- Revised the close handlers in §11.5.2 (static modal) and §11.5.3 (static slide overlay) to the guarded `(target, event)` form.
- One new rule in §11.5.4: static-overlay close handlers take `(target, event)` and dismiss on a backdrop click or explicit close control, ignoring interior clicks; the §11.5.1 dynamic modal is explicitly exempt.

**4.3 PS spec (§11 Routes)**
- Added a new §11.1 "Canonical form" subsection (mirroring §12.1's structure) showing the page-route and API-route canonical scriptblocks — including the long-reconstructed `if ((Test-ActionEndpoint -WebEvent $WebEvent) -eq $false) { return }` guard. Renumbered the existing rules subsection §11.1 → §11.2. No rule text changed; this only surfaces the accepted form.

---

## 5. Carry-forward items dispositioned

The three Summary 26 §5.2 candidate items were resolved rather than carried again:

1. **Overlay inner-id naming collision → reclassified as a populator fix, struck from the spec list.** Chosen approach: have the HTML populator treat an id as an overlay-*outer* id only when its element also carries the matching `cc-*-overlay` class. This eliminates the spurious `MISSING_PANEL_PURPOSE_COMMENT` on natural inner ids (e.g. `bid-slideout-title`) without any new authoring rule or naming restriction. Lands with the §6 open item below (same HTML-populator overlay-detection code).
2. **`Test-ActionEndpoint` canonical form → added to the PS spec** (§4.3 above). Closed.
3. **Pipeline doc (parallel-run + JS route derivation) → not a spec item.** Belongs in `CC_Catalog_Pipeline_Working_Doc.md`. Carry-forward action: verify/capture there if not already present.

---

## 6. Open item for next session (enforcement gap)

The §4.1 HTML backdrop-close rule is **authoritative but currently unenforced** — no drift code checks for it. Per the standing principle that the spec should carry little to no unenforceable content, the enforcement must land close behind the rule, not linger.

- **HTML side (clear path):** add a drift code in `Populate-AssetRegistry-HTML.ps1` overlay-construct validation (alongside `MALFORMED_*_STRUCTURE` / `MISSING_DIALOG_CLASS`) that flags an overlay outer element whose `data-action-click` is absent or does not match its `.cc-dialog-close` button's close action. The populator already walks these tokens, so the check is structural and within reach.
- **Sub-question to decide:** whether to also enforce the JS-side guard form (handler takes `(target, event)` and guards), which is a harder parse, or treat the HTML attribute check as the enforceable proxy (if the backdrop carries the action, the handler must cope with backdrop clicks, which surfaces in testing). Recommend deciding this when the check is built.
- **Bundle with carry-forward item 1** (the overlay inner-id populator disambiguation) — both are HTML-populator overlay-detection changes; natural to do together.

---

## 7. Files delivered this session

- `bidata-monitoring.js`, `BIDATAMonitoring.ps1` (slideout + modal unified; deployed, drift-clean)
- `backup.js`, `Backup.ps1` (modal + two slideouts unified; latent inside-click bug fixed; BOM + line endings normalized)
- `business-services.js`, `BusinessServices.ps1` (backdrop-close added to slideout + modal)
- `replication-monitoring.js`, `ReplicationMonitoring.ps1` (info slideout unified; BOM + line endings normalized)

Plus three spec-amendment paste-ready blocks (HTML §5.4, JS §11.5, PS §11) for authoring-side application.

No live PowerShell parse was available in-session; a syntax pass before deployment was advised for all PS files. A manual click-test of each overlay's close paths (backdrop / X / Cancel where present / interior click) was advised as the behavioral proof.

---

## 8. Cross-references

- `CC_Session_Summary_26.md` — predecessor; established the whole-page-migration phase and raised the three §5.2 candidate items dispositioned here.
- `CC_HTML_Spec.md` — §5.4 overlay constructs (amended), §7.5 action-attribute carve-out (pre-existing, consistent).
- `CC_JS_Spec.md` — §11.5 overlay open/close handler patterns (amended).
- `CC_PS_Spec.md` — §11 routes (amended: new §11.1 canonical form).
- `Populate-AssetRegistry-HTML.ps1` — target for the §6 open item and carry-forward item 1.
- `CC_Catalog_Pipeline_Working_Doc.md` — target for carry-forward item 3.

---

*End of Session 27 summary. The overlay-close consistency pass is complete across all five migrated pages, and the standard is codified in the HTML, JS, and PS specs. Next session: resume page migration (page selection by-ear at session start), and land the HTML-populator backdrop-close enforcement (§6) — ideally bundled with the overlay inner-id disambiguation — so the new spec rule does not stay unenforced.*
