# ============================================================================
# xFACts Control Center - BDL Import Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BDLImport.ps1
# 
# Guided BDL Import workflow (5 steps):
#   1. Environment  2. Upload File  3. Select Entities (multi-select)
#   4. Map & Validate (per-entity loop)  5. Execute (tabbed summary)
#
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)
#
# CHANGELOG
# ---------
# 2026-04-16  Added Import History panel to right column (below templates)
#             Adjusted column widths: main 65→55, guide 35→45
#             History panel renders active rows + Y/M/D accordion, polls
#             /api/bdl-import/history on configured interval
# 2026-04-08  Consolidated to 5-step wizard with step swap and multi-select
#             Steps 4/5 merged into Map & Validate with per-entity loop
#             Step 5 (Execute) uses tabbed per-entity summary
# 2026-04-06  Replaced all native alert/confirm dialogs with shared styled modals
#             Added Promote to Production flow with cooldown timer
# 2026-04-04  Simplified guide panel — removed step circles and compact toggle
# ============================================================================

Add-PodeRoute -Method Get -Path '/bdl-import' -Authentication 'ADLogin' -ScriptBlock {

    $access = Get-UserAccess -WebEvent $WebEvent -PageRoute '/bdl-import'
    if (-not $access.HasAccess) {
        Write-PodeHtmlResponse -Value (Get-AccessDeniedHtml -DisplayName $access.DisplayName -PageRoute '/bdl-import') -StatusCode 403
        return
    }

    $ctx = Get-UserContext -WebEvent $WebEvent

    $adminGear = if ($ctx.IsAdmin) {
        '<span class="nav-spacer"></span><a href="/admin" class="nav-link nav-admin" title="Administration">&#9881;</a>'
    } else { '' }

    $navHtml = if ($access.IsDeptOnly) {
        @"
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/bdl-import" class="nav-link active">BDL Import</a>
    </nav>
"@
    } else {
        @"
    <nav class="nav-bar">
        <a href="/" class="nav-link">Home</a>
        <a href="/server-health" class="nav-link">Server Health</a>
        <a href="/jobflow-monitoring" class="nav-link">Job/Flow Monitoring</a>
        <a href="/batch-monitoring" class="nav-link">Batch Monitoring</a>
        <a href="/backup" class="nav-link">Backup Monitoring</a>
        <a href="/index-maintenance" class="nav-link">Index Maintenance</a>
        <a href="/dbcc-operations" class="nav-link">DBCC Operations</a>
        <a href="/bidata-monitoring" class="nav-link">BIDATA Monitoring</a>
        <a href="/file-monitoring" class="nav-link">File Monitoring</a>
        <a href="/replication-monitoring" class="nav-link">Replication Monitoring</a>
        <a href="/jboss-monitoring" class="nav-link">JBoss Monitoring</a>
        <a href="/dm-operations" class="nav-link">DM Operations</a>
        <span class="nav-separator">|</span>
        <a href="/departmental/business-services" class="nav-link">Business Services</a>
        <a href="/departmental/business-intelligence" class="nav-link">Business Intelligence</a>
        <a href="/departmental/client-relations" class="nav-link">Client Relations</a>
    </nav>
"@
    }

    $navHtml = $navHtml.Replace('</nav>', "$adminGear</nav>")

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>BDL Import - xFACts Control Center</title>
    <link rel="stylesheet" href="/css/bdl-import.css">
    <link rel="stylesheet" href="/css/engine-events.css">
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1><a href="/docs/pages/guides/bdl-import-guide.html" target="_blank">BDL Import</a></h1>
            <p class="page-subtitle">Guided bulk data load import into Debt Manager</p>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- TWO-COLUMN LAYOUT                                                -->
    <!-- ================================================================ -->
    <div class="bdl-layout">
        
        <!-- LEFT COLUMN: Stepper + Action Panels -->
        <div class="bdl-main">
            
            <!-- STEPPER BAR (5 steps) -->
            <div class="stepper">
                <div class="env-badge hidden" id="env-badge"></div>
                <div class="step active" id="step-ind-1" onclick="BDL.goToStep(1)">
                    <div class="step-number" id="step-num-1">1</div>
                    <div class="step-label">Environment</div>
                </div>
                <div class="step-connector" id="conn-1"></div>
                <div class="step" id="step-ind-2" onclick="BDL.goToStep(2)">
                    <div class="step-number" id="step-num-2">2</div>
                    <div class="step-label">Upload File</div>
                </div>
                <div class="step-connector" id="conn-2"></div>
                <div class="step" id="step-ind-3" onclick="BDL.goToStep(3)">
                    <div class="step-number" id="step-num-3">3</div>
                    <div class="step-label">Select Entities</div>
                </div>
                <div class="step-connector" id="conn-3"></div>
                <div class="step" id="step-ind-4" onclick="BDL.goToStep(4)">
                    <div class="step-number" id="step-num-4">4</div>
                    <div class="step-label">Map &amp; Validate</div>
                </div>
                <div class="step-connector" id="conn-4"></div>
                <div class="step" id="step-ind-5" onclick="BDL.goToStep(5)">
                    <div class="step-number" id="step-num-5">5</div>
                    <div class="step-label">Execute</div>
                </div>
            </div>
            
            <!-- STEP 1: Environment Selection -->
            <div class="step-panel active" id="panel-1">
                <div class="step-content">
                    <div class="env-cards" id="env-cards">
                        <div class="loading">Loading environments...</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 2: File Upload -->
            <div class="step-panel" id="panel-2">
                <div class="step-content">
                    <div class="upload-zone" id="upload-zone" 
                         ondragover="BDL.dragOver(event)" 
                         ondragleave="BDL.dragLeave(event)" 
                         ondrop="BDL.fileDrop(event)">
                        <div class="upload-prompt" id="upload-prompt">
                            <div class="upload-icon">&#128196;</div>
                            <div class="upload-text">Drag &amp; drop a CSV or Excel file here</div>
                            <div class="upload-or">or</div>
                            <label class="upload-btn">
                                Browse Files
                                <input type="file" id="file-input" accept=".csv,.txt,.xlsx,.xls" onchange="BDL.fileSelected(this)" hidden>
                            </label>
                            <div class="upload-formats">Accepted formats: .csv, .txt, .xlsx, .xls</div>
                        </div>
                        <div id="file-preview" class="file-preview hidden">
                            <div class="file-info" id="file-info"></div>
                            <div class="preview-table-wrap">
                                <table class="preview-table" id="preview-table"></table>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 3: Entity Type Selection (Multi-Select) -->
            <div class="step-panel" id="panel-3">
                <div class="step-content">
                    <div class="entity-select-banner" id="entity-select-banner">
                        <span class="entity-banner-text">Click entity types to select them for import. You can select multiple.</span>
                        <span class="entity-banner-count" id="entity-select-count"></span>
                    </div>
                    <div class="entity-grid" id="entity-grid">
                        <div class="loading">Loading entity types...</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 4: Map & Validate (per-entity loop) -->
            <div class="step-panel" id="panel-4">
                <div class="step-content">
                    <div id="map-validate-area">
                        <div class="placeholder-message">Complete previous steps to begin.</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 5: Execute (tabbed per-entity summary) -->
            <div class="step-panel" id="panel-5">
                <div class="step-content">
                    <div id="execute-area">
                        <div class="placeholder-message">Complete mapping and validation to review and execute.</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP NAVIGATION -->
            <div class="step-nav">
                <button class="nav-btn btn-back" id="btn-back" onclick="BDL.prevStep()" disabled>&#8592; Back</button>
                <button class="nav-btn btn-next" id="btn-next" onclick="BDL.nextStep()" disabled>Next &#8594;</button>
            </div>
        </div>
        
        <!-- RIGHT COLUMN: Step Guide + Templates + Import History -->
        <div class="bdl-guide" id="bdl-guide">
            <div class="guide-tip-panel" id="guide-content">
                <div class="guide-text" id="guide-text-1">
                    <h4>Select Target Environment</h4>
                    <p>Click an environment card to choose where this import will be processed. The environment controls which DM server receives the file and handles the API calls.</p>
                    <p>A color-coded badge will appear in the stepper bar as a reminder of your target environment throughout the wizard.</p>
                    <p class="guide-tip">Always test new file layouts on TEST first. You can promote a successful test import to PROD from Step 5 without re-running the wizard.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-2">
                    <h4>Upload Data File</h4>
                    <p>Drag a file into the upload area or click Browse. Accepted formats: CSV, TXT, XLSX, XLS. The file is parsed in your browser &mdash; nothing is uploaded yet.</p>
                    <p>The first row must be column headers. A preview grid will show the first several rows so you can verify the file loaded correctly. Excel date columns are automatically formatted.</p>
                    <p class="guide-tip">Recommended limit: ~250,000 rows per import. For Excel files, the first sheet is used.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-3">
                    <h4>Select Entity Types</h4>
                    <p>Click one or more entity cards to select what you want to import. Cards are grouped by Consumer, Account, and Other. Click the <strong>i</strong> icon on any card to preview its available fields.</p>
                    <p>Selecting multiple entities means each will get its own mapping and validation cycle in Step 4, processed one at a time.</p>
                    <p class="guide-tip">Your department determines which entities and fields are available. If something is missing, contact the Applications team.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-4">
                    <h4>Map &amp; Validate</h4>
                    <p><strong>Identifier first:</strong> Select which file column contains the DM consumer or account number. Mapping is disabled until this is set.</p>
                    <p><strong>Mapping:</strong> Drag source columns onto BDL fields, or click to pair them. Some fields support a mode toggle (File / Blanket / Conditional) for flexible value assignment. Tag entities use assignment cards instead of drag-and-drop.</p>
                    <p><strong>Validation:</strong> Click <em>Validate</em> to check your data. Fix required empty fields (fill or skip) and invalid lookup values (replace or skip). The system re-validates automatically after each action.</p>
                    <p class="guide-tip">All mappings and assignments are preserved on back navigation. Changed mappings trigger automatic re-staging on the next validate.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-5">
                    <h4>Review &amp; Execute</h4>
                    <p>Review the summary for each entity tab: environment, row counts, mapped fields, and nullified fields. Use <em>Preview XML</em> to inspect the exact output before submitting.</p>
                    <p>Optionally enter a <strong>Jira ticket</strong> to create a consolidated AR log linking all imported records to the ticket.</p>
                    <p>Click <strong>Submit All</strong> to execute. Each entity is submitted independently &mdash; one failure does not block the others. Results appear in the unified results pane below.</p>
                    <p class="guide-tip">After a successful TEST or STAGE import, a Promote to Production option appears with a cooldown timer.</p>
                </div>
            </div>
            <div class="template-section" id="template-section">
                <div class="template-header">Mapping Templates</div>
                <div class="template-list" id="template-list">
                    <div class="template-empty">Select an entity type to see available templates.</div>
                </div>
                <div class="template-save-area hidden" id="template-save-area">
                    <button class="template-save-btn" onclick="BDL.showSaveTemplate()">Save Current Mapping as Template</button>
                </div>
            </div>

            <!-- Import History Panel -->
            <div class="history-section" id="history-section">
                <div class="history-header">
                    <div class="history-title-row">
                        <span class="history-title">Import History</span>
                        <span class="history-live-indicator hidden" id="history-live-indicator" title="Polling live — active imports in flight"></span>
                        <span class="history-last-updated" id="history-last-updated"></span>
                        <button class="history-refresh-btn" id="history-refresh-btn" onclick="BDL.refreshHistory()" title="Refresh now">&#8635;</button>
                    </div>
                    <div class="history-filter-row">
                        <div class="history-env-chips" id="history-env-chips">
                            <span class="history-chip history-chip-env history-chip-active" data-env="ALL" onclick="BDL.setHistoryEnvFilter('ALL')">All</span>
                        </div>
                        <div class="history-user-toggle" id="history-user-toggle">
                            <span class="history-toggle-btn history-toggle-active" data-scope="me" onclick="BDL.setHistoryUserScope('me')">Mine</span>
                            <span class="history-toggle-btn" data-scope="all" onclick="BDL.setHistoryUserScope('all')">All Users</span>
                        </div>
                    </div>
                </div>
                <div class="history-body">
                    <div class="history-active-section" id="history-active-section">
                        <div class="history-empty">Loading history...</div>
                    </div>
                    <div class="history-tree" id="history-tree"></div>
                </div>
            </div>
        </div>
        
    </div>
    
    <!-- Template Preview Slideout -->
    <div class="slide-panel-overlay" id="template-slideout-overlay" onclick="BDL.closeTemplatePreview()"></div>
    <div class="slide-panel" id="template-slideout">
        <div class="slide-panel-header">
            <h3 id="template-slideout-title">Template Preview</h3>
            <button class="modal-close" onclick="BDL.closeTemplatePreview()">&times;</button>
        </div>
        <div class="slide-panel-body" id="template-slideout-body"></div>
    </div>

    <!-- Save Template Modal -->
    <div class="template-modal-overlay hidden" id="template-modal-overlay">
        <div class="template-modal">
            <div class="template-modal-header">
                <span>Save Mapping Template</span>
                <span class="template-modal-close" onclick="BDL.closeSaveTemplate()">&times;</span>
            </div>
            <div class="template-modal-body">
                <div class="template-modal-field">
                    <label for="save-template-name">Template Name</label>
                    <input type="text" id="save-template-name" placeholder="e.g., Acme Phone Export" maxlength="100">
                </div>
                <div class="template-modal-field">
                    <label for="save-template-desc">Description <span class="template-optional">(optional)</span></label>
                    <textarea id="save-template-desc" placeholder="Brief description of this file layout..." maxlength="500" rows="3"></textarea>
                </div>
                <div class="template-modal-preview" id="save-template-preview"></div>
                <div class="template-modal-actions">
                    <button class="nav-btn" onclick="BDL.closeSaveTemplate()">Cancel</button>
                    <button class="replace-btn" onclick="BDL.saveTemplate()">Save Template</button>
                </div>
                <div class="template-modal-status hidden" id="save-template-status"></div>
            </div>
        </div>
    </div>
    
    <script>window.isAdmin = __IS_ADMIN__;</script>
    <script>window.userTier = '__USER_TIER__';</script>
    <script src="/js/xlsx.full.min.js"></script>
    <script src="/js/engine-events.js"></script>
    <script src="/js/bdl-import.js"></script>
</body>
</html>
"@

    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    $html = $html.Replace('__USER_TIER__', $access.Tier)
    Write-PodeHtmlResponse -Value $html
}