# CC Session Summary 41 -- A&I Completion, Dock Animation Fix, Populator Trim

**Date:** 2026-06-07
**Status:** Applications & Integration COMPLETE (drift 2/2 expected shim rows). Foundation fully proven on a real page. HTML populator comment-trimmed and verified. Admin guide delivered.
**Position in initiative:** Admin is the last remaining CC page. Everything blocking it is now resolved.

---

## 1. What this session was

Picked up from Session 40 (overlay-construct foundation). The foundation existed
but had only been proven on File Monitoring, which has no dock with a real seam.
This session: finished Applications & Integration (the first dock consumer with a
positive seam), which surfaced and resolved a real dock foundation bug; closed out
the subheader spec edits; wrote the Admin refactor guide; and did the HTML
populator comment-condensation pass. Admin itself was NOT started -- it is the
next session's work, fully prepped.

---

## 2. Foundation fix -- the dock hide/animation bug (cc-shared.css)

A&I is the first dock anchored at a positive seam `left` (804px, beside the wide
meta/catalog panel). That exposed a Session-40 bug invisible on File Monitoring:

- **Bug:** the dock hid via `transform: translateX(-100%)` (move left by its own
  width). That fully hides a dock at `left: 0`, but a dock at `left: 820` only
  moves to right-edge x=820, leaving ~820px of empty dark panel on screen at rest,
  at a higher z-index than the paired panel. Symptoms: empty panel visible on page
  load, and the catalog panel appearing "not to open" (it opened behind the
  resting dock, which painted over it).
- **Root cause of the second symptom:** z-index plus the broken resting position;
  the panel was opening correctly the whole time.

Fix iterations (all in `cc-shared.css`, dock construct only):
1. **max-width clamp** (`max-width: 0` -> `100vw`) -- hides at any seam, but the
   `100vw` transition span made the open animation snap (visible motion completed
   in the first ~third of the duration). Rejected on feel.
2. **Border sliver** -- the shared `.cc-dialog` border painted a thin vertical line
   at zero width. Fixed by `border: none` on the dock base and adding the
   top+left framing borders only in `cc-open` (matching the original page-local
   dock, which framed only when visible).
3. **clip-path (final):** base `clip-path: inset(0 100% 0 0)` (clipped from the
   right, hidden) -> open `clip-path: inset(0)`, transition on `clip-path`. Width
   stays at the real tier value, so the reveal animates across the actual width
   (graceful, matches the original 0.3s feel), hides fully at any seam, and every
   selector stays <=2 tokens (avoids COMPOUND_DEPTH_3PLUS, which is why Session 40
   abandoned width-animation originally). Open state keeps the top+left framing
   borders.

Spec check confirmed: CC_CSS_Spec Sec. 14 forbidden list is selectors/structure
only -- there is NO property-level restriction, so `clip-path` is fully legal. The
spec is silent on visual mechanism; the dock animation needed no spec text.

**Behavioral note (accepted by Dirk):** clip-path *reveals* the pre-laid-out
content rather than *reflowing* it as the box grows. Motion/direction/timing match
the original; the only difference is content does not reflow during the sweep
(arguably cleaner -- no jitter). The unrefactored Admin dock still reflows; that
goes away when Admin is converted to the same chrome dock.

---

## 3. Applications & Integration -- COMPLETE

A&I turned out partially pre-refactored (API already clean -- 15 endpoints all
guarded; the "16 GETs need guards" note was Admin's, mis-attributed in S40).
Only the catalog slide-up panel and the detail dock needed conversion. Delivered
route + CSS + JS as a set; API untouched.

- Catalog panel -> `cc-slideup-overlay` + `cc-dialog cc-dialog-slideup cc-wide
  cc-h-short`, id `aai-slideup-catalog`.
- Detail dock -> `cc-dialog cc-dialog-dock cc-xwide cc-dock-at-wide cc-h-short`,
  id `aai-dock-catalog-detail` (no action attr -- cleared the 2
  ACTION_ON_NON_INTERACTIVE drift rows).
- Pinned strips -> `cc-dialog-subheader`. Inner content ids preserved on chrome
  elements (43 JS refs). Open/close rewritten to JS spec Sec. 11.5.3 (slide-up)
  and Sec. 11.5.4 (dock).
- **Final drift 4 -> 2** (only the expected CCShared shim rows remain).
  Confirmed clean by Dirk re-running the populators after the dock fix.

The full construct set (slide-up, dock with correct seam/hide/animation,
subheader) is now proven on a real, deployed, behavior-preserving page.

---

## 4. Spec edits (subheader) -- applied by Dirk in Session 40, re-verified this session

The six CC_HTML_Spec edits from S40 (Sec. 5.4.4 / 5.4.6 optional-subheader child
sequence, Sec. 14.2 subheader + four cc-dock-at-* rows, Sec. 15 MALFORMED_*
wording) were re-verified as still correct after this session's dock-animation
detour. The detour was all visual mechanism (clip-path, borders) -- which the spec
does not describe -- plus the seam classes, already covered by the Sec. 14.2 rows.
No spec change was invalidated; nothing new is needed. Spec is aligned with reality.

---

## 5. HTML populator comment trim -- COMPLETE and verified

`Populate-AssetRegistry-HTML.ps1`: **6615 -> 6098 lines (517 removed, ~7.8%).**
Lower than the rough ~1,000 estimate because the file's bulk is code, not comments
-- but the comment waste Dirk flagged is gone.

Convention established (applies to all four populators going forward):
- **Cut:** anything a section banner already says; reproduced code/markup
  templates (page-shell, chrome shell, engine-card, refresh-info, token-kind
  tables); return-shape field dumps; spec-mechanism rationale; cross-references;
  step-by-step restatements of visible code.
- **Keep (condensed to 1-3 lines):** one-line "what it is" per function, plus the
  genuinely non-obvious "why" -- infinite-loop guards, foreach-iterators-as-caller-
  given contract, overlay backdrop-close carve-out, class-based (not id-based)
  capture, the Q4 multi-emission whitespace carve-out.

Two bonus fixes:
- All four "canonical" instances removed (1 drift-description string ->
  "required form", 3 comments). Zero remaining in the file.
- A **stale comment** corrected: the dock-structure validator's comment still
  described the pre-amendment "exactly two children" shape; updated to the
  optional-subheader/header-actions reality.

Verification (the safety basis): a **code-only diff** (comments + blank lines
stripped from both versions) confirmed the executable code is byte-identical to
the original across all 4566 code lines, except the one approved canonical->
required string. Code braces unchanged (1465/1464 both files); block comments
balanced 29/29; byte discipline clean (no BOM, uniform CRLF, pure ASCII, single
trailing newline). PowerShell parse could not be run in-environment (no pwsh);
the code-only diff is the equivalent guarantee that no logic changed.

Remaining: the other three populators get the same pass in future sessions. They
are already spec-refactored, so those are pure comment passes with no structural
risk.

---

## 6. Go-forward -- Admin (the last CC page)

### Decision: refactor it, do not exclude it

Admin maps cleanly to the existing constructs -- there is no shape it cannot
express. The "it feels so different" impression is because it is *unrefactored*
(old `Admin.*` global namespace, inline onclicks, stateful descendant selectors),
not because it is structurally alien. Every other page looked like this before
conversion. Excluding it would put a permanent hole in the catalog on the most
consequential page and would be the first crack in "spec is sole authority." So:
convert it.

### Is there wheel-spinning risk?

No *construct-fit* risk -- all six slide-ups, the dock, and the subheaders map to
proven chrome. The real risk is **volume in the JS**: Admin has no dispatch model
and a ~160-function `Admin.*` namespace with ~90 inline onclick call-sites. That
is a throughput problem, not a fit problem -- the A&I dispatch pattern maps onto it
fine, there is just a lot of it. Two pre-identified tricky-but-solved patterns
(both in the guide): (G1) onclick handlers carrying args + stopPropagation ->
data-action + argument attributes, decide the container-vs-nested convention once
and apply uniformly; (G2) ~12 stateful descendant selectors that are CSS+JS+markup
triples (the JS must move the state class onto the child that changes). Knowing
these upfront is what keeps them from becoming mid-session surprises.

### Session strategy: single-session target, with a real safety net

- **Aim for a single session.** Explicitly declaring it multi-session tends to
  make it multi-session (and overrun). The prep (the Admin guide, pre-decided
  construct mappings/ids, G1/G2 flagged) is what makes one session viable -- that
  is where time is saved, not in a split.
- **Deployment is decoupled via staging.** Dirk will stage all four converted
  files to a holding folder and NOT deploy until the complete set is ready.
  Production Admin stays untouched and fully functional throughout. This removes
  the "never stop with a broken deployed page" pressure entirely -- nothing goes
  live until all four deploy together.
- **Because deployment is staged, the discipline shifts** from "don't deploy
  broken" to "don't stop mid-file." If we must stop, finish whatever file we are
  in (so it is coherent to resume), bank the set in the holding folder, and
  continue next session. No broken page either way.
- **Build order:** CSS first (establish the flattened state-class contract the JS
  and route will target) -> route + JS in lockstep (build the `adm_` dispatch
  architecture, convert constructs and handlers together -- these CANNOT be split
  across sessions, they are mutually dependent and would leave a broken page) ->
  API last. The 15 API guards are the only fully independent piece and are both
  the natural finish line and the cleanest resume point if needed.

### The Admin lift (from the guide)

- Route (388 lines): 52 onclick -> data-action; 84 ids -> adm- + overlay/dock
  id-forms; 6 slide-ups + dock + engine panel -> chrome; 3 inline styles -> CSS.
- JS (1337 lines, LARGEST): build `adm_` dispatch from scratch; rename ~160
  functions; convert ~38 rendered-HTML onclicks; rewrite 6 slide-up + dock
  open/close; audit 4 setInterval timers.
- CSS (1229 lines): 29 forbidden descendant/sibling/group selectors -- ~12 flatten
  to state-on-element (CSS+JS+markup triples), ~17 DELETE (panel-scope layout now
  chrome-owned); one-declaration-per-line reformat.
- API (1579 lines): 15 of 27 routes lack Test-ActionEndpoint guards; add them.

Construct mappings (pre-decided, in the guide): engine -> slideup cc-narrow
cc-h-short; metadata -> cc-wide (+ dock); globalconfig -> cc-xwide; schedule ->
cc-wide; docpipeline -> cc-default cc-h-max; alertfailures -> cc-default
cc-h-short; detail dock -> cc-wide cc-dock-at-wide. Keep the toggle switch,
bitmask badges, and inline editors page-local (not chrome-promoted this cycle).

---

## 7. After Admin -- the cutover (not next session; the one after)

Once Admin is converted and deployed, the end-of-migration cutover is possible:
- Switch Start-ControlCenter to load `xFACts-CCShared.psm1`.
- Strip the CCShared import shims from every route (clears the 2-row-per-page
  transitional drift platform-wide).
- Retire `xFACts-Helpers.psm1` and `engine-events.css/js`.
- Then: chrome-promotion pass (toggle-switch, inline-edit) and the comment-trim
  pass on the other three populators.

---

## 8. Parked / carried

- **cc-shared.css gradient comment** still contains "canonical" -- separate cleanup,
  not blocking.
- Other three populators: same comment-condensation pass, one per session.
- DBCC disk-alert suppression during CHECKDB runs (medium; cross-component).
- B2B: investigation-first per B2B_Roadmap.md; no new tables/columns until the
  relevant area resolves.

---

## 9. Lessons (this session)

- **A foundation verified against zero real consumers fails on the first real one.**
  The dock hide was "verified" in S40 with no positive-seam consumer; it broke the
  instant A&I gave it a real seam. Verify constructs against an actual consumer
  with the actual conditions, not in the abstract.
- **"It feels different" usually means "it is far from spec," not "it does not fit
  the spec."** Admin's alienness is unrefactored-ness. The constructs fit.
- **Decoupling deployment from completion (staging) removes the rush.** The
  single-session pressure was really about not deploying a broken page; staging
  solves that directly, so we can aim high without testing limits.
- **The code-only diff is the right verification for a comment-only pass.** Strip
  comments from both versions, confirm byte-identical code. It proves no logic
  moved without needing to execute anything.

---

## 10. Session boot sequence (next session -- Admin)

1. Read the instructions, then this summary (CC_Session_Summary_41), all 4 specs 
   *completely from end to end*, then the Admin_Refactor_Guide.
2. `project_knowledge_search` the anchor docs (the specs, this summary, Development
   Guidelines, Backlog, Platform Registry); `web_fetch` the cache-busted manifest
   for anything else.
3. Confirm Admin's Component_Registry row (component_name, cc_prefix, section_key,
   route). Request the four current Admin files; read all four in full before
   proposing anything (do not work from this summary's recollection).
4. Build order: CSS -> route + JS (lockstep) -> API. Lift the CCShared import shim
   verbatim from a deployed route. Stage all four to the holding folder; do not
   deploy until the set is complete.
