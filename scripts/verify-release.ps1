# Installs a release's Windows package before it is published, as a user would, and checks the version it reports: the counterpart of
# scripts/verify-release.sh.
#   scripts/verify-release.ps1 <version> <dist> [-Keep]
# <dist> holds the release's packages. The zip and a SHA256SUMS of all of them are laid out the way a GitHub release serves them, and
# scripts/install.ps1 installs from there (XLESS_RELEASE_BASE=file://...) twice: pinned to <version>, with Windows PowerShell, and as the
# latest, with PowerShell 7. Each time `xless --version`, with no other directory than System32 on PATH, and share/xless/VERSION must be
# <version>. It is the real installation of the user who runs this (%LOCALAPPDATA%\Programs\xless), so only for a machine that is thrown
# away. Taken away again at the end, unless -Keep.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Version, [Parameter(Mandatory = $true)][string]$Dist, [switch]$Keep)
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install.ps1'
$zip = Join-Path $Dist "xless-$Version-windows-x86_64.zip"
if (-not (Test-Path -LiteralPath $zip)) { throw "verify-release: no $zip" }
$release = Join-Path ([IO.Path]::GetTempPath()) "xless-release-$([Guid]::NewGuid().ToString('N'))"
$target = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\xless'
$saved = @{}
foreach ($name in 'XLESS_RELEASE_BASE', 'XLESS_VERSION', 'XLESS_UNINSTALL', 'PATH') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

# As `irm ... | iex` does.
function Invoke-Installer([string]$shell) {
    & $shell -NoProfile -NonInteractive -Command "Invoke-Expression ([IO.File]::ReadAllText('$($installer -replace "'", "''")'))" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "verify-release: install.ps1 failed with $shell ($LASTEXITCODE)" }
}

function Assert-Installed([string]$label) {
    $env:PATH = Join-Path $env:SystemRoot 'System32'
    try { $got = & (Join-Path $target 'bin\xless.exe') --version } finally { $env:PATH = $saved['PATH'] }
    if ($LASTEXITCODE -ne 0 -or $got -cne $Version) { throw "verify-release: ${label}: xless --version printed '$got' ($LASTEXITCODE), expected '$Version'" }
    $got = [IO.File]::ReadAllText((Join-Path $target 'share\xless\VERSION')).Trim()
    if ($got -cne $Version) { throw "verify-release: ${label}: share/xless/VERSION is '$got', expected '$Version'" }
    Write-Host "verify-release: ${label}: xless $Version installed and reports $Version"
}

try {
    $sums = Get-ChildItem -LiteralPath $Dist -File | Where-Object { $_.Name -match '^xless-.*\.(tar\.gz|zip)$' } | Sort-Object Name |
        ForEach-Object { "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)`n" }
    foreach ($directory in "download\v$Version", 'latest\download') {
        $there = Join-Path $release $directory
        New-Item -ItemType Directory -Path $there | Out-Null
        Copy-Item -LiteralPath $zip -Destination $there
        [IO.File]::WriteAllText((Join-Path $there 'SHA256SUMS'), ($sums -join ''))
    }
    $env:XLESS_RELEASE_BASE = ([Uri]$release).AbsoluteUri
    $env:XLESS_VERSION = $Version
    Invoke-Installer 'powershell.exe'
    Assert-Installed "v$Version"
    $env:XLESS_VERSION = ''
    Invoke-Installer 'pwsh.exe'
    Assert-Installed 'latest'
    if (-not $Keep) {
        $env:XLESS_UNINSTALL = '1'
        Invoke-Installer 'powershell.exe'
        if (Test-Path -LiteralPath $target) { throw "verify-release: $target is still there" }
    }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $release) { Remove-Item -LiteralPath $release -Recurse -Force }
}
