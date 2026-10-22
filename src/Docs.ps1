# ---------------------------------------------------------------------------------------------
#  The manuals (docs\*.html) opened from the window
#  The pages come with the docs-and-samples zip (dist/fujikyun_docs_samples.zip): extracted into
#  this folder they are in docs\ or fujikyun_docs_samples\docs\. A place in a page (#anchor) is
#  reached through a small local page that forwards to it: a file opened by Windows loses #anchor.
# ---------------------------------------------------------------------------------------------

$script:FujiDocPages = @('index', 'tutorial', 'manual', 'templates', 'faq', 'setup', 'changes')
# Read on GitHub when the pages are not on this PC (no #anchor there: GitHub names its headings itself)
$script:FujiDocsOnline = 'https://github.com/uchidakoichi/RPA/blob/master/docs/src/'

# The page's file, or '' when it is not here. FileExists: { param($Path) ... } (the runner's Io style)
function Find-FujiDocFile {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][scriptblock]$FileExists)
    if ($script:FujiDocPages -notcontains $Page) { return '' }
    foreach ($folder in @('docs', (Join-Path 'fujikyun_docs_samples' 'docs'))) {
        $p = Join-Path (Join-Path $Directory $folder) ($Page + '.html')
        if (& $FileExists $p) { return $p }
    }
    return ''
}

# file:///C:/.../manual.html#anchor (the anchor percent-encoded; browsers match it to the heading id)
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
