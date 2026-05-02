#==============================================================================
# Asset Registry — HTML Populator (TEST/THROWAWAY) v2
#
# Walks every .ps1/.psm1 file in the Control Center, finds string-bearing
# tokens that contain HTML, and extracts:
#   - HTML_ID DEFINITION rows for every id="..."
#   - CSS_CLASS USAGE rows for every class name found in class="..."
#
# v2 changes (helper string-extraction enhancement):
#   - Now scans ALL string-bearing tokens, not just here-strings:
#       * HereStringExpandable, HereStringLiteral (@" "@ and @' '@)
#       * StringExpandable, StringLiteral ("..." and '...')
#   - This captures HTML emitted by helper functions like Get-NavBarHtml
#     that build markup via $html += "<div class='...'>" string concatenation.
#   - Cheap heuristic filters non-HTML strings before regex extraction
#     (must contain '<' followed by word char OR contain class=/id=).
#
# Scope determination for CSS_CLASS USAGE rows:
#   The class is looked up against existing CSS_CLASS DEFINITION rows in
#   dbo.Asset_Registry (loaded fresh at the start of this script). If the
#   class has a SHARED DEFINITION somewhere, scope=SHARED and source_file
#   points to that shared CSS file. Otherwise scope=LOCAL with source_file
#   pointing to the LOCAL CSS file that defines it (or '<undefined>' if
#   no DEFINITION exists in any CSS file).
#
# Variable interpolations like class="$x" or class="${prefix}-foo" are
# skipped — we can't statically resolve them.
#
# Run AFTER the CSS populator has loaded all CSS_CLASS DEFINITION rows.
#==============================================================================

$ErrorActionPreference = 'Stop'

# ----- Configuration ---------------------------------------------------------
$SqlServer   = 'AVG-PROD-LSNR'
$SqlDatabase = 'xFACts'

$Ps1Roots = @(
    'E:\xFACts-ControlCenter\scripts\routes',
    'E:\xFACts-ControlCenter\scripts\modules'
)

$Ps1Files = @()
foreach ($root in $Ps1Roots) {
    if (Test-Path $root) {
        $Ps1Files += @(Get-ChildItem -Path $root -Filter '*.ps1'  -Recurse | Select-Object -ExpandProperty FullName)
        $Ps1Files += @(Get-ChildItem -Path $root -Filter '*.psm1' -Recurse | Select-Object -ExpandProperty FullName)
    }
}
Write-Host ("Found {0} PS files to scan" -f $Ps1Files.Count) -ForegroundColor Cyan


# ----- Build CSS class definition lookup -------------------------------------
Write-Host "Loading existing CSS class definitions from Asset_Registry..." -ForegroundColor Cyan

$cssDefs = Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate -Query @"
SELECT component_name, scope, file_name
FROM dbo.Asset_Registry
WHERE component_type = 'CSS_CLASS'
  AND reference_type = 'DEFINITION'
  AND file_type = 'CSS'
  AND is_active = 1;
"@

$sharedClassMap = @{}
$localClassMap  = @{}

foreach ($d in $cssDefs) {
    $name = $d.component_name
    if ($null -eq $name) { continue }
    if ($d.scope -eq 'SHARED') {
        if (-not $sharedClassMap.ContainsKey($name)) {
            $sharedClassMap[$name] = $d.file_name
        }
    } else {
        if (-not $localClassMap.ContainsKey($name)) {
            $localClassMap[$name] = $d.file_name
        }
    }
}

Write-Host ("  Shared CSS classes:     {0}" -f $sharedClassMap.Count) -ForegroundColor Yellow
Write-Host ("  Local-only CSS classes: {0}" -f $localClassMap.Count) -ForegroundColor Yellow


# ----- Helpers ---------------------------------------------------------------

function Get-PsTokens {
    param([Parameter(Mandatory=$true)][string]$FilePath)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$errors) | Out-Null
    return $tokens
}

# Quick heuristic to skip strings that don't look like HTML before regex.
function Test-LooksLikeHtml {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    if ($Text.Length -lt 8) { return $false }
    if ($Text -match '<\s*\w') { return $true }
    if ($Text -match '\b(class|id)\s*=') { return $true }
    return $false
}

# Extract HTML class and id attribute occurrences from a string of text.
# Returns array of records: @{ Kind='class'|'id'; Value='...'; LineOffset=N; ColumnStart=N }
function Get-HtmlAttributeOccurrences {
    param([string]$Text)
    if ($null -eq $Text) { return @() }

    $results = New-Object System.Collections.Generic.List[object]

    # Match class="..." | class='...' | id="..." | id='...'
    $pattern = '\b(class|id)\s*=\s*(["''])([^"'']*)\2'
    $regexMatches = [regex]::Matches($Text, $pattern)

    foreach ($m in $regexMatches) {
        $attrName = $m.Groups[1].Value.ToLower()
        $value    = $m.Groups[3].Value

        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value -match '\$') { continue }

        $charIndex = $m.Index
        $textBefore = $Text.Substring(0, $charIndex)
        $lineOffset = ($textBefore -split "`n").Count - 1
        $lastNewline = $textBefore.LastIndexOf("`n")
        $columnStart = if ($lastNewline -ge 0) { $charIndex - $lastNewline } else { $charIndex + 1 }

        $results.Add([ordered]@{
            Kind        = $attrName
            Value       = $value
            LineOffset  = $lineOffset
            ColumnStart = $columnStart
        })
    }

    return $results
}

# Strip the wrappers off a token's Text so we get just the content,
# and return the source line where that content starts.
function Get-StringContent {
    param([Parameter(Mandatory=$true)] $Token)

    $kind     = $Token.Kind
    $rawText  = $Token.Text
    $startLine = $Token.Extent.StartLineNumber
    if (-not $startLine) { $startLine = $Token.StartLineNumber }

    if ($kind -in @('HereStringExpandable','HereStringLiteral')) {
        $inner = $rawText
        if ($inner.StartsWith('@"') -or $inner.StartsWith("@'")) { $inner = $inner.Substring(2) }
        if ($inner.EndsWith('"@')   -or $inner.EndsWith("'@"))   { $inner = $inner.Substring(0, $inner.Length - 2) }
        # Strip a single leading newline (the line containing the @" / @')
        if     ($inner.StartsWith("`r`n")) { $inner = $inner.Substring(2); $contentStart = $startLine + 1 }
        elseif ($inner.StartsWith("`n"))   { $inner = $inner.Substring(1); $contentStart = $startLine + 1 }
        else                               { $contentStart = $startLine }
        return @{ Inner = $inner; ContentStartLine = $contentStart }
    }

    if ($kind -in @('StringExpandable','StringLiteral')) {
        $inner = $rawText
        if ($inner.Length -ge 2) {
            $first = $inner[0]; $last = $inner[$inner.Length - 1]
            if (($first -eq '"' -or $first -eq "'") -and ($last -eq '"' -or $last -eq "'")) {
                $inner = $inner.Substring(1, $inner.Length - 2)
            }
        }
        return @{ Inner = $inner; ContentStartLine = $startLine }
    }

    return $null
}


# ----- Walk all PS files, extract HTML rows ----------------------------------
Write-Host ""
Write-Host "Extracting HTML attributes from PS string tokens..." -ForegroundColor Cyan

$rows = New-Object System.Collections.Generic.List[object]
$dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-AddDedupeKey { param([string]$Key) return $script:dedupeKeys.Add($Key) }

$tokenKindStats = @{
    HereStringExpandable = 0
    HereStringLiteral    = 0
    StringExpandable     = 0
    StringLiteral        = 0
}
$totalHtmlAttrs = 0

$relevantKinds = @('HereStringExpandable','HereStringLiteral','StringExpandable','StringLiteral')

foreach ($file in $Ps1Files) {
    $name = [System.IO.Path]::GetFileName($file)
    $tokens = Get-PsTokens -FilePath $file

    $stringTokens = @($tokens | Where-Object { $_.Kind -in $relevantKinds })
    if ($stringTokens.Count -eq 0) { continue }

    $startCount = $rows.Count

    foreach ($tok in $stringTokens) {
        $content = Get-StringContent -Token $tok
        if ($null -eq $content) { continue }
        $inner        = $content.Inner
        $contentStart = $content.ContentStartLine

        if (-not (Test-LooksLikeHtml -Text $inner)) { continue }

        $tokenKindStats[$tok.Kind]++

        $occurrences = Get-HtmlAttributeOccurrences -Text $inner
        $totalHtmlAttrs += $occurrences.Count

        foreach ($occ in $occurrences) {
            $sourceLine = $contentStart + $occ.LineOffset

            if ($occ.Kind -eq 'id') {
                $key = "$name|$sourceLine|HTML_ID|$($occ.Value)|DEFINITION|"
                if (Test-AddDedupeKey -Key $key) {
                    $script:rows.Add([ordered]@{
                        FileName       = $name
                        FileType       = 'HTML'
                        LineStart      = $sourceLine
                        LineEnd        = $sourceLine
                        ColumnStart    = $occ.ColumnStart
                        ComponentType  = 'HTML_ID'
                        ComponentName  = $occ.Value
                        StateModifier  = $null
                        ReferenceType  = 'DEFINITION'
                        Scope          = 'LOCAL'
                        SourceFile     = $name
                        SourceSection  = $null
                        Signature      = "id=`"$($occ.Value)`""
                        ParentFunction = $null
                        ParentObject   = $null
                        RawText        = "id=`"$($occ.Value)`""
                    })
                }
            } else {
                $classNames = @($occ.Value -split '\s+' | Where-Object { $_ })
                foreach ($cls in $classNames) {
                    if ($sharedClassMap.ContainsKey($cls)) {
                        $scope      = 'SHARED'
                        $sourceFile = $sharedClassMap[$cls]
                    } elseif ($localClassMap.ContainsKey($cls)) {
                        $scope      = 'LOCAL'
                        $sourceFile = $localClassMap[$cls]
                    } else {
                        $scope      = 'LOCAL'
                        $sourceFile = '<undefined>'
                    }

                    $key = "$name|$sourceLine|CSS_CLASS|$cls|USAGE|"
                    if (Test-AddDedupeKey -Key $key) {
                        $script:rows.Add([ordered]@{
                            FileName       = $name
                            FileType       = 'HTML'
                            LineStart      = $sourceLine
                            LineEnd        = $sourceLine
                            ColumnStart    = $occ.ColumnStart
                            ComponentType  = 'CSS_CLASS'
                            ComponentName  = $cls
                            StateModifier  = $null
                            ReferenceType  = 'USAGE'
                            Scope          = $scope
                            SourceFile     = $sourceFile
                            SourceSection  = $null
                            Signature      = "class=`"$($occ.Value)`""
                            ParentFunction = $null
                            ParentObject   = $null
                            RawText        = "class=`"$($occ.Value)`""
                        })
                    }
                }
            }
        }
    }

    $delta = $rows.Count - $startCount
    if ($delta -gt 0) {
        Write-Host ("  {0,-50} -> {1,4} rows" -f $name, $delta) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Token-kind scan stats:" -ForegroundColor Yellow
foreach ($k in $tokenKindStats.Keys) {
    Write-Host ("  {0,-22} {1}" -f $k, $tokenKindStats[$k])
}
Write-Host ("Total HTML attrs found: {0}" -f $totalHtmlAttrs) -ForegroundColor Yellow
Write-Host ("Total rows generated:   {0}" -f $rows.Count) -ForegroundColor Yellow

$rows | Group-Object { "$($_.ComponentType) / $($_.Scope)" } | Sort-Object Count -Descending |
    Format-Table @{L='Type / Scope';E='Name'}, Count -AutoSize


# ----- Insert into Asset_Registry --------------------------------------------
Write-Host ""
Write-Host "Clearing existing HTML rows from Asset_Registry..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate `
    -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'HTML';"

if ($rows.Count -eq 0) {
    Write-Host "No rows to insert." -ForegroundColor Yellow
    return
}

Write-Host "Inserting $($rows.Count) rows..." -ForegroundColor Cyan

$dt = New-Object System.Data.DataTable
[void]$dt.Columns.Add('file_name',         [string])
[void]$dt.Columns.Add('object_registry_id',[int])
[void]$dt.Columns.Add('file_type',         [string])
[void]$dt.Columns.Add('line_start',        [int])
[void]$dt.Columns.Add('line_end',          [int])
[void]$dt.Columns.Add('column_start',      [int])
[void]$dt.Columns.Add('component_type',    [string])
[void]$dt.Columns.Add('component_name',    [string])
[void]$dt.Columns.Add('component_subtype', [string])
[void]$dt.Columns.Add('state_modifier',    [string])
[void]$dt.Columns.Add('reference_type',    [string])
[void]$dt.Columns.Add('scope',             [string])
[void]$dt.Columns.Add('source_file',       [string])
[void]$dt.Columns.Add('source_section',    [string])
[void]$dt.Columns.Add('signature',         [string])
[void]$dt.Columns.Add('parent_function',   [string])
[void]$dt.Columns.Add('parent_object',     [string])
[void]$dt.Columns.Add('raw_text',          [string])
[void]$dt.Columns.Add('purpose_description',[string])
[void]$dt.Columns.Add('design_notes',      [string])
[void]$dt.Columns.Add('related_asset_id',  [int])

function Get-NullableValue {
    param($Value, [int]$MaxLen = 0)
    if ($null -eq $Value) { return [System.DBNull]::Value }
    if ($MaxLen -gt 0 -and $Value.Length -gt $MaxLen) { return $Value.Substring(0, $MaxLen) }
    return $Value
}

foreach ($r in $rows) {
    $row = $dt.NewRow()
    $row['file_name']           = $r.FileName
    $row['object_registry_id']  = [System.DBNull]::Value
    $row['file_type']           = $r.FileType
    $row['line_start']          = if ($null -eq $r.LineStart) { 1 } else { [int]$r.LineStart }
    $row['line_end']            = if ($null -eq $r.LineEnd)   { [System.DBNull]::Value } else { [int]$r.LineEnd }
    $row['column_start']        = if ($null -eq $r.ColumnStart) { [System.DBNull]::Value } else { [int]$r.ColumnStart }
    $row['component_type']      = $r.ComponentType
    $row['component_name']      = Get-NullableValue $r.ComponentName 256
    $row['component_subtype']   = [System.DBNull]::Value
    $row['state_modifier']      = Get-NullableValue $r.StateModifier 200
    $row['reference_type']      = $r.ReferenceType
    $row['scope']               = $r.Scope
    $row['source_file']         = $r.SourceFile
    $row['source_section']      = Get-NullableValue $r.SourceSection 150
    $row['signature']           = Get-NullableValue $r.Signature
    $row['parent_function']     = Get-NullableValue $r.ParentFunction 200
    $row['parent_object']       = [System.DBNull]::Value
    $row['raw_text']            = Get-NullableValue $r.RawText
    $row['purpose_description'] = [System.DBNull]::Value
    $row['design_notes']        = [System.DBNull]::Value
    $row['related_asset_id']    = [System.DBNull]::Value
    $dt.Rows.Add($row)
}

$conn = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDatabase;Integrated Security=True;TrustServerCertificate=True;"
$conn.Open()
$bcp = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
$bcp.DestinationTableName = 'dbo.Asset_Registry'
$bcp.BatchSize = 500
foreach ($col in $dt.Columns) {
    [void]$bcp.ColumnMappings.Add($col.ColumnName, $col.ColumnName)
}
$bcp.WriteToServer($dt)
$conn.Close()

Write-Host ("Inserted {0} rows into dbo.Asset_Registry." -f $rows.Count) -ForegroundColor Green

# ----- Verification -----------------------------------------------------------
Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate -Query @"
SELECT component_type, scope, reference_type, COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
GROUP BY component_type, scope, reference_type
ORDER BY component_type, scope, reference_type;
"@ | Format-Table -AutoSize

Write-Host ""
Write-Host "Sample: helper consumption (xFACts-Helpers.psm1)" -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate -Query @"
SELECT TOP 30 file_name, line_start, component_type, component_name, scope, source_file
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
  AND file_name = 'xFACts-Helpers.psm1'
ORDER BY line_start, component_name;
"@ | Format-Table -AutoSize

Write-Host ""
Write-Host "Sample: xf-modal usage in BIDATAMonitoring.ps1 (regression check)" -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate -Query @"
SELECT file_name, line_start, component_name, scope, source_file
FROM dbo.Asset_Registry
WHERE file_type = 'HTML'
  AND file_name = 'BIDATAMonitoring.ps1'
  AND component_name LIKE 'xf-modal%'
ORDER BY line_start, component_name;
"@ | Format-Table -AutoSize