# ---------------------------------------------------------------------------------------------
#  The manual opened from the window: fujikyun_manual.html next to fujikyun.ps1 holds every page
#  and shows the one named in its address (#page-manual/<heading>). That address is reached through
#  a small local page that forwards to it: a file opened by Windows loses #anchor.
# ---------------------------------------------------------------------------------------------

$script:FujiDocPages = @('index', 'tutorial', 'manual', 'templates', 'faq', 'setup', 'changes')
$script:FujiDocFileName = 'fujikyun_manual.html'
# Read on GitHub when the pages are not on this PC (no #anchor there: GitHub names its headings itself)
$script:FujiDocsOnline = 'https://github.com/uchidakoichi/RPA/blob/master/docs/src/'

# The manual's file, or '' when it is not here. FileExists: { param($Path) ... } (the runner's Io style)
function Find-FujiDocFile {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][scriptblock]$FileExists)
    $p = Join-Path $Directory $script:FujiDocFileName
    if (& $FileExists $p) { return $p }
    return ''
}

# The address of a page, and of a heading in it, inside the manual: page-manual or page-manual/<heading>
function Get-FujiDocPageAnchor {
    param([Parameter(Mandatory)][string]$Page, [string]$Anchor = '')
    if ($script:FujiDocPages -notcontains $Page) { $Page = 'index' }
    if ($Anchor) { return 'page-' + $Page + '/' + $Anchor }
    return 'page-' + $Page
}

# file:///C:/.../fujikyun_manual.html#anchor (the anchor percent-encoded; browsers match it to the heading id)
function ConvertTo-FujiDocUrl {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Anchor = '')
    $url = (New-Object -TypeName System.Uri -ArgumentList $Path, ([System.UriKind]::Absolute)).AbsoluteUri
    if ($Anchor) { $url += '#' + [uri]::EscapeDataString($Anchor) }
    return $url
}

# A page that goes straight on to Url (the address is HTML-escaped, so it stays one attribute)
function New-FujiDocForwardHtml {
    param([Parameter(Mandatory)][string]$Url)
    $u = [System.Net.WebUtility]::HtmlEncode($Url)
    return '<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=' + $u + '"></head><body><a href="' + $u + '">' + $u + '</a></body></html>'
}

function Get-FujiDocOnlineUrl {
    param([Parameter(Mandatory)][string]$Page)
    return $script:FujiDocsOnline + $Page + '.md'
}

# Where a command is explained in the manual (fujikyun_commands.json "doc"); the command list otherwise
function Get-FujiCommandDocAnchor {
    param([string]$Cmd)
    $def = Get-FujiCommandDef -Cmd $Cmd
    if ($null -ne $def -and $def.Contains('doc') -and $def['doc']) { return [string]$def['doc'] }
    return [string](Get-FujiText 'gui.docCommandAnchor')
}
