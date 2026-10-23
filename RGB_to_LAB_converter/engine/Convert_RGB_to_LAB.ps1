# Raw RGB -> CIELAB / Delta E / hue angle converter.
# Runs on Windows PowerShell 5.1 with no extra software: every raw-RGB CSV
# (or experiment folder) in RawRGB_input becomes an Excel workbook in output.
# The calculations reproduce the earlier Node.js converter exactly.

param(
    [string]$InputRoot = "",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$ConverterRoot = Split-Path -Parent $PSScriptRoot
if (-not $InputRoot) { $InputRoot = Join-Path $ConverterRoot "RawRGB_input" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ConverterRoot "output" }
$SettingsFileName = "conversion_settings.json"
$OutputSuffix = "_LAB_DeltaE_Hue"
$ErrorSuffix = "_CONVERSION_ERROR.txt"

# Non-ASCII characters are built from code points so the script file itself
# stays plain ASCII (Windows PowerShell reads scripts as ANSI).
$Delta = [string][char]0x0394
$Minus = [string][char]0x2212
$Degree = [string][char]0x00B0
$Times = [string][char]0x00D7
$EnDash = [string][char]0x2013

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Get-Mean([double[]]$Values) {
    if ($Values.Count -eq 0) { return $null }
    return ($Values | Measure-Object -Sum).Sum / $Values.Count
}

function Get-SampleSd([double[]]$Values) {
    if ($Values.Count -lt 2) { return $null }
    $average = Get-Mean $Values
    $sum = 0.0
    foreach ($value in $Values) { $sum += ($value - $average) * ($value - $average) }
    return [Math]::Sqrt($sum / ($Values.Count - 1))
}

function Format-Number([double]$Value) {
    if ($Value -eq [Math]::Floor($Value)) { return $Value.ToString("0", $Invariant) }
    return ([Math]::Round($Value, 8)).ToString("R", $Invariant)
}

function ConvertTo-Double([string]$Text, [string]$Label) {
    $number = 0.0
    if (-not [double]::TryParse($Text, [System.Globalization.NumberStyles]::Float, $Invariant, [ref]$number)) {
        throw "Expected a numeric value for $Label, received: $Text"
    }
    return $number
}

function Get-NormalizedText([string]$Text) {
    if ($null -eq $Text) { return "" }
    return $Text.Replace([string][char]0x03BC, "u").Replace([string][char]0x00B5, "u").Trim()
}

function Get-Stem([string]$FileName) {
    return [System.IO.Path]::GetFileNameWithoutExtension($FileName)
}

function Get-SafeFileName([string]$Value) {
    $safe = ($Value -replace '[<>:"/\\|?*]', "_").Trim()
    if (-not $safe) { return "RGB_batch" }
    return $safe
}

# ---------------------------------------------------------------------------
# Concentration from the image name (pg/ng/ug/mg per mL -> pg/mL, molar -> nM)
# ---------------------------------------------------------------------------

function New-MassCondition([double]$Value, [string]$Unit) {
    $multiplier = @{ pg = 1.0; ng = 1e3; ug = 1e6; mg = 1e9 }[$Unit.ToLowerInvariant()]
    return [pscustomobject]@{ IsNumeric = $true; Value = $Value * $multiplier; Unit = "pg/mL" }
}

function New-MolarCondition([double]$Value, [string]$Unit) {
    $multipliers = @{ "pM" = 0.001; "nM" = 1.0; "uM" = 1e3; "mM" = 1e6; "M" = 1e9 }
    $multiplier = 1.0
    foreach ($key in $multipliers.Keys) { if ($key -ceq $Unit) { $multiplier = $multipliers[$key] } }
    return [pscustomobject]@{ IsNumeric = $true; Value = $Value * $multiplier; Unit = "nM" }
}

function Get-LastNumber([string]$Text) {
    $found = [regex]::Matches($Text, '[+-]?[0-9]+(?:\.[0-9]+)?')
    if ($found.Count -eq 0) { return $null }
    return [double]::Parse($found[$found.Count - 1].Value, $Invariant)
}

function ConvertTo-Condition([string]$Text, [string]$UnitHint) {
    $normalized = Get-NormalizedText $Text
    $hint = ((Get-NormalizedText $UnitHint) -replace '\s+', '') -replace '_per_', '/' -replace 'per', '/'
    $number = '([+-]?[0-9]+(?:\.[0-9]+)?)'
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    $match = [regex]::Match($normalized, "$number\s*(pg|ng|ug|mg)\s*(?:[_\- ]*per[_\- ]*mL|/\s*mL)", $ignoreCase)
    if ($match.Success) { return New-MassCondition ([double]::Parse($match.Groups[1].Value, $Invariant)) $match.Groups[2].Value }

    $found = [regex]::Matches($normalized, "$number\s*(pg|ng|ug|mg)(?![A-Za-z])", $ignoreCase)
    if ($found.Count -gt 0) {
        $last = $found[$found.Count - 1]
        return New-MassCondition ([double]::Parse($last.Groups[1].Value, $Invariant)) $last.Groups[2].Value
    }
    $hintMatch = [regex]::Match($hint, '^(pg|ng|ug|mg)/mL$', $ignoreCase)
    if ($hintMatch.Success) {
        $value = Get-LastNumber $normalized
        if ($null -ne $value) { return New-MassCondition $value $hintMatch.Groups[1].Value }
    }

    $found = [regex]::Matches($normalized, "$number\s*(pM|nM|uM|mM|M)(?![A-Za-z])")
    if ($found.Count -gt 0) {
        $last = $found[$found.Count - 1]
        return New-MolarCondition ([double]::Parse($last.Groups[1].Value, $Invariant)) $last.Groups[2].Value
    }
    $hintMatch = [regex]::Match($hint, '^(pM|nM|uM|mM|M)$')
    if ($hintMatch.Success) {
        $value = Get-LastNumber $normalized
        if ($null -ne $value) { return New-MolarCondition $value $hintMatch.Groups[1].Value }
    }

    if ($hint) {
        $value = Get-LastNumber $normalized
        if ($null -ne $value) {
            return [pscustomobject]@{ IsNumeric = $true; Value = $value; Unit = $UnitHint.Trim() }
        }
    }
    if ($normalized) {
        return [pscustomobject]@{ IsNumeric = $false; Value = $normalized; Unit = "label" }
    }
    throw "Could not read an empty condition label from `"$Text`"."
}

function Get-ConditionLabel($Condition) {
    if ($Condition.IsNumeric) { return "$(Format-Number $Condition.Value) $($Condition.Unit)" }
    return [string]$Condition.Value
}

# ---------------------------------------------------------------------------
# Colour maths (same constants as the original workbook)
# ---------------------------------------------------------------------------

function ConvertTo-Linear([double]$Value8) {
    $value = [Math]::Min(255.0, [Math]::Max(0.0, $Value8)) / 255.0
    if ($value -le 0.04045) { return $value / 12.92 }
    return [Math]::Pow(($value + 0.055) / 1.055, 2.4)
}

function Get-Pivot([double]$Value) {
    if ($Value -gt (216.0 / 24389.0)) { return [Math]::Pow($Value, 1.0 / 3.0) }
    return ((24389.0 / 27.0) * $Value + 16.0) / 116.0
}

function ConvertTo-Lab([double]$R8, [double]$G8, [double]$B8) {
    $r = ConvertTo-Linear $R8
    $g = ConvertTo-Linear $G8
    $b = ConvertTo-Linear $B8
    $x = (0.412390799265959 * $r + 0.357584339383878 * $g + 0.180480788401834 * $b) / 0.95047
    $y = (0.212639005871510 * $r + 0.715168678767756 * $g + 0.072192315360734 * $b) / 1.00000
    $z = (0.019330818715592 * $r + 0.119194779794626 * $g + 0.950532152249660 * $b) / 1.08883
    $fx = Get-Pivot $x
    $fy = Get-Pivot $y
    $fz = Get-Pivot $z
    return [pscustomobject]@{ L = 116.0 * $fy - 16.0; A = 500.0 * ($fx - $fy); B = 200.0 * ($fy - $fz) }
}

function Get-HueAngle([double]$A, [double]$B) {
    $degrees = [Math]::Atan2($B, $A) * 180.0 / [Math]::PI
    return ($degrees + 360.0) % 360.0
}

# ---------------------------------------------------------------------------
# Well selection: "Well2", "BottomRight", "Well1TP" ... (number and position)
# ---------------------------------------------------------------------------

function Get-WellIdentity([string]$Value) {
    $full = (Get-NormalizedText $Value).ToLowerInvariant()
    $full = $full -replace 'buttom|button', 'bottom' -replace 'samplesize[0-9]+', '' -replace '[^a-z0-9]+', ''
    $numberMatch = [regex]::Match($full, '^well([0-9]+)')
    $number = $null
    if ($numberMatch.Success) { $number = [int]$numberMatch.Groups[1].Value }
    return [pscustomobject]@{ Full = $full; Number = $number; Position = ($full -replace '^well[0-9]+', '') }
}

function Test-WellSelected([string]$Well, [string[]]$Selections) {
    if ($Selections.Count -eq 0) { return $true }
    $wellId = Get-WellIdentity $Well
    foreach ($selection in $Selections) {
        $selected = Get-WellIdentity $selection
        if (-not $selected.Full) { continue }
        if ($wellId.Full -eq $selected.Full) { return $true }
        if ($null -ne $selected.Number -and $null -ne $wellId.Number -and $selected.Number -ne $wellId.Number) { continue }
        if ($selected.Position -and $wellId.Position) {
            if ($wellId.Position -eq $selected.Position -or $wellId.Position.EndsWith($selected.Position) -or $selected.Position.EndsWith($wellId.Position)) { return $true }
            continue
        }
        if (-not $selected.Position -and $null -ne $selected.Number -and $wellId.Number -eq $selected.Number) { return $true }
    }
    return $false
}

function Get-RoleClass($Row) {
    $combined = "$(Get-NormalizedText $Row.Role) $(Get-NormalizedText $Row.Region)".ToLowerInvariant()
    if ($combined.Contains("black")) { return "black" }
    if ($combined.Contains("white")) { return "white" }
    if ($combined.Contains("sample")) { return "sample" }
    return "other"
}

# ---------------------------------------------------------------------------
# Reading the raw-RGB CSV files
# ---------------------------------------------------------------------------

$NumericColumns = @("Image_Index", "ROI_Index", "ROI_Number", "ROI_X", "ROI_Y", "ROI_Width", "ROI_Height", "Area_px", "R", "G", "B")
$CanonicalHeaders = @(
    "Image_Index", "Source_Folder", "Source_File", "Condition_Field", "Condition_Unit", "Condition_Value",
    "ROI_Index", "Role", "Region", "Well_Position", "ROI_Number", "ROI_Shape", "ROI_X", "ROI_Y",
    "ROI_Width", "ROI_Height", "Area_px", "R", "G", "B"
)

function Read-RawRecords([string[]]$CsvFiles) {
    $records = New-Object System.Collections.Generic.List[object]
    for ($fileIndex = 0; $fileIndex -lt $CsvFiles.Count; $fileIndex++) {
        $csvPath = $CsvFiles[$fileIndex]
        $csvName = [System.IO.Path]::GetFileName($csvPath)
        $rows = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
        if ($rows.Count -eq 0) { continue }
        $headers = @($rows[0].PSObject.Properties.Name | ForEach-Object { $_.Trim() })
        foreach ($required in @("Source_File", "Region", "Well_Position", "R", "G", "B")) {
            if ($headers -notcontains $required) { throw "$csvName is missing required column: $required" }
        }
        $rowNumber = 1
        foreach ($row in $rows) {
            $rowNumber++
            $source = @{}
            foreach ($property in $row.PSObject.Properties) {
                $value = [string]$property.Value
                $name = $property.Name.Trim()
                if ($NumericColumns -contains $name -and $value -ne "") {
                    $source[$name] = ConvertTo-Double $value "$name at $csvName row $rowNumber"
                } else {
                    $source[$name] = $value
                }
            }
            $record = [ordered]@{}
            foreach ($header in $CanonicalHeaders) {
                if ($source.ContainsKey($header)) { $record[$header] = $source[$header] } else { $record[$header] = "" }
            }
            if ($record.Image_Index -is [string] -and $record.Image_Index -eq "") { $record.Image_Index = [double]($fileIndex + 1) }
            if (-not $record.Source_Folder) { $record.Source_Folder = "." }
            if (-not $record.Source_File) {
                $record.Source_File = ($csvName -replace '__RGB_Raw_3ROI\.csv$', '.jpg' -replace '\.csv$', '.jpg')
            }
            if (-not $record.Condition_Value) { $record.Condition_Value = Get-Stem $record.Source_File }
            if ($record.ROI_Index -is [string] -and $record.ROI_Index -eq "") { $record.ROI_Index = [double]($rowNumber - 1) }
            if (-not $record.Role) {
                $region = (Get-NormalizedText $record.Region).ToLowerInvariant()
                if ($region.Contains("black")) { $record.Role = "BlackReference" }
                elseif ($region.Contains("white")) { $record.Role = "WhiteReference" }
                elseif ($region.Contains("sample")) { $record.Role = "Sample" }
            }
            $records.Add([pscustomobject]$record)
        }
    }
    if ($records.Count -eq 0) { throw "The raw-RGB CSV input contains no data rows." }
    $seen = @{}
    foreach ($record in $records) {
        $key = "$($record.Image_Index)|$($record.Source_File)|$($record.ROI_Index)|$($record.Role)"
        if ($seen.ContainsKey($key)) { throw "Duplicate raw-RGB row detected: $key" }
        $seen[$key] = $true
    }
    return ,$records
}

# ---------------------------------------------------------------------------
# Calculation
# ---------------------------------------------------------------------------

function Invoke-Calculation($Records, [string[]]$SelectedWells, $Settings) {
    $imageMap = [ordered]@{}
    foreach ($record in $Records) {
        $key = "$($record.Image_Index)|$($record.Source_File)"
        if (-not $imageMap.Contains($key)) {
            $condition = ConvertTo-Condition $record.Condition_Value $record.Condition_Unit
            $imageMap[$key] = [pscustomobject]@{
                Key = $key; ImageIndex = [double]$record.Image_Index; SourceFile = [string]$record.Source_File
                Condition = $condition; Label = (Get-ConditionLabel $condition)
                Rows = (New-Object System.Collections.Generic.List[object])
            }
        }
        $imageMap[$key].Rows.Add($record)
    }
    $units = @($imageMap.Values | Where-Object { $_.Condition.IsNumeric } | ForEach-Object { $_.Condition.Unit } | Select-Object -Unique)
    if ($units.Count -gt 1) {
        throw "The input contains incompatible numeric condition units ($($units -join ', ')). Process one condition type per file."
    }
    $hasLabels = @($imageMap.Values | Where-Object { -not $_.Condition.IsNumeric }).Count -gt 0
    $unit = "label"
    if ($units.Count -eq 1) { $unit = $units[0] }

    $images = @($imageMap.Values | Sort-Object `
        @{ Expression = { if ($_.Condition.IsNumeric) { 0 } else { 1 } } },
        @{ Expression = { if ($_.Condition.IsNumeric) { [double]$_.Condition.Value } else { 0.0 } } },
        @{ Expression = { $_.ImageIndex } },
        @{ Expression = { $_.SourceFile } })

    $wellRows = New-Object System.Collections.Generic.List[object]
    foreach ($image in $images) {
        $blackRows = @($image.Rows | Where-Object { (Get-RoleClass $_) -eq "black" })
        $whiteRows = @($image.Rows | Where-Object { (Get-RoleClass $_) -eq "white" })
        $allSamples = @($image.Rows | Where-Object { (Get-RoleClass $_) -eq "sample" })
        $samples = @($allSamples | Where-Object {
            $wellName = $_.Well_Position
            if (-not $wellName) { $wellName = $_.Region }
            Test-WellSelected $wellName $SelectedWells
        })
        if ($blackRows.Count -eq 0 -or $whiteRows.Count -eq 0 -or $samples.Count -eq 0) {
            $available = @($allSamples | ForEach-Object { if ($_.Well_Position) { $_.Well_Position } else { $_.Region } } | Select-Object -Unique) -join ", "
            throw "$($image.SourceFile) must contain at least one black reference, one white reference and one included sample ROI. Found black=$($blackRows.Count), white=$($whiteRows.Count), included sample=$($samples.Count). Available wells: $available."
        }
        $black = [pscustomobject]@{ R = (Get-Mean ($blackRows | ForEach-Object { [double]$_.R })); G = (Get-Mean ($blackRows | ForEach-Object { [double]$_.G })); B = (Get-Mean ($blackRows | ForEach-Object { [double]$_.B })) }
        $white = [pscustomobject]@{ R = (Get-Mean ($whiteRows | ForEach-Object { [double]$_.R })); G = (Get-Mean ($whiteRows | ForEach-Object { [double]$_.G })); B = (Get-Mean ($whiteRows | ForEach-Object { [double]$_.B })) }
        foreach ($channel in @("R", "G", "B")) {
            if (-not ($white.$channel -gt 0)) { throw "$($image.SourceFile) has an invalid white $channel reference." }
        }
        $factor = [pscustomobject]@{ R = 255.0 / $white.R; G = 255.0 / $white.G; B = 255.0 / $white.B }

        $groups = [ordered]@{}
        foreach ($row in $samples) {
            $well = [string]$row.Well_Position
            if (-not $well) { $well = [string]$row.Region }
            if (-not $well) { $well = "ROI_$($row.ROI_Index)" }
            if (-not $groups.Contains($well)) {
                $groups[$well] = [pscustomobject]@{ Well = $well; FirstRoi = [double]$row.ROI_Index; Rows = (New-Object System.Collections.Generic.List[object]) }
            }
            $group = $groups[$well]
            $group.FirstRoi = [Math]::Min($group.FirstRoi, [double]$row.ROI_Index)
            $group.Rows.Add($row)
        }
        foreach ($group in @($groups.Values | Sort-Object FirstRoi, Well)) {
            $assay = [pscustomobject]@{
                R = (Get-Mean ($group.Rows | ForEach-Object { [double]$_.R }))
                G = (Get-Mean ($group.Rows | ForEach-Object { [double]$_.G }))
                B = (Get-Mean ($group.Rows | ForEach-Object { [double]$_.B }))
            }
            $balanced = [pscustomobject]@{ R = $assay.R * $factor.R; G = $assay.G * $factor.G; B = $assay.B * $factor.B }
            $corrected = [pscustomobject]@{ R = $balanced.R - $black.R; G = $balanced.G - $black.G; B = $balanced.B - $black.B }
            $lab = ConvertTo-Lab $corrected.R $corrected.G $corrected.B
            $sortValue = [double]::PositiveInfinity
            if ($image.Condition.IsNumeric) { $sortValue = [double]$image.Condition.Value }
            $wellRows.Add([pscustomobject]@{
                ImageKey = $image.Key; ImageIndex = $image.ImageIndex; SortValue = $sortValue
                ConditionValue = $image.Condition.Value; Well = $group.Well; WellOrder = $group.FirstRoi
                RoiCount = $group.Rows.Count; Assay = $assay; Black = $black; White = $white
                Factor = $factor; Balanced = $balanced; Corrected = $corrected; Lab = $lab
            })
        }
    }

    $summaries = foreach ($image in $images) {
        $wells = @($wellRows | Where-Object { $_.ImageKey -eq $image.Key })
        $summary = [pscustomobject]@{
            Key = $image.Key; SourceFile = $image.SourceFile; ConditionValue = $image.Condition.Value
            IsNumeric = $image.Condition.IsNumeric; Label = $image.Label; WellCount = $wells.Count; Wells = $wells
            CorrectedR = (Get-Mean ($wells | ForEach-Object { $_.Corrected.R }))
            CorrectedG = (Get-Mean ($wells | ForEach-Object { $_.Corrected.G }))
            CorrectedB = (Get-Mean ($wells | ForEach-Object { $_.Corrected.B }))
            L = (Get-Mean ($wells | ForEach-Object { $_.Lab.L })); LSd = (Get-SampleSd ($wells | ForEach-Object { $_.Lab.L }))
            A = (Get-Mean ($wells | ForEach-Object { $_.Lab.A })); ASd = (Get-SampleSd ($wells | ForEach-Object { $_.Lab.A }))
            B = (Get-Mean ($wells | ForEach-Object { $_.Lab.B })); BSd = (Get-SampleSd ($wells | ForEach-Object { $_.Lab.B }))
            InverseL = (Get-Mean ($wells | ForEach-Object { 100.0 - $_.Lab.L }))
            Hue = 0.0; CorrectedBStar = 0.0; DeltaL = 0.0; DeltaA = 0.0; DeltaB = 0.0; DeltaE = 0.0
        }
        $summary.Hue = Get-HueAngle $summary.A $summary.B
        $summary
    }
    $summaries = @($summaries)

    $reference = $null
    if ($Settings.reference_file) {
        $requested = (Get-NormalizedText ([string]$Settings.reference_file)).ToLowerInvariant()
        $reference = $summaries | Where-Object {
            (Get-NormalizedText $_.SourceFile).ToLowerInvariant() -eq $requested -or (Get-NormalizedText (Get-Stem $_.SourceFile)).ToLowerInvariant() -eq $requested
        } | Select-Object -First 1
        if (-not $reference) {
            throw "Reference file `"$($Settings.reference_file)`" is not present. Available files: $(($summaries | ForEach-Object { $_.SourceFile }) -join ', ')"
        }
    } elseif ($null -ne $Settings.reference_value -and "$($Settings.reference_value)" -ne "") {
        $requestedValue = ConvertTo-Double ([string]$Settings.reference_value) "reference_value"
        $tolerance = [Math]::Max(1e-9, [Math]::Abs($requestedValue) * 1e-9)
        $reference = $summaries | Where-Object { $_.IsNumeric -and [Math]::Abs([double]$_.ConditionValue - $requestedValue) -le $tolerance } | Select-Object -First 1
        if (-not $reference) {
            throw "Reference $requestedValue $unit is not present. Available: $(($summaries | ForEach-Object { $_.ConditionValue }) -join ', ')"
        }
    } else {
        $reference = $summaries | Where-Object { $_.IsNumeric -and [double]$_.ConditionValue -eq 0 } | Select-Object -First 1
        if (-not $reference) { $reference = $summaries | Where-Object { $_.IsNumeric } | Select-Object -First 1 }
        if (-not $reference) { $reference = $summaries[0] }
    }
    foreach ($summary in $summaries) {
        $summary.CorrectedBStar = $summary.B - $reference.B
        $summary.DeltaL = $summary.L - $reference.L
        $summary.DeltaA = $summary.A - $reference.A
        $summary.DeltaB = $summary.B - $reference.B
        $summary.DeltaE = [Math]::Sqrt($summary.DeltaL * $summary.DeltaL + $summary.DeltaA * $summary.DeltaA + $summary.DeltaB * $summary.DeltaB)
    }

    $wellOrder = New-Object System.Collections.Generic.List[string]
    foreach ($image in $images) {
        foreach ($row in @($image.Rows | Where-Object { (Get-RoleClass $_) -eq "sample" } | Sort-Object { [double]$_.ROI_Index })) {
            $well = [string]$row.Well_Position
            if (-not $well) { $well = [string]$row.Region }
            if (-not $well) { $well = "Sample" }
            if (-not $wellOrder.Contains($well)) { $wellOrder.Add($well) }
        }
    }

    $conditionHeader = "Concentration ($unit)"
    if ($hasLabels) { $conditionHeader = "Condition" }
    return [pscustomobject]@{
        Images = $images; ImageMap = $imageMap; WellRows = @($wellRows | Sort-Object SortValue, ImageIndex, WellOrder, Well)
        Summaries = $summaries; Reference = $reference; WellOrder = $wellOrder; Unit = $unit
        HasLabels = $hasLabels; ConditionHeader = $conditionHeader
    }
}

# ---------------------------------------------------------------------------
# Minimal .xlsx writer (Office Open XML in a zip, no extra software needed)
# ---------------------------------------------------------------------------

# Cell styles defined in Get-StylesXml.
$S = @{ Default = 0; Header = 1; Num2 = 2; Num3 = 3; Conc = 4; Int = 5; Bold = 6; Wrap = 7; Title = 8; Note = 9 }

function New-Cell($Value, [int]$Style = 0) { return [pscustomobject]@{ Value = $Value; Style = $Style } }

function Get-ColumnLetter([int]$Index) {
    $number = $Index + 1
    $label = ""
    while ($number -gt 0) {
        $remainder = ($number - 1) % 26
        $label = [string][char](65 + $remainder) + $label
        $number = [Math]::Floor(($number - 1) / 26)
    }
    return $label
}

function ConvertTo-XmlText([string]$Text) {
    $clean = [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    return [System.Security.SecurityElement]::Escape($clean)
}

function Get-SheetXml($Rows, [double[]]$Widths, [int]$FreezeRows, [int]$FreezeColumns) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0" showGridLines="0">')
    if ($FreezeRows -gt 0 -or $FreezeColumns -gt 0) {
        $topLeft = "$(Get-ColumnLetter $FreezeColumns)$($FreezeRows + 1)"
        $pane = "bottomLeft"
        if ($FreezeColumns -gt 0 -and $FreezeRows -gt 0) { $pane = "bottomRight" } elseif ($FreezeColumns -gt 0) { $pane = "topRight" }
        $split = ""
        if ($FreezeColumns -gt 0) { $split += " xSplit=`"$FreezeColumns`"" }
        if ($FreezeRows -gt 0) { $split += " ySplit=`"$FreezeRows`"" }
        [void]$builder.Append("<pane$split topLeftCell=`"$topLeft`" activePane=`"$pane`" state=`"frozen`"/>")
    }
    [void]$builder.Append('</sheetView></sheetViews><cols>')
    for ($index = 0; $index -lt $Widths.Count; $index++) {
        [void]$builder.Append("<col min=`"$($index + 1)`" max=`"$($index + 1)`" width=`"$($Widths[$index].ToString($Invariant))`" customWidth=`"1`"/>")
    }
    [void]$builder.Append('</cols><sheetData>')
    for ($rowIndex = 0; $rowIndex -lt $Rows.Count; $rowIndex++) {
        $row = $Rows[$rowIndex]
        [void]$builder.Append("<row r=`"$($rowIndex + 1)`">")
        for ($columnIndex = 0; $columnIndex -lt $row.Count; $columnIndex++) {
            $cell = $row[$columnIndex]
            if ($null -eq $cell) { continue }
            $reference = "$(Get-ColumnLetter $columnIndex)$($rowIndex + 1)"
            $value = $cell.Value
            $styleAttribute = ""
            if ($cell.Style -ne 0) { $styleAttribute = " s=`"$($cell.Style)`"" }
            if ($null -eq $value -or ($value -is [double] -and ([double]::IsNaN($value) -or [double]::IsInfinity($value)))) {
                if ($cell.Style -ne 0) { [void]$builder.Append("<c r=`"$reference`"$styleAttribute/>") }
            } elseif ($value -is [double] -or $value -is [int] -or $value -is [long]) {
                [void]$builder.Append("<c r=`"$reference`"$styleAttribute><v>$(([double]$value).ToString('R', $Invariant))</v></c>")
            } else {
                [void]$builder.Append("<c r=`"$reference`"$styleAttribute t=`"inlineStr`"><is><t xml:space=`"preserve`">$(ConvertTo-XmlText ([string]$value))</t></is></c>")
            }
        }
        [void]$builder.Append('</row>')
    }
    [void]$builder.Append('</sheetData></worksheet>')
    return $builder.ToString()
}

function Get-StylesXml {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<numFmts count="1"><numFmt numFmtId="164" formatCode="0.000"/></numFmts>' +
        '<fonts count="5"><font><sz val="10"/><color rgb="FF1F2937"/><name val="Arial"/></font>' +
        '<font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Arial"/></font>' +
        '<font><b/><sz val="10"/><color rgb="FF1F2937"/><name val="Arial"/></font>' +
        '<font><i/><sz val="10"/><color rgb="FF4B5563"/><name val="Arial"/></font>' +
        '<font><b/><sz val="12"/><color rgb="FFFFFFFF"/><name val="Arial"/></font></fonts>' +
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill></fills>' +
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="10">' +
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>' +
        '<xf numFmtId="2" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="1" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
        '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top"/></xf>' +
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>' +
        '<xf numFmtId="0" fontId="4" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>' +
        '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
        '</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
}

function Save-Workbook([string]$Path, $Sheets) {
    $temporary = "$Path.tmp"
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $stream = [System.IO.File]::Open($temporary, [System.IO.FileMode]::CreateNew)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = [ordered]@{}
        $overrides = ""
        $sheetList = ""
        $relationships = ""
        for ($index = 0; $index -lt $Sheets.Count; $index++) {
            $number = $index + 1
            $entries["xl/worksheets/sheet$number.xml"] = $Sheets[$index].Xml
            $overrides += "<Override PartName=`"/xl/worksheets/sheet$number.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>"
            $sheetList += "<sheet name=`"$(ConvertTo-XmlText $Sheets[$index].Name)`" sheetId=`"$number`" r:id=`"rId$number`"/>"
            $relationships += "<Relationship Id=`"rId$number`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$number.xml`"/>"
        }
        $styleId = $Sheets.Count + 1
        $relationships += "<Relationship Id=`"rId$styleId`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/>"
        $entries["[Content_Types].xml"] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' + $overrides + '</Types>'
        $entries["_rels/.rels"] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
        $entries["xl/workbook.xml"] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>' + $sheetList + '</sheets></workbook>'
        $entries["xl/_rels/workbook.xml.rels"] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + $relationships + '</Relationships>'
        $entries["xl/styles.xml"] = Get-StylesXml
        foreach ($name in $entries.Keys) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object System.IO.StreamWriter($entry.Open(), $utf8)
            $writer.Write($entries[$name])
            $writer.Dispose()
        }
    } finally {
        $zip.Dispose()
        $stream.Dispose()
    }
    try {
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw "Cannot replace $([System.IO.Path]::GetFileName($Path)). Close it in Excel and run Convert again."
    }
}

# ---------------------------------------------------------------------------
# Workbook content (same sheets as before)
# ---------------------------------------------------------------------------

function New-TableRows([string[]]$Headers, $DataRows) {
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@($Headers | ForEach-Object { New-Cell $_ $S.Header }))
    foreach ($dataRow in $DataRows) { $rows.Add($dataRow) }
    # The leading comma keeps the list from being unrolled into a fixed array.
    return ,$rows
}

function Get-ConditionCell($Value) {
    if ($Value -is [double]) { return New-Cell $Value $S.Conc }
    return New-Cell ([string]$Value)
}

function New-WorkbookSheets($Result, [string]$DatasetName, [string[]]$SelectedWells, [int]$CsvCount, [int]$RawCount, $Records) {
    $reference = $Result.Reference
    $referenceText = "$($reference.Label) ($($reference.SourceFile))"
    $wellCounts = @($Result.Summaries | ForEach-Object { $_.WellCount } | Measure-Object -Minimum -Maximum)
    $roiCounts = @($Result.WellRows | ForEach-Object { $_.RoiCount } | Measure-Object -Minimum -Maximum)
    $sheets = New-Object System.Collections.Generic.List[object]

    # README
    $conditionType = $Result.Unit
    if ($Result.HasLabels) { $conditionType = "Numeric unit: $($Result.Unit); nonnumeric sample labels are preserved as named conditions." }
    $includedText = "All sample wells present in the Raw RGB data"
    if ($SelectedWells.Count -gt 0) { $includedText = $SelectedWells -join ", " }
    $readmeItems = @(
        @("Dataset", $DatasetName),
        @("Source CSV files", "$CsvCount file(s); original Source_File names are preserved in Raw RGB."),
        @("Raw rows", [double]$RawCount),
        @("Source images / conditions", [double]$Result.Images.Count),
        @("Detected condition type", $conditionType),
        @("Included sample wells", $includedText),
        @("Sample wells per image", "$($wellCounts[0].Minimum)$EnDash$($wellCounts[0].Maximum)"),
        @("Sample ROIs per well", "$($roiCounts[0].Minimum)$EnDash$($roiCounts[0].Maximum)"),
        @("${Delta}E reference", "$referenceText; automatically uses 0 when present, otherwise the lowest numeric concentration or the first named condition."),
        @("Black reference", "Channel-wise mean of all rows identified as black reference within the same source image."),
        @("White reference", "Channel-wise mean of all rows identified as white reference within the same source image."),
        @("Assay RGB", "Channel-wise mean of all Sample ROI rows with the same Well_Position within one source image."),
        @("White-balance factor", "FactorR = 255 / WhiteR; FactorG and FactorB are calculated in the same way."),
        @("White balance", "White-balanced channel = Assay channel $Times white-balance factor."),
        @("Corrected RGB", "Corrected channel = White-balanced channel $Minus black-reference mean."),
        @("CIELAB", "Corrected RGB is clipped to 0$($EnDash)255, linearized as sRGB, transformed to XYZ and converted to CIELAB with D65 reference white."),
        @("Summary and SD", "Means and sample SD (n$($Minus)1) are calculated across the sample wells in each source image. SD is blank when only one sample well exists."),
        @("CIE76 ${Delta}E*ab", "${Delta}E = SQRT[(L*$($Minus)L*ref)^2 + (a*$($Minus)a*ref)^2 + (b*$($Minus)b*ref)^2], using condition-level mean LAB values."),
        @("Hue angle", "h$Degree = MOD[atan2(b*, a*) $Times 180/$([char]0x03C0), 360], using condition-level mean a* and b*."),
        @("Raw-data protection", "The source CSV is read only and is reproduced in the Raw RGB sheet. The workbook is a separate output file.")
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@((New-Cell "RGB to CIELAB, ${Delta}E and hue angle" $S.Title), (New-Cell "" $S.Title)))
    $rows.Add(@((New-Cell "$DatasetName calculation record generated from ImageJ Raw RGB data." $S.Note)))
    $rows.Add(@())
    $rows.Add(@((New-Cell "Item" $S.Header), (New-Cell "Specification" $S.Header)))
    foreach ($item in $readmeItems) { $rows.Add(@((New-Cell $item[0] $S.Bold), (New-Cell $item[1] $S.Wrap))) }
    $sheets.Add([pscustomobject]@{ Name = "README"; Xml = (Get-SheetXml $rows @(27, 112) 0 0) })

    # Summary
    $headers = @($Result.ConditionHeader, "Corrected R mean", "Corrected G mean", "Corrected B mean", "L* mean", "L* SD", "a* mean", "a* SD", "b* mean", "Corrected b*", "b* SD", "100$($Minus)L* mean") +
        @($Result.WellOrder | ForEach-Object { "b* $_" }) + @("${Delta}E*ab (CIE76)", "Hue angle ($Degree)")
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add(@(New-Cell "Table S1. $DatasetName corrected RGB, CIELAB, ${Delta}E and hue-angle results" $S.Title) + @(1..($headers.Count - 1) | ForEach-Object { New-Cell "" $S.Title }))
    $rows.Add(@(New-Cell "$($Result.Summaries.Count) source image(s); $($Result.WellRows.Count) sample well(s); ${Delta}E reference $($reference.Label)." $S.Note))
    $rows.Add(@($headers | ForEach-Object { New-Cell $_ $S.Header }))
    foreach ($summary in $Result.Summaries) {
        $bByWell = @{}
        foreach ($well in $summary.Wells) { $bByWell[$well.Well] = $well.Lab.B }
        $cells = @((Get-ConditionCell $summary.ConditionValue)) +
            @($summary.CorrectedR, $summary.CorrectedG, $summary.CorrectedB, $summary.L, $summary.LSd, $summary.A, $summary.ASd, $summary.B, $summary.CorrectedBStar, $summary.BSd, $summary.InverseL | ForEach-Object { New-Cell $_ $S.Num2 }) +
            @($Result.WellOrder | ForEach-Object { New-Cell $bByWell[$_] $S.Num2 }) +
            @((New-Cell $summary.DeltaE $S.Num2), (New-Cell $summary.Hue $S.Num2))
        $rows.Add($cells)
    }
    $rows.Add(@())
    $rows.Add(@(New-Cell "Reference: $referenceText. Corrected b* = b* mean $Minus reference b* mean. Hue angle uses mean a* and b*. Named conditions are retained as labels." $S.Note))
    $widths = @(20, 15, 15, 15, 12, 11, 12, 11, 12, 13, 11, 14) + @($Result.WellOrder | ForEach-Object { 17 }) + @(15, 15)
    $sheets.Add([pscustomobject]@{ Name = "Summary"; Xml = (Get-SheetXml $rows $widths 3 0) })

    # Well RGB
    $headers = @($Result.ConditionHeader, "Well", "n (ROI)", "Assay R", "Assay G", "Assay B", "Black R", "Black G", "Black B", "White R", "White G", "White B",
        "Factor R", "Factor G", "Factor B", "White balance R", "White balance G", "White balance B", "Corrected R", "Corrected G", "Corrected B")
    $data = @(foreach ($row in $Result.WellRows) {
        ,(@((Get-ConditionCell $row.ConditionValue), (New-Cell $row.Well), (New-Cell ([double]$row.RoiCount) $S.Int)) +
            @($row.Assay.R, $row.Assay.G, $row.Assay.B, $row.Black.R, $row.Black.G, $row.Black.B, $row.White.R, $row.White.G, $row.White.B,
              $row.Factor.R, $row.Factor.G, $row.Factor.B, $row.Balanced.R, $row.Balanced.G, $row.Balanced.B,
              $row.Corrected.R, $row.Corrected.G, $row.Corrected.B | ForEach-Object { New-Cell $_ $S.Num3 }))
    })
    $sheets.Add([pscustomobject]@{ Name = "Well RGB"; Xml = (Get-SheetXml (New-TableRows $headers $data) @(20, 23, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 15, 15, 15, 13, 13, 13) 1 2) })

    # LAB Calculations
    $headers = @($Result.ConditionHeader, "Well", "Corrected R", "Corrected G", "Corrected B", "L*", "a*", "b*", "100$($Minus)L*")
    $data = @(foreach ($row in $Result.WellRows) {
        ,(@((Get-ConditionCell $row.ConditionValue), (New-Cell $row.Well)) +
            @($row.Corrected.R, $row.Corrected.G, $row.Corrected.B, $row.Lab.L, $row.Lab.A, $row.Lab.B, (100.0 - $row.Lab.L) | ForEach-Object { New-Cell $_ $S.Num3 }))
    })
    $rows = New-TableRows $headers $data
    $rows.Add(@())
    $rows.Add(@((New-Cell "RGB $([char]0x2192) CIELAB (D65) calculation details" $S.Header), (New-Cell "" $S.Header)))
    $notes = @(
        @("1. Reference averaging", "Black and white RGB values are channel-wise means within each source image."),
        @("2. White balancing", "Factor = 255 / White; White-balanced RGB = Assay RGB $Times Factor; Corrected RGB = White-balanced RGB $Minus Black."),
        @("3. Valid sRGB range", "Each corrected channel is clipped to 0$($EnDash)255 before CIELAB conversion; the unclipped corrected value remains visible in the table."),
        @("4. Linearization", "c = clipped value / 255; c_lin = c / 12.92 when c $([char]0x2264) 0.04045, otherwise ((c + 0.055) / 1.055)^2.4."),
        @("5. XYZ", "X=0.412390799265959R+0.357584339383878G+0.180480788401834B; Y=0.212639005871510R+0.715168678767756G+0.072192315360734B; Z=0.019330818715592R+0.119194779794626G+0.950532152249660B."),
        @("6. D65 normalization", "x=X/0.95047; y=Y/1.00000; z=Z/1.08883."),
        @("7. CIELAB helper", "f(t)=t^(1/3) when t>216/24389; otherwise f(t)=[(24389/27)t+16]/116."),
        @("8. CIELAB", "L*=116f(y)$($Minus)16; a*=500[f(x)$($Minus)f(y)]; b*=200[f(y)$($Minus)f(z)].")
    )
    foreach ($note in $notes) { $rows.Add(@((New-Cell $note[0] $S.Bold), (New-Cell $note[1] $S.Wrap))) }
    $sheets.Add([pscustomobject]@{ Name = "LAB Calculations"; Xml = (Get-SheetXml $rows @(29, 23, 14, 14, 14, 12, 12, 12, 13) 1 2) })

    # Delta E and hue angle
    $headers = @($Result.ConditionHeader, "Well / basis", "L* mean", "a* mean", "b* mean", "Reference L*", "Reference a*", "Reference b*",
        "${Delta}L*", "${Delta}a*", "${Delta}b*", "${Delta}E*ab (CIE76)", "Hue angle ($Degree)")
    $data = @(foreach ($summary in $Result.Summaries) {
        $basis = "Mean of $($summary.WellCount) wells"
        if ($summary.WellCount -eq 1) { $basis = $summary.Wells[0].Well }
        ,(@((Get-ConditionCell $summary.ConditionValue), (New-Cell $basis)) +
            @($summary.L, $summary.A, $summary.B, $reference.L, $reference.A, $reference.B, $summary.DeltaL, $summary.DeltaA, $summary.DeltaB, $summary.DeltaE, $summary.Hue | ForEach-Object { New-Cell $_ $S.Num2 }))
    })
    $rows = New-TableRows $headers $data
    $rows.Add(@())
    $rows.Add(@((New-Cell "${Delta}E and hue-angle calculation details" $S.Header), (New-Cell "" $S.Header)))
    $notes = @(
        @("Reference color", "$referenceText; 0 is preferred when present, otherwise the lowest numeric concentration or first named condition is used. Change it with conversion_settings.json."),
        @("Mean LAB source", "Each result row uses the mean L*, a* and b* across all sample wells in that source image."),
        @("Component differences", "${Delta}L*=L*sample$($Minus)L*reference; ${Delta}a*=a*sample$($Minus)a*reference; ${Delta}b*=b*sample$($Minus)b*reference."),
        @("CIE76", "${Delta}E*ab=SQRT[(${Delta}L*)^2+(${Delta}a*)^2+(${Delta}b*)^2]."),
        @("Hue angle", "h$Degree=MOD[atan2(b*,a*)$($Times)180/$([char]0x03C0),360]. 0$Degree=+a* red; 90$Degree=+b* yellow; 180$Degree=$($Minus)a* green; 270$Degree=$($Minus)b* blue.")
    )
    foreach ($note in $notes) { $rows.Add(@((New-Cell $note[0] $S.Bold), (New-Cell $note[1] $S.Wrap))) }
    $sheets.Add([pscustomobject]@{ Name = "${Delta}E and Hue angle"; Xml = (Get-SheetXml $rows @(29, 19, 12, 12, 12, 13, 13, 13, 11, 11, 11, 15, 15) 1 0) })

    # Raw RGB
    $headers = @("Image_Index", "Source_Folder", "Source_File", "Region", "Well_Position", "ROI_Number", "R", "G", "B", $Result.ConditionHeader,
        "Included_in_calculation", "ROI_Index", "Role", "ROI_Shape", "ROI_X", "ROI_Y", "ROI_Width", "ROI_Height", "Area_px", "Condition_Field", "Condition_Unit", "Condition_Value")
    $data = @(foreach ($record in $Records) {
        $image = $Result.ImageMap["$($record.Image_Index)|$($record.Source_File)"]
        $role = Get-RoleClass $record
        $included = "No"
        if ($role -eq "black" -or $role -eq "white") { $included = "Reference" }
        elseif ($role -eq "sample") {
            $wellName = $record.Well_Position
            if (-not $wellName) { $wellName = $record.Region }
            if (Test-WellSelected $wellName $SelectedWells) { $included = "Yes" }
        }
        $numberCell = { param($value, $style) if ($value -is [double]) { New-Cell $value $style } else { New-Cell ([string]$value) } }
        ,@(
            (& $numberCell $record.Image_Index $S.Int), (New-Cell $record.Source_Folder), (New-Cell $record.Source_File),
            (New-Cell $record.Region), (New-Cell $record.Well_Position), (& $numberCell $record.ROI_Number $S.Int),
            (New-Cell $record.R $S.Num3), (New-Cell $record.G $S.Num3), (New-Cell $record.B $S.Num3),
            (Get-ConditionCell $image.Condition.Value), (New-Cell $included), (& $numberCell $record.ROI_Index $S.Int),
            (New-Cell $record.Role), (New-Cell $record.ROI_Shape), (& $numberCell $record.ROI_X $S.Int), (& $numberCell $record.ROI_Y $S.Int),
            (& $numberCell $record.ROI_Width $S.Int), (& $numberCell $record.ROI_Height $S.Int), (& $numberCell $record.Area_px $S.Num3),
            (New-Cell $record.Condition_Field), (New-Cell $record.Condition_Unit), (New-Cell $record.Condition_Value)
        )
    })
    $widths = @(13, 18, 31, 20, 20, 13, 13, 13, 13, 13, 24, 13, 20, 13, 13, 13, 13, 13, 13, 18, 18, 31)
    $sheets.Add([pscustomobject]@{ Name = "Raw RGB"; Xml = (Get-SheetXml (New-TableRows $headers $data) $widths 1 3) })
    return $sheets
}

# ---------------------------------------------------------------------------
# Datasets in RawRGB_input
# ---------------------------------------------------------------------------

function Read-Settings([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
    } catch {
        throw "$([System.IO.Path]::GetFileName($Path)) cannot be read: $($_.Exception.Message)"
    }
}

function Get-Jobs {
    New-Item -ItemType Directory -Force -Path $InputRoot | Out-Null
    $rootSettings = Read-Settings (Join-Path $InputRoot $SettingsFileName)
    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(Get-ChildItem -LiteralPath $InputRoot | Sort-Object Name)) {
        if (-not $item.PSIsContainer -and $item.Extension -ieq ".csv") {
            $jobs.Add([pscustomobject]@{ Name = $item.BaseName; Files = @($item.FullName); Settings = $rootSettings; IsFolder = $false })
        } elseif ($item.PSIsContainer) {
            $csvFiles = @(Get-ChildItem -LiteralPath $item.FullName -Filter "*.csv" | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object { $_.FullName })
            if ($csvFiles.Count -eq 0) { continue }
            # A whole ImageJ output folder: the combined Batch__ file holds every row.
            $batchFiles = @($csvFiles | Where-Object { [System.IO.Path]::GetFileName($_) -match '^(?i)batch__.*\.csv$' })
            if ($batchFiles.Count -eq 1) { $csvFiles = $batchFiles }
            $jobs.Add([pscustomobject]@{ Name = $item.Name; Files = $csvFiles; Settings = (Read-Settings (Join-Path $item.FullName $SettingsFileName)); IsFolder = $true })
        }
    }
    return ,$jobs
}

function Get-SettingText($Settings, [string]$Name) {
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Get-SelectedWells($Settings) {
    $property = $Settings.PSObject.Properties["selected_wells"]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    $values = @($property.Value | ForEach-Object { [string]$_ })
    if ($values.Count -eq 1) { $values = @($values[0] -split '[,;|]') }
    $values = @($values | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($values.Count -eq 1 -and @("all", "*") -contains $values[0].ToLowerInvariant()) { return @() }
    return $values
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$jobs = Get-Jobs
if ($jobs.Count -eq 0) {
    Write-Host "No raw-RGB CSV was found in:"
    Write-Host $InputRoot
    exit 0
}
$failed = 0
foreach ($job in $jobs) {
    $datasetName = $job.Name
    $settingsName = Get-SettingText $job.Settings "dataset_name"
    if ($job.IsFolder -and $settingsName) { $datasetName = $settingsName }
    $outputName = "$datasetName$OutputSuffix"
    $requestedOutput = Get-SettingText $job.Settings "output_name"
    if ($job.IsFolder -and $requestedOutput) { $outputName = $requestedOutput -replace '\.xlsx$', '' }
    $outputPath = Join-Path $OutputRoot "$(Get-SafeFileName $outputName).xlsx"
    $errorPath = Join-Path $OutputRoot "$(Get-SafeFileName $outputName)$ErrorSuffix"
    Write-Host ""
    Write-Host "Converting: $datasetName"
    try {
        $selectedWells = Get-SelectedWells $job.Settings
        $settings = [pscustomobject]@{
            reference_file = (Get-SettingText $job.Settings "reference_file")
            reference_value = (Get-SettingText $job.Settings "reference_value")
        }
        $records = Read-RawRecords $job.Files
        $result = Invoke-Calculation $records $selectedWells $settings
        $sheets = New-WorkbookSheets $result $datasetName $selectedWells $job.Files.Count $records.Count $records
        Save-Workbook $outputPath $sheets
        if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath -Force }
        Write-Host "Done: $([System.IO.Path]::GetFileName($outputPath)) ($($result.Images.Count) images, $($result.WellRows.Count) sample wells; Delta E reference $($result.Reference.Label))"
    } catch {
        $failed++
        $message = "Conversion failed for: $($job.Files -join ', ')`r`n`r`n$($_.Exception.Message)"
        Write-Host $message -ForegroundColor Red
        [System.IO.File]::WriteAllText($errorPath, $message)
    }
}
Write-Host ""
Write-Host "Finished: $($jobs.Count - $failed) converted, $failed failed."
if ($failed -gt 0) { exit 1 }
