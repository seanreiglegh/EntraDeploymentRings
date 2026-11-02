<#
    Test-DocLinks.ps1
    Revision: 1.0

    Checks every relative link in the repository's Markdown files: the target
    file must exist and, when a #fragment is given, the target Markdown file
    must have a matching heading (GitHub anchor rules). External http(s) links
    are not fetched. Exits 1 when a broken link is found. Used by CI.

        pwsh ./tools/Test-DocLinks.ps1

    REVISION HISTORY (most recent first)
    1.0   2026-11-01  First public release.
#>
#Requires -Version 7.2
[CmdletBinding()]
param([string] $Root = (Split-Path -Parent $PSScriptRoot))

Set-StrictMode -Version 3.0

function ConvertTo-GitHubAnchor([string] $Heading) {
    $h = $Heading.Trim().ToLowerInvariant()
    $h = [regex]::Replace($h, '[^\w\- ]', '')
    return $h.Replace(' ', '-')
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.md' |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' }
$headingCache = @{}
$broken = [System.Collections.Generic.List[string]]::new()
$checked = 0

foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    # Ignore links inside fenced code blocks.
    $text = [regex]::Replace($text, '(?s)```.*?```', '')
    foreach ($m in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
        $link = $m.Groups[1].Value
        if ($link -match '^(https?|mailto):') { continue }
        $checked++
        $target, $anchor = $link.Split('#', 2)
        $targetPath = if ($target) { [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName $target)) } else { $file.FullName }
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $broken.Add("$($file.FullName.Substring($Root.Length + 1)): missing file '$link'"); continue
        }
        if ($anchor -and $targetPath -like '*.md') {
            if (-not $headingCache.ContainsKey($targetPath)) {
                $headingCache[$targetPath] = @([regex]::Matches((Get-Content -LiteralPath $targetPath -Raw), '(?m)^#+ (.+)$') | ForEach-Object { ConvertTo-GitHubAnchor $_.Groups[1].Value })
            }
            if ($headingCache[$targetPath] -notcontains $anchor) {
                $broken.Add("$($file.FullName.Substring($Root.Length + 1)): missing anchor '$link'")
            }
        }
    }
}

"Checked $checked relative link(s) in $($files.Count) Markdown file(s)."
if ($broken.Count) {
    $broken | ForEach-Object { "BROKEN  $_" }
    exit 1
}
'No broken links.'
