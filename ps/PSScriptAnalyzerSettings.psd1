# PSScriptAnalyzer settings for the PowerShell edition (maintainers only):
#   Invoke-ScriptAnalyzer -Path ps -Recurse -Settings ps/PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    # The New- / Set- / Update- functions here change in-memory data or the window only (undo
    # restores data); nothing outside the app changes without the user choosing it in a dialog.
    ExcludeRules = @('PSUseShouldProcessForStateChangingFunctions')
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
}
