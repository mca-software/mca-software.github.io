<#
.SYNOPSIS
    Refreshes the hardcoded GitHub star counts in the site's HTML.

.DESCRIPTION
    The site is static: star counts are baked into the pages rather than fetched by
    the visitor's browser. That keeps the pages dependency-free and sends no visitor
    traffic to GitHub, at the cost of the numbers going stale. Run this before
    publishing to bring them back in line.

    Nothing is hardcoded here. The script scans the HTML for elements carrying a
    data-stars-repo attribute and updates the star number inside each one, so adding
    a new project card means adding the attribute and nothing else:

        <span class="stars" data-stars-repo="owner/repo">&#9733; 12</span>

    A repo whose count cannot be read is left exactly as it is. A network failure or
    a rate limit must never rewrite a real number into a wrong one.

.PARAMETER Root
    Site root. Defaults to the repository this script lives in.

.PARAMETER WhatIf
    Report what would change without writing anything.

.EXAMPLE
    pwsh tools/update-stars.ps1
    pwsh tools/update-stars.ps1 -WhatIf

.NOTES
    The GitHub API allows 60 unauthenticated requests per hour per IP, which is far
    more than this needs. Set GITHUB_TOKEN in the environment to raise that if you
    ever hit it.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

function Get-StarCount {
    param([string]$Repo)

    $headers = @{
        'User-Agent' = 'mcasoftware.dev-update-stars'
        'Accept'     = 'application/vnd.github+json'
    }
    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $headers -TimeoutSec 30
    } catch {
        Write-Warning "$Repo : lookup failed, leaving the page unchanged. $($_.Exception.Message)"
        return $null
    }

    # A repo that exists but reports nothing is a malformed answer, not a zero.
    if ($null -eq $response.stargazers_count) {
        Write-Warning "$Repo : response carried no stargazers_count, leaving the page unchanged."
        return $null
    }
    return [int]$response.stargazers_count
}

$pages = Get-ChildItem -Path $Root -Filter *.html -Recurse -File |
         Where-Object { $_.FullName -notmatch '\\node_modules\\' }

$attributePattern = 'data-stars-repo="([^"]+)"'
$repos = $pages |
    ForEach-Object { [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName), $attributePattern) } |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

if (-not $repos) {
    Write-Host 'No data-stars-repo attributes found. Nothing to do.'
    return
}

Write-Host "Reading star counts for $($repos.Count) repositories..."
$counts = @{}
foreach ($repo in $repos) {
    $count = Get-StarCount -Repo $repo
    if ($null -ne $count) {
        $counts[$repo] = $count
        Write-Host ("  {0,-45} {1}" -f $repo, $count)
    }
}

$changed = 0
foreach ($page in $pages) {
    $original = Get-Content -Raw -LiteralPath $page.FullName
    $updated = $original

    foreach ($repo in $counts.Keys) {
        # Match one element carrying this repo's attribute, then rewrite only the
        # digits after the star inside it. Keeps surrounding wording ("on GitHub")
        # intact, whatever it happens to be on that page.
        $elementPattern = '(<[^>]*data-stars-repo="' + [regex]::Escape($repo) + '"[^>]*>)([^<]*)(</)'
        $updated = [regex]::Replace($updated, $elementPattern, {
            param($match)
            $inner = $match.Groups[2].Value
            $rewritten = [regex]::Replace($inner, '(★\s*)\d+', "`${1}$($counts[$repo])")
            $match.Groups[1].Value + $rewritten + $match.Groups[3].Value
        })
    }

    if ($updated -ne $original) {
        $relative = $page.FullName.Substring($Root.Length).TrimStart('\', '/')
        if ($PSCmdlet.ShouldProcess($relative, 'update star counts')) {
            # Match the rest of the site: UTF-8, no BOM, LF line endings.
            [System.IO.File]::WriteAllText($page.FullName, $updated, (New-Object System.Text.UTF8Encoding $false))
            Write-Host "  updated  $relative"
        } else {
            Write-Host "  would update  $relative"
        }
        $changed++
    }
}

if ($changed -eq 0) {
    Write-Host 'All star counts were already current.'
} else {
    Write-Host "$changed file(s) touched."
}
