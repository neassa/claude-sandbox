#Requires -Version 5.1
# Install or update the Claude Sandbox on Windows.
# Usage:
#   gh release download -R ljanaideh/claude-sandbox -p 'install.ps1' -O "$env:TEMP\install.ps1" --clobber
#   powershell -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
# Do not pipe into iex: the pipeline splits the script into lines (fails on the
# first blank line) and a Fail/exit would close the caller's terminal.

[CmdletBinding()]
param(
    [string]$Repo   = 'ljanaideh/claude-sandbox',
    [string]$Tag    = 'latest',
    [string]$Image  = 'claude-sandbox',
    [string]$Volume = 'claude-home',
    # Path to an already-downloaded claude-sandbox-<arch>.tar.gz (skips gh download).
    [string]$Tarball = $env:CLAUDE_SANDBOX_TARBALL
)

$ErrorActionPreference = 'Stop'

function Step  { param($M) Write-Host "==> $M" -ForegroundColor Cyan }
function Ok    { param($M) Write-Host "  [ok]      $M" -ForegroundColor Green }
function Chg   { param($M) Write-Host "  [changed] $M" -ForegroundColor Yellow }
function Fail  { param($M) Write-Host "  [FAIL]    $M" -ForegroundColor Red; exit 1 }

Step "Pre-flight"
try {
    $null = & docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) { throw }
    Ok "Docker reachable"
} catch { Fail "Docker not reachable. Open Rancher/Docker Desktop and wait for 'Running'." }

try { $null = & gh --version 2>$null; if ($LASTEXITCODE -ne 0) { throw }; Ok "gh CLI installed" }
catch { Fail "gh CLI not installed. Run: winget install GitHub.cli" }

$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM') { 'arm64' } else { 'amd64' }
Ok "Architecture: $arch"

Step "Downloading image"
$asset = "claude-sandbox-$arch.tar.gz"

# Release metadata (tag, asset API url + size, optional SHA256SUMS) in one call.
$relApi = if ($Tag -eq 'latest') { "repos/$Repo/releases/latest" } else { "repos/$Repo/releases/tags/$Tag" }
$rel = $null
try {
    $relJson = (& gh api $relApi 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $relJson) { $rel = $relJson | ConvertFrom-Json }
} catch { $rel = $null }
$relTag    = if ($rel) { $rel.tag_name } else { '' }
$assetMeta = if ($rel) { $rel.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1 } else { $null }
$sumsMeta  = if ($rel) { $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1 } else { $null }

# Windows ships curl.exe (10 1803+). `curl` alone is an alias for Invoke-WebRequest.
$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
$script:ghToken = $null

# Download with curl + HTTP range resume. A stream killed mid-way by a VPN or
# TLS-inspecting proxy ("local error: tls: bad record MAC" from gh's Go client)
# continues from the last byte instead of starting over; the result is then
# verified by size and, when the release publishes SHA256SUMS, by checksum.
function Fetch-Asset {
    param([string]$Url, [string]$Dest, $Size, [switch]$Quiet)   # $Size = $null when unknown
    if (-not $script:ghToken) { $script:ghToken = ((& gh auth token) -join '').Trim() }
    $progress = if ($Quiet) { '-s' } else { '--progress-bar' }
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $have = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        if ($Size -and $have -eq $Size) { return $true }
        if ($Size -and $have -gt $Size) { Remove-Item $Dest -Force; $have = 0 }
        if ($attempt -gt 1) {
            Write-Host ("  [retry]   attempt $attempt, resuming from {0} MB..." -f [math]::Floor($have / 1MB)) -ForegroundColor Yellow
        }
        # Authorization goes to api.github.com only; curl drops it on the
        # redirect to the asset CDN, which is what the signed CDN URL expects.
        # No curl --retry: its internal retries restart from the offset of the
        # first request and discard bytes fetched since; this loop resumes
        # from the real end of the file instead. The progress bar briefly
        # shows 100% for the tiny API redirect response before the real one.
        $http = (& $curlCmd -fSL $progress -C - `
            -H "Authorization: Bearer $script:ghToken" `
            -H "Accept: application/octet-stream" `
            -o $Dest -w '%{http_code}' $Url) -join ''
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($http -eq '416') { return $true }                       # range not satisfiable: file already complete
        if ($http -match '^4\d\d$' -and $http -notin @('408', '429')) {   # permanent: don't retry
            Write-Host "  [FAIL]    HTTP $http for $Url" -ForegroundColor Red
            return $false
        }
        Start-Sleep -Seconds (3 * $attempt)
    }
    return $false
}

function Verify-Asset {
    param([string]$File, [string]$Name, $Size)
    if (-not $relTag) { Write-Host "  [warn]    could not reach the GitHub API; skipping verification" -ForegroundColor Yellow; return $true }
    $have = (Get-Item $File).Length
    if ($Size -and $have -ne $Size) { Write-Host "  [FAIL]    $Name is $have bytes, release $relTag says $Size" -ForegroundColor Red; return $false }
    if (-not $sumsMeta) { Ok "Size verified ($have bytes); release $relTag publishes no SHA256SUMS"; return $true }
    $sums = Join-Path $env:TEMP 'claude-sandbox-SHA256SUMS'
    if (Test-Path $sums) { Remove-Item $sums -Force }
    if (-not $curlCmd -or -not (Fetch-Asset $sumsMeta.url $sums $null -Quiet)) {
        Write-Host "  [warn]    could not download SHA256SUMS; size check only" -ForegroundColor Yellow; return $true
    }
    $pattern = '^\s*([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Name) + '\s*$'
    $line = Get-Content $sums | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $line) { Write-Host "  [warn]    no SHA256SUMS entry for $Name; size check only" -ForegroundColor Yellow; return $true }
    $expected = ($line -replace $pattern, '$1').ToLower()
    $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { Write-Host "  [FAIL]    SHA256 mismatch for $Name" -ForegroundColor Red; return $false }
    Ok "SHA256 verified"
    return $true
}

$downloaded = $false
if ($Tarball) {
    if (-not (Test-Path $Tarball)) { Fail "Tarball not found: $Tarball" }
    $tmp = $Tarball
    Ok "Using local tarball $Tarball"
    $expectedSize = if ($assetMeta) { $assetMeta.size } else { $null }
    if (-not (Verify-Asset $tmp $asset $expectedSize)) { Fail "Local tarball does not match release $relTag. Download it again." }
} else {
    if (-not $assetMeta) {
        $authOk = $false
        try { & gh auth status 2>$null | Out-Null; $authOk = ($LASTEXITCODE -eq 0) } catch { $authOk = $false }
        if (-not $authOk) { Fail "gh is not authenticated. Run: gh auth login" }
        Fail "Release asset $asset not found for '$Tag' in $Repo"
    }
    # Stable location so a partial download from an earlier run is resumed.
    $dlDir = Join-Path $env:TEMP 'claude-sandbox-install'
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $tmp = Join-Path $dlDir "$relTag-$asset"
    Write-Host ("  downloading $asset ({0} MB) for $relTag - resumable, re-run if interrupted" -f [math]::Floor($assetMeta.size / 1MB))
    $browserHint = "download $asset in your browser from https://github.com/$Repo/releases/tag/$relTag and re-run: .\install.ps1 -Tarball <path-to-$asset>"
    if ($curlCmd) {
        if (-not (Fetch-Asset $assetMeta.url $tmp $assetMeta.size)) {
            Fail "Download failed after 10 resumable attempts. The partial file is kept at $tmp - re-run to continue, or $browserHint"
        }
    } else {
        # No curl.exe: fall back to gh, forced to HTTP/1.1 (Go's HTTP/2 client
        # is what TLS-inspecting proxies most often break).
        $env:GODEBUG = 'http2client=0'
        & gh release download $relTag -R $Repo -p $asset -O $tmp --clobber
        if ($LASTEXITCODE -ne 0) { Fail "gh download failed. Please $browserHint" }
    }
    if (-not (Verify-Asset $tmp $asset $assetMeta.size)) {
        Remove-Item $tmp -Force
        Fail "Downloaded file failed verification and was deleted. Re-run to download again."
    }
    Ok "Downloaded $asset"
    $downloaded = $true
}

Step "Loading image"
& docker load -i $tmp
if ($LASTEXITCODE -ne 0) { Fail "docker load failed" }
if ($downloaded) { Remove-Item $tmp -Force }
Chg "Image loaded"

$loaded = & docker images --format "{{.Repository}}:{{.Tag}}" `
    | Where-Object { $_ -match "^claude-sandbox:.*-$arch$" } `
    | Select-Object -First 1
if (-not $loaded) { Fail "Loaded image not found in 'docker images'" }
& docker tag $loaded $Image
Chg "Tagged $loaded -> $Image"

$vols = & docker volume ls --format '{{.Name}}'
if ($vols -contains $Volume) { Ok "Volume '$Volume' exists" }
else { & docker volume create $Volume | Out-Null; Chg "Volume '$Volume' created" }

if ($env:OS -eq 'Windows_NT') {
    Step "Execution policy (the profile must be allowed to load in new sessions)"
    $pol = Get-ExecutionPolicy -List
    $gpo = $pol | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' } | Select-Object -First 1
    $cu  = ($pol | Where-Object Scope -eq 'CurrentUser').ExecutionPolicy
    $lm  = ($pol | Where-Object Scope -eq 'LocalMachine').ExecutionPolicy
    $blocking = @('Restricted', 'AllSigned', 'Undefined')
    if ($gpo) {
        if ($gpo.ExecutionPolicy -in 'Restricted', 'AllSigned') {
            Write-Host "  [WARN]    Group Policy sets execution policy $($gpo.ExecutionPolicy): profile scripts will not load in new sessions. Ask IT." -ForegroundColor Yellow
        } else { Ok "Execution policy $($gpo.ExecutionPolicy) (Group Policy)" }
    } elseif ($cu -notin $blocking) { Ok "Execution policy CurrentUser=$cu" }
    elseif ($lm -notin $blocking) { Ok "Execution policy LocalMachine=$lm" }
    else {
        try {
            Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
            Chg "Execution policy CurrentUser set to RemoteSigned (was $cu) so the profile loads in new sessions"
        } catch {
            Write-Host "  [WARN]    Could not set execution policy ($($_.Exception.Message)). Run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor Yellow
        }
    }
}

Step "Updating PowerShell profile"
$startMarker = '# >>> claude-sandbox functions'
$endPattern  = '# <<< claude-sandbox functions <+'
$blockRegex  = "(?ms)\r?\n?$([regex]::Escape($startMarker)).*?$endPattern\r?\n?"

$block = @"

# >>> claude-sandbox functions (managed by install.ps1) >>>
# Host CA passthrough: corporate TLS inspection (Cloudflare WARP Gateway,
# Zscaler, ...) re-signs HTTPS with a private CA the image does not trust,
# which surfaces as "Unable to connect to API: SSL certificate verification
# failed". Export the Windows root stores to PEM, mount that over the
# container's CA bundle and point Node at it.
# Override with `$env:CLAUDE_SANDBOX_CA_BUNDLE = 'C:\path\bundle.pem' ('none' disables).
function claude-docker {
    `$caBundle = `$env:CLAUDE_SANDBOX_CA_BUNDLE
    if (-not `$caBundle) {
        `$caBundle = Join-Path `$env:USERPROFILE '.claude-sandbox\ca-bundle.pem'
        New-Item -ItemType Directory -Force -Path (Split-Path `$caBundle) | Out-Null
        Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\CA, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            ForEach-Object {
                "-----BEGIN CERTIFICATE-----``n" +
                [Convert]::ToBase64String(`$_.RawData, 'InsertLineBreaks') +
                "``n-----END CERTIFICATE-----"
            } | Set-Content -Path `$caBundle -Encoding ascii
    }
    `$caArgs = @()
    if (`$caBundle -ne 'none' -and (Test-Path `$caBundle) -and (Get-Item `$caBundle).Length -gt 0) {
        `$caArgs = @('-v', "`${caBundle}:/etc/ssl/certs/ca-certificates.crt:ro",
                    '-e', 'NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt')
    }
    docker run -it --rm ``
        --cap-add=NET_ADMIN --cap-add=NET_RAW ``
        -v "`${PWD}:/workspace" ``
        -v $($Volume):/home/dev ``
        -p 127.0.0.1:8976:8976 ``
        -w //workspace ``
        @caArgs ``
        $Image @args
}
function claude-update {
    # Run as a file in a child process: iex would split lines and an installer
    # failure (exit 1) would close this terminal.
    `$installer = Join-Path `$env:TEMP 'claude-sandbox-install.ps1'
    iwr -UseBasicParsing "https://github.com/$Repo/releases/latest/download/install.ps1" -OutFile `$installer
    powershell -ExecutionPolicy Bypass -File `$installer
    . `$PROFILE
}
function claude-refresh {
    `$cid = docker ps -q --filter "ancestor=$Image" | Select-Object -First 1
    if (-not `$cid) { Write-Host "No running $Image container."; return }
    docker exec -u root `$cid //usr/local/bin/refresh-allows.sh
}
# <<< claude-sandbox functions <<<
"@

function Remove-ManagedBlock {   # returns $true when a block was removed
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $c = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $c -or $c -notmatch [regex]::Escape($startMarker)) { return $false }
    Set-Content -Path $Path -Value ($c -replace $blockRegex, '') -NoNewline
    return $true
}
function Write-ManagedBlock {
    param([string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
    $c = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $c) { $c = '' }
    $refreshed = $c -match [regex]::Escape($startMarker)
    # Appended at the END so it wins over any older claude-docker defined earlier in the file.
    Set-Content -Path $Path -Value (($c -replace $blockRegex, '').TrimEnd() + $block) -NoNewline
    if ($refreshed) { Chg "Refreshed managed block in $Path" } else { Chg "Added managed block to $Path" }
}

# Write to the current-host profile (`$PROFILE): PowerShell loads it LAST, after
# profile.ps1 and the AllUsers profiles, so our definitions win over stale ones
# there. Also write the other edition's profile (Windows PowerShell 5.1 vs
# PowerShell 7) when that edition is set up, so both shells get the functions.
$docs = Split-Path (Split-Path $PROFILE.CurrentUserCurrentHost -Parent) -Parent
$otherEditions = @(
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
) | Where-Object { $_ -ne $PROFILE.CurrentUserCurrentHost -and (Test-Path (Split-Path $_ -Parent)) }
$targets = @($PROFILE.CurrentUserCurrentHost) + @($otherEditions)
foreach ($t in $targets) { Write-ManagedBlock $t }

# Earlier installers wrote to profile.ps1 (AllHosts); remove those copies.
$oldLocations = @(
    $PROFILE.CurrentUserAllHosts,
    (Join-Path $docs 'WindowsPowerShell\profile.ps1'),
    (Join-Path $docs 'PowerShell\profile.ps1')
) | Select-Object -Unique | Where-Object { $targets -notcontains $_ }
foreach ($old in $oldLocations) {
    try { if (Remove-ManagedBlock $old) { Chg "Removed old managed block from $old" } } catch {}
}

# Any claude-* function defined outside a managed block may override ours.
$scan = @(
    $PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost,
    $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost,
    (Join-Path $docs 'WindowsPowerShell\profile.ps1'), (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'PowerShell\profile.ps1'), (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
) | Select-Object -Unique
$conflicts = 0
foreach ($f in $scan) {
    if (-not (Test-Path $f)) { continue }
    $inBlock = $false; $ln = 0
    foreach ($line in (Get-Content $f)) {
        $ln++
        if ($line -match [regex]::Escape($startMarker)) { $inBlock = $true }
        if ($line -match $endPattern) { $inBlock = $false; continue }
        if (-not $inBlock -and $line -match '^\s*function\s+(claude-(docker|update|refresh))\b') {
            $conflicts++
            Write-Host "  [WARN]    ${f}:${ln} defines $($Matches[1]) outside the managed block. It may override the installed one - delete it." -ForegroundColor Yellow
        }
    }
}
if ($conflicts -eq 0) { Ok "No conflicting claude-* definitions in other profiles" }

Write-Host ""
Write-Host "Done. Reload: . `$PROFILE" -ForegroundColor Green
Write-Host "Then run:    claude-docker" -ForegroundColor Green
