# ---------------------------------------------------------------------------------------------
#  Editor: state and operations behind the window (no Windows Forms here, so it is testable)
#  The window calls these functions and redraws; every change goes through Submit-FujiEditorChange
#  (undo history, "unsaved" mark, autosave to the temp file) like the HTA's commitChange.
#
#  Editor (hashtable):
#    Directory   folder of the macros file and the other working files
#    Log         { param($Message, $Level) }  Level: info | ok | warn | error
#    Data        [ordered]@{ version; macros = List }   (Data.ps1)
#    MacroIndex  current macro;  Selected  selected step index or -1
#    History     List of @{ Desc; Time; MacroIndex; Selected; Data };  HistoryPos
#    Dirty, SaveBlockReason (save needs confirming), Notices (shown once after start)
#    Csv         @{ Path; Encoding; Records; Header; Rows; Warnings }
#  A collapsed block start carries collapsed = $true (view state, never written to files).
# ---------------------------------------------------------------------------------------------

$script:FujiFileNames = @{
    Macro         = 'fujikyun_macros.json'
    Temp          = 'fujikyun_macros_temp.json'
    DiscardedTemp = 'fujikyun_macros_temp_discarded'
    Broken        = 'fujikyun_macros_broken'
    Backup        = 'fujikyun_macros_backup.json'
    Samples       = 'samples'
    Export        = 'macro_export'
    Images        = 'rpa_images'
}
$script:FujiHistoryLimit = 30

function New-FujiEditor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param([Parameter(Mandatory)][string]$Directory, [scriptblock]$Log = $null)
    return @{
        Directory       = $Directory
        Log             = $Log
        Data            = [ordered]@{ version = $script:FujiDataVersion; macros = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
        MacroIndex      = 0
        Selected        = -1
        History         = (New-Object -TypeName 'System.Collections.Generic.List[object]')
        HistoryPos      = -1
        Dirty           = $false
        SaveBlockReason = ''
        Notices         = (New-Object -TypeName 'System.Collections.Generic.List[string]')
        Csv             = (New-FujiCsvState)
    }
}

function Write-FujiEditorLog {
    param([hashtable]$Editor, [string]$Message, [string]$Level = 'info')
    if ($Editor.Log) { & $Editor.Log $Message $Level }
}

function Get-FujiEditorPath {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Name)
    return (Join-Path -Path $Editor.Directory -ChildPath $Name)
}

# A path typed by the user: absolute (C:\.. or \\server\..) as is, otherwise inside the working folder
function Resolve-FujiEditorPath {
    param([Parameter(Mandatory)][hashtable]$Editor, [AllowEmptyString()][string]$Path)
    $p = ([string]$Path).Trim().Trim('"')
    if ($p -eq '') { return '' }
    if ($p -match '^[A-Za-z]:[\\/]' -or $p -match '^\\\\') { return $p }
    return (Get-FujiEditorPath -Editor $Editor -Name ($p -replace '/', '\'))
}

function Get-FujiTimeStamp { return (Get-Date -Format 'yyyyMMdd_HHmmss') }

# File name from free text (macro names): no path characters, at most 80 characters
function Get-FujiSafeFileName {
    param([AllowEmptyString()][string]$Text)
    $name = ([regex]::Replace([string]$Text, '[\\/:*?"<>|\r\n\t]', '_')).Trim()
    if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
    return $name
}

# ----------------------------------------------------------------- copies (undo history, duplicates)
function Copy-FujiStep {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Step)
    $o = [ordered]@{}
    foreach ($k in $Step.Keys) { $o[$k] = $Step[$k] }
    return $o
}

function Copy-FujiMacro {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Macro)
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($s in $Macro.steps) {
        $o = [ordered]@{}
        foreach ($k in $s.Keys) { $o[$k] = $s[$k] }
        $steps.Add($o)
    }
    return [ordered]@{ id = $Macro.id; name = $Macro.name; targetWindow = $Macro.targetWindow; steps = $steps }
}

function Copy-FujiMacroData {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($m in $Data.macros) { $list.Add((Copy-FujiMacro -Macro $m)) }
    return [ordered]@{ version = $Data.version; macros = $list }
}

# ----------------------------------------------------------------- current macro
function Get-FujiCurrentMacro {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $i = $Editor.MacroIndex
    if ($i -ge 0 -and $i -lt $Editor.Data.macros.Count) { return $Editor.Data.macros[$i] }
    return $null
}

function Get-FujiCurrentStepList {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $m = Get-FujiCurrentMacro -Editor $Editor
    if ($null -eq $m) { return , (New-Object -TypeName 'System.Collections.Generic.List[object]') }
    return , $m.steps
}

function New-FujiMacroId {
    param([Parameter(Mandatory)][hashtable]$Editor)
    do {
        $id = New-FujiId
        $used = $false
        foreach ($m in $Editor.Data.macros) { if ($m.id -eq $id) { $used = $true } }
    } while ($used)
    return $id
}

# { param($Id) ... } giving a macro's current name (CALL_MACRO labels)
function Get-FujiMacroNameLookup {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $ed = $Editor
    return {
        param($Id)
        foreach ($m in $ed.Data.macros) { if ($m.id -eq $Id) { return $m.name } }
        return ''
    }.GetNewClosure()
}

function Initialize-FujiMacroList {
    param([Parameter(Mandatory)][hashtable]$Editor)
    if ($Editor.Data.macros.Count -eq 0) {
        $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $Editor.Data.macros.Add([ordered]@{ id = (New-FujiMacroId -Editor $Editor); name = (Get-FujiText 'editor.newMacro'); targetWindow = ''; steps = $steps })
    }
    if ($Editor.MacroIndex -lt 0 -or $Editor.MacroIndex -ge $Editor.Data.macros.Count) { $Editor.MacroIndex = 0 }
}

# ----------------------------------------------------------------- loading and saving
function New-FujiSampleData {
    $steps = @(
        [ordered]@{ cmd = 'COMMENT'; val = (Get-FujiText 'editor.sampleComment'); label = '' }
        [ordered]@{ cmd = 'GROUP_START'; val = (Get-FujiText 'editor.sampleGroup'); label = '' }
        [ordered]@{ cmd = 'CSV'; val = '1'; label = '' }
        [ordered]@{ cmd = 'KEY'; val = '{TAB}'; label = '' }
        [ordered]@{ cmd = 'CSV'; val = '2'; label = '' }
        [ordered]@{ cmd = 'KEY'; val = '{ENTER}'; label = '' }
        [ordered]@{ cmd = 'GROUP_END'; val = ''; label = '' }
        [ordered]@{ cmd = 'WAIT'; val = '500'; label = '' }
    )
    return [ordered]@{
        version = $script:FujiDataVersion
        macros  = @([ordered]@{ id = (New-FujiId); name = (Get-FujiText 'editor.sampleName'); targetWindow = (Get-FujiText 'editor.sampleTarget'); steps = $steps })
    }
}

# Parsed file content, or $null (logged) when the file cannot be read as JSON
function Read-FujiMacroFile {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Path)
    try {
        return (ConvertFrom-FujiJson -Json (Read-FujiUtf8File -Path $Path))
    } catch {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.readFailed' $Path $_.Exception.Message) -Level 'error'
        return $null
    }
}

function Get-FujiFileDataVersion {
    param($Source)
    if ($Source -is [System.Collections.IDictionary] -and $Source.Contains('version') -and $Source['version'] -is [ValueType]) {
        return [double]$Source['version']
    }
    return 0
}

# A file from a newer edition: saving it here would turn unknown commands into comments
function Test-FujiEditorDataVersion {
    param([Parameter(Mandatory)][hashtable]$Editor, $Source, [string]$What)
    $v = Get-FujiFileDataVersion -Source $Source
    if ($v -gt $script:FujiDataVersion) {
        $Editor.SaveBlockReason = Get-FujiText 'editor.newerVersion' $What $v $script:FujiDataVersion
        $Editor.Notices.Add($Editor.SaveBlockReason)
    }
}

# Moves the temp file aside under a timestamped name; $false when it could not be moved
function Move-FujiTempFileAside {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $name = $script:FujiFileNames.DiscardedTemp + '_' + (Get-FujiTimeStamp) + '.json'
    try {
        Move-Item -LiteralPath (Get-FujiEditorPath $Editor $script:FujiFileNames.Temp) -Destination (Get-FujiEditorPath $Editor $name) -ErrorAction Stop
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.tempMoved' $name)
        return $true
    } catch {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.tempMoveFailed' $_.Exception.Message) -Level 'warn'
        return $false
    }
}

function Copy-FujiUnreadableFile {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Path)
    $name = $script:FujiFileNames.Broken + '_' + (Get-FujiTimeStamp) + '.json'
    $dest = Get-FujiEditorPath $Editor $name
    try {
        if (Test-Path -LiteralPath $dest) { return '' }
        Copy-Item -LiteralPath $Path -Destination $dest -ErrorAction Stop
        return $name
    } catch {
        return ''
    }
}

# Startup (the HTA's loadInitialData). AskRestoreTemp: { $true = restore the temp file }
function Initialize-FujiEditorData {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][scriptblock]$AskRestoreTemp)
    $loaded = $null
    $tempPath = Get-FujiEditorPath $Editor $script:FujiFileNames.Temp
    $mainPath = Get-FujiEditorPath $Editor $script:FujiFileNames.Macro
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
        if (& $AskRestoreTemp) {
            $loaded = Read-FujiMacroFile -Editor $Editor -Path $tempPath
            if ($null -ne $loaded) {
                $Editor.Dirty = $true
                Test-FujiEditorDataVersion -Editor $Editor -Source $loaded -What (Get-FujiText 'editor.whatTemp')
                Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.tempRestored') -Level 'ok'
            }
        } elseif (-not (Move-FujiTempFileAside -Editor $Editor)) {
            # It could not be moved aside: open it rather than let the next autosave overwrite it unseen
            $loaded = Read-FujiMacroFile -Editor $Editor -Path $tempPath
            if ($null -ne $loaded) {
                $Editor.Dirty = $true
                Test-FujiEditorDataVersion -Editor $Editor -Source $loaded -What (Get-FujiText 'editor.whatTemp')
                $Editor.Notices.Add((Get-FujiText 'editor.tempNotMoved' $script:FujiFileNames.Macro))
            }
        }
    }
    if ($null -eq $loaded -and (Test-Path -LiteralPath $mainPath -PathType Leaf)) {
        $loaded = Read-FujiMacroFile -Editor $Editor -Path $mainPath
        if ($null -ne $loaded) {
            Test-FujiEditorDataVersion -Editor $Editor -Source $loaded -What (Get-FujiText 'editor.whatMain')
            Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.mainLoaded' $script:FujiFileNames.Macro) -Level 'ok'
        } else {
            # Never treat an existing but unreadable file like a missing one: keep a copy and guard the next save
            $copy = Copy-FujiUnreadableFile -Editor $Editor -Path $mainPath
            $kept = Get-FujiText 'editor.brokenNotCopied'
            if ($copy) { $kept = Get-FujiText 'editor.brokenCopied' $copy }
            $Editor.SaveBlockReason = Get-FujiText 'editor.mainUnreadable' $script:FujiFileNames.Macro $kept
            $hint = ''
            if (Test-Path -LiteralPath (Get-FujiEditorPath $Editor $script:FujiFileNames.Backup) -PathType Leaf) {
                $hint = Get-FujiText 'editor.backupHint' $script:FujiFileNames.Backup
            }
            $Editor.Notices.Add($Editor.SaveBlockReason + (Get-FujiText 'editor.mainUnreadableNotice' $hint))
        }
    }
    if ($null -eq $loaded) {
        $loaded = New-FujiSampleData
        if ($Editor.SaveBlockReason) {
            Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.sampleShownBroken') -Level 'error'
        } else {
            Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.sampleCreated')
        }
    }
    $Editor.Data = (ConvertTo-FujiMacroData -Source $loaded).Data
    $Editor.MacroIndex = 0
    $Editor.Selected = -1
    Initialize-FujiMacroList -Editor $Editor
    $Editor.History.Clear()
    $Editor.HistoryPos = -1
    Add-FujiHistory -Editor $Editor -Description (Get-FujiText 'editor.historyStart')
}

function Save-FujiEditorTemp {
    param([Parameter(Mandatory)][hashtable]$Editor)
    try {
        Write-FujiTextFile -Path (Get-FujiEditorPath $Editor $script:FujiFileNames.Temp) -Text (ConvertTo-FujiMacroJson -Data $Editor.Data)
    } catch {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.autoSaveFailed' $_.Exception.Message) -Level 'error'
    }
}

# Writes the macros file (previous version kept as the backup) and removes the temp file.
# The caller asks first when SaveBlockReason is set. Returns '' or the error text.
function Save-FujiEditorData {
    param([Parameter(Mandatory)][hashtable]$Editor)
    try {
        Write-FujiFileSafely -Path (Get-FujiEditorPath $Editor $script:FujiFileNames.Macro) -Text (ConvertTo-FujiMacroJson -Data $Editor.Data) -BackupPath (Get-FujiEditorPath $Editor $script:FujiFileNames.Backup)
    } catch {
        $msg = $_.Exception.Message
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.saveFailed' $msg) -Level 'error'
        return $msg
    }
    $temp = Get-FujiEditorPath $Editor $script:FujiFileNames.Temp
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    $Editor.Dirty = $false
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.saved' $script:FujiFileNames.Macro $script:FujiFileNames.Backup) -Level 'ok'
    return ''
}

# ----------------------------------------------------------------- undo / redo
function Add-FujiHistory {
    param([Parameter(Mandatory)][hashtable]$Editor, [string]$Description)
    $h = $Editor.History
    if ($Editor.HistoryPos -lt $h.Count - 1) {
        $h.RemoveRange($Editor.HistoryPos + 1, $h.Count - $Editor.HistoryPos - 1)
    }
    $h.Add(@{
            Desc       = $Description
            Time       = (Get-Date -Format 'HH:mm:ss')
            MacroIndex = $Editor.MacroIndex
            Selected   = $Editor.Selected
            Data       = (Copy-FujiMacroData -Data $Editor.Data)
        })
    while ($h.Count -gt $script:FujiHistoryLimit) { $h.RemoveAt(0) }
    $Editor.HistoryPos = $h.Count - 1
}

# After every data change (add / edit / delete / move ...)
function Submit-FujiEditorChange {
    param([Parameter(Mandatory)][hashtable]$Editor, [string]$Description)
    Add-FujiHistory -Editor $Editor -Description $Description
    $Editor.Dirty = $true
    Save-FujiEditorTemp -Editor $Editor
}

# ShowMacroIndex: macro to display (undo shows the macro whose change is being undone)
function Restore-FujiHistory {
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Position, [int]$ShowMacroIndex = -1, [string]$UndoneDescription = '')
    if ($Position -lt 0 -or $Position -ge $Editor.History.Count -or $Position -eq $Editor.HistoryPos) { return $false }
    $h = $Editor.History[$Position]
    $Editor.Data = Copy-FujiMacroData -Data $h.Data
    $Editor.HistoryPos = $Position
    $target = $h.MacroIndex
    if ($ShowMacroIndex -ge 0) { $target = $ShowMacroIndex }
    $Editor.MacroIndex = [Math]::Min($target, $Editor.Data.macros.Count - 1)
    Initialize-FujiMacroList -Editor $Editor
    $Editor.Selected = -1
    if ($target -eq $h.MacroIndex) { $Editor.Selected = [Math]::Min($h.Selected, (Get-FujiCurrentStepList $Editor).Count - 1) }
    $Editor.Dirty = $true
    Save-FujiEditorTemp -Editor $Editor
    if ($UndoneDescription) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.undone' $UndoneDescription)
    } else {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.jumped' ($Position + 1) $h.Desc)
    }
    return $true
}

function Undo-FujiEditorChange {
    param([Parameter(Mandatory)][hashtable]$Editor)
    if ($Editor.HistoryPos -lt 1) { return $false }
    $current = $Editor.History[$Editor.HistoryPos]
    return (Restore-FujiHistory -Editor $Editor -Position ($Editor.HistoryPos - 1) -ShowMacroIndex $current.MacroIndex -UndoneDescription $current.Desc)
}

function Redo-FujiEditorChange {
    param([Parameter(Mandatory)][hashtable]$Editor)
    return (Restore-FujiHistory -Editor $Editor -Position ($Editor.HistoryPos + 1))
}

# ----------------------------------------------------------------- macros
function Add-FujiMacro {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Name)
    $Editor.Data.macros.Add([ordered]@{ id = (New-FujiMacroId $Editor); name = $Name; targetWindow = ''; steps = (New-Object -TypeName 'System.Collections.Generic.List[object]') })
    $Editor.MacroIndex = $Editor.Data.macros.Count - 1
    $Editor.Selected = -1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.macroAdd' $Name)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.macroAdded' $Name) -Level 'ok'
}

function Rename-FujiMacro {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Name)
    $m = Get-FujiCurrentMacro $Editor
    if ($null -eq $m -or $m.name -ceq $Name) { return }
    $m.name = $Name
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.macroRename' $Name)
}

function Copy-FujiCurrentMacro {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $m = Get-FujiCurrentMacro $Editor
    if ($null -eq $m) { return }
    $copy = Copy-FujiMacro -Macro $m
    $copy.id = New-FujiMacroId $Editor
    $copy.name = Get-FujiText 'editor.copyName' $m.name
    $Editor.Data.macros.Insert($Editor.MacroIndex + 1, $copy)
    $Editor.MacroIndex++
    $Editor.Selected = -1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.macroCopy' $copy.name)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.macroCopied' $copy.name) -Level 'ok'
}

function Remove-FujiCurrentMacro {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The window asks before calling; undo restores it')]
    param([Parameter(Mandatory)][hashtable]$Editor)
    $m = Get-FujiCurrentMacro $Editor
    if ($null -eq $m) { return }
    $Editor.Data.macros.RemoveAt($Editor.MacroIndex)
    Initialize-FujiMacroList -Editor $Editor
    if ($Editor.MacroIndex -ge $Editor.Data.macros.Count) { $Editor.MacroIndex = $Editor.Data.macros.Count - 1 }
    $Editor.Selected = -1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.macroDelete' $m.name)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.macroDeleted' $m.name) -Level 'warn'
}

function Set-FujiTargetWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Edits in-memory data; undo restores it')]
    param([Parameter(Mandatory)][hashtable]$Editor, [AllowEmptyString()][string]$Title)
    $m = Get-FujiCurrentMacro $Editor
    $value = ([string]$Title).Trim()
    if ($null -eq $m -or $m.targetWindow -ceq $value) { return }
    $m.targetWindow = $value
    $shown = $value
    if (-not $shown) { $shown = Get-FujiText 'editor.history.none' }
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.target' $shown)
    if (-not $value) { $value = Get-FujiText 'editor.targetNone' }
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.targetSet' $value)
}

# Writes the current macro to macro_export\<name>.json (never overwriting) and returns the path
function Export-FujiCurrentMacro {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $m = Get-FujiCurrentMacro $Editor
    $folder = Get-FujiEditorPath $Editor $script:FujiFileNames.Export
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder) }
    $stem = Get-FujiSafeFileName $m.name
    if (-not $stem) { $stem = 'macro' }
    $path = Join-Path $folder ($stem + '.json')
    for ($n = 2; Test-Path -LiteralPath $path; $n++) { $path = Join-Path $folder ('{0} ({1}).json' -f $stem, $n) }
    Write-FujiTextFile -Path $path -Text (ConvertTo-FujiMacroJson -Data @{ macros = @($m) })
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.exported' $m.name $path) -Level 'ok'
    return $path
}

# Adds the macros of an exported file. Returns '' or a message the window shows (file too new).
function Import-FujiMacroFile {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][string]$Path)
    $obj = Read-FujiMacroFile -Editor $Editor -Path $Path
    if ($null -eq $obj) { return '' }
    $v = Get-FujiFileDataVersion -Source $obj
    if ($v -gt $script:FujiDataVersion) { return (Get-FujiText 'editor.importNewer' $v $script:FujiDataVersion) }
    $data = (ConvertTo-FujiMacroData -Source $obj).Data
    if ($data.macros.Count -eq 0) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.importEmpty' $Path) -Level 'warn'
        return ''
    }
    foreach ($m in $data.macros) {
        $m.id = New-FujiMacroId $Editor
        $Editor.Data.macros.Add($m)
    }
    $Editor.MacroIndex = $Editor.Data.macros.Count - 1
    $Editor.Selected = -1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.import' $data.macros[0].name)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.imported' $data.macros.Count $Path) -Level 'ok'
    return ''
}

# ----------------------------------------------------------------- templates
function Get-FujiTemplateStep {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template, [scriptblock]$MacroNameOf = $null)
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in $Template['steps']) {
        $val = ''
        if ($item.Count -gt 1 -and $null -ne $item[1]) { $val = [string]$item[1] }
        $step = [ordered]@{ cmd = [string]$item[0]; val = $val; label = '' }
        if ($item.Count -gt 2 -and $item[2] -is [System.Collections.IDictionary]) {
            foreach ($k in $item[2].Keys) { $step[$k] = $item[2][$k] }
        }
        if (-not $step.label) { $step.label = Get-FujiStepLabel -Cmd $step.cmd -Value $val -MacroNameOf $MacroNameOf }
        $out.Add($step)
    }
    return , $out
}

function ConvertTo-FujiTemplateCsvText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Template)
    $rows = @()
    foreach ($r in $Template['csv']) { $rows += , ([string[]]$r.ToArray()) }
    return (ConvertTo-FujiCsvText -Rows $rows)
}

# samples\<csvFile> (an existing file is kept so user edits survive); returns its path or ''
function Write-FujiTemplateCsv {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][System.Collections.IDictionary]$Template)
    if (-not $Template['csvFile']) { return '' }
    $folder = Get-FujiEditorPath $Editor $script:FujiFileNames.Samples
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [void](New-Item -ItemType Directory -Path $folder) }
    $path = Join-Path $folder ([string]$Template['csvFile'])
    if (-not (Test-Path -LiteralPath $path)) {
        Write-FujiTextFile -Path $path -Text (ConvertTo-FujiTemplateCsvText -Template $Template) -Bom
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.templateCsv' $path) -Level 'ok'
    }
    return $path
}

# New macro from a built-in template; returns its name
function New-FujiMacroFromTemplate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Edits in-memory data; undo restores it')]
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][System.Collections.IDictionary]$Template)
    $base = [string]$Template['name']
    $name = $base
    $n = 2
    while (@($Editor.Data.macros | Where-Object { $_.name -ceq $name }).Count -gt 0) {
        $name = '{0} ({1})' -f $base, $n
        $n++
    }
    $steps = Get-FujiTemplateStep -Template $Template -MacroNameOf (Get-FujiMacroNameLookup $Editor)
    $Editor.Data.macros.Add([ordered]@{ id = (New-FujiMacroId $Editor); name = $name; targetWindow = [string]$Template['targetWindow']; steps = $steps })
    $Editor.MacroIndex = $Editor.Data.macros.Count - 1
    $Editor.Selected = -1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.template' $name)
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.templateCreated' $base) -Level 'ok'
    return $name
}

# ----------------------------------------------------------------- the step list
# Visible rows: @{ Index; Depth; HiddenCount } (blocks inside a collapsed block are left out).
# Moves the selection off a hidden step, like the HTA's renderSteps.
function Get-FujiStepRow {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $steps = Get-FujiCurrentStepList $Editor
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $depths = Get-FujiDepth -Steps $steps
    $hideUntil = -1
    $hidden = New-Object -TypeName 'System.Collections.Generic.List[bool]'
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $isHidden = $i -le $hideUntil
        $hidden.Add($isHidden)
        if ($isHidden) { continue }
        $count = 0
        if ((Test-FujiBlockStart $steps[$i].cmd) -and $steps[$i].Contains('collapsed') -and $steps[$i]['collapsed']) {
            $end = Find-FujiBlockEnd -Steps $steps -StartIndex $i
            if ($end -lt 0) { $hideUntil = $steps.Count - 1; $count = $steps.Count - $i - 1 } else { $hideUntil = $end; $count = [Math]::Max(0, $end - $i - 1) }
        }
        $rows.Add(@{ Index = $i; Depth = $depths[$i]; HiddenCount = $count })
    }
    if ($Editor.Selected -ge $steps.Count) { $Editor.Selected = $steps.Count - 1 }
    while ($Editor.Selected -gt 0 -and $hidden[$Editor.Selected]) { $Editor.Selected-- }
    return , $rows
}

# New commands go right after the selected step (after the whole block if it is collapsed)
function Get-FujiInsertionIndex {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $steps = Get-FujiCurrentStepList $Editor
    $sel = $Editor.Selected
    if ($sel -lt 0 -or $sel -ge $steps.Count) { return $steps.Count }
    if ((Test-FujiBlockStart $steps[$sel].cmd) -and $steps[$sel].Contains('collapsed') -and $steps[$sel]['collapsed']) {
        $end = Find-FujiBlockEnd -Steps $steps -StartIndex $sel
        if ($end -ge 0) { return $end + 1 }
    }
    return $sel + 1
}

function Expand-FujiAncestor {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Steps, [int]$Index)
    $stack = New-Object -TypeName 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $Index -and $i -lt $Steps.Count; $i++) {
        if (Test-FujiBlockStart $Steps[$i].cmd) { $stack.Add($i) }
        elseif ((Test-FujiBlockEnd $Steps[$i].cmd) -and $stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
    }
    foreach ($j in $stack) { $Steps[$j].Remove('collapsed') }
}

function Switch-FujiBlockCollapsed {
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Index)
    $steps = Get-FujiCurrentStepList $Editor
    if ($Index -lt 0 -or $Index -ge $steps.Count -or -not (Test-FujiBlockStart $steps[$Index].cmd)) { return }
    $step = $steps[$Index]
    if ($step.Contains('collapsed')) { $step.Remove('collapsed'); return }
    $step['collapsed'] = $true
    if ($Editor.Selected -gt $Index) {
        $end = Find-FujiBlockEnd -Steps $steps -StartIndex $Index
        if ($end -lt 0 -or $Editor.Selected -le $end) { $Editor.Selected = $Index }
    }
}

function Set-FujiAllCollapsed {
    param([Parameter(Mandatory)][hashtable]$Editor, [bool]$Collapsed)
    foreach ($s in (Get-FujiCurrentStepList $Editor)) {
        if (-not (Test-FujiBlockStart $s.cmd)) { continue }
        if ($Collapsed) { $s['collapsed'] = $true } else { $s.Remove('collapsed') }
    }
    if ($Collapsed) { $Editor.Selected = -1 }
}

function Get-FujiStepCaption {
    param([System.Collections.IDictionary]$Step, [int]$Max = 24)
    $t = [string]$Step.label
    if (-not $t) { $t = [string]$Step.cmd }
    return (Format-FujiShort $t $Max)
}

# ----------------------------------------------------------------- step operations
# Step: @{ cmd; val; label [; when] } from Complete-FujiStepEdit. $false when it cannot go there.
function Add-FujiEditorStep {
    param([Parameter(Mandatory)][hashtable]$Editor, [Parameter(Mandatory)][System.Collections.IDictionary]$Step)
    $steps = Get-FujiCurrentStepList $Editor
    $cmd = $Step.cmd
    $at = Get-FujiInsertionIndex $Editor
    $pieces = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $pieces.Add($Step)
    if ($cmd -eq 'TRY_START') { $pieces.Add([ordered]@{ cmd = 'CATCH'; val = ''; label = (Get-FujiCommandDef 'CATCH')['title'] }) }
    if (Test-FujiBlockStart $cmd) {
        $endCmd = Get-FujiBlockEndOf $cmd
        $pieces.Add([ordered]@{ cmd = $endCmd; val = ''; label = ((Get-FujiCommandDef $endCmd)['title']) })
    }
    if (Test-FujiBlockMiddle $cmd) {
        $trial = New-Object -TypeName 'System.Collections.Generic.List[object]' -ArgumentList (, [object[]]$steps.ToArray())
        $trial.InsertRange($at, $pieces)
        if (-not (Test-FujiBlockBalanced -Steps $trial)) {
            $owner = Get-FujiBlockOwnerOf $cmd
            Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.middleMisplaced' ((Get-FujiCommandDef $cmd)['title']) ((Get-FujiCommandDef $owner)['title'])) -Level 'warn'
            return $false
        }
    }
    $steps.InsertRange($at, $pieces)
    Expand-FujiAncestor -Steps $steps -Index $at
    $Editor.Selected = $at
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.add' ((Get-FujiCommandDef $cmd)['title']) (Format-FujiShort $Step.label 20))
    return $true
}

# Updated: result of Complete-FujiStepEdit for the same command
function Set-FujiEditorStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Edits in-memory data; undo restores it')]
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Index, [Parameter(Mandatory)][System.Collections.IDictionary]$Updated)
    $steps = Get-FujiCurrentStepList $Editor
    $step = $steps[$Index]
    $step.val = $Updated.val
    $step.label = $Updated.label
    foreach ($f in (Get-FujiCommandDef $step.cmd)['fields']) {
        if (-not $f.Contains('prop')) { continue }
        $id = [string]$f['id']
        if ($Updated.Contains($id) -and $Updated[$id]) { $step[$id] = $Updated[$id] } else { $step.Remove($id) }
    }
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.edit' (Format-FujiShort $Updated.label 24))
}

# Moves steps From..To so that they start at InsertAt (an index of the list before the move)
function Move-FujiEditorRange {
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$From, [int]$To, [int]$InsertAt, [string]$DescriptionKey = 'move')
    $steps = Get-FujiCurrentStepList $Editor
    $count = $To - $From + 1
    if ($InsertAt -ge $From -and $InsertAt -le $To + 1) { return $false }
    # Try the move on a copy first: a block end moved above its own start would leave an unclosed block
    $trial = New-Object -TypeName 'System.Collections.Generic.List[object]' -ArgumentList (, [object[]]$steps.ToArray())
    $moved = $trial.GetRange($From, $count)
    $trial.RemoveRange($From, $count)
    $at = $InsertAt
    if ($at -gt $From) { $at -= $count }
    $trial.InsertRange($at, $moved)
    if ((Test-FujiBlockBalanced -Steps $steps) -and -not (Test-FujiBlockBalanced -Steps $trial)) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.moveBlocked') -Level 'warn'
        return $false
    }
    $steps.Clear()
    $steps.AddRange($trial)
    Expand-FujiAncestor -Steps $steps -Index $at
    $Editor.Selected = $at
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText ('editor.history.' + $DescriptionKey) (Get-FujiStepCaption $moved[0]))
    return $true
}

# Direction -1 up / 1 down: the selected step, or the whole block when it is a block start
function Move-FujiEditorStep {
    param([Parameter(Mandatory)][hashtable]$Editor, [ValidateSet(-1, 1)][int]$Direction)
    $steps = Get-FujiCurrentStepList $Editor
    $sel = $Editor.Selected
    if ($sel -lt 0 -or $sel -ge $steps.Count) { return $false }
    $range = Get-FujiBlockRange -Steps $steps -Index $sel
    if ($Direction -lt 0) {
        if ($range.From -gt 0) { return (Move-FujiEditorRange -Editor $Editor -From $range.From -To $range.To -InsertAt ($range.From - 1) -DescriptionKey 'moveUp') }
    } elseif ($range.To -lt $steps.Count - 1) {
        return (Move-FujiEditorRange -Editor $Editor -From $range.From -To $range.To -InsertAt ($range.To + 2) -DescriptionKey 'moveDown')
    }
    return $false
}

# The block a start or end step belongs to: @{ Start; End; Name; Kind }, or $null for other steps
function Get-FujiEditorBlock {
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Index)
    $steps = Get-FujiCurrentStepList $Editor
    if ($Index -lt 0 -or $Index -ge $steps.Count) { return $null }
    $cmd = $steps[$Index].cmd
    $start = -1
    $end = -1
    if (Test-FujiBlockStart $cmd) { $start = $Index; $end = Find-FujiBlockEnd -Steps $steps -StartIndex $Index }
    elseif (Test-FujiBlockEnd $cmd) { $end = $Index; $start = Find-FujiBlockStart -Steps $steps -EndIndex $Index }
    if ($start -lt 0 -or $end -lt 0) { return $null }
    $s = $steps[$start]
    $name = [string]$s.label
    if (-not $name) { $name = Get-FujiStepLabel -Cmd $s.cmd -Value $s.val }
    return @{ Start = $start; End = $end; Name = $name; Kind = [string]((Get-FujiCommandDef $s.cmd)['title']) }
}

# Mode: Step (one step), All (a block with its contents), Frame (a block's start, end and ELSE / CATCH)
function Remove-FujiEditorStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The window asks before removing a block; undo restores it')]
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Index, [ValidateSet('Step', 'All', 'Frame')][string]$Mode = 'Step')
    $steps = Get-FujiCurrentStepList $Editor
    if ($Index -lt 0 -or $Index -ge $steps.Count) { return }
    $block = $null
    if ($Mode -ne 'Step') { $block = Get-FujiEditorBlock -Editor $Editor -Index $Index }
    if ($null -eq $block) {
        $step = $steps[$Index]
        $steps.RemoveAt($Index)
        $at = $Index
        $desc = Get-FujiText 'editor.history.delete' (Get-FujiStepCaption $step)
    } elseif ($Mode -eq 'All') {
        $steps.RemoveRange($block.Start, $block.End - $block.Start + 1)
        $at = $block.Start
        $desc = Get-FujiText 'editor.history.deleteAll' $block.Kind $block.Name
    } else {
        $middles = Get-FujiBlockMiddleIndex -Steps $steps -Start $block.Start -End $block.End
        $remove = @($block.Start, $block.End) + $middles
        foreach ($r in ($remove | Sort-Object -Descending)) { $steps.RemoveAt($r) }
        $at = $block.Start
        $desc = Get-FujiText 'editor.history.unwrap' $block.Kind $block.Name
    }
    if ($steps.Count -eq 0) { $Editor.Selected = -1 } else { $Editor.Selected = [Math]::Min($at, $steps.Count - 1) }
    Submit-FujiEditorChange -Editor $Editor -Description $desc
}

function Copy-FujiEditorStep {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $steps = Get-FujiCurrentStepList $Editor
    $sel = $Editor.Selected
    if ($sel -lt 0 -or $sel -ge $steps.Count) { return $false }
    $cmd = $steps[$sel].cmd
    if (Test-FujiBlockMiddle $cmd) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.middleNoCopy' ((Get-FujiCommandDef $cmd)['title'])) -Level 'warn'
        return $false
    }
    $range = Get-FujiBlockRange -Steps $steps -Index $sel
    if (Test-FujiBlockEnd $cmd) {
        # A lone block end would close the enclosing block early: copy the whole block instead
        $start = Find-FujiBlockStart -Steps $steps -EndIndex $sel
        if ($start -lt 0) { return $false }
        $range = @{ From = $start; To = $sel }
    }
    $copies = New-Object -TypeName 'System.Collections.Generic.List[object]'
    for ($i = $range.From; $i -le $range.To; $i++) { $copies.Add((Copy-FujiStep -Step $steps[$i])) }
    $steps.InsertRange($range.To + 1, $copies)
    $Editor.Selected = $range.To + 1
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText 'editor.history.copy' (Get-FujiStepCaption $copies[0]))
    return $true
}

# A disabled step is kept but skipped at run time (a disabled block start skips the whole block)
function Switch-FujiEditorStepDisabled {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $steps = Get-FujiCurrentStepList $Editor
    $sel = $Editor.Selected
    if ($sel -lt 0 -or $sel -ge $steps.Count) { return $false }
    $step = $steps[$sel]
    if ((Test-FujiBlockEnd $step.cmd) -or (Test-FujiBlockMiddle $step.cmd)) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.noDisable' ((Get-FujiCommandDef $step.cmd)['title'])) -Level 'warn'
        return $false
    }
    if ($step.Contains('disabled')) {
        $step.Remove('disabled')
        $key = 'editor.history.enable'
    } else {
        $step['disabled'] = $true
        $key = 'editor.history.disable'
    }
    Submit-FujiEditorChange -Editor $Editor -Description (Get-FujiText $key (Get-FujiStepCaption $step))
    return $true
}

# ----------------------------------------------------------------- the step editor dialog
# @{ Values = ordered settings by field id (prop fields too); CustomLabel = label typed by the user }
function Get-FujiStepEditState {
    param([Parameter(Mandatory)][string]$Cmd, [System.Collections.IDictionary]$Step = $null, [scriptblock]$MacroNameOf = $null)
    $def = Get-FujiCommandDef $Cmd
    $val = [string]$def['defaultVal']
    if ($null -ne $Step) { $val = [string]$Step.val }
    $values = ConvertFrom-FujiStepValue -Cmd $Cmd -Value $val
    foreach ($f in $def['fields']) {
        if (-not $f.Contains('prop')) { continue }
        $id = [string]$f['id']
        $values[$id] = ''
        if ($null -ne $Step -and $Step.Contains($id) -and $Step[$id]) { $values[$id] = [string]$Step[$id] }
    }
    $custom = ''
    if ($null -ne $Step -and $Step.label -and $Step.label -cne (Get-FujiStepLabel -Cmd $Cmd -Value $val -MacroNameOf $MacroNameOf)) { $custom = [string]$Step.label }
    return @{ Values = $values; CustomLabel = $custom }
}

# Raw: what the dialog's fields hold, by field id. Returns @{ Error } or @{ Step }.
function Complete-FujiStepEdit {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(Mandatory)][System.Collections.IDictionary]$Raw, [AllowEmptyString()][string]$Label = '', [scriptblock]$MacroNameOf = $null)
    $def = Get-FujiCommandDef $Cmd
    $v = [ordered]@{}
    foreach ($f in $def['fields']) {
        if ($f['type'] -eq 'capture' -or $f['type'] -eq 'rectcapture') { continue }
        $id = [string]$f['id']
        $text = ''
        if ($Raw.Contains($id) -and $null -ne $Raw[$id]) { $text = [string]$Raw[$id] }
        if ($f.Contains('raw') -and $f['raw']) { $v[$id] = $text } else { $v[$id] = $text.Trim() }
    }
    $err = Test-FujiStepSetting -Cmd $Cmd -Settings $v
    if ($err) { return @{ Error = $err } }
    $macroName = ''
    if ($Cmd -eq 'CALL_MACRO' -and $MacroNameOf) { $macroName = [string](& $MacroNameOf $v['id']) }
    $val = ConvertTo-FujiStepValue -Cmd $Cmd -Settings $v -MacroName $macroName
    $text = ([string]$Label).Trim()
    if (-not $text) { $text = Get-FujiStepLabel -Cmd $Cmd -Value $val -MacroNameOf $MacroNameOf }
    $step = [ordered]@{ cmd = $Cmd; val = $val; label = $text }
    foreach ($f in $def['fields']) {
        if ($f.Contains('prop') -and $v[[string]$f['id']]) { $step[[string]$f['id']] = $v[[string]$f['id']] }
    }
    return @{ Step = $step }
}

# ----------------------------------------------------------------- CSV loaded in the editor
function New-FujiCsvState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only')]
    param()
    return @{ Path = ''; Encoding = ''; Records = @(); Header = $null; Rows = @(); Warnings = @() }
}

function Set-FujiCsvHeader {
    param([Parameter(Mandatory)][hashtable]$Editor, [bool]$HasHeader)
    $csv = $Editor.Csv
    $records = @($csv.Records)
    $csv.Header = $null
    if ($HasHeader -and $records.Count -gt 0) { $csv.Header = [string[]]$records[0] }
    if ($HasHeader) { $csv.Rows = @($records | Select-Object -Skip 1) } else { $csv.Rows = $records }
}

function Get-FujiCsvMaxColumn {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $csv = $Editor.Csv
    $max = 0
    if ($null -ne $csv.Header) { $max = $csv.Header.Length }
    $limit = [Math]::Min(@($csv.Rows).Count, 200)
    for ($i = 0; $i -lt $limit; $i++) { if ($csv.Rows[$i].Length -gt $max) { $max = $csv.Rows[$i].Length } }
    return $max
}

function Get-FujiCsvHeaderName {
    param([Parameter(Mandatory)][hashtable]$Editor, [int]$Column)
    $h = $Editor.Csv.Header
    if ($null -ne $h -and $Column -ge 1 -and $Column -le $h.Length) { return ([string]$h[$Column - 1]).Trim() }
    return ''
}

# Reads a CSV into the editor. Returns @{ Ok; HeaderForced } (HeaderForced: a results / error CSV
# turns "first line is the header" on)
function Import-FujiEditorCsv {
    param([Parameter(Mandatory)][hashtable]$Editor, [AllowEmptyString()][string]$Path, [string]$Encoding = 'auto', [bool]$HasHeader = $true)
    $p = ([string]$Path).Trim().Trim('"')
    if (-not $p) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.noPath') -Level 'warn'
        return @{ Ok = $false; HeaderForced = $false }
    }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.notFound' $p) -Level 'error'
        return @{ Ok = $false; HeaderForced = $false }
    }
    try {
        $res = Read-FujiCsvText -Path $p -Encoding $Encoding
        $parsed = ConvertFrom-FujiCsv -Text $res.Text
    } catch {
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.failed' $_.Exception.Message) -Level 'error'
        return @{ Ok = $false; HeaderForced = $false }
    }
    $csv = $Editor.Csv
    $csv.Path = $p
    $csv.Encoding = $res.Encoding
    # Arrays, not the parser's List: "@(...)" around a generic List fails once the same line has
    # run often enough to be compiled and then meets an empty List (PowerShell 5.1 and 7:
    # "Argument types do not match"), so lists are turned into arrays with ToArray()
    $csv.Records = $parsed.Records.ToArray()
    $csv.Warnings = $parsed.Warnings
    $forced = $false
    if (-not $HasHeader -and $csv.Records.Count -gt 0) {
        $marker = Get-FujiText 'editor.csv.resultHeaderName'
        foreach ($f in $csv.Records[0]) {
            if (([string]$f).Trim() -ceq $marker) { $forced = $true }
        }
        if ($forced) {
            $HasHeader = $true
            Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.resultHeader')
        }
    }
    Set-FujiCsvHeader -Editor $Editor -HasHeader $HasHeader
    Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.loaded' (@($csv.Rows).Count) (Get-FujiEncodingLabel $csv.Encoding) $p) -Level 'ok'
    Write-FujiCsvShapeWarning -Editor $Editor
    return @{ Ok = $true; HeaderForced = $forced }
}

function Get-FujiEncodingLabel {
    param([string]$Encoding)
    $t = Get-FujiText ('editor.csv.encodings.' + $Encoding)
    if ($t -eq ('editor.csv.encodings.' + $Encoding)) { return $Encoding }
    return $t
}

function Write-FujiCsvShapeWarning {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $csv = $Editor.Csv
    foreach ($w in $csv.Warnings) { Write-FujiEditorLog -Editor $Editor -Message ([string][char]0x26A0 + ' ' + $w) -Level 'warn' }
    $rows = @($csv.Rows)
    $expected = 0
    if ($null -ne $csv.Header) { $expected = $csv.Header.Length } elseif ($rows.Count -gt 0) { $expected = $rows[0].Length }
    $odd = New-Object -TypeName 'System.Collections.Generic.List[int]'
    $blank = 0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if (Test-FujiBlankRow -Row $rows[$i]) { $blank++ }
        elseif ($rows[$i].Length -ne $expected) { $odd.Add($i + 1) }
    }
    if ($odd.Count -gt 0) {
        $list = ($odd | Select-Object -First 5) -join ([string][char]0x30FB)
        if ($odd.Count -gt 5) { $list += Get-FujiText 'editor.csv.oddMore' ($odd.Count - 5) }
        Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.oddRows' $list) -Level 'warn'
    }
    if ($blank -gt 0) { Write-FujiEditorLog -Editor $Editor -Message (Get-FujiText 'editor.csv.blankRows' $blank) }
}

# One line for the toolbar: "rows x columns [encoding] header: ..."
function Get-FujiCsvInfoText {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $csv = $Editor.Csv
    if (-not $csv.Path) { return (Get-FujiText 'editor.csv.none') }
    $text = Get-FujiText 'editor.csv.info' (@($csv.Rows).Count) (Get-FujiCsvMaxColumn $Editor) (Get-FujiEncodingLabel $csv.Encoding)
    if ($null -ne $csv.Header) { $text += Get-FujiText 'editor.csv.infoHeader' (Format-FujiShort ($csv.Header -join ', ') 60) }
    return $text
}

# Choices for the editor's "insert a placeholder" list: @(@(token, description), ...)
function Get-FujiPlaceholderChoice {
    param([Parameter(Mandatory)][hashtable]$Editor)
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $cols = Get-FujiCsvMaxColumn $Editor
    for ($i = 1; $i -le $cols; $i++) {
        $name = Get-FujiCsvHeaderName -Editor $Editor -Column $i
        # An all-digit header would be read as a column number, and braces cannot be inside a placeholder
        $byName = $name -and $name -notmatch '^[0-9]+$' -and $name -notmatch '[{}]'
        $token = '{{' + $i + '}}'
        if ($byName) { $token = '{{' + $name + '}}' }
        $desc = Get-FujiText 'editor.placeholder.csvCol' $i
        if ($name) { $desc += Get-FujiText 'editor.placeholder.csvColName' $name }
        $list.Add(@($token, $desc))
    }
    if ($cols -eq 0) { $list.Add(@('{{1}}', (Get-FujiText 'editor.placeholder.csvFirst'))) }
    foreach ($n in (Get-FujiDefinedVarName -Steps (Get-FujiCurrentStepList $Editor) -ErrorVarName (Get-FujiText 'data.errorVar'))) {
        $list.Add(@(('{{$' + $n + '}}'), (Get-FujiText 'editor.placeholder.var' $n)))
    }
    foreach ($p in $script:FujiCommands['placeholderHelp']) { $list.Add(@([string]$p[0], [string]$p[1])) }
    return , $list
}

# ----------------------------------------------------------------- screen capture helper
# Rectangle around the cursor kept on the desktop, with the cursor at its centre (CLICK_IMG clicks
# the centre of the match): near an edge it shrinks symmetrically. Screen: @{ X; Y; Width; Height }
function Get-FujiCaptureRect {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height, [Parameter(Mandatory)][hashtable]$Screen)
    $hw = [Math]::Max(1, [Math]::Min([Math]::Floor($Width / 2), [Math]::Min($X - $Screen.X, $Screen.X + $Screen.Width - 1 - $X)))
    $hh = [Math]::Max(1, [Math]::Min([Math]::Floor($Height / 2), [Math]::Min($Y - $Screen.Y, $Screen.Y + $Screen.Height - 1 - $Y)))
    return @{ X = [int]($X - $hw); Y = [int]($Y - $hh); Width = [int]($hw * 2); Height = [int]($hh * 2) }
}
