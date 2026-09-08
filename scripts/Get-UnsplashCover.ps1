<#
.SYNOPSIS
    Fetches a themed cover image from Unsplash and wires it into a Hugo post.

.DESCRIPTION
    Authoring-time helper. Searches the Unsplash API for a photo matching a query,
    downloads it into static/img/posts/<slug>.jpg and writes the cover + attribution
    fields into the post's front matter.

    The Unsplash API is never touched during `hugo build`, so CI needs no secret and
    burns no rate limit. Only the Access Key is required; the Secret Key is for OAuth
    (acting on behalf of a logged-in Unsplash user) and is not used here.

.PARAMETER Post
    Post to attach the cover to. Accepts a slug ("Hello"), a filename ("Hello.md")
    or a full path ("content/posts/Hello.md").

.PARAMETER Query
    Search phrase, e.g. "kubernetes", "server room", "pipeline".

.PARAMETER List
    Show the top candidates without downloading anything, so you can pick one
    and re-run with -Index.

.PARAMETER Index
    Which search result to use (1-based). Default 1.

.EXAMPLE
    ./scripts/Get-UnsplashCover.ps1 -Post Hello -Query "kubernetes" -List
    ./scripts/Get-UnsplashCover.ps1 -Post Hello -Query "kubernetes" -Index 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Post,
    [Parameter(Mandatory)][string]$Query,
    [ValidateSet('landscape', 'portrait', 'squarish')][string]$Orientation = 'landscape',
    [ValidateRange(1, 30)][int]$Index = 1,
    [switch]$List,
    [int]$Width = 1600,
    [int]$Height = 900,
    [ValidateRange(1, 100)][int]$Quality = 80,
    [string]$AppName = 'blog-devops'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

# --- credentials -------------------------------------------------------------

function Get-AccessKey {
    if ($env:UNSPLASH_ACCESS_KEY) { return $env:UNSPLASH_ACCESS_KEY }

    $envFile = Join-Path $RepoRoot '.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*UNSPLASH_ACCESS_KEY\s*=\s*(.+?)\s*$') {
                return $matches[1].Trim("'", '"')
            }
        }
    }

    throw @"
No Unsplash Access Key found.

Set it for the current session:
    `$env:UNSPLASH_ACCESS_KEY = 'your-access-key'

...or persist it in a local .env file (already git-ignored):
    copy .env.example .env    # then paste the key into it

The Access Key is the only credential needed. Never commit it.
"@
}

# --- front matter ------------------------------------------------------------

function ConvertTo-YamlString {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Update-FrontMatter {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values
    )

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') {
        throw "$Path does not start with a '---' front matter block."
    }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { throw "$Path has an unterminated front matter block." }

    $fm = [System.Collections.Generic.List[string]]::new()
    if ($end -gt 1) { $fm.AddRange([string[]]@($lines[1..($end - 1)])) }
    $body = if ($end -lt $lines.Count - 1) { @($lines[($end + 1)..($lines.Count - 1)]) } else { @() }

    foreach ($key in $Values.Keys) {
        $rendered = "{0}: {1}" -f $key, (ConvertTo-YamlString $Values[$key])
        $found = $false
        for ($i = 0; $i -lt $fm.Count; $i++) {
            if ($fm[$i] -match "^\s*$([regex]::Escape($key))\s*:") {
                $fm[$i] = $rendered
                $found = $true
                break
            }
        }
        if (-not $found) { [void]$fm.Add($rendered) }
    }

    $out = @('---') + $fm + @('---') + $body
    Set-Content -LiteralPath $Path -Value $out -Encoding utf8NoBOM
}

# --- resolve the post --------------------------------------------------------

$candidates = @(
    $Post
    Join-Path $RepoRoot $Post
    Join-Path $RepoRoot "content/posts/$Post"
    Join-Path $RepoRoot "content/posts/$Post.md"
)
$PostPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if (-not $PostPath) {
    throw "Post not found. Tried:`n  " + ($candidates -join "`n  ")
}
$PostPath = (Resolve-Path -LiteralPath $PostPath).Path
$Slug = [System.IO.Path]::GetFileNameWithoutExtension($PostPath).ToLowerInvariant()

# --- search ------------------------------------------------------------------

$headers = @{
    'Authorization'  = "Client-ID $(Get-AccessKey)"
    'Accept-Version' = 'v1'
}

$searchUri = 'https://api.unsplash.com/search/photos' +
    "?query=$([uri]::EscapeDataString($Query))" +
    "&orientation=$Orientation" +
    '&per_page=10&content_filter=high'

Write-Host "Searching Unsplash for '$Query' ($Orientation)..." -ForegroundColor Cyan
try {
    $search = Invoke-RestMethod -Uri $searchUri -Headers $headers
}
catch {
    $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    if ($status -eq 401) { throw "Unsplash rejected the Access Key (401). Check UNSPLASH_ACCESS_KEY." }
    if ($status -eq 403) { throw "Unsplash rate limit reached (403). Demo apps allow 50 requests/hour." }
    throw
}

if ($search.total -eq 0) { throw "No photos found for '$Query'. Try a broader phrase." }

if ($List) {
    Write-Host "`nTop results for '$Query' - re-run with -Index N to pick one:`n" -ForegroundColor Cyan
    $n = 0
    foreach ($p in $search.results) {
        $n++
        $desc = if ($p.description) { $p.description } elseif ($p.alt_description) { $p.alt_description } else { '(no description)' }
        if ($desc.Length -gt 70) { $desc = $desc.Substring(0, 67) + '...' }
        '{0,2}. {1,-70} {2} ({3}x{4})' -f $n, $desc, $p.user.name, $p.width, $p.height
    }
    Write-Host ''
    return
}

if ($Index -gt $search.results.Count) {
    throw "Only $($search.results.Count) result(s) for '$Query'; -Index $Index is out of range."
}
$photo = $search.results[$Index - 1]

# --- trigger the download endpoint (required by the Unsplash API Guidelines) --

Write-Host "Registering download with Unsplash..." -ForegroundColor Cyan
[void](Invoke-RestMethod -Uri $photo.links.download_location -Headers $headers)

# --- download the file -------------------------------------------------------

$targetDir = Join-Path $RepoRoot 'static/img/posts'
if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}
$targetFile = Join-Path $targetDir "$Slug.jpg"

# urls.raw already carries a query string, so these are appended with '&'
$imageUri = "$($photo.urls.raw)&w=$Width&h=$Height&fit=crop&crop=entropy&q=$Quality&fm=jpg"

Write-Host "Downloading ${Width}x${Height} JPEG..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $imageUri -OutFile $targetFile | Out-Null

# --- write front matter ------------------------------------------------------

$utm = "utm_source=$([uri]::EscapeDataString($AppName))&utm_medium=referral"
$alt = if ($photo.alt_description) { $photo.alt_description } else { $Query }

# Unsplash profile names sometimes carry stray double spaces
function Format-Text { param([AllowNull()][string]$s) ($s -replace '\s+', ' ').Trim() }

$values = [ordered]@{
    cover          = "/img/posts/$Slug.jpg"
    coverAlt       = Format-Text $alt
    coverCredit    = Format-Text $photo.user.name
    coverCreditUrl = "https://unsplash.com/@$($photo.user.username)?$utm"
}
Update-FrontMatter -Path $PostPath -Values $values

# --- report ------------------------------------------------------------------

$sizeKb = [math]::Round((Get-Item -LiteralPath $targetFile).Length / 1KB)

Write-Host ''
Write-Host 'Cover attached.' -ForegroundColor Green
Write-Host "  post   : $([IO.Path]::GetRelativePath($RepoRoot, $PostPath))"
Write-Host "  image  : static/img/posts/$Slug.jpg ($sizeKb KB)"
Write-Host "  credit : $($photo.user.name) (@$($photo.user.username))"
Write-Host ''
Write-Host 'Remember to commit the image together with the post:' -ForegroundColor Yellow
Write-Host "  git add content/posts static/img/posts"
