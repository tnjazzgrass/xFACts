# CC HTML Populator Alignment Plan

**Purpose:** Cheat sheet for the next session's `Populate-AssetRegistry-HTML.ps1` rewrite to align it with the new `CC_HTML_Spec.md`. Identifies what changes, where in the file, and what to be aware of. Not a code-level rewrite spec — the session doing the work will read the populator's code as needed for implementation detail. This document is the map.

---

## 1. Populator structure (current)

The populator is a single PowerShell file at `E:\xFACts-PowerShell\Populate-AssetRegistry-HTML.ps1`, dot-sourcing `xFACts-OrchestratorFunctions.ps1` and `xFACts-AssetRegistryFunctions.ps1`. Roughly the sections, in order of appearance:

| # | Section | Purpose |
|---|---|---|
| 1 | `param()` block + dot-source + Initialize-XFActsScript | Standard populator boot |
| 2 | `CONFIGURATION: PATHS AND DISCOVERY` | `$PsScanRoots` list; HTML void element set; `$RecognizedEvents` event closed set |
| 3 | `SPEC CONSTANTS - DRIFT CODE DESCRIPTIONS` | The `$DriftDescriptions` ordered hashtable — every drift code the populator can emit, organized by spec section (15.1 page shell, 15.2 chrome, 15.3 assets, 15.4 IDs, 15.5 classes, 15.6 actions, 15.7 data-*, 15.8 text, 15.9 SVG, 15.10 comments, 15.11 helper-emitted) |
| 4 | `SCRIPT-SCOPE STATE` | Row collection, dedupe set, per-file context fields, known page prefixes set, helper script-scope state |
| 5 | `FILE DISCOVERY` (deferred until after function defs but logically here) | File walk loop with `$FileFilter` support |
| 6 | `REGISTRY LOADS` | Loads Object_Registry, Component_Registry, RBAC_NavRegistry, ProcessRegistry |
| 7 | `HTML TOKENIZER` (`ConvertTo-HtmlTokens` and token-walking helpers) | Token kinds: Doctype, StartTag, EndTag, SelfClose, Comment, Text, PsInterp, Entity; helpers `Find-MatchingClose`, `Find-NextSignificantToken`, `Find-TokenIndex`, `Get-AttributesFromToken`, `Test-AttrTextMatches` |
| 8 | `POWERSHELL AST: HTML EMISSION DISCOVERY` | Finds HTML emissions via three patterns: HereString, StringBuilder, StringLiteral; `Get-HtmlEmissions` is the entry point |
| 9 | `PODE ROUTE DISCOVERY` | Locates `Add-PodeRoute -Path ...` calls; cross-checked against ProcessRegistry by engine card validation |
| 10 | `ROW EMITTERS` | `New-HtmlRow`, `Add-HtmlFileRow`, `Add-HtmlIdRow`, `Add-HtmlDataAttributeRow`, `Add-HtmlEventHandlerRow`, `Add-HtmlTextRow`, `Add-HtmlEntityRow`, `Add-HtmlSvgRow`, `Add-HtmlCommentRow`, plus class/css-link/script USAGE emitters |
| 11 | `ID VALIDATION` | `Get-IdValueDriftCodes`, prefix shape check, chrome ID closed-set check |
| 12 | `OVERLAY PANEL DETECTION` | `Get-OverlayIdInfo` — parses overlay IDs into Kind/Role/Key. Currently handles **pair-based** roles: slideout has `overlay`+`panel`; modal has `overlay`+`dialog`; slideup has `backdrop`+`panel`. **THIS WHOLE FUNCTION CHANGES SHAPE — see §3 below.** |
| 13 | `PAGE SHELL VALIDATION` | `Get-PageShellDrift` — scans tokens for DOCTYPE, `<head>`, CSS refs, `<body>` attrs, `$navHtml`, header bar, banners, script tag. Drift attaches to HTML_FILE row. |
| 14 | `PAGE CHROME VALIDATION` | `Invoke-PageChromeValidation` — validates `cc-header-bar`/`cc-header-right`/`cc-refresh-info` structure. Calls `Test-EngineRowContainer` and `Test-RefreshInfo` subordinates. |
| 15 | `ENGINE CARD VALIDATION` | `Invoke-EngineCardValidation` — finds every `cc-card-engine-*` ID, validates 4-element body structure, cross-references ProcessRegistry. **HAS CLASS NAME MISMATCHES — see §4 below.** |
| 16 | `OVERLAY POST-WALK VALIDATION` | `Invoke-OverlayPostWalkValidation` — runs pair-completeness check + contiguity check on collected overlay constructs. **WHOLE FUNCTION REWRITTEN — see §3 below.** |
| 17 | `PER-FILE WALK` (the main scan loop) | Discovers emissions per file, tokenizes each, calls all validators, walks every token to emit rows for each ID/class/data-attribute/event-handler/text/entity/comment; classifies comments; accumulates overlay constructs for post-walk |
| 18 | `OUTPUT BOUNDARY VALIDATION` | `Test-DriftCodesAgainstMasterTable` — confirms every emitted drift code is in `$DriftDescriptions` |
| 19 | `OCCURRENCE INDEX COMPUTATION` | Per-key occurrence_index assignment |
| 20 | `SUMMARY OUTPUT` + `DATABASE WRITE` | Standard populator tail |

**Total lines: ~5,500.** The bulk is the per-file walk (section 17), the engine card validator (15), and the page chrome validator (14). Token-walking infrastructure is mature and battle-tested.

---

## 2. Drift code reconciliation

The new spec defines 78 drift codes in §14. The populator's current `$DriftDescriptions` defines roughly 90+ codes. Reconciliation falls into three buckets.

### 2.1 Retired codes (remove from `$DriftDescriptions` and all emission sites)

These codes do not appear in the new spec's §14 table:

| Code | Reason for retirement |
|---|---|
| `INCOMPLETE_OVERLAY_PAIR` | Gap 10 nested pattern eliminates the pair concept entirely. Overlay constructs are now single-rooted (outer overlay + nested dialog); there is no pair to be incomplete. |
| `OVERLAY_PANEL_NOT_CONTIGUOUS` | Renamed to `OVERLAY_BLOCK_NON_CONTIGUOUS` per Gap 11's terminology. |
| `MALFORMED_HEADER_BAR_CONTAINER` | Consolidated into `MALFORMED_HEADER_BAR_STRUCTURE` per new spec §14. |
| `MALFORMED_HEADER_BAR_LEFT` | Consolidated into `MALFORMED_HEADER_BAR_STRUCTURE`. |
| `MALFORMED_HEADER_BAR_RIGHT` | Consolidated into `MALFORMED_HEADER_BAR_STRUCTURE`. |
| `MALFORMED_HEADER_RIGHT_CHILDREN` | Consolidated into `MALFORMED_HEADER_BAR_STRUCTURE`. |
| `MALFORMED_REFRESH_INFO_CONTAINER` | Consolidated into `MALFORMED_REFRESH_INFO_STRUCTURE`. |
| `MALFORMED_LIVE_INDICATOR` | Consolidated into `MALFORMED_REFRESH_INFO_STRUCTURE`. |
| `MALFORMED_LIVE_STATUS_LINE` | Consolidated into `MALFORMED_REFRESH_INFO_STRUCTURE`. |
| `MALFORMED_REFRESH_BUTTON` | Consolidated into `MALFORMED_REFRESH_INFO_STRUCTURE`. |
| `MALFORMED_ENGINE_ROW_CONTAINER` | Consolidated into `MALFORMED_ENGINE_ROW_STRUCTURE`. |
| `MALFORMED_ENGINE_ROW_CHILDREN` | Consolidated into `MALFORMED_ENGINE_ROW_STRUCTURE`. |
| `MALFORMED_ENGINE_CARD_ATTRIBUTES` | Consolidated into `MALFORMED_ENGINE_CARD` per new spec. |
| `MALFORMED_ENGINE_LABEL` | Consolidated into `MALFORMED_ENGINE_CARD`. |
| `MALFORMED_ENGINE_BAR` | Consolidated into `MALFORMED_ENGINE_CARD`. |
| `MALFORMED_ENGINE_COUNTDOWN` | Consolidated into `MALFORMED_ENGINE_CARD`. |
| `INLINE_CLASS_CONCATENATION` | Subsumed by new `FORBIDDEN_DYNAMIC_CLASS_PATTERN`. |
| `INLINE_CLASS_PREFIX_MIX` | Subsumed by `FORBIDDEN_DYNAMIC_CLASS_PATTERN`. |
| `INLINE_CLASS_MULTI_INTERPOLATION` | Subsumed by `FORBIDDEN_DYNAMIC_CLASS_PATTERN`. |
| `INLINE_CLASS_BRACED_INTERPOLATION` | Subsumed by `FORBIDDEN_DYNAMIC_CLASS_PATTERN`. |
| `MALFORMED_TEXT_INTERPOLATION` | Renamed `FORBIDDEN_TEXT_INTERPOLATION` per new spec §14. |

### 2.2 Retained codes (no change needed, but verify descriptions align with new spec wording)

These survive the spec rewrite intact:

`MALFORMED_DOCTYPE`, `MALFORMED_HTML_ROOT`, `MALFORMED_HEAD`, `FORBIDDEN_HARDCODED_TITLE`, `MISSING_BODY_SECTION_CLASS`, `MISSING_DATA_CC_PAGE`, `MISSING_DATA_CC_PREFIX`, `MISSING_NAV_SUBSTITUTION`, `MALFORMED_BODY_CLOSE`, `MISSING_HEADER_BAR`, `FORBIDDEN_HARDCODED_PAGE_HEADER`, `DUPLICATE_LAST_UPDATE_ID`, `ENGINE_CARD_PAGE_MISMATCH`, `ENGINE_CARD_ORDER_MISMATCH`, `ENGINE_SLUG_REGISTRY_MISMATCH`, `MISSING_ENGINE_CARD_REGISTRATION`, `MISSING_CONNECTION_BANNER`, `FORBIDDEN_BANNER_CONTENT`, `MISSING_PAGE_ERROR_BANNER`, `FORBIDDEN_PAGE_ERROR_BANNER_CONTENT`, `PAGE_ERROR_BANNER_ORDER_VIOLATION`, `MALFORMED_CSS_LINK`, `MALFORMED_PAGE_CSS_REFERENCE`, `MALFORMED_SHARED_CSS_REFERENCE`, `CSS_REFERENCE_ORDER_VIOLATION`, `UNEXPECTED_CSS_REFERENCE`, `WRONG_SCRIPT_SOURCE`, `MALFORMED_SCRIPT_TAG`, `MISSING_SHARED_SCRIPT_TAG`, `UNEXPECTED_SCRIPT_TAG`, `CHROME_ID_OUTSIDE_CLOSED_SET`, `CHROME_ID_REUSED_AS_LOCAL`, `MISSING_PREFIX_ID`, `CROSS_PAGE_PREFIX_COLLISION`, `MALFORMED_ID_VALUE`, `DUPLICATE_ID_DECLARATION`, `MALFORMED_MODAL_ID`, `MALFORMED_SLIDEOUT_ID`, `MALFORMED_SLIDEUP_ID`, `MISSING_PANEL_PURPOSE_COMMENT`, `MALFORMED_CLASS_VALUE_WHITESPACE`, `MALFORMED_CLASS_NAME`, `DUPLICATE_CLASS_IN_VALUE`, `CLASS_PREFIX_MISMATCH`, `UNKNOWN_EVENT_TYPE`, `MALFORMED_ACTION_VALUE`, `ACTION_PREFIX_MISMATCH`, `UNRESOLVED_DATA_ACTION`, `ORPHANED_ACTION_ARGUMENT`, `ARGUMENT_NAME_COLLIDES_WITH_EVENT`, `MALFORMED_ACTION_ARGUMENT_NAME`, `FORBIDDEN_INLINE_ACTION_ARGUMENT_INTERPOLATION`, `MALFORMED_DATA_ATTRIBUTE_NAME`, `FORBIDDEN_INLINE_DATA_INTERPOLATION`, `EMPTY_DISPLAY_TEXT`, `MALFORMED_COMMENT_DASHES`, `FORBIDDEN_COMMENT_INTERPOLATION`, `MALFORMED_COMMENT_UNCLOSED`, `FORBIDDEN_INLINE_STYLE_BLOCK`, `FORBIDDEN_INLINE_STYLE_ATTRIBUTE`, `FORBIDDEN_INLINE_SCRIPT_BLOCK`, `FORBIDDEN_INLINE_EVENT_HANDLER`, `FORBIDDEN_HELPER_ASSET_REFERENCE`, `FORBIDDEN_HELPER_PAGE_PREFIX_ID`, `FORBIDDEN_HELPER_PAGE_PREFIX_CLASS`, `FORBIDDEN_HELPER_PAGE_ACTION`, `FORBIDDEN_HELPER_PAGE_DATA_ATTRIBUTE`, `FORBIDDEN_HELPER_PAGE_ACTION_ARGUMENT`.

For each: cross-check that the populator's description matches the new spec's §14 description; minor textual realignment may be needed but no logic changes.

### 2.3 New codes (add to `$DriftDescriptions` and add emission sites)

| Code | Spec section | Validator location |
|---|---|---|
| `MISSING_BROWSER_TITLE_VAR` | §1.1 | New check in `Get-PageShellDrift` and/or new validator that inspects the PS AST for `$browserTitle = Get-PageBrowserTitle ...` assignment. See §6 trouble spots — cross-spec validation. |
| `MISSING_NAV_HTML_VAR` | §1.1 | Same — PS AST inspection for `$navHtml = Get-NavBarHtml ...`. |
| `MISSING_HEADER_HTML_VAR` | §2.1 | Same — PS AST inspection for `$headerHtml = Get-PageHeaderHtml ...`. |
| `FORBIDDEN_PAGE_PREFIXED_BODY_CLASS` | §1.1 | New check in `Get-PageShellDrift` after the `<body>` attribute parse: tokenize the class attribute value, verify every class is `cc-section-*` or `cc-*` prefixed (no page-prefixed classes allowed on `<body>`). |
| `MALFORMED_PAGE_SHELL_ORDER` | §1.2 | New file-level validator. Confirms the mandated page-shell elements (nav substitution, header bar, connection banner, page error banner, page-specific content, overlay block, script tag) appear in that order. |
| `MALFORMED_PAGE_SHELL_WHITESPACE` | §1.2.3 | New validator. Walks between adjacent mandated page-shell elements and confirms exactly one blank line between each. **Implementation note:** This requires preserving original whitespace from the here-string text, since the tokenizer collapses Text tokens. May need to inspect the raw emission text directly rather than the token stream. |
| `MALFORMED_ATTRIBUTE_ORDER` | §1.2.4 | New validator. For every mandated structural element (`<body>`, header bar elements, banner elements, overlay outer elements), confirm attributes appear in the order shown in the spec's templates. **Implementation note:** Add to per-element validators (page shell, page chrome, overlay) rather than as a single check. |
| `MALFORMED_MODAL_STRUCTURE` | §5.4 | Existing emitted code, but new requirement: validates that `cc-modal-overlay` contains exactly one direct child `cc-dialog`, which in turn contains the required `cc-dialog-header`/`cc-dialog-body` children. Replaces the prior modal validation that checked for `cc-modal` as the inner element. |
| `MALFORMED_SLIDEOUT_STRUCTURE` | §5.4 | New code. Same shape as `MALFORMED_MODAL_STRUCTURE` but for `cc-slide-overlay`. |
| `MALFORMED_SLIDEUP_STRUCTURE` | §5.4 | New code. Same shape but for `cc-slideup-overlay`. |
| `OVERLAY_BLOCK_NON_CONTIGUOUS` | §5.4 | Renamed from `OVERLAY_PANEL_NOT_CONTIGUOUS`; logic carries forward from `Invoke-OverlayPostWalkValidation`'s contiguity check, but the check now ALSO catches non-purpose-comments inside the block (Gap 11a rule). |
| `ACTION_ON_NON_INTERACTIVE_ELEMENT` | §7.5 | New validator. On every `data-action-<event>` attribute emission, check the parent element's tag name + class attribute. Allow only the interactive elements (`<button>`, `<a href>`, `<input>`, `<select>`, `<textarea>`) plus the three overlay container classes (`cc-modal-overlay`, `cc-slide-overlay`, `cc-slideup-overlay`). |
| `ARGUMENT_PREFIX_MISMATCH` | §7.4 | New validator. On every argument attribute emission, parse the parent element's `data-action-<event>` value to extract its prefix; confirm the argument attribute's name prefix matches. Page-prefix → page-prefix; `cc-` → `cc-`. |
| `UNREGISTERED_PLATFORM_DATA_ATTRIBUTE` | §8 | New validator. On every `data-cc-*` attribute emission, check against the closed set in §13.4 (currently just `data-cc-page` and `data-cc-prefix`). |
| `FORBIDDEN_ROUTE_LOCAL_HELPER` | §11 | New validator. Inspect the PS AST for any function defined inside a route's ScriptBlock that returns a string passing `Test-LooksLikeHtmlEmission`. Emit on the function definition. |
| `HELPER_EMITS_UNREGISTERED_ID` | §5.1, §11.1 | New validator (or extension of existing helper-ID checks). On every helper-emission ID, confirm it matches one of the six chrome ID patterns in §5.1 (`cc-last-update`, `cc-connection-banner`, `cc-page-error-banner`, `cc-card-engine-<slug>`, `cc-engine-bar-<slug>`, `cc-engine-cd-<slug>`). |

---

## 3. Overlay validation — the biggest change

`Invoke-OverlayPostWalkValidation` and `Get-OverlayIdInfo` together implement the pair-based overlay model from the OLD spec. The new spec uses a **nested single-rooted** model. These two functions must be rewritten substantially.

### 3.1 What changes in `Get-OverlayIdInfo`

Currently parses IDs into `OverlayKind` + `OverlayRole` + `OverlayKey`. Role values: `overlay`, `panel`, `backdrop`, `dialog`. Key normalization assumes pair-based IDs (e.g., `bkp-slideout-local-retention-overlay` and `bkp-slideout-local-retention` form a pair under the key `bkp-slideout-local-retention`).

**New shape:**
- Each overlay construct has a single ID on its outermost element. There is no pair, no "role." The ID forms become:
  - Modal: `<prefix>-modal-<purpose>` (single element, no suffix)
  - Slideout: `<prefix>-slideout-<purpose>` (single element, no `-overlay` or `-panel` suffix)
  - Slide-up: `<prefix>-slideup-<purpose>` (single element, no `-backdrop` or `-panel` suffix)
- The function returns `OverlayKind` only — no role, no key. The "key" concept disappears with the pair concept.
- The drift codes `MALFORMED_MODAL_ID`, `MALFORMED_SLIDEOUT_ID`, `MALFORMED_SLIDEUP_ID` retain meaning but now validate the simpler single-form pattern.

### 3.2 What changes in `Invoke-OverlayPostWalkValidation`

Currently does two things: pair completeness, then contiguity.

**New shape:**
- **Pair completeness check is REMOVED.** No pairs in the new model.
- **Contiguity check is RENAMED** to use `OVERLAY_BLOCK_NON_CONTIGUOUS` instead of `OVERLAY_PANEL_NOT_CONTIGUOUS`.
- **Contiguity check is STRENGTHENED:** under Gap 11a, the only things allowed between overlay constructs in the block are formatting whitespace and each construct's preceding purpose comment. Non-purpose comments and section dividers inside the block are drift.
- **Three new structural validators are added** to validate each overlay construct's nested shape:
  - For each `cc-modal-overlay` element, confirm it has exactly one direct child `.cc-dialog`. Confirm the `.cc-dialog` has `.cc-dialog-header` and `.cc-dialog-body` children in order; optionally `.cc-dialog-actions` last. Confirm the `.cc-dialog-header` has exactly one `.cc-dialog-title` and exactly one `.cc-dialog-close`. Drift code: `MALFORMED_MODAL_STRUCTURE`.
  - Same for `cc-slide-overlay`. Drift code: `MALFORMED_SLIDEOUT_STRUCTURE`.
  - Same for `cc-slideup-overlay`. Drift code: `MALFORMED_SLIDEUP_STRUCTURE`.

**These structural validators should be a single helper** (e.g., `Test-OverlayConstructStructure`) parameterized by the outer overlay class, since the three constructs differ only in which outer class anchors them — the inner `.cc-dialog` shape is identical across all three.

### 3.3 What changes in the per-file walk's overlay tracking

Currently, the per-file walk collects "overlay constructs" as the walker encounters IDs that pass `Get-OverlayIdInfo`. Each construct row carries `OverlayKind`, `OverlayRole`, `OverlayKey`, `PurposeCommentText`.

**New shape:**
- Drop `OverlayRole` and `OverlayKey` from the construct collection.
- Each collected construct represents one outer overlay element. The post-walk validator runs the three new structural checks against each.
- Purpose comment association is now 1:1 (one comment per construct), not 1:2. Simpler.

---

## 4. Class and ID name reconciliation (current populator disagrees with spec)

The populator currently checks against several class and ID names that **the new spec does not use.** These need surgical rename.

| Populator currently checks | Spec specifies | Locations to update |
|---|---|---|
| `cc-engine-card` (class) | `cc-card-engine` (class) | `Invoke-EngineCardValidation` — both the discovery scan and the outer-class validation |
| `cc-engine-countdown` (class) | `cc-engine-cd` (class) | `Invoke-EngineCardValidation` — third-child validation block |
| `cc-modal-overlay` + nested `cc-modal` | `cc-modal-overlay` + nested `cc-dialog` | Modal structure validator (currently looks for `cc-modal` as direct child; new spec requires `cc-dialog`) |
| `cc-slide-overlay` + sibling `cc-slide-panel` | `cc-slide-overlay` + nested `cc-dialog` | Slideout structure (currently expects sibling pair; new spec requires nested) |
| `cc-slideup-backdrop` + sibling `cc-slideup-panel` | `cc-slideup-overlay` + nested `cc-dialog` | Slide-up structure (currently expects sibling pair; new spec requires nested AND renamed outer class) |
| Header bar/refresh info/engine row checked for individual class/attribute drift codes | New spec uses consolidated `MALFORMED_HEADER_BAR_STRUCTURE`, `MALFORMED_REFRESH_INFO_STRUCTURE`, `MALFORMED_ENGINE_ROW_STRUCTURE` | `Invoke-PageChromeValidation`, `Test-EngineRowContainer`, and the engine card body validation |

For the inner `.cc-dialog` classes that are entirely new to the populator (`cc-dialog`, `cc-dialog-header`, `cc-dialog-title`, `cc-dialog-close`, `cc-dialog-body`, `cc-dialog-actions`), the populator must add structure-validation logic that looks for these specific class names inside overlay constructs.

---

## 5. New validators needed (functional summary)

For each new spec rule, here's what the validator does, in plain English. The next session will implement these against the existing populator infrastructure.

| Validator name (suggested) | What it checks | Drift code(s) emitted | Where it's called from |
|---|---|---|---|
| `Test-RouteVariableAssignments` | Inspects the PS AST for the three mandated variable assignments (`$browserTitle`, `$navHtml`, `$headerHtml`) inside each route file's ScriptBlock. Each must come from the corresponding `Get-Page*` helper call. | `MISSING_BROWSER_TITLE_VAR`, `MISSING_NAV_HTML_VAR`, `MISSING_HEADER_HTML_VAR` | Per-file walk for Route files; called before the HTML token walk |
| `Test-BodyClassPrefixDiscipline` | After `<body>` attribute parse in `Get-PageShellDrift`, parse the class attribute value and confirm every class token is `cc-section-*` or `cc-*`. No page-prefixed classes allowed. | `FORBIDDEN_PAGE_PREFIXED_BODY_CLASS` | Extension of `Get-PageShellDrift` |
| `Test-PageShellOrder` | Walks the token stream and confirms the mandated structural elements appear in the order shown in §1.2.2. | `MALFORMED_PAGE_SHELL_ORDER` | Per-file walk for Route files; either standalone validator or extension of `Get-PageShellDrift` |
| `Test-PageShellWhitespace` | Inspects the raw emission text for blank-line discipline between mandated page-shell elements. **Reads source text directly, not just tokens.** | `MALFORMED_PAGE_SHELL_WHITESPACE` | Per-file walk for Route files; runs against the emission's `.Text` field |
| `Test-AttributeOrder` | On each mandated structural element, confirms attributes appear in template-shown order. Applied per element where the spec template fixes attribute order. | `MALFORMED_ATTRIBUTE_ORDER` | Sub-check in `Get-PageShellDrift`, `Invoke-PageChromeValidation`, `Invoke-EngineCardValidation`, the new overlay structure validators |
| `Test-OverlayConstructStructure` | For each `cc-modal-overlay` / `cc-slide-overlay` / `cc-slideup-overlay` outer element: confirms exactly one direct `.cc-dialog` child, confirms `.cc-dialog` has the required inner element shape. | `MALFORMED_MODAL_STRUCTURE`, `MALFORMED_SLIDEOUT_STRUCTURE`, `MALFORMED_SLIDEUP_STRUCTURE` | Called from rewritten `Invoke-OverlayPostWalkValidation`, once per collected overlay construct |
| `Test-OverlayBlockContiguity` | Walks the token stream between the first and last overlay construct. Allows only formatting whitespace and purpose comments between constructs. Anything else (HTML elements, non-purpose comments, section dividers) is drift. | `OVERLAY_BLOCK_NON_CONTIGUOUS` | Replaces the contiguity check inside `Invoke-OverlayPostWalkValidation` |
| `Test-ActionElementType` | On every `data-action-<event>` attribute emission, checks the parent element's tag name and class attribute. Permitted: interactive elements (`<button>`, `<a href>`, `<input>`, `<select>`, `<textarea>`) and overlay container classes (`cc-modal-overlay`, `cc-slide-overlay`, `cc-slideup-overlay`). | `ACTION_ON_NON_INTERACTIVE_ELEMENT` | Sub-check inside the per-attribute walk where `data-action-*` is currently processed |
| `Test-ArgumentPrefixMatch` | On every argument attribute emission, parses the parent element's action value to extract its prefix, then confirms the argument attribute's name prefix matches. | `ARGUMENT_PREFIX_MISMATCH` | Sub-check inside the per-attribute walk where argument attributes are currently processed |
| `Test-PlatformDataAttributeClosedSet` | On every `data-cc-*` attribute emission (excluding `data-action-*` which is a separate family), confirms the attribute name is in the §13.4 closed set. Currently the closed set has two entries: `data-cc-page`, `data-cc-prefix`. | `UNREGISTERED_PLATFORM_DATA_ATTRIBUTE` | Sub-check inside the data-attribute walk |
| `Test-RouteLocalHelperFunctions` | Inspects the PS AST for any function defined inside a route's ScriptBlock that returns HTML. | `FORBIDDEN_ROUTE_LOCAL_HELPER` | Per-file walk for Route files; called once per file alongside emission discovery |
| `Test-HelperEmittedChromeId` | On every helper-emitted ID, confirms it matches one of the six chrome ID patterns in §5.1. Existing helper-prefix checks become a sub-case of this validation. | `HELPER_EMITS_UNREGISTERED_ID` | Sub-check inside helper-emission ID processing in `Get-IdValueDriftCodes` or a dedicated helper-emission ID validator |

---

## 6. Trouble spots — things to watch out for

Honest flags. Each of these is something the next session should approach carefully, with extra reading or possibly an inline question to confirm direction.

### 6.1 `MALFORMED_PAGE_SHELL_WHITESPACE` requires raw text inspection

The HTML tokenizer collapses runs of whitespace into Text tokens. Blank-line discipline (exactly one blank line between adjacent mandated page-shell elements) can't be cleanly checked from the token stream alone — the tokenizer has already normalized the whitespace by the time validators run.

**Implementation path:** The validator works on the raw emission text (`.Text` on the emission object) rather than the token stream. It finds the source line range for each mandated page-shell element (from the token's `.LineOffset`), then counts blank lines between them in the raw text. Workable but requires care: line offsets are zero-based and the emission's first line may not be the first line of the raw text if the here-string has interpolations.

**Alternative:** Skip strict whitespace validation. The new spec calls it out as drift, but if implementing it cleanly is too risky, the populator can defer it (and the spec amendment can be considered). I would NOT recommend this — the rule was deliberately added in Gap 2 — but flagging the implementation cost.

### 6.2 `MISSING_*_VAR` codes require PS AST inspection

The three new "variable assignment" checks (`MISSING_BROWSER_TITLE_VAR`, etc.) require inspecting the PowerShell AST of the route file's ScriptBlock to confirm the assignment statements exist with the right shape (`$browserTitle = Get-PageBrowserTitle -PageRoute '<route>'`).

The populator currently does some PS AST work (`Get-PodeRoutes`, `Get-HtmlEmissions`'s string discovery), so the AST infrastructure is in place. But these checks are a step beyond what's currently done — they require finding a specific assignment statement inside a ScriptBlock, parsing its right-hand side as a CommandAst, and confirming the command name and the parameter binding shape.

**Implementation path:** Add to the existing per-route walk. After `Get-PodeRoutes` finds the route's ScriptBlock, walk its assignments and look for the three target variables. This is doable and within the populator's existing AST capability, just new code.

### 6.3 Coordinated changes with `cc-shared.css`

The unified `cc-dialog-*` class family doesn't exist in `cc-shared.css` yet. When the populator's overlay structure validators look for `.cc-dialog`, `.cc-dialog-header`, etc., they will validate against the new spec but **deployed pages will not render correctly** because the CSS classes are not defined.

This is expected per Session_Summary_7 §9.2 (cross-file refactor initiative). The populator validates against the spec; deployed pages are expected to carry drift until the coordinated `cc-shared.css` rewrite lands.

The next session should be aware: **Backup will show known drift after the populator rewrite, specifically on the overlay constructs.** That's expected and documented. The Backup partial rewrite (Path 1) in the same session will fix everything EXCEPT the overlay constructs, because those depend on the cc-shared.css rewrite.

### 6.4 Test plan recommendation

Once the populator rewrite lands, the validation sweep is:

1. Run populator in preview mode against all files. Capture row counts and drift code distribution.
2. Compare against a baseline run with the old populator on the same files. New codes should appear; retired codes should not.
3. Run targeted on Backup specifically and Admin (post-refactor) and confirm the drift codes that fire match the expected Category-A vs. cross-file-refactor split.
4. Run on `xFACts-CCShared.psm1` (the helper module) and confirm helper-specific drift codes fire correctly with the new ID closed-set rule.

---

## 7. Recommended sequence of changes (for next session)

A logical order that minimizes back-and-forth between sections of the populator:

1. **Update `$DriftDescriptions`.** Remove retired codes; add new codes; verify retained codes' descriptions align with new spec §14. This is mechanical and fast. **Do this first.**

2. **Update class/ID name constants.** Rename `cc-engine-card` → `cc-card-engine` and `cc-engine-countdown` → `cc-engine-cd` throughout the engine card validator. (Search for exact string occurrences; both class names and any references to them in drift context strings need updating.)

3. **Rewrite `Get-OverlayIdInfo`.** Simplify to return `OverlayKind` only. Remove `OverlayRole`, `OverlayKey`, and the pair-based parsing logic.

4. **Rewrite `Invoke-OverlayPostWalkValidation`.** Remove pair completeness; rename contiguity drift code; add the three structural validators (modal, slideout, slide-up).

5. **Add new validators** in approximate order of complexity:
   - `Test-PlatformDataAttributeClosedSet` (small, sub-check inside existing walk)
   - `Test-ArgumentPrefixMatch` (small, sub-check inside existing walk)
   - `Test-ActionElementType` (medium, sub-check requires parent element context)
   - `Test-BodyClassPrefixDiscipline` (small, extension of existing `<body>` parse)
   - `Test-HelperEmittedChromeId` (small, extension of existing helper-ID logic)
   - `Test-AttributeOrder` (medium, added to multiple existing validators)
   - `Test-PageShellOrder` (medium, single-pass structural check)
   - `Test-OverlayBlockContiguity` (medium, partial reuse of existing contiguity check)
   - `Test-OverlayConstructStructure` (large, new structural walker)
   - `Test-RouteVariableAssignments` (large, PS AST inspection)
   - `Test-RouteLocalHelperFunctions` (large, PS AST inspection)
   - `Test-PageShellWhitespace` (large, raw text inspection)

6. **Run preview-mode tests** per §6.4.

7. **Deliver the rewritten populator** as a full file replacement in `/mnt/user-data/outputs/`.

8. **Move on to Backup partial rewrite (Path 1)** in the same session if context allows.

---

## 8. Files to fetch at next session start

The next session should retrieve:

- **Current `Populate-AssetRegistry-HTML.ps1`** from the GitHub manifest (cache-busted URL). The version in Project Knowledge should be current.
- **The new `CC_HTML_Spec.md`** (committed to repo before next session).
- **This alignment plan** (`CC_HTML_Populator_Alignment_Plan.md`).
- **`Backup.ps1`** from the GitHub manifest, for the Path 1 partial rewrite step that follows.
- **`xFACts-AssetRegistryFunctions.ps1`** to confirm no shared infrastructure changes are needed for the new validators.

The session does NOT need to re-fetch the OLD spec or any other historical reference. The new spec is authoritative.

---

## 9. Resolved decisions to apply during the rewrite

These were decided in the session that produced this plan. Apply during the rewrite without re-litigation.

### 9.1 The HTML populator owns the variable-assignment check

The three `MISSING_*_VAR` codes (browser title, nav HTML, header HTML) are emitted by the HTML populator via PS AST inspection of route file ScriptBlocks. The PS populator does not duplicate this check. No shared helper in `xFACts-AssetRegistryFunctions.ps1` is needed. Standard PS AST walking via the existing infrastructure used by `Get-PodeRoutes` and `Get-HtmlEmissions`.

### 9.2 No spec references in source files. ASCII only.

This applies to the populator rewrite and to every other source file in the xFACts platform. Two parts:

**Remove all spec section references from code comments.** The populator currently contains many `Per CC_HTML_Spec.md Section X.Y` style references. Strip them all. Comments stay focused on what the code does and why; spec authority is implicit, not narrated. The principle: comments describe the code, not the spec.

**Remove all non-ASCII characters from source files.** Specifically the section symbol `§`. The `§` character is multi-byte UTF-8 (`C2 A7`), and its presence in a script causes GitHub to treat the file as binary instead of text — at which point the file becomes non-fetchable via `web_fetch` and `raw.githubusercontent.com`. This is an operational failure mode, not a stylistic preference. The session producing this plan confirmed multiple prior sweeps were required to replace `§` with the word "Section" in scripts that had drifted into containing it. Going forward: scripts and any other source files (`.ps1`, `.psm1`, `.js`, `.css`, `.html`, the source HTML inside `.ps1` here-strings) are ASCII-only.

Working documentation (`.md` files) is exempt; `§` is acceptable there. The constraint is on executable source.

### 9.3 Engine card registry-validation codes stay in the populator

`ENGINE_SLUG_REGISTRY_MISMATCH` and `MISSING_ENGINE_CARD_REGISTRATION` are retained drift codes (added to spec §14 via amendment). The populator continues to emit them; they validate registry data integrity that the new spec §2.3 implies but didn't previously codify.

### 9.4 Script tag count codes stay in the populator

`MISSING_SHARED_SCRIPT_TAG` and `UNEXPECTED_SCRIPT_TAG` are retained drift codes (added to spec §14 via amendment). The populator continues to emit them; they validate "exactly one script tag" per spec §3.2.

### 9.5 `MALFORMED_PAGE_SHELL_WHITESPACE` is implemented as planned

The blank-line discipline rule from Gap 2 is enforced. The validator works on raw emission text (the `.Text` field on emission objects), not the collapsed token stream. The three implementation risks (PS interpolation, mixed line endings, multi-chunk emissions) are addressed at implementation time with care; the rule is not relaxed or deferred.

---

## 10. Platform-wide implications worth tracking

These came up during the resolution discussions but are out of scope for the immediate next session's work. Logged here so they survive to the right future session.

### 10.1 `xFACts_Development_Guidelines.md` needs the ASCII-only and no-spec-reference rules formalized

The two rules from §9.2 (no spec references in source files; ASCII only) should be codified in the platform's Development Guidelines so they propagate to anyone working in the platform — Claude or otherwise. The guidelines are the right home for platform-wide rules of this kind. Future work item, not part of next session's populator rewrite.

### 10.2 Other populators likely need cleanup passes

`Populate-AssetRegistry-CSS.ps1`, `Populate-AssetRegistry-JS.ps1`, and `Populate-AssetRegistry-PS.ps1` likely contain `§` symbols and spec-section comment references. Not a forced sweep; cleaned up the next time each file is touched for substantive work.

### 10.3 The four spec amendments from this session

Recap for the spec changelog / session summary: §14 added `ENGINE_SLUG_REGISTRY_MISMATCH`, `MISSING_ENGINE_CARD_REGISTRATION`, `MISSING_SHARED_SCRIPT_TAG`, `UNEXPECTED_SCRIPT_TAG`. All four resolve drift conditions the populator already detects and that align with spec sections (§2.3 and §3.2) that previously didn't enumerate them in the drift table.

---

## 11. What this plan deliberately does NOT cover

Out of scope:

- **Detailed code-level rewrites.** This plan identifies sections that need rewriting; the next session reads the code as needed and writes the new version. Plan tells you where; code tells you what.
- **Per-row test cases.** Validation testing happens after the rewrite via §6.6's recommended sweep, not by enumerating expected rows here.
- **CSS or JS populator alignment.** Those populators do not need updating from this spec change (the spec is HTML-only; chrome class additions in §13.2 will be addressed by `cc-shared.css` work in the cross-file refactor initiative, not by populator changes).
- **`Backup.ps1` Path 1 rewrite details.** Covered by the next session's third deliverable, not this plan.
