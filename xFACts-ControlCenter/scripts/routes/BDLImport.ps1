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
            <h1>BDL Import</h1>
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
                    <div class="entity-search">
                        <input type="text" id="entity-search" placeholder="Filter entity types..." oninput="BDL.filterEntities(this.value)">
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
        
        <!-- RIGHT COLUMN: Step Guide + Templates -->
        <div class="bdl-guide" id="bdl-guide">
            <div class="guide-tip-panel" id="guide-content">
                <div class="guide-text" id="guide-text-1">
                    <h4>Select Target Environment</h4>
                    <p>Choose the Debt Manager environment where this import will be executed. The environment determines which server receives the file and processes the API calls.</p>
                    <p class="guide-tip">Use Test for initial validation of new file formats. Production imports should be verified on Test first.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-2">
                    <h4>Upload Data File</h4>
                    <p>Upload a CSV or Excel file containing the data to import. The first row should contain column headers. A preview of the first few rows will be displayed.</p>
                    <p class="guide-tip">Maximum recommended size is 250,000 rows per import.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-3">
                    <h4>Select Entity Types</h4>
                    <p>Choose the type(s) of data you want to import from this file. Click a card to select it, click again to deselect. You can select multiple entity types if this file contains data for more than one BDL operation.</p>
                    <p class="guide-tip">Each selected entity type will have its own mapping and validation cycle in the next step.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-4">
                    <h4>Map &amp; Validate</h4>
                    <p>For each selected entity type, map columns from your file to BDL fields, then validate the data. Issues are presented one at a time — resolve each before moving to the next entity.</p>
                    <p class="guide-tip">Each entity is mapped and validated independently. Progress is preserved if you navigate back.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-5">
                    <h4>Review &amp; Execute</h4>
                    <p>Review the import summary for each entity type. Once confirmed, the system builds files, registers them with DM, and triggers the imports.</p>
                    <p class="guide-tip">Each entity type is submitted independently. If one fails, the others are unaffected.</p>
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