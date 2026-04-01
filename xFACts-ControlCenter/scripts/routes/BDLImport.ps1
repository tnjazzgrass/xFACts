# ============================================================================
# xFACts Control Center - BDL Import Page
# Location: E:\xFACts-ControlCenter\scripts\routes\BDLImport.ps1
# 
# Guided BDL Import workflow: environment selection, entity type picker,
# file upload, column mapping, validation, and import execution.
#
# Version: Tracked in dbo.System_Metadata (component: ControlCenter.BDLImport)
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
</head>
<body>
    $navHtml
    
    <div class="header-bar">
        <div>
            <h1>BDL Import</h1>
            <p class="page-subtitle">Guided bulk data load import into Debt Manager</p>
        </div>
        <div class="header-right">
            <label class="compact-toggle" title="Toggle step guidance panel">
                <input type="checkbox" id="compact-mode" onchange="BDL.toggleCompactMode(this.checked)">
                <span>Hide Guide</span>
            </label>
        </div>
    </div>
    
    <div id="connection-error" class="connection-error"></div>
    
    <!-- ================================================================ -->
    <!-- TWO-COLUMN LAYOUT                                                -->
    <!-- ================================================================ -->
    <div class="bdl-layout">
        
        <!-- LEFT COLUMN: Stepper + Action Panels -->
        <div class="bdl-main">
            
            <!-- STEPPER BAR -->
            <div class="stepper">
                <div class="step active" id="step-ind-1" onclick="BDL.goToStep(1)">
                    <div class="step-number" id="step-num-1">1</div>
                    <div class="step-label">Environment</div>
                </div>
                <div class="step-connector" id="conn-1"></div>
                <div class="step" id="step-ind-2" onclick="BDL.goToStep(2)">
                    <div class="step-number" id="step-num-2">2</div>
                    <div class="step-label">Entity Type</div>
                </div>
                <div class="step-connector" id="conn-2"></div>
                <div class="step" id="step-ind-3" onclick="BDL.goToStep(3)">
                    <div class="step-number" id="step-num-3">3</div>
                    <div class="step-label">Upload File</div>
                </div>
                <div class="step-connector" id="conn-3"></div>
                <div class="step" id="step-ind-4" onclick="BDL.goToStep(4)">
                    <div class="step-number" id="step-num-4">4</div>
                    <div class="step-label">Map Columns</div>
                </div>
                <div class="step-connector" id="conn-4"></div>
                <div class="step" id="step-ind-5" onclick="BDL.goToStep(5)">
                    <div class="step-number" id="step-num-5">5</div>
                    <div class="step-label">Validate</div>
                </div>
                <div class="step-connector" id="conn-5"></div>
                <div class="step" id="step-ind-6" onclick="BDL.goToStep(6)">
                    <div class="step-number" id="step-num-6">6</div>
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
            
            <!-- STEP 2: Entity Type Selection -->
            <div class="step-panel" id="panel-2">
                <div class="step-content">
                    <div class="entity-search">
                        <input type="text" id="entity-search" placeholder="Filter entity types..." oninput="BDL.filterEntities(this.value)">
                    </div>
                    <div class="entity-grid" id="entity-grid">
                        <div class="loading">Loading entity types...</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 3: File Upload -->
            <div class="step-panel" id="panel-3">
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
            
            <!-- STEP 4: Column Mapping -->
            <div class="step-panel" id="panel-4">
                <div class="step-content">
                    <div id="mapping-area">
                        <div class="placeholder-message">Complete previous steps to begin column mapping.</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 5: Validation -->
            <div class="step-panel" id="panel-5">
                <div class="step-content">
                    <div id="validation-area">
                        <div class="placeholder-message">Complete column mapping to run validation.</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP 6: Review & Execute -->
            <div class="step-panel" id="panel-6">
                <div class="step-content">
                    <div id="execute-area">
                        <div class="placeholder-message">Complete validation to review and execute.</div>
                    </div>
                </div>
            </div>
            
            <!-- STEP NAVIGATION -->
            <div class="step-nav">
                <button class="nav-btn btn-back" id="btn-back" onclick="BDL.prevStep()" disabled>&#8592; Back</button>
                <div class="step-nav-spacer"></div>
                <button class="nav-btn btn-next" id="btn-next" onclick="BDL.nextStep()" disabled>Next &#8594;</button>
            </div>
        </div>
        
        <!-- RIGHT COLUMN: Step Guide -->
        <div class="bdl-guide" id="bdl-guide">
            <div class="guide-header">Step Guide</div>
            <div class="guide-steps">
                <div class="guide-step active" id="guide-1" onclick="BDL.goToStep(1)">
                    <div class="guide-num" id="guide-num-1">1</div>
                    <div class="guide-label">Environment</div>
                </div>
                <div class="guide-step" id="guide-2" onclick="BDL.goToStep(2)">
                    <div class="guide-num" id="guide-num-2">2</div>
                    <div class="guide-label">Entity Type</div>
                </div>
                <div class="guide-step" id="guide-3" onclick="BDL.goToStep(3)">
                    <div class="guide-num" id="guide-num-3">3</div>
                    <div class="guide-label">Upload File</div>
                </div>
                <div class="guide-step" id="guide-4" onclick="BDL.goToStep(4)">
                    <div class="guide-num" id="guide-num-4">4</div>
                    <div class="guide-label">Map Columns</div>
                </div>
                <div class="guide-step" id="guide-5" onclick="BDL.goToStep(5)">
                    <div class="guide-num" id="guide-num-5">5</div>
                    <div class="guide-label">Validate</div>
                </div>
                <div class="guide-step" id="guide-6" onclick="BDL.goToStep(6)">
                    <div class="guide-num" id="guide-num-6">6</div>
                    <div class="guide-label">Execute</div>
                </div>
            </div>
            <div class="guide-content" id="guide-content">
                <div class="guide-text" id="guide-text-1">
                    <h4>Select Target Environment</h4>
                    <p>Choose the Debt Manager environment where this BDL import will be executed.</p>
                    <p>The environment determines which DM server receives the import file and processes the API calls.</p>
                    <p class="guide-tip">Tip: Use Test for initial validation of new file formats. Production imports should be verified on Test first.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-2">
                    <h4>Select Entity Type</h4>
                    <p>Choose the type of data you are importing. Each entity type corresponds to a specific DM data structure with its own set of available fields.</p>
                    <p class="guide-tip">Tip: The entity type determines which BDL fields are available for column mapping in the next step.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-3">
                    <h4>Upload Data File</h4>
                    <p>Upload a CSV or Excel file containing the data to import. A preview of the first few rows will be displayed for verification.</p>
                    <p class="guide-tip">Tip: Files should have column headers in the first row. Maximum recommended size is 250,000 rows per import.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-4">
                    <h4>Map Columns</h4>
                    <p>Map each column from your uploaded file to the corresponding BDL field. Required fields are marked and must be mapped before proceeding.</p>
                    <p class="guide-tip">Tip: Click a source column, then click a BDL field to pair them. Or drag and drop between panels.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-5">
                    <h4>Validate Data</h4>
                    <p>All rows are checked against BDL field requirements: data types, maximum lengths, required fields, and lookup table values.</p>
                    <p>Invalid lookup values can be replaced inline. Required fields with empty values must be filled before proceeding.</p>
                </div>
                <div class="guide-text hidden" id="guide-text-6">
                    <h4>Review &amp; Execute</h4>
                    <p>Review the import summary. Once confirmed, the system will build the BDL XML file, register it with Debt Manager, and trigger the import.</p>
                    <p class="guide-tip">Note: This action cannot be undone. Failed imports require a new file with a new filename.</p>
                </div>
            </div>
        </div>
        
    </div>
    
    <script>window.isAdmin = __IS_ADMIN__;</script>
    <script>window.userTier = '__USER_TIER__';</script>
    <script src="/js/xlsx.full.min.js"></script>
    <script src="/js/bdl-import.js"></script>
</body>
</html>
"@

    $html = $html.Replace('__IS_ADMIN__', $(if ($ctx.IsAdmin) { 'true' } else { 'false' }))
    $html = $html.Replace('__USER_TIER__', $access.Tier)
    Write-PodeHtmlResponse -Value $html
}