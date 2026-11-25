# Installs the Swift toolchain of versions.env on a Windows runner (pr.yml's windows-tests), and puts it on the PATH of the steps
# that follow.
#   scripts/windows-toolchain.ps1                      downloads, checks and installs it
#   scripts/windows-toolchain.ps1 -Check <installer>   only checks a file, as the install does
# swift.org publishes neither a checksum nor a detached signature for its Windows installers. The file must have the SHA-256 of
# versions.env (taken from winget's manifest of the same version), and its Authenticode signature must be valid and of the signer
# named there. Nothing is started before both hold. Needs no elevation: the toolchain goes into the user's own profile.
[CmdletBinding()]
param([string]$Check = '', [string]$Versions = (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.env'))
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell's progress bar makes a download many times slower

function Get-Pin([string]$name) {
    $found = @(Get-Content -LiteralPath $Versions | Where-Object { $_ -clike "$name=*" })
    if ($found.Count -ne 1) { throw "versions.env has no single $name" }
    return $found[0].Substring($name.Length + 1) -replace '^"(.*)"$', '$1'
}

# Throws unless the file is the pinned installer, signed by the pinned signer.
function Assert-Installer([string]$path) {
    $expected = Get-Pin 'SWIFT_WINDOWS_SHA256_X86_64'
    if ($expected -cnotmatch '^[0-9a-f]{64}$') { throw 'SWIFT_WINDOWS_SHA256_X86_64 is not a SHA-256' }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) { throw "the installer's SHA-256 is $actual, not versions.env's $expected" }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid') { throw "the installer's Authenticode signature is not valid: $($signature.Status)" }
    $signer = Get-Pin 'SWIFT_WINDOWS_SIGNER'
    if ($signature.SignerCertificate.Subject -cne $signer) {
        throw "the installer is signed by '$($signature.SignerCertificate.Subject)', not by versions.env's '$signer'"
    }
    Write-Host "the installer is versions.env's: SHA-256 $actual, signed by $signer"
}

if ($Check) { Assert-Installer $Check; return }

$url = Get-Pin 'SWIFT_WINDOWS_URL_X86_64'
$version = Get-Pin 'SWIFT_VERSION'
if ($url -cne "https://download.swift.org/swift-$version-release/windows10/swift-$version-RELEASE/swift-$version-RELEASE-windows10.exe") {
    throw "SWIFT_WINDOWS_URL_X86_64 is not swift.org's installer of SWIFT_VERSION ${version}: $url"
}
$dir = Join-Path $env:RUNNER_TEMP "swift-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir | Out-Null
$installer = Join-Path $dir 'installer.exe'
for ($attempt = 1; ; $attempt++) {
    # curl.exe is Windows' own.
    & "$env:SystemRoot\System32\curl.exe" --fail --silent --show-error --proto '=https' --connect-timeout 30 --speed-limit 100000 --speed-time 60 --max-time 1200 --output $installer $url
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 3) { throw "cannot download $url (curl: $LASTEXITCODE)" }
    Write-Host "::warning::downloading the Swift toolchain failed (curl: $LASTEXITCODE), trying again"
    Start-Sleep -Seconds (20 * $attempt)
}
Assert-Installer $installer

for ($attempt = 1; ; $attempt++) {
    $log = Join-Path $dir "install-$attempt.log"
    $process = Start-Process -FilePath $installer -ArgumentList '/quiet', '/norestart', '/log', $log -PassThru
    $null = $process.Handle   # kept open, so that the exit code can be read
    $ended = $process.WaitForExit(20 * 60 * 1000)
    if (-not $ended) { $process.Kill() }
    $code = if ($ended) { $process.ExitCode } else { 'none: it did not end' }
    if ($code -in 0, 3010) { break }   # 3010: installed, Windows would like to restart
    Get-Content -LiteralPath $log -Tail 60 -ErrorAction SilentlyContinue | Write-Host
    if ($attempt -eq 2) { throw "the Swift installer failed (exit code $code)" }
    Write-Host "::warning::the Swift installer failed (exit code $code), trying once more"
}
Remove-Item -LiteralPath $installer -Force

# What the installer set for new processes, for this job's next steps.
$paths = @()
$sdk = $null
foreach ($level in 'Machine', 'User') {
    $variables = [Environment]::GetEnvironmentVariables($level)
    $paths += @("$($variables['Path'])" -split ';' | Where-Object { $_ -match '\\Swift\\' })
    if ($variables['SDKROOT']) { $sdk = $variables['SDKROOT'] }
}
$paths = @($paths | Select-Object -Unique)
if ($paths.Count -eq 0 -or -not $sdk) { throw 'the Swift installer set no PATH or no SDKROOT' }
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::AppendAllText($env:GITHUB_PATH, (($paths | ForEach-Object { "$_`n" }) -join ''), $utf8)
[IO.File]::AppendAllText($env:GITHUB_ENV, "SDKROOT=$sdk`n", $utf8)
$env:Path = ($paths -join ';') + ';' + $env:Path
$env:SDKROOT = $sdk
Write-Host "PATH: $($paths -join ' ')"
Write-Host "SDKROOT: $sdk"
& swift --version
if ($LASTEXITCODE -ne 0) { throw "swift --version failed ($LASTEXITCODE)" }
$reported = (& swift --version 2>$null) -join ' '
if ($reported -notmatch "Swift version $([regex]::Escape(($version -replace '\.0$', '')))(\.0)?[ (]") { throw "the installed swift is not ${version}: $reported" }
