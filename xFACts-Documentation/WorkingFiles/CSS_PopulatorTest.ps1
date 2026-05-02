#==============================================================================
# Asset Registry — CSS Populator (TEST/THROWAWAY) v2
#
# Walks all .css files, parses with PostCSS via parse-css.js, generates
# Asset_Registry rows, INSERTs them.
#
# Key changes from v1:
#  - Parser distinguishes COMPOUND (no combinator between classes — same
#    element) from DESCENDANT (combinator separates classes — different
#    elements). This matches CSS semantics.
#  - Compound modifiers (e.g., .foo.active) are stored on the primary
#    DEFINITION row in the new state_modifier column rather than producing
#    spurious USAGE rows.
#  - Descendant relationships (.foo .bar) still produce a separate USAGE
#    row for the descendant class.
#  - Multi-selector dedupe: a single rule like .foo, .foo .bar no longer
#    produces 2 DEFINITION rows for foo. Dedupe key is
#    (file_name, line_start, component_name, reference_type, state_modifier).
#  - signature column populated without truncation (column is now VARCHAR(MAX)).
#  - raw_text similarly without the 500-char cap.
#==============================================================================

$ErrorActionPreference = 'Stop'

# ----- Configuration ---------------------------------------------------------
$NodeExe        = 'C:\Program Files\nodejs\node.exe'
$NodeLibsPath   = 'C:\Program Files\nodejs-libs\node_modules'
$ParseCssScript = 'E:\xFACts-PowerShell\parse-css.js'

$SqlServer      = 'AVG-PROD-LSNR'
$SqlDatabase    = 'xFACts'

$env:NODE_PATH = $NodeLibsPath

# Shared files — definitions in these files get scope=SHARED
$SharedFiles = @(
    'engine-events.css',
    'engine-events.js',
    'engine-events-API.ps1',
    'xFACts-Helpers.psm1'
)

# Glob all CSS files
$CcRoot = 'E:\xFACts-ControlCenter'
$CssFiles = @(Get-ChildItem -Path "$CcRoot\public\css\" -Filter '*.css' | Select-Object -ExpandProperty FullName)


# ----- Helpers ---------------------------------------------------------------

function Invoke-CssParse {
    param([Parameter(Mandatory=$true)][string]$FilePath)
    $tempIn = [System.IO.Path]::GetTempFileName()
    try {
        $source = Get-Content -Path $FilePath -Raw -Encoding UTF8
        [System.IO.File]::WriteAllText($tempIn, $source, [System.Text.UTF8Encoding]::new($false))
        $output = Get-Content -Path $tempIn -Raw -Encoding UTF8 | & $NodeExe $ParseCssScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Node parser failed for ${FilePath}: $($output | Out-String)"
        }
        return ($output | Out-String) | ConvertFrom-Json
    } finally {
        Remove-Item -Path $tempIn -Force -ErrorAction SilentlyContinue
    }
}

# Section banner: comment containing 5+ '=' chars; title is first non-equals line
function Get-BannerTitle {
    param([string]$CommentText)
    if ($null -eq $CommentText) { return $null }
    if ($CommentText -notmatch '={5,}') { return $null }

    $lines = $CommentText -split "`n"
    foreach ($line in $lines) {
        $trimmed = $line.Trim().Trim('=').Trim()
        if ($trimmed.Length -gt 0) { return $trimmed }
    }
    return $null
}

# Extract every var(--foo) reference from a CSS value string
function Get-VarReferences {
    param([string]$Value)
    if ($null -eq $Value) { return @() }
    $regexMatches = [regex]::Matches($Value, 'var\(\s*--([a-zA-Z0-9_-]+)\s*[,)]')
    return @($regexMatches | ForEach-Object { $_.Groups[1].Value })
}

# Collapse multiline strings to single line for raw_text/signature
function Format-SingleLine {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $crlf = "`r`n"; $lf = "`n"; $cr = "`r"
    return ($Text -replace $crlf, ' ' -replace $lf, ' ' -replace $cr, ' ').Trim()
}

# Walk one selector's children, splitting into compounds at combinator boundaries.
# Returns an array of compound objects:
#   @{ Classes = @('foo','bar'); HasClasses = $true }   # for class-bearing compounds
#   @{ Classes = @();             HasClasses = $false } # for tag-only compounds (body, h1, *)
function Get-CompoundList {
    param([Parameter(Mandatory=$true)] $SelectorChildren)

    $compounds = @()
    $currentClasses = New-Object System.Collections.Generic.List[string]
    $currentHasNonClass = $false

    foreach ($node in $SelectorChildren) {
        $t = $node.type
        if ($t -eq 'combinator') {
            # End of current compound, push it
            $compounds += [ordered]@{
                Classes        = @($currentClasses.ToArray())
                HasClasses     = ($currentClasses.Count -gt 0)
                HasNonClass    = $currentHasNonClass
            }
            $currentClasses = New-Object System.Collections.Generic.List[string]
            $currentHasNonClass = $false
        } elseif ($t -eq 'class') {
            $currentClasses.Add($node.value)
        } elseif ($t -eq 'tag' -or $t -eq 'universal' -or $t -eq 'id' -or $t -eq 'attribute') {
            $currentHasNonClass = $true
        }
        # pseudo and others contribute nothing to compound class list, ignore
    }
    # Push the final compound
    $compounds += [ordered]@{
        Classes        = @($currentClasses.ToArray())
        HasClasses     = ($currentClasses.Count -gt 0)
        HasNonClass    = $currentHasNonClass
    }
    return ,$compounds
}


# ----- Pass 1: collect SHARED-scope class names ------------------------------
Write-Host "Pass 1: scanning all files, collecting SHARED definitions..." -ForegroundColor Cyan

$sharedClasses    = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedVariables  = New-Object 'System.Collections.Generic.HashSet[string]'
$sharedKeyframes  = New-Object 'System.Collections.Generic.HashSet[string]'

$astCache = @{}

foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    Write-Host "  Parsing $name ..." -NoNewline
    $parsed = Invoke-CssParse -FilePath $file
    $astCache[$file] = $parsed
    Write-Host " done." -ForegroundColor Green

    if ($SharedFiles -notcontains $name) { continue }

    # Walk the shared file collecting definitions: primary class names,
    # variable definitions, keyframe definitions
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($parsed.ast)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }

        if ($node.type -eq 'rule' -and $node.selectorTree) {
            foreach ($sel in $node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                $compounds = Get-CompoundList -SelectorChildren $sel.nodes
                foreach ($cmp in $compounds) {
                    if ($cmp.HasClasses) {
                        # Primary (leftmost) class in the compound is what's being defined here
                        [void]$sharedClasses.Add($cmp.Classes[0])
                    }
                }
            }
        }
        if ($node.type -eq 'decl' -and $node.prop -and $node.prop.StartsWith('--')) {
            [void]$sharedVariables.Add($node.prop.Substring(2))
        }
        if ($node.type -eq 'atrule' -and $node.name -eq 'keyframes' -and $node.params) {
            [void]$sharedKeyframes.Add($node.params.Trim())
        }
        if ($node.nodes) {
            foreach ($child in $node.nodes) { $stack.Push($child) }
        }
    }
}

Write-Host ("  Shared classes:   {0}" -f $sharedClasses.Count) -ForegroundColor Yellow
Write-Host ("  Shared variables: {0}" -f $sharedVariables.Count) -ForegroundColor Yellow
Write-Host ("  Shared keyframes: {0}" -f $sharedKeyframes.Count) -ForegroundColor Yellow


# ----- Pass 2: generate rows -------------------------------------------------
Write-Host ""
Write-Host "Pass 2: generating rows..." -ForegroundColor Cyan

$rows = New-Object System.Collections.Generic.List[object]

# Dedupe set: identifies (file, line, component_name, reference_type, state_modifier)
# tuples already emitted, so multi-selector lists with duplicate primary classes
# only generate one row.
$dedupeKeys = New-Object 'System.Collections.Generic.HashSet[string]'

function Test-AddDedupeKey {
    param([string]$Key)
    return $script:dedupeKeys.Add($Key)
}

# Generate a row from a single selector within a rule.
# A selector can produce:
#   - 1 row for the primary compound's first class (DEFINITION) with state_modifiers
#   - N USAGE rows for descendant compounds' first classes (one each)
#   - 1 CSS_RULE row if no compounds have classes (e.g., 'body', 'h1', '*')
function Add-RowsForSelector {
    param(
        [Parameter(Mandatory=$true)] $SelectorNode,
        [Parameter(Mandatory=$true)] [string] $RuleSelectorText,
        [Parameter(Mandatory=$true)] [string] $FileName,
        [Parameter(Mandatory=$true)] [bool]   $FileIsShared,
        [Parameter(Mandatory=$true)] [int]    $LineStart,
        [Parameter(Mandatory=$true)] [int]    $LineEnd,
        [Parameter(Mandatory=$true)] [int]    $ColumnStart,
        [string] $CurrentBanner = $null,
        [string] $CurrentAtrule = $null
    )

    $compounds = Get-CompoundList -SelectorChildren $SelectorNode.nodes

    # Find the leftmost compound that has classes — that's where the primary
    # DEFINITION lives.
    $primaryIdx = -1
    for ($i = 0; $i -lt $compounds.Count; $i++) {
        if ($compounds[$i].HasClasses) { $primaryIdx = $i; break }
    }

    if ($primaryIdx -lt 0) {
        # Selector has no classes anywhere — emit one CSS_RULE row.
        $key = "$FileName|$LineStart|CSS_RULE||DEFINITION|"
        if (Test-AddDedupeKey -Key $key) {
            $script:rows.Add([ordered]@{
                FileName       = $FileName
                FileType       = 'CSS'
                LineStart      = $LineStart
                LineEnd        = $LineEnd
                ColumnStart    = $ColumnStart
                ComponentType  = 'CSS_RULE'
                ComponentName  = $null
                StateModifier  = $null
                ReferenceType  = 'DEFINITION'
                Scope          = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
                SourceFile     = $FileName
                SourceSection  = $script:CurrentBannerOuter
                Signature      = $RuleSelectorText
                ParentFunction = $CurrentAtrule
                ParentObject   = $null
                RawText        = $RuleSelectorText
            })
        }
        return
    }

    # Emit DEFINITION row for the primary compound's first class.
    $primary = $compounds[$primaryIdx]
    $primaryName = $primary.Classes[0]
    $modifiers = if ($primary.Classes.Count -gt 1) {
                     ($primary.Classes[1..($primary.Classes.Count-1)] -join ', ')
                 } else { $null }

    $defKey = "$FileName|$LineStart|CSS_CLASS|$primaryName|DEFINITION|$modifiers"
    if (Test-AddDedupeKey -Key $defKey) {
        $script:rows.Add([ordered]@{
            FileName       = $FileName
            FileType       = 'CSS'
            LineStart      = $LineStart
            LineEnd        = $LineEnd
            ColumnStart    = $ColumnStart
            ComponentType  = 'CSS_CLASS'
            ComponentName  = $primaryName
            StateModifier  = $modifiers
            ReferenceType  = 'DEFINITION'
            Scope          = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
            SourceFile     = $FileName
            SourceSection  = $script:CurrentBannerOuter
            Signature      = $RuleSelectorText
            ParentFunction = $CurrentAtrule
            ParentObject   = $null
            RawText        = $RuleSelectorText
        })
    }

    # Emit USAGE rows for any subsequent compounds' first classes (descendants).
    for ($i = $primaryIdx + 1; $i -lt $compounds.Count; $i++) {
        $cmp = $compounds[$i]
        if (-not $cmp.HasClasses) { continue }
        $usageName = $cmp.Classes[0]
        $usageModifiers = if ($cmp.Classes.Count -gt 1) {
                              ($cmp.Classes[1..($cmp.Classes.Count-1)] -join ', ')
                          } else { $null }

        $scope = if ($script:sharedClasses.Contains($usageName)) { 'SHARED' } else { 'LOCAL' }
        $sourceFile = if ($scope -eq 'LOCAL') { $FileName } else { '<shared>' }

        $useKey = "$FileName|$LineStart|CSS_CLASS|$usageName|USAGE|$usageModifiers"
        if (Test-AddDedupeKey -Key $useKey) {
            $script:rows.Add([ordered]@{
                FileName       = $FileName
                FileType       = 'CSS'
                LineStart      = $LineStart
                LineEnd        = $LineEnd
                ColumnStart    = $ColumnStart
                ComponentType  = 'CSS_CLASS'
                ComponentName  = $usageName
                StateModifier  = $usageModifiers
                ReferenceType  = 'USAGE'
                Scope          = $scope
                SourceFile     = $sourceFile
                SourceSection  = $script:CurrentBannerOuter
                Signature      = $RuleSelectorText
                ParentFunction = $CurrentAtrule
                ParentObject   = $null
                RawText        = $RuleSelectorText
            })
        }
    }
}

function Add-RowsFromAst {
    param(
        [Parameter(Mandatory=$true)] $Node,
        [Parameter(Mandatory=$true)] [string] $FileName,
        [Parameter(Mandatory=$true)] [bool]   $FileIsShared,
        [string] $CurrentAtrule = $null
    )

    if ($null -eq $Node) { return }

    # COMMENT_BANNER detection
    if ($Node.type -eq 'comment') {
        $title = Get-BannerTitle -CommentText $Node.text
        if ($title) {
            $rawSnippet = Format-SingleLine -Text $Node.text
            $bannerKey = "$FileName|$($Node.source.start.line)|COMMENT_BANNER|$title|DEFINITION|"
            if (Test-AddDedupeKey -Key $bannerKey) {
                $script:rows.Add([ordered]@{
                    FileName       = $FileName
                    FileType       = 'CSS'
                    LineStart      = $Node.source.start.line
                    LineEnd        = $Node.source.end.line
                    ColumnStart    = $Node.source.start.column
                    ComponentType  = 'COMMENT_BANNER'
                    ComponentName  = $title
                    StateModifier  = $null
                    ReferenceType  = 'DEFINITION'
                    Scope          = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
                    SourceFile     = $FileName
                    SourceSection  = $null
                    Signature      = $null
                    ParentFunction = $null
                    ParentObject   = $null
                    RawText        = $rawSnippet
                })
            }
            $script:CurrentBannerOuter = $title
            return
        }
    }

    # CSS_RULE / CSS_CLASS — handle every selector in the rule's selector list
    if ($Node.type -eq 'rule') {
        $line = $Node.source.start.line
        $endLine = $Node.source.end.line
        $col = $Node.source.start.column

        if ($Node.selectorTree -and $Node.selectorTree.nodes) {
            foreach ($sel in $Node.selectorTree.nodes) {
                if ($sel.type -ne 'selector') { continue }
                Add-RowsForSelector -SelectorNode $sel -RuleSelectorText $Node.selector `
                    -FileName $FileName -FileIsShared $FileIsShared `
                    -LineStart $line -LineEnd $endLine -ColumnStart $col `
                    -CurrentBanner $script:CurrentBannerOuter -CurrentAtrule $CurrentAtrule
            }
        }

        # Walk into the rule's body to find decls (var() uses, custom prop defs)
        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -FileName $FileName -FileIsShared $FileIsShared -CurrentAtrule $CurrentAtrule
            }
        }
        return
    }

    # decl — CSS_VARIABLE def/use, CSS_KEYFRAME use
    if ($Node.type -eq 'decl') {
        if ($Node.prop -and $Node.prop.StartsWith('--')) {
            $varName = $Node.prop.Substring(2)
            $key = "$FileName|$($Node.source.start.line)|CSS_VARIABLE|$varName|DEFINITION|"
            if (Test-AddDedupeKey -Key $key) {
                $script:rows.Add([ordered]@{
                    FileName       = $FileName
                    FileType       = 'CSS'
                    LineStart      = $Node.source.start.line
                    LineEnd        = $Node.source.end.line
                    ColumnStart    = $Node.source.start.column
                    ComponentType  = 'CSS_VARIABLE'
                    ComponentName  = $varName
                    StateModifier  = $null
                    ReferenceType  = 'DEFINITION'
                    Scope          = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
                    SourceFile     = $FileName
                    SourceSection  = $script:CurrentBannerOuter
                    Signature      = $Node.value
                    ParentFunction = $CurrentAtrule
                    ParentObject   = $null
                    RawText        = "$($Node.prop): $($Node.value)"
                })
            }
        }

        $vars = Get-VarReferences -Value $Node.value
        foreach ($v in $vars) {
            $scope = if ($script:sharedVariables.Contains($v)) { 'SHARED' } else { 'LOCAL' }
            $sourceFile = if ($scope -eq 'LOCAL') { $FileName } else { '<shared>' }
            $key = "$FileName|$($Node.source.start.line)|CSS_VARIABLE|$v|USAGE|"
            if (Test-AddDedupeKey -Key $key) {
                $script:rows.Add([ordered]@{
                    FileName       = $FileName
                    FileType       = 'CSS'
                    LineStart      = $Node.source.start.line
                    LineEnd        = $Node.source.end.line
                    ColumnStart    = $Node.source.start.column
                    ComponentType  = 'CSS_VARIABLE'
                    ComponentName  = $v
                    StateModifier  = $null
                    ReferenceType  = 'USAGE'
                    Scope          = $scope
                    SourceFile     = $sourceFile
                    SourceSection  = $script:CurrentBannerOuter
                    Signature      = "var(--$v)"
                    ParentFunction = $CurrentAtrule
                    ParentObject   = $null
                    RawText        = "$($Node.prop): $($Node.value)"
                })
            }
        }

        if ($Node.prop -in @('animation-name','animation')) {
            foreach ($tok in ($Node.value -split '\s+|,')) {
                $t = $tok.Trim()
                if ($t -and $script:sharedKeyframes.Contains($t)) {
                    $key = "$FileName|$($Node.source.start.line)|CSS_KEYFRAME|$t|USAGE|"
                    if (Test-AddDedupeKey -Key $key) {
                        $script:rows.Add([ordered]@{
                            FileName       = $FileName
                            FileType       = 'CSS'
                            LineStart      = $Node.source.start.line
                            LineEnd        = $Node.source.end.line
                            ColumnStart    = $Node.source.start.column
                            ComponentType  = 'CSS_KEYFRAME'
                            ComponentName  = $t
                            StateModifier  = $null
                            ReferenceType  = 'USAGE'
                            Scope          = 'SHARED'
                            SourceFile     = '<shared>'
                            SourceSection  = $script:CurrentBannerOuter
                            Signature      = "$($Node.prop): $($Node.value)"
                            ParentFunction = $CurrentAtrule
                            ParentObject   = $null
                            RawText        = "$($Node.prop): $($Node.value)"
                        })
                    }
                }
            }
        }
        return
    }

    # @keyframes
    if ($Node.type -eq 'atrule' -and $Node.name -eq 'keyframes') {
        $kfName = $Node.params.Trim()
        $key = "$FileName|$($Node.source.start.line)|CSS_KEYFRAME|$kfName|DEFINITION|"
        if (Test-AddDedupeKey -Key $key) {
            $script:rows.Add([ordered]@{
                FileName       = $FileName
                FileType       = 'CSS'
                LineStart      = $Node.source.start.line
                LineEnd        = $Node.source.end.line
                ColumnStart    = $Node.source.start.column
                ComponentType  = 'CSS_KEYFRAME'
                ComponentName  = $kfName
                StateModifier  = $null
                ReferenceType  = 'DEFINITION'
                Scope          = if ($FileIsShared) { 'SHARED' } else { 'LOCAL' }
                SourceFile     = $FileName
                SourceSection  = $script:CurrentBannerOuter
                Signature      = "@keyframes $kfName"
                ParentFunction = $null
                ParentObject   = $null
                RawText        = "@keyframes $kfName"
            })
        }
        return
    }

    # @media etc. — recurse into children with the at-rule as parent context
    if ($Node.type -eq 'atrule') {
        $atruleLabel = "@$($Node.name) $($Node.params)".Trim()
        if ($Node.nodes) {
            foreach ($child in $Node.nodes) {
                Add-RowsFromAst -Node $child -FileName $FileName -FileIsShared $FileIsShared -CurrentAtrule $atruleLabel
            }
        }
        return
    }

    # Root or unknown — recurse
    if ($Node.nodes) {
        foreach ($child in $Node.nodes) {
            Add-RowsFromAst -Node $child -FileName $FileName -FileIsShared $FileIsShared -CurrentAtrule $CurrentAtrule
        }
    }
}

# Walk each file's cached AST.
$script:CurrentBannerOuter = $null
foreach ($file in $CssFiles) {
    $name = [System.IO.Path]::GetFileName($file)
    $isShared = $SharedFiles -contains $name
    $script:CurrentBannerOuter = $null
    $scopeLabel = if ($isShared) { 'SHARED' } else { 'LOCAL' }
    Write-Host "  Walking $name ($scopeLabel)..." -ForegroundColor Cyan

    $startCount = $rows.Count
    Add-RowsFromAst -Node $astCache[$file].ast -FileName $name -FileIsShared $isShared
    Write-Host ("    -> {0} rows" -f ($rows.Count - $startCount)) -ForegroundColor Green
}

Write-Host ""
Write-Host ("Total rows generated: {0}" -f $rows.Count) -ForegroundColor Yellow

$rows | Group-Object ComponentType | Sort-Object Count -Descending | Format-Table @{L='Component Type';E='Name'}, Count -AutoSize


# ----- Insert into Asset_Registry --------------------------------------------
Write-Host ""
Write-Host "Clearing existing CSS rows from Asset_Registry..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate `
    -Query "DELETE FROM dbo.Asset_Registry WHERE file_type = 'CSS';"

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
    $row['line_start']          = if ($null -eq $r.LineStart)   { 1 } else { [int]$r.LineStart }
    $row['line_end']            = if ($null -eq $r.LineEnd)     { [System.DBNull]::Value } else { [int]$r.LineEnd }
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

Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase -TrustServerCertificate -Query @"
SELECT component_type, scope, reference_type, COUNT(*) AS row_count
FROM dbo.Asset_Registry
WHERE file_type = 'CSS'
GROUP BY component_type, scope, reference_type
ORDER BY component_type, scope, reference_type;
"@ | Format-Table -AutoSize