<#
.SYNOPSIS
    Control Center page route for the guided BDL Import wizard.

.DESCRIPTION
    Registers the GET /bdl-import page route. Renders the five-step BDL Import
    wizard shell (environment, file upload, entity selection, map and validate,
    execute) with its right-column step guide, mapping-template panel, and
    import-history panel, plus the page's overlay constructs. All interactive
    behavior is supplied by the page JavaScript loaded via the cc-shared.js
    bootloader; this route emits only the static shell and chrome.

.COMPONENT
    Tools.BDLImport

.NOTES
    File Name : BDLImport.ps1
    Location  : E:\xFACts-ControlCenter\scripts\routes\BDLImport.ps1

    FILE ORGANIZATION
    -----------------
    CHANGELOG: CHANGE HISTORY
    ROUTE: PAGE PATH
#>

<# ============================================================================
   CHANGELOG: CHANGE HISTORY
   ----------------------------------------------------------------------------
   Dated change history for this route file, most-recent first.
   Prefix: (none)
   ============================================================================ #>

# 2026-06-05  Migrated to the CC file-format spec. Adopted the cc-shared
#             bootloader shell: cc-header-bar, cc-refresh-info, the chrome
#             banner substitution, and the body data attributes for the
#             tools section. Converted interactive markup to data-action
#             attributes and moved presentational state to page-local classes.
#             Admin gating is now fully server-side. The template preview,
#             save-template, production advisory, alignment, and promote
#             advisory overlays are static cc- overlay constructs in a
#             contiguous overlay block.
# 2026-04-29  Phase 3d of dynamic nav: replaced hardcoded nav block with
#             Get-NavBarHtml helper. Page header and browser title render from
#             RBAC_NavRegistry via Get-PageHeaderHtml and Get-PageBrowserTitle.
# 2026-04-16  Added Import History panel to right column below templates.
#             History panel renders active rows plus a year/month/day accordion
#             and polls /api/bdl-import/history on the configured interval.
# 2026-04-08  Consolidated to the 5-step wizard with step swap and multi-select.
#             Steps 4 and 5 merged into Map and Validate with a per-entity loop.
#             Step 5 (Execute) uses a tabbed per-entity summary.
# 2026-04-06  Replaced native alert and confirm dialogs with shared styled
#             modals. Added the Promote to Production flow with a cooldown timer.
# 2026-04-04  Simplified the guide panel by removing step circles and the
#             compact toggle.

<# ============================================================================
   ROUTE: PAGE PATH
   ----------------------------------------------------------------------------
   Registers the GET /bdl-import page route. Resolves access, composes the nav,
   header, and banner chrome, and emits the wizard shell HTML.
   Prefix: (none)
   ============================================================================ #>

Add-PodeRoute -Method Get -Path '/bdl-import' -Authentication 'ADLogin' -ScriptBlock {
    Import-Module -Name "E:\xFACts-ControlCenter\scripts\modules\xFACts-CCShared.psm1" -Force -DisableNameChecking
    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/bdl-import') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent
    $navHtml      = Get-NavBarHtml       -UserContext $ctx -CurrentPageRoute '/bdl-import'
    $headerHtml   = Get-PageHeaderHtml    -PageRoute '/bdl-import'
    $browserTitle = Get-PageBrowserTitle  -PageRoute '/bdl-import'
    $bannerHtml   = Get-ChromeBannersHtml

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>$browserTitle</title>

    <link rel="stylesheet" href="/css/bdl-import.css">

    <link rel="stylesheet" href="/css/cc-shared.css">
</head>

<body class="cc-section-tools" data-cc-page="bdl-import" data-cc-prefix="bdl">
$navHtml

    <div class="cc-header-bar">
        <div>
            $headerHtml
        </div>
        <div class="cc-header-right">
            <div class="cc-refresh-info">
                <span class="cc-live-indicator"></span>
                <span>Live</span> | Updated: <span id="cc-last-update" class="cc-last-updated">-</span>
                <button class="cc-page-refresh-btn" data-action-click="cc-page-refresh" title="Refresh all data">&#8635;</button>
            </div>
        </div>
    </div>

    $bannerHtml

    <div id="bdl-connection-error" class="bdl-connection-error bdl-hidden"></div>

    <div class="bdl-layout">

        <div class="bdl-main">

            <div class="bdl-stepper">
                <div class="bdl-env-badge bdl-hidden" id="bdl-env-badge"></div>
                <button type="button" class="bdl-step bdl-active" id="bdl-step-ind-1" data-action-click="bdl-step-goto" data-action-bdl-step="1">
                    <div class="bdl-step-number" id="bdl-step-num-1">1</div>
                    <div class="bdl-step-label" id="bdl-step-label-1">Environment</div>
                </button>
                <div class="bdl-step-connector" id="bdl-conn-1"></div>
                <button type="button" class="bdl-step" id="bdl-step-ind-2" data-action-click="bdl-step-goto" data-action-bdl-step="2">
                    <div class="bdl-step-number" id="bdl-step-num-2">2</div>
                    <div class="bdl-step-label" id="bdl-step-label-2">Upload File</div>
                </button>
                <div class="bdl-step-connector" id="bdl-conn-2"></div>
                <button type="button" class="bdl-step" id="bdl-step-ind-3" data-action-click="bdl-step-goto" data-action-bdl-step="3">
                    <div class="bdl-step-number" id="bdl-step-num-3">3</div>
                    <div class="bdl-step-label" id="bdl-step-label-3">Select Entities</div>
                </button>
                <div class="bdl-step-connector" id="bdl-conn-3"></div>
                <button type="button" class="bdl-step" id="bdl-step-ind-4" data-action-click="bdl-step-goto" data-action-bdl-step="4">
                    <div class="bdl-step-number" id="bdl-step-num-4">4</div>
                    <div class="bdl-step-label" id="bdl-step-label-4">Map &amp; Validate</div>
                </button>
                <div class="bdl-step-connector" id="bdl-conn-4"></div>
                <button type="button" class="bdl-step" id="bdl-step-ind-5" data-action-click="bdl-step-goto" data-action-bdl-step="5">
                    <div class="bdl-step-number" id="bdl-step-num-5">5</div>
                    <div class="bdl-step-label" id="bdl-step-label-5">Execute</div>
                </button>
            </div>

            <div class="bdl-step-panel bdl-active" id="bdl-panel-1">
                <div class="bdl-step-content">
                    <div class="bdl-env-cards" id="bdl-env-cards">
                        <div class="bdl-loading">Loading environments...</div>
                    </div>
                </div>
            </div>

            <div class="bdl-step-panel" id="bdl-panel-2">
                <div class="bdl-step-content">
                    <div class="bdl-upload-zone" id="bdl-upload-zone">
                        <div class="bdl-upload-prompt" id="bdl-upload-prompt">
                            <div class="bdl-upload-icon">&#128196;</div>
                            <div class="bdl-upload-text">Drag &amp; drop a CSV or Excel file here</div>
                            <div class="bdl-upload-or">or</div>
                            <label class="bdl-upload-btn">
                                Browse Files
                                <input type="file" id="bdl-file-input" class="bdl-hidden" accept=".csv,.txt,.xlsx,.xls" data-action-change="bdl-file-selected">
                            </label>
                            <div class="bdl-upload-formats">Accepted formats: .csv, .txt, .xlsx, .xls</div>
                        </div>
                        <div id="bdl-file-preview" class="bdl-file-preview bdl-hidden">
                            <div class="bdl-file-info" id="bdl-file-info"></div>
                            <div class="bdl-preview-table-wrap">
                                <table class="bdl-preview-table" id="bdl-preview-table"></table>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="bdl-step-panel" id="bdl-panel-3">
                <div class="bdl-step-content">
                    <div class="bdl-entity-select-banner" id="bdl-entity-select-banner">
                        <span class="bdl-entity-banner-text">Click entity types to select them for import. You can select multiple.</span>
                        <span class="bdl-entity-banner-count" id="bdl-entity-select-count"></span>
                    </div>
                    <div id="bdl-entity-grid">
                        <div class="bdl-loading">Loading entity types...</div>
                    </div>
                </div>
            </div>

            <div class="bdl-step-panel" id="bdl-panel-4">
                <div class="bdl-step-content">
                    <div id="bdl-map-validate-area">
                        <div class="bdl-placeholder-message">Complete previous steps to begin.</div>
                    </div>
                </div>
            </div>

            <div class="bdl-step-panel" id="bdl-panel-5">
                <div class="bdl-step-content">
                    <div id="bdl-execute-area">
                        <div class="bdl-placeholder-message">Complete mapping and validation to review and execute.</div>
                    </div>
                </div>
            </div>

            <div class="bdl-step-nav">
                <button type="button" class="bdl-nav-btn" id="bdl-btn-back" data-action-click="bdl-step-back" disabled>&#8592; Back</button>
                <button type="button" class="bdl-nav-btn bdl-btn-next" id="bdl-btn-next" data-action-click="bdl-step-next" disabled>Next &#8594;</button>
            </div>
        </div>

        <div class="bdl-guide" id="bdl-guide">
            <div class="bdl-guide-tip-panel" id="bdl-guide-content">
                <div class="bdl-guide-text" id="bdl-guide-text-1">
                    <h4>Select Target Environment</h4>
                    <p>Click an environment card to choose where this import will be processed. The environment controls which DM server receives the file and handles the API calls.</p>
                    <p>A color-coded badge will appear in the stepper bar as a reminder of your target environment throughout the wizard.</p>
                    <p class="bdl-guide-tip">Always test new file layouts on TEST first. You can promote a successful test import to PROD from Step 5 without re-running the wizard.</p>
                </div>
                <div class="bdl-guide-text bdl-hidden" id="bdl-guide-text-2">
                    <h4>Upload Data File</h4>
                    <p>Drag a file into the upload area or click Browse. Accepted formats: CSV, TXT, XLSX, XLS. The file is parsed in your browser &mdash; nothing is uploaded yet.</p>
                    <p>The first row must be column headers. A preview grid will show the first several rows so you can verify the file loaded correctly. Excel date columns are automatically formatted.</p>
                    <p class="bdl-guide-tip">Recommended limit: ~250,000 rows per import. For Excel files, the first sheet is used.</p>
                </div>
                <div class="bdl-guide-text bdl-hidden" id="bdl-guide-text-3">
                    <h4>Select Entity Types</h4>
                    <p>Click one or more entity cards to select what you want to import. Cards are grouped by Consumer, Account, and Other. Click the <strong>i</strong> icon on any card to preview its available fields.</p>
                    <p>Selecting multiple entities means each will get its own mapping and validation cycle in Step 4, processed one at a time.</p>
                    <p class="bdl-guide-tip">Your department determines which entities and fields are available. If something is missing, contact the Applications team.</p>
                </div>
                <div class="bdl-guide-text bdl-hidden" id="bdl-guide-text-4">
                    <h4>Map &amp; Validate</h4>
                    <p><strong>Identifier first:</strong> Select which file column contains the DM consumer or account number. Mapping is disabled until this is set.</p>
                    <p><strong>Mapping:</strong> Drag source columns onto BDL fields, or click to pair them. Some fields support a mode toggle (File / Blanket / Conditional) for flexible value assignment. Tag entities use assignment cards instead of drag-and-drop.</p>
                    <p><strong>Validation:</strong> Click <em>Validate</em> to check your data. Fix required empty fields (fill or skip) and invalid lookup values (replace or skip). The system re-validates automatically after each action.</p>
                    <p class="bdl-guide-tip">All mappings and assignments are preserved on back navigation. Changed mappings trigger automatic re-staging on the next validate.</p>
                </div>
                <div class="bdl-guide-text bdl-hidden" id="bdl-guide-text-5">
                    <h4>Review &amp; Execute</h4>
                    <p>Review the summary for each entity tab: environment, row counts, mapped fields, and nullified fields. Use <em>Preview XML</em> to inspect the exact output before submitting.</p>
                    <p>Optionally enter a <strong>Jira ticket</strong> to create a consolidated AR log linking all imported records to the ticket.</p>
                    <p>Click <strong>Submit All</strong> to execute. Each entity is submitted independently &mdash; one failure does not block the others. Results appear in the unified results pane below.</p>
                    <p class="bdl-guide-tip">After a successful TEST or STAGE import, a Promote to Production option appears with a cooldown timer.</p>
                </div>
            </div>
            <div class="bdl-template-section" id="bdl-template-section">
                <div class="bdl-template-header">Mapping Templates</div>
                <div class="bdl-template-list" id="bdl-template-list">
                    <div class="bdl-template-empty">Select an entity type to see available templates.</div>
                </div>
                <div class="bdl-template-save-area bdl-hidden" id="bdl-template-save-area">
                    <button class="bdl-template-save-btn" data-action-click="bdl-show-save-template">Save Current Mapping as Template</button>
                </div>
            </div>

            <div class="bdl-history-section" id="bdl-history-section">
                <div class="bdl-history-header">
                    <div class="bdl-history-title-row">
                        <span class="bdl-history-title">Import History</span>
                        <span class="bdl-history-live-indicator bdl-hidden" id="bdl-history-live-indicator" title="Polling live - active imports in flight"></span>
                        <span class="bdl-history-last-updated" id="bdl-history-last-updated"></span>
                        <button class="bdl-history-refresh-btn" id="bdl-history-refresh-btn" data-action-click="bdl-refresh-history" title="Refresh now">&#8635;</button>
                    </div>
                    <div class="bdl-history-filter-row">
                        <div class="bdl-history-env-chips" id="bdl-history-env-chips">
                            <button type="button" class="bdl-history-chip bdl-history-chip-active" data-bdl-env="ALL" data-action-click="bdl-history-env-filter" data-action-bdl-env="ALL">All</button>
                        </div>
                        <div class="bdl-history-user-toggle" id="bdl-history-user-toggle">
                            <button type="button" class="bdl-history-toggle-btn bdl-history-toggle-active" data-scope="me" data-action-click="bdl-history-user-scope" data-action-bdl-scope="me">Mine</button>
                            <button type="button" class="bdl-history-toggle-btn" data-scope="all" data-action-click="bdl-history-user-scope" data-action-bdl-scope="all">All Users</button>
                        </div>
                    </div>
                </div>
                <div class="bdl-history-body">
                    <div class="bdl-history-active-section" id="bdl-history-active-section">
                        <div class="bdl-history-empty">Loading history...</div>
                    </div>
                    <div class="bdl-history-tree" id="bdl-history-tree"></div>
                </div>
            </div>
        </div>

    </div>

    <!-- Purpose: template preview slideout showing a saved template's column mappings -->
    <div id="bdl-slideout-template-preview" class="cc-slide-overlay" data-action-click="bdl-template-preview-close">
        <div class="cc-dialog cc-dialog-slide">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title" id="bdl-template-preview-title">Template Preview</h3>
                <button class="cc-dialog-close" data-action-click="bdl-template-preview-close">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bdl-template-preview-body"></div>
        </div>
    </div>

    <!-- Purpose: save-current-mapping-as-template modal -->
    <div id="bdl-modal-save-template" class="cc-modal-overlay cc-hidden" data-action-click="bdl-save-template-close">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Save Mapping Template</h3>
                <button class="cc-dialog-close" data-action-click="bdl-save-template-close">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <div class="bdl-template-modal-field">
                    <label class="bdl-template-modal-label" for="bdl-save-template-name">Template Name</label>
                    <input type="text" id="bdl-save-template-name" class="bdl-template-modal-input" placeholder="e.g., Acme Phone Export" maxlength="100">
                </div>
                <div class="bdl-template-modal-field">
                    <label class="bdl-template-modal-label" for="bdl-save-template-desc">Description <span class="bdl-template-optional">(optional)</span></label>
                    <textarea id="bdl-save-template-desc" class="bdl-template-modal-textarea" placeholder="Brief description of this file layout..." maxlength="500" rows="3"></textarea>
                </div>
                <div class="bdl-template-modal-preview" id="bdl-save-template-preview"></div>
                <div class="bdl-template-modal-status bdl-hidden" id="bdl-save-template-status"></div>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="bdl-save-template-close">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="bdl-save-template">Save Template</button>
            </div>
        </div>
    </div>

    <!-- Purpose: advisory shown when the user targets Production directly from Step 1 -->
    <div id="bdl-modal-prod-advisory" class="cc-modal-overlay cc-hidden" data-action-click="bdl-prod-advisory-back">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Production Environment</h3>
                <button class="cc-dialog-close" data-action-click="bdl-prod-advisory-back">&times;</button>
            </div>
            <div class="cc-dialog-body">
                <p class="cc-dialog-paragraph">You are about to target <strong class="cc-dialog-strong">Production</strong> directly.</p>
                <p class="cc-dialog-paragraph cc-last">If you haven't validated this data in a test environment first, consider running a test import on TEST or STAGE before loading to Production.</p>
            </div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="bdl-prod-advisory-back">Go Back</button>
                <button class="cc-dialog-btn-primary" data-action-click="bdl-prod-advisory-continue">Continue to Production</button>
            </div>
        </div>
    </div>

    <!-- Purpose: row-count alignment modal for multi-entity imports -->
    <div id="bdl-modal-alignment" class="cc-modal-overlay cc-hidden" data-action-click="bdl-alignment-close">
        <div class="cc-dialog cc-dialog-modal cc-medium">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Align Row Counts</h3>
                <button class="cc-dialog-close" data-action-click="bdl-alignment-close">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bdl-alignment-body"></div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="bdl-alignment-close">Cancel</button>
                <button class="cc-dialog-btn-primary" data-action-click="bdl-alignment-apply">Apply</button>
            </div>
        </div>
    </div>

    <!-- Purpose: advisory shown before promoting a test import to Production -->
    <div id="bdl-modal-promote-advisory" class="cc-modal-overlay cc-hidden" data-action-click="bdl-promote-advisory-back">
        <div class="cc-dialog cc-dialog-modal">
            <div class="cc-dialog-header">
                <h3 class="cc-dialog-title">Promote to Production</h3>
                <button class="cc-dialog-close" data-action-click="bdl-promote-advisory-back">&times;</button>
            </div>
            <div class="cc-dialog-body" id="bdl-promote-advisory-body"></div>
            <div class="cc-dialog-actions">
                <button class="cc-dialog-btn-cancel" data-action-click="bdl-promote-advisory-back">Cancel</button>
                <button class="cc-dialog-btn-primary cc-dialog-btn-danger" data-action-click="bdl-promote-advisory-go">Promote to Production</button>
            </div>
        </div>
    </div>

    <script src="/js/xlsx.full.min.js"></script>

    <script src="/js/cc-shared.js"></script>
</body>
</html>
"@

    Write-PodeHtmlResponse -Value $html
}