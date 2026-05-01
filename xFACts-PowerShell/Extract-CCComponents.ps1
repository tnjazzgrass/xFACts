# ============================================================================
# Extract-CCComponents.ps1
# Location: E:\xFACts-ControlCenter\scripts\Extract-CCComponents.ps1 (proposed)
# Version: 0.1 (initial draft - companion to CC_FileFormat_Spec.md v0.2)
#
# Parses Control Center source files (CSS, JS, PS1, PSM1) per the
# CC_FileFormat_Spec and emits two outputs:
#   1. Component CSV  -- one row per extracted component
#   2. Compliance MD  -- one section per file with violation list
#
# This is v0.1 of the parser. Many existing files predate the spec and
# will produce many violations on the first run. Use the compliance
# report as the to-do list for bringing each file into spec compliance.
#
# USAGE
# -----
#   # Parse a single file
#   .\Extract-CCComponents.ps1 -Path "E:\xFACts-ControlCenter\public\css\engine-events.css"
#
#   # Parse all files in a directory tree
#   .\Extract-CCComponents.ps1 -Directory "E:\xFACts-ControlCenter"
#
#   # Specify output paths
#   .\Extract-CCComponents.ps1 -Directory "E:\xFACts-ControlCenter" `
#       -ComponentCsv "C:\temp\components.csv" `
#       -ComplianceMd "C:\temp\compliance.md"
# ============================================================================

[CmdletBinding(DefaultParameterSetName='Path')]
param(
    [Parameter(ParameterSetName='Path', Mandatory)]
    [string[]]$Path,

    [Parameter(ParameterSetName='Directory', Mandatory)]
    [string]$Directory,

    [Parameter(ParameterSetName='Directory')]
    [string[]]$IncludeExtensions = @('.css', '.js', '.ps1', '.psm1'),

    [string]$ComponentCsv = "$PWD\cc_components.csv",
    [string]$ComplianceMd = "$PWD\cc_compliance.md",

    [switch]$StrictMode  # Abort on first ERROR-level violation
)

# ============================================================================
# 1. UTILITY HELPERS
# ============================================================================

function New-Component {
    param(
        [string]$ComponentType,
        [string]$ComponentName,
        [string]$Scope = '',
        [string]$HostFile,
        [string]$SourceFile,
        [string]$SourceSection = '',
        [string]$Signature = '',
        [string]$DefaultValue = '',
        [string]$Variants = '',
        [string]$PurposeDescription = '',
        [string]$Notes = '',
        [int]$LineNumber = 0
    )
    return [PSCustomObject]@{
        component_type      = $ComponentType
        component_name      = $ComponentName
        scope               = $Scope
        host_file           = $HostFile
        source_file         = $SourceFile
        source_section      = $SourceSection
        signature           = $Signature
        default_value       = $DefaultValue
        variants            = $Variants
        purpose_description = $PurposeDescription
        notes               = $Notes
        line_number         = $LineNumber
    }
}

function New-Violation {
    param(
        [string]$File,
        [int]$LineNumber,
        [ValidateSet('ERROR','WARNING','INFO')]
        [string]$Severity,
        [string]$Rule,
        [string]$Message
    )
    return [PSCustomObject]@{
        file        = $File
        line_number = $LineNumber
        severity    = $Severity
        rule        = $Rule
        message     = $Message
    }
}

# Determine the SHARED/LOCAL scope from the file name.
# Anything in engine-events.* or xFACts-Helpers.psm1 is SHARED;
# everything else is LOCAL (i.e., page-specific).
function Get-FileScope {
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileName($FileName)
    if ($base -match '^engine-events\.' -or $base -eq 'xFACts-Helpers.psm1') {
        return 'SHARED'
    }
    return 'LOCAL'
}

# Detect PS1 file subtype: ROUTE (page route), API (API endpoints),
# MODULE (helpers .psm1 or unknown .ps1), or SHARED-API (engine-events-API.ps1).
function Get-Ps1FileSubtype {
    param([string]$FileName)
    $base = [System.IO.Path]::GetFileName($FileName)
    if ($base -eq 'engine-events-API.ps1') { return 'SHARED-API' }
    if ($base -match '-API\.ps1$')          { return 'API' }
    if ($base -match '\.psm1$')             { return 'MODULE' }
    if ($base -match 'Monitoring\.ps1$' -or $base -in @('Backup.ps1','Admin.ps1','Home.ps1','BDLImport.ps1','ClientPortal.ps1','DmOperations.ps1','DBCCOperations.ps1','IndexMaintenance.ps1','BatchMonitoring.ps1','BIDATAMonitoring.ps1','JBossMonitoring.ps1','FileMonitoring.ps1','JobFlowMonitoring.ps1','PlatformMonitoring.ps1','ReplicationMonitoring.ps1','ServerHealth.ps1','BusinessIntelligence.ps1','BusinessServices.ps1','ApplicationsIntegration.ps1','ClientRelations.ps1')) {
        return 'ROUTE'
    }
    return 'MODULE'  # Default: treat unknown ps1 as module
}

# ============================================================================
# 2. SECTION SCANNER (LANGUAGE-AGNOSTIC)
# ============================================================================
# Scans a list of file lines and returns an array of section markers:
#   { Number, Title, StartLine, EndLine }
# Section banners follow the spec:
#   <comment-rule with 78 = chars>
#   N. SECTION TITLE IN CAPS
#   <comment-rule with 78 - chars>
#   ... description ...
#   <comment-rule with 78 = chars>
# The comment characters (// or # or /*) vary by language but the structure
# is identical. This function uses a flexible regex to recognize the banner.

function Find-SectionBanners {
    param(
        [string[]]$Lines,
        [string]$FileName
    )

    $banners = [System.Collections.ArrayList]::new()
    $violations = [System.Collections.ArrayList]::new()

    # Section title line: optionally has a comment prefix (// or # or /*)
    # then "N. <TITLE>" (number+period+space+caps title, possibly with punctuation)
    $titleRegex = '^\s*(?:\#|\/\/|\/\*\s*)?\s*(\d+)\.\s+([A-Z][A-Z0-9 :,\-\(\)\&]+?)\s*$'

    # Top/bottom rule: 78 equals signs, possibly with comment prefix
    $ruleEqRegex = '^\s*(?:\#|\/\/|\/\*\s*)?\s*={70,}\s*(?:\*\/)?\s*$'

    # Mid rule: 78 dashes, possibly with comment prefix
    $ruleDashRegex = '^\s*(?:\#|\/\/|\/\*\s*)?\s*-{70,}\s*$'

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match $titleRegex) {
            $sectionNum = [int]$matches[1]
            $sectionTitle = $matches[2].Trim()

            # Look back for a top rule within 1-2 lines
            $hasTopRule = $false
            for ($j = [Math]::Max(0, $i - 2); $j -lt $i; $j++) {
                if ($Lines[$j] -match $ruleEqRegex) { $hasTopRule = $true; break }
            }

            if (-not $hasTopRule) { continue }

            # Look forward for a mid rule within 1-2 lines (preferred but not required)
            $hasMidRule = $false
            for ($j = $i + 1; $j -lt [Math]::Min($Lines.Count, $i + 3); $j++) {
                if ($Lines[$j] -match $ruleDashRegex) { $hasMidRule = $true; break }
            }

            [void]$banners.Add([PSCustomObject]@{
                Number     = $sectionNum
                Title      = "$sectionNum. $sectionTitle"
                StartLine  = $i + 1
                EndLine    = $Lines.Count
            })

            if (-not $hasMidRule) {
                [void]$violations.Add((New-Violation -File $FileName -LineNumber ($i + 1) `
                    -Severity 'INFO' -Rule 'section-banner-missing-mid-rule' `
                    -Message "Section banner '$sectionNum. $sectionTitle' missing mid-rule (dashed line). Spec requires a dashed-line rule below the title for the description block."))
            }
        }
    }

    # Set EndLine for each banner = StartLine of next banner - 1
    for ($k = 0; $k -lt $banners.Count - 1; $k++) {
        $banners[$k].EndLine = $banners[$k + 1].StartLine - 1
    }

    # Validate sequential numbering
    for ($k = 0; $k -lt $banners.Count; $k++) {
        $expected = $k + 1
        if ($banners[$k].Number -ne $expected) {
            [void]$violations.Add((New-Violation -File $FileName -LineNumber $banners[$k].StartLine `
                -Severity 'WARNING' -Rule 'section-number-sequence' `
                -Message "Section number $($banners[$k].Number) found where $expected was expected"))
        }
    }

    return @($banners, $violations)
}

# Given a line number, return the section it falls within.
function Get-SectionAtLine {
    param(
        $Banners,
        [int]$LineNumber
    )
    foreach ($b in $Banners) {
        if ($LineNumber -ge $b.StartLine -and $LineNumber -le $b.EndLine) {
            return $b.Title
        }
    }
    return ''
}

# ============================================================================
# 3. FILE HEADER VALIDATION
# ============================================================================
# Every file begins with a header block. We validate:
#   - Has identity line ("xFACts Control Center - ...")
#   - Has Location line
#   - Has Version line referencing System_Metadata
#   - Has CHANGELOG section

function Test-FileHeader {
    param(
        [string[]]$Lines,
        [string]$FileName
    )

    $violations = [System.Collections.ArrayList]::new()

    # Look at first 50 lines (headers should be at the top)
    $headerLines = $Lines[0..[Math]::Min(49, $Lines.Count - 1)] -join "`n"

    if ($headerLines -notmatch 'xFACts Control Center\s*-') {
        [void]$violations.Add((New-Violation -File $FileName -LineNumber 1 `
            -Severity 'WARNING' -Rule 'file-header-identity' `
            -Message 'File header missing identity line ("xFACts Control Center - ...")'))
    }
    if ($headerLines -notmatch 'Location:') {
        [void]$violations.Add((New-Violation -File $FileName -LineNumber 1 `
            -Severity 'WARNING' -Rule 'file-header-location' `
            -Message 'File header missing Location line'))
    }
    if ($headerLines -notmatch 'Version:.*System_Metadata') {
        [void]$violations.Add((New-Violation -File $FileName -LineNumber 1 `
            -Severity 'WARNING' -Rule 'file-header-version' `
            -Message 'File header missing Version line (must reference dbo.System_Metadata)'))
    }
    if ($headerLines -notmatch 'CHANGELOG') {
        [void]$violations.Add((New-Violation -File $FileName -LineNumber 1 `
            -Severity 'INFO' -Rule 'file-header-changelog' `
            -Message 'File header missing CHANGELOG section'))
    }

    return $violations
}

# ============================================================================
# 4. CSS PARSER
# ============================================================================

function Parse-CssFile {
    param(
        [string]$FilePath,
        [string[]]$Lines
    )

    $components = [System.Collections.ArrayList]::new()
    $violations = [System.Collections.ArrayList]::new()
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $scope = Get-FileScope -FileName $fileName

    # Validate file header
    foreach ($v in (Test-FileHeader -Lines $Lines -FileName $fileName)) {
        [void]$violations.Add($v)
    }

    # Find sections
    $bannersResult = Find-SectionBanners -Lines $Lines -FileName $fileName
    $banners = $bannersResult[0]
    foreach ($v in $bannersResult[1]) { [void]$violations.Add($v) }

    if ($banners.Count -eq 0) {
        [void]$violations.Add((New-Violation -File $fileName -LineNumber 1 `
            -Severity 'WARNING' -Rule 'no-sections' `
            -Message 'File contains no recognized section banners'))
    }

    # ---- Extract @keyframes ----
    # @keyframes <name> { ... }
    # We don't try to parse the inner blocks; we just record the keyframe name.
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '^\s*@keyframes\s+([a-zA-Z][\w\-]*)') {
            $kfName = $matches[1]
            $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)
            [void]$components.Add((New-Component `
                -ComponentType 'CSS_KEYFRAME' `
                -ComponentName $kfName `
                -Scope $scope `
                -HostFile $fileName `
                -SourceFile $fileName `
                -SourceSection $section `
                -Signature "@keyframes $kfName" `
                -LineNumber ($i + 1)))
        }
    }

    # ---- Extract CSS class selectors ----
    # We collect class names per rule. Each rule starts at a selector line and
    # is delimited by `{`. A selector line may have multiple selectors separated
    # by commas. Compound selectors (.foo.bar) emit one row per class but with
    # the full compound as `signature`.
    #
    # We track variants: ".engine-bar.idle" is a variant of ".engine-bar".
    # The base class gets a row; the variant gets folded into the variants
    # JSON column.

    # Pass 1: collect every class selector occurrence
    $occurrences = [System.Collections.ArrayList]::new()  # @{ ClassName, Compound, Selector, Section, Line, IsVariant }

    $blockDepth = 0
    $inKeyframes = $false
    $selectorBuffer = [System.Collections.ArrayList]::new()  # accumulates multi-line selectors

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $stripped = $line.Trim()

        if ($stripped -eq '') { continue }

        # Track keyframes block
        if ($line -match '^\s*@keyframes\s+') { $inKeyframes = $true }

        $openBraces  = ([regex]::Matches($line, '\{')).Count
        $closeBraces = ([regex]::Matches($line, '\}')).Count
        $prevDepth = $blockDepth
        $blockDepth += $openBraces - $closeBraces

        if ($inKeyframes -and $blockDepth -eq 0) { $inKeyframes = $false; continue }
        if ($inKeyframes) { continue }

        # Skip pure comment lines
        if ($stripped.StartsWith('/*') -or $stripped.StartsWith('*') -or $stripped.StartsWith('//')) { continue }

        # Multi-line selector accumulation:
        # If at depth 0 and the line ends with ',' it's a selector continuation
        if ($prevDepth -eq 0) {
            $contentBeforeBrace = ($stripped -split '\{')[0].TrimEnd()
            if ($contentBeforeBrace.EndsWith(',')) {
                [void]$selectorBuffer.Add(@{ LineNumber = $i + 1; Text = $contentBeforeBrace })
                continue
            }
        }

        # Selector lines: at depth 0 and contain a class selector
        $selectorPart = $null
        $selectorStartLine = $i + 1

        if ($stripped.Contains('{') -and $prevDepth -eq 0) {
            $selectorPart = ($stripped -split '\{')[0].Trim()
            if ($selectorBuffer.Count -gt 0) {
                $bufferedText = ($selectorBuffer | ForEach-Object { $_.Text }) -join ' '
                $selectorPart = $bufferedText + ' ' + $selectorPart
                $selectorStartLine = $selectorBuffer[0].LineNumber
                [void]$selectorBuffer.Clear()
            }
        } elseif ($prevDepth -eq 0) {
            # Look ahead for {
            for ($j = $i + 1; $j -lt [Math]::Min($Lines.Count, $i + 5); $j++) {
                $nextStripped = $Lines[$j].Trim()
                if ($nextStripped -eq '') { continue }
                if ($nextStripped.StartsWith('{')) {
                    $selectorPart = $stripped
                    if ($selectorBuffer.Count -gt 0) {
                        $bufferedText = ($selectorBuffer | ForEach-Object { $_.Text }) -join ' '
                        $selectorPart = $bufferedText + ' ' + $selectorPart
                        $selectorStartLine = $selectorBuffer[0].LineNumber
                        [void]$selectorBuffer.Clear()
                    }
                    break
                } else { break }
            }
        }

        if (-not $selectorPart -or -not $selectorPart.Contains('.')) {
            # Reset buffer if we're not building a selector
            if ($prevDepth -eq 0 -and -not $stripped.EndsWith(',')) {
                [void]$selectorBuffer.Clear()
            }
            continue
        }

        # Skip @-rules
        if ($selectorPart.StartsWith('@')) {
            [void]$selectorBuffer.Clear()
            continue
        }

        # Split on commas to get individual selectors
        $selectors = $selectorPart -split ',\s*'

        foreach ($sel in $selectors) {
            $sel = $sel.Trim()
            if ($sel -eq '') { continue }

            $section = Get-SectionAtLine -Banners $banners -LineNumber $selectorStartLine

            # Tokenize the selector by descendant whitespace.
            $selTokens = $sel -split '\s+' | Where-Object { $_ -ne '' -and $_ -notin @('>','~','+') }

            foreach ($token in $selTokens) {
                $tokenClasses = [regex]::Matches($token, '\.([a-zA-Z][\w\-]*)') | ForEach-Object { $_.Groups[1].Value }
                if ($tokenClasses.Count -eq 0) { continue }

                $pseudoMatches = [regex]::Matches($token, ':([\w\-]+)') | ForEach-Object { $_.Groups[1].Value }

                $primary = $tokenClasses[0]
                $variantSuffixes = @()
                if ($tokenClasses.Count -gt 1) {
                    $variantSuffixes += $tokenClasses[1..($tokenClasses.Count - 1)]
                }
                $variantSuffixes += $pseudoMatches

                [void]$occurrences.Add([PSCustomObject]@{
                    ClassName  = $primary
                    Compound   = $token
                    Selector   = $sel
                    Section    = $section
                    Line       = $selectorStartLine
                    IsVariant  = ($variantSuffixes.Count -gt 0)
                    Variants   = $variantSuffixes
                })
            }
        }
    }

    # Pass 2: aggregate by class name. Primary class (first-seen, no variant) gets the row.
    # Variants are accumulated into the variants column.
    $byClass = @{}
    foreach ($occ in $occurrences) {
        if (-not $byClass.ContainsKey($occ.ClassName)) {
            $byClass[$occ.ClassName] = @{
                FirstLine = $occ.Line
                Section   = $occ.Section
                Selector  = $occ.Selector
                Compound  = $occ.Compound
                Variants  = [System.Collections.Generic.HashSet[string]]::new()
            }
        }
        $entry = $byClass[$occ.ClassName]
        # Use the earliest non-variant occurrence as the canonical
        if (-not $occ.IsVariant -and $entry.HasNonVariant -ne $true) {
            $entry.FirstLine = $occ.Line
            $entry.Section   = $occ.Section
            $entry.Selector  = $occ.Selector
            $entry.Compound  = $occ.Compound
            $entry.HasNonVariant = $true
        }
        foreach ($v in $occ.Variants) {
            [void]$entry.Variants.Add($v)
        }
    }

    foreach ($className in $byClass.Keys) {
        $entry = $byClass[$className]
        $variantsJson = ''
        if ($entry.Variants.Count -gt 0) {
            $variantsJson = '[' + (($entry.Variants | Sort-Object | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
        }
        [void]$components.Add((New-Component `
            -ComponentType 'CSS_CLASS' `
            -ComponentName $className `
            -Scope $scope `
            -HostFile $fileName `
            -SourceFile $fileName `
            -SourceSection $entry.Section `
            -Signature ".$className" `
            -Variants $variantsJson `
            -LineNumber $entry.FirstLine))
    }

    return @($components, $violations)
}

# ============================================================================
# 5. JS PARSER
# ============================================================================

function Parse-JsFile {
    param(
        [string]$FilePath,
        [string[]]$Lines
    )

    $components = [System.Collections.ArrayList]::new()
    $violations = [System.Collections.ArrayList]::new()
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $scope = Get-FileScope -FileName $fileName

    foreach ($v in (Test-FileHeader -Lines $Lines -FileName $fileName)) {
        [void]$violations.Add($v)
    }

    $bannersResult = Find-SectionBanners -Lines $Lines -FileName $fileName
    $banners = $bannersResult[0]
    foreach ($v in $bannersResult[1]) { [void]$violations.Add($v) }

    # Determine which sections are SHARED CONSTANTS / PAGE CONSTANTS / STATE / PAGE HOOKS
    $constantsSections = $banners | Where-Object { $_.Title -match '(SHARED CONSTANTS|PAGE CONSTANTS|CONSTANTS$|^[\d\.\s]+CONSTANTS)' }
    $stateSections     = $banners | Where-Object { $_.Title -match '\bSTATE\b' }
    $hookSections      = $banners | Where-Object { $_.Title -match '\bHOOKS?\b|PAGE HOOKS?' }

    # Find top-level declarations:
    #   function NAME(...)
    #   var NAME = ...
    #   let NAME = ...
    #   const NAME = ...
    # We only consider lines at zero indent (no leading whitespace).

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]

        # Skip indented lines (not top-level)
        if ($line -match '^\s+\S') { continue }
        if ($line.Trim() -eq '') { continue }
        if ($line.Trim().StartsWith('//')) { continue }
        if ($line.Trim().StartsWith('/*')) { continue }
        if ($line.Trim().StartsWith('*')) { continue }

        $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)
        $isConstantSection = ($constantsSections | Where-Object { $_.Title -eq $section }) -ne $null
        $isStateSection    = ($stateSections | Where-Object { $_.Title -eq $section }) -ne $null
        $isHookSection     = ($hookSections | Where-Object { $_.Title -eq $section }) -ne $null

        # function NAME(args) {
        if ($line -match '^function\s+([a-zA-Z_\$][\w\$]*)\s*\(([^)]*)\)') {
            $funcName = $matches[1]
            $args = $matches[2].Trim()
            $type = if ($isHookSection) { 'JS_HOOK' } else { 'JS_FUNCTION' }

            # Look back for a doc comment (JSDoc /** ... */ or // single-line)
            $doc = Get-PrecedingComment -Lines $Lines -Index $i

            [void]$components.Add((New-Component `
                -ComponentType $type `
                -ComponentName $funcName `
                -Scope $scope `
                -HostFile $fileName `
                -SourceFile $fileName `
                -SourceSection $section `
                -Signature "($args)" `
                -PurposeDescription $doc `
                -LineNumber ($i + 1)))
            continue
        }

        # async function NAME(args) {
        if ($line -match '^async\s+function\s+([a-zA-Z_\$][\w\$]*)\s*\(([^)]*)\)') {
            $funcName = $matches[1]
            $args = $matches[2].Trim()
            $type = if ($isHookSection) { 'JS_HOOK' } else { 'JS_FUNCTION' }
            $doc = Get-PrecedingComment -Lines $Lines -Index $i
            [void]$components.Add((New-Component `
                -ComponentType $type `
                -ComponentName $funcName `
                -Scope $scope `
                -HostFile $fileName `
                -SourceFile $fileName `
                -SourceSection $section `
                -Signature "(async)($args)" `
                -PurposeDescription $doc `
                -LineNumber ($i + 1)))
            continue
        }

        # var/let/const NAME = ...
        if ($line -match '^(var|let|const)\s+([a-zA-Z_\$][\w\$]*)\s*=\s*(.*?)\s*;?\s*$') {
            $kind = $matches[1]
            $varName = $matches[2]
            $rhs = $matches[3]

            # Decide type based on section + naming convention
            # All-caps name → constant, camelCase → state (per spec section 3.2)
            $type = 'JS_STATE'
            if ($isConstantSection -or ($isStateSection -eq $false -and $varName -cmatch '^[A-Z][A-Z0-9_]+$')) {
                $type = 'JS_CONSTANT'
            }

            # Brief signature: trim long RHS, keep just enough to be informative
            $sig = $rhs
            if ($sig.Length -gt 80) { $sig = $sig.Substring(0, 77) + '...' }

            $doc = Get-PrecedingComment -Lines $Lines -Index $i

            [void]$components.Add((New-Component `
                -ComponentType $type `
                -ComponentName $varName `
                -Scope $scope `
                -HostFile $fileName `
                -SourceFile $fileName `
                -SourceSection $section `
                -Signature $sig `
                -PurposeDescription $doc `
                -LineNumber ($i + 1)))
            continue
        }
    }

    return @($components, $violations)
}

# Helper: extract preceding comment for documentation.
# Returns the first non-@ line of a JSDoc block, or a single-line comment text.
function Get-PrecedingComment {
    param(
        [string[]]$Lines,
        [int]$Index
    )

    if ($Index -eq 0) { return '' }

    # Walk back through blank lines
    $j = $Index - 1
    while ($j -ge 0 -and $Lines[$j].Trim() -eq '') { $j-- }
    if ($j -lt 0) { return '' }

    $prev = $Lines[$j].Trim()

    # JSDoc end: */
    if ($prev -eq '*/') {
        # Walk back to /** to gather the block
        $k = $j - 1
        $docLines = [System.Collections.ArrayList]::new()
        while ($k -ge 0) {
            $l = $Lines[$k].Trim()
            if ($l.StartsWith('/**')) { break }
            # Strip leading * and whitespace
            $clean = ($l -replace '^\*\s*', '').Trim()
            if ($clean -ne '' -and -not $clean.StartsWith('@')) {
                [void]$docLines.Insert(0, $clean)
            }
            $k--
        }
        if ($docLines.Count -gt 0) {
            return $docLines[0]  # First non-@ line
        }
        return ''
    }

    # Single-line comment
    if ($prev.StartsWith('//')) {
        return ($prev -replace '^//\s*', '').Trim()
    }

    # PowerShell-style block comment <# ... #>
    if ($prev -eq '#>') {
        $k = $j - 1
        while ($k -ge 0) {
            $l = $Lines[$k].Trim()
            if ($l -match '^\.SYNOPSIS\s*$') {
                # Next non-blank line is the synopsis content
                $kk = $k + 1
                while ($kk -le $j -and $Lines[$kk].Trim() -eq '') { $kk++ }
                if ($kk -le $j) {
                    return $Lines[$kk].Trim()
                }
            }
            if ($l.StartsWith('<#')) { break }
            $k--
        }
        return ''
    }

    return ''
}

# ============================================================================
# 6. PS1/PSM1 PARSER
# ============================================================================

function Parse-Ps1File {
    param(
        [string]$FilePath,
        [string[]]$Lines
    )

    $components = [System.Collections.ArrayList]::new()
    $violations = [System.Collections.ArrayList]::new()
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $scope = Get-FileScope -FileName $fileName
    $subtype = Get-Ps1FileSubtype -FileName $fileName

    foreach ($v in (Test-FileHeader -Lines $Lines -FileName $fileName)) {
        [void]$violations.Add($v)
    }

    $bannersResult = Find-SectionBanners -Lines $Lines -FileName $fileName
    $banners = $bannersResult[0]
    foreach ($v in $bannersResult[1]) { [void]$violations.Add($v) }

    # Extract PowerShell function declarations (Type 2: module files)
    if ($subtype -in @('MODULE')) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $line = $Lines[$i]
            if ($line -match '^\s*function\s+([A-Z][a-zA-Z]+-[A-Z][a-zA-Z]+(?:[A-Z][a-zA-Z0-9]*)?)\s*\{?\s*$') {
                $funcName = $matches[1]
                $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)
                $doc = Get-PrecedingComment -Lines $Lines -Index $i

                # Look for param() block within the next 30 lines
                $params = ''
                for ($j = $i + 1; $j -lt [Math]::Min($Lines.Count, $i + 30); $j++) {
                    if ($Lines[$j] -match 'param\s*\(') {
                        # Capture params until closing paren
                        $paramText = ''
                        $depth = 0
                        for ($k = $j; $k -lt [Math]::Min($Lines.Count, $j + 50); $k++) {
                            $paramText += $Lines[$k] + "`n"
                            $depth += ([regex]::Matches($Lines[$k], '\(')).Count
                            $depth -= ([regex]::Matches($Lines[$k], '\)')).Count
                            if ($depth -le 0 -and $paramText -match 'param\s*\(') { break }
                        }
                        # Extract param names
                        $paramMatches = [regex]::Matches($paramText, '\$([A-Za-z_][\w]*)')
                        $paramNames = $paramMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
                        $params = '(' + ($paramNames -join ', ') + ')'
                        break
                    }
                }

                [void]$components.Add((New-Component `
                    -ComponentType 'PS_FUNCTION' `
                    -ComponentName $funcName `
                    -Scope $scope `
                    -HostFile $fileName `
                    -SourceFile $fileName `
                    -SourceSection $section `
                    -Signature $params `
                    -PurposeDescription $doc `
                    -LineNumber ($i + 1)))
            }
        }

        # Extract $script: variables
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $line = $Lines[$i]
            if ($line -match '^\s*\$script:([A-Za-z_][\w]*)\s*=') {
                $varName = $matches[1]
                $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)
                [void]$components.Add((New-Component `
                    -ComponentType 'PS_STATE' `
                    -ComponentName $varName `
                    -Scope 'LOCAL' `
                    -HostFile $fileName `
                    -SourceFile $fileName `
                    -SourceSection $section `
                    -LineNumber ($i + 1)))
            }
        }
    }

    # Extract Add-PodeRoute calls (Type 1: route/API files)
    if ($subtype -in @('ROUTE', 'API', 'SHARED-API')) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $line = $Lines[$i]
            if ($line -match "Add-PodeRoute\s+(?:-Method\s+(\w+)\s+)?-Path\s+'([^']+)'") {
                $method = if ($matches[1]) { $matches[1] } else { 'GET' }
                $routePath = $matches[2]
                $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)

                # Look back for a comment block
                $doc = ''
                $j = $i - 1
                while ($j -ge 0 -and $Lines[$j].Trim() -eq '') { $j-- }
                $commentBuffer = [System.Collections.ArrayList]::new()
                while ($j -ge 0) {
                    $prev = $Lines[$j].Trim()
                    if ($prev.StartsWith('#') -and -not $prev.StartsWith('# ====')) {
                        # Skip sub-section markers like "# -- /api/foo --"
                        if (-not $prev.StartsWith('# --')) {
                            $clean = ($prev -replace '^#\s*', '').Trim()
                            if ($clean -ne '') { [void]$commentBuffer.Insert(0, $clean) }
                        }
                        $j--
                    } else { break }
                }
                if ($commentBuffer.Count -gt 0) { $doc = $commentBuffer[0] }

                [void]$components.Add((New-Component `
                    -ComponentType 'API_ROUTE' `
                    -ComponentName $routePath `
                    -Scope $scope `
                    -HostFile $fileName `
                    -SourceFile $fileName `
                    -SourceSection $section `
                    -Signature "$method $routePath" `
                    -PurposeDescription $doc `
                    -LineNumber ($i + 1)))
            }
        }
    }

    # For ROUTE files: extract id="..." attributes from inline HTML
    if ($subtype -eq 'ROUTE') {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $line = $Lines[$i]
            $idMatches = [regex]::Matches($line, "\bid\s*=\s*['""]([\w\-]+)['""]")
            foreach ($m in $idMatches) {
                $idVal = $m.Groups[1].Value
                $section = Get-SectionAtLine -Banners $banners -LineNumber ($i + 1)
                [void]$components.Add((New-Component `
                    -ComponentType 'HTML_ID' `
                    -ComponentName $idVal `
                    -Scope $scope `
                    -HostFile $fileName `
                    -SourceFile $fileName `
                    -SourceSection $section `
                    -LineNumber ($i + 1)))
            }
        }
    }

    return @($components, $violations)
}

# ============================================================================
# 7. MAIN ORCHESTRATION
# ============================================================================

function Invoke-Parse {
    param(
        [string[]]$Files
    )

    $allComponents = [System.Collections.ArrayList]::new()
    $allViolations = [System.Collections.ArrayList]::new()
    $fileResults = [System.Collections.ArrayList]::new()

    foreach ($f in $Files) {
        if (-not (Test-Path $f)) {
            Write-Warning "File not found: $f"
            continue
        }

        $ext = [System.IO.Path]::GetExtension($f).ToLower()
        $lines = Get-Content -LiteralPath $f -Encoding UTF8

        $parsed = $null
        switch ($ext) {
            '.css'  { $parsed = Parse-CssFile -FilePath $f -Lines $lines }
            '.js'   { $parsed = Parse-JsFile  -FilePath $f -Lines $lines }
            '.ps1'  { $parsed = Parse-Ps1File -FilePath $f -Lines $lines }
            '.psm1' { $parsed = Parse-Ps1File -FilePath $f -Lines $lines }
            default {
                Write-Verbose "Skipping unsupported file: $f"
                continue
            }
        }

        $fileComponents = $parsed[0]
        $fileViolations = $parsed[1]

        foreach ($c in $fileComponents) { [void]$allComponents.Add($c) }
        foreach ($v in $fileViolations) { [void]$allViolations.Add($v) }

        [void]$fileResults.Add([PSCustomObject]@{
            File             = [System.IO.Path]::GetFileName($f)
            ComponentCount   = $fileComponents.Count
            ViolationCount   = $fileViolations.Count
            ErrorCount       = ($fileViolations | Where-Object { $_.severity -eq 'ERROR' }).Count
            WarningCount     = ($fileViolations | Where-Object { $_.severity -eq 'WARNING' }).Count
            InfoCount        = ($fileViolations | Where-Object { $_.severity -eq 'INFO' }).Count
            Status           = if (($fileViolations | Where-Object { $_.severity -in @('ERROR','WARNING') }).Count -eq 0) { 'PASS' } else { 'FAIL' }
        })
    }

    return @($allComponents, $allViolations, $fileResults)
}

# ---- File list determination ----
$filesToParse = @()
if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $filesToParse = $Path
} else {
    if (-not (Test-Path $Directory)) {
        throw "Directory not found: $Directory"
    }
    foreach ($ext in $IncludeExtensions) {
        $found = Get-ChildItem -Path $Directory -Recurse -Include "*$ext" -File | Where-Object { $_.FullName -notmatch '\\node_modules\\' }
        $filesToParse += $found.FullName
    }
}

Write-Host "Parsing $($filesToParse.Count) files..." -ForegroundColor Cyan

$result = Invoke-Parse -Files $filesToParse
$allComponents = $result[0]
$allViolations = $result[1]
$fileResults = $result[2]

# ============================================================================
# 8. WRITE OUTPUTS
# ============================================================================

# Write component CSV
$allComponents | Export-Csv -LiteralPath $ComponentCsv -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($allComponents.Count) components to $ComponentCsv" -ForegroundColor Green

# Write compliance markdown
$mdLines = [System.Collections.ArrayList]::new()
[void]$mdLines.Add("# CC File Format Compliance Report")
[void]$mdLines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$mdLines.Add("Files scanned: $($fileResults.Count)")
[void]$mdLines.Add("")
[void]$mdLines.Add("## Summary")
$totalPass = ($fileResults | Where-Object { $_.Status -eq 'PASS' }).Count
$totalFail = ($fileResults | Where-Object { $_.Status -eq 'FAIL' }).Count
$totalViolations = ($allViolations).Count
[void]$mdLines.Add("- Files passing: $totalPass")
[void]$mdLines.Add("- Files failing: $totalFail")
[void]$mdLines.Add("- Total violations: $totalViolations")
if ($totalViolations -gt 0) {
    $byRule = $allViolations | Group-Object -Property rule | Sort-Object Count -Descending
    [void]$mdLines.Add("")
    [void]$mdLines.Add("### Violation rules by frequency")
    foreach ($g in $byRule) {
        [void]$mdLines.Add("- $($g.Name): $($g.Count)")
    }
}
[void]$mdLines.Add("")
[void]$mdLines.Add("---")
[void]$mdLines.Add("")

foreach ($fr in $fileResults | Sort-Object File) {
    [void]$mdLines.Add("## File: $($fr.File)")
    [void]$mdLines.Add("Status: $($fr.Status) -- Components: $($fr.ComponentCount), Violations: $($fr.ViolationCount) (E:$($fr.ErrorCount) W:$($fr.WarningCount) I:$($fr.InfoCount))")
    [void]$mdLines.Add("")

    $fileViolations = $allViolations | Where-Object { $_.file -eq $fr.File }
    if ($fileViolations.Count -gt 0) {
        [void]$mdLines.Add("### Violations")
        foreach ($v in ($fileViolations | Sort-Object line_number)) {
            [void]$mdLines.Add("- Line $($v.line_number) [$($v.severity)] $($v.rule): $($v.message)")
        }
        [void]$mdLines.Add("")
    }
}

$mdLines -join "`n" | Set-Content -LiteralPath $ComplianceMd -Encoding UTF8
Write-Host "Wrote compliance report to $ComplianceMd" -ForegroundColor Green

# Console summary
Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Cyan
foreach ($fr in $fileResults | Sort-Object File) {
    $color = if ($fr.Status -eq 'PASS') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-40} {1,4} components  {2,4} violations  {3}" -f $fr.File, $fr.ComponentCount, $fr.ViolationCount, $fr.Status) -ForegroundColor $color
}
Write-Host ""
Write-Host "Total components: $($allComponents.Count)" -ForegroundColor Cyan
Write-Host "Total violations: $($allViolations.Count)" -ForegroundColor Cyan