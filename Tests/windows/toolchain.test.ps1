# scripts/windows-toolchain.ps1 -Check: only the pinned installer, signed by the pinned signer. Runs on Windows (pr.yml's windows-tests).
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script = Join-Path $root 'scripts/windows-toolchain.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) "xless-toolchain-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir | Out-Null

function Write-Versions([string]$name, [string[]]$lines) {
    $path = Join-Path $dir $name
    [IO.File]::WriteAllLines($path, $lines)
    return $path
}
function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
# The message it is refused with; '' when it is accepted.
function Get-Refusal([string]$file, [string]$versions) {
    try { & $script -Check $file -Versions $versions *>$null } catch { return $_.Exception.Message }
    return ''
}
function Assert-Like([string]$what, [string]$actual, [string]$pattern) {
    if ($actual -notlike $pattern) { throw "FAIL: ${what}: '$actual' is not like '$pattern'" }
    Write-Host "ok: $what"
}

try {
    # A file that is signed by somebody, and its signer.
    $signed = Join-Path $dir 'signed.exe'
    Copy-Item -LiteralPath (Get-Command pwsh.exe, powershell.exe -ErrorAction SilentlyContinue | Where-Object {
        (Get-AuthenticodeSignature -LiteralPath $_.Source).SignatureType -eq 'Authenticode' } | Select-Object -First 1).Source -Destination $signed
    $signature = Get-AuthenticodeSignature -LiteralPath $signed
    if ($signature.Status -ne 'Valid') { throw "the test's own signed file is not valid: $($signature.Status)" }
    $signer = $signature.SignerCertificate.Subject
    $unsigned = Join-Path $dir 'unsigned.exe'
    [IO.File]::WriteAllText($unsigned, 'not an installer')

    $good = Write-Versions 'good.env' @("SWIFT_WINDOWS_SHA256_X86_64=$(Get-Sha256 $signed)", "SWIFT_WINDOWS_SIGNER=`"$signer`"")
    Assert-Like 'the pinned file of the pinned signer is accepted' "[$(Get-Refusal $signed $good)]" '[[][]]'
    Assert-Like 'another file is refused by its hash' (Get-Refusal $unsigned $good) "*SHA-256 is *, not versions.env's*"

    $bytes = [IO.File]::ReadAllBytes($signed)
    $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1
    $bytes[4096] = $bytes[4096] -bxor 1
    $altered = Join-Path $dir 'altered.exe'
    [IO.File]::WriteAllBytes($altered, $bytes)
    Assert-Like 'an altered one is refused by its hash' (Get-Refusal $altered $good) "*SHA-256 is *, not versions.env's*"
    $alteredPin = Write-Versions 'altered.env' @("SWIFT_WINDOWS_SHA256_X86_64=$(Get-Sha256 $altered)", "SWIFT_WINDOWS_SIGNER=$signer")
    Assert-Like 'and by its signature, were that its hash' (Get-Refusal $altered $alteredPin) '*signature is not valid*'
    $unsignedPin = Write-Versions 'unsigned.env' @("SWIFT_WINDOWS_SHA256_X86_64=$(Get-Sha256 $unsigned)", "SWIFT_WINDOWS_SIGNER=$signer")
    Assert-Like 'an unsigned one too' (Get-Refusal $unsigned $unsignedPin) '*signature is not valid*'
    $other = Write-Versions 'other.env' @("SWIFT_WINDOWS_SHA256_X86_64=$(Get-Sha256 $signed)", 'SWIFT_WINDOWS_SIGNER=CN=Somebody else')
    Assert-Like "another signer's is refused" (Get-Refusal $signed $other) "*is signed by *, not by versions.env's*"
    $none = Write-Versions 'none.env' @("SWIFT_WINDOWS_SIGNER=$signer")
    Assert-Like 'without a pin nothing is accepted' (Get-Refusal $signed $none) '*no single SWIFT_WINDOWS_SHA256_X86_64*'
    $empty = Write-Versions 'empty.env' @('SWIFT_WINDOWS_SHA256_X86_64=', "SWIFT_WINDOWS_SIGNER=$signer")
    Assert-Like 'nor with an empty one' (Get-Refusal $signed $empty) '*is not a SHA-256*'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force }
Write-Host 'toolchain: ok'
