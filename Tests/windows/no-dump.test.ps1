# A process that read a secret leaves nothing of its memory when it crashes: no dump where Windows is told to write one of every crash
# (LocalDumps, which an administrator sets: run this as one, on a machine that is thrown away). Windows only.
#   pwsh Tests/windows/no-dump.test.ps1 <XlessWindowsProbe.exe>
param([Parameter(Mandatory = $true)][string]$Probe)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$probe = (Resolve-Path $Probe).Path
$name = Split-Path -Leaf $probe
$reporting = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
$key = "$reporting\LocalDumps\$name"
$dumps = Join-Path ([IO.Path]::GetTempPath()) ("xless-dumps-" + [Guid]::NewGuid())
$failures = 0

function Fail([string]$why) {
    Write-Host "FAIL: $why"
    $script:failures++
}

# The exit code and the dump (its path, or $null) of one run.
function Crash([string]$mode, [string]$how) {
    Get-ChildItem $dumps | Remove-Item
    $process = Start-Process -FilePath $probe -ArgumentList $mode, $how -NoNewWindow -Wait -PassThru -RedirectStandardOutput (Join-Path $dumps '..\xless-probe-out.txt') -RedirectStandardError (Join-Path $dumps '..\xless-probe-err.txt')
    if (-not ((Get-Content -Raw (Join-Path $dumps '..\xless-probe-out.txt') -ErrorAction SilentlyContinue) -match 'ready')) { Fail "$mode $how did not come to its crash" }
    # An error report is written by another process.
    foreach ($i in 1..20) {
        $dump = @(Get-ChildItem $dumps -Filter *.dmp)
        if ($dump.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 500
    @{ Code = $process.ExitCode; Dump = $(if ($dump.Count -gt 0) { $dump[0].FullName } else { $null }) }
}

New-Item -ItemType Directory $dumps | Out-Null
New-Item -Path $key -Force | Out-Null
try {
    New-ItemProperty -Path $key -Name DumpFolder -PropertyType ExpandString -Value $dumps | Out-Null
    New-ItemProperty -Path $key -Name DumpType -PropertyType DWord -Value 2 | Out-Null
    foreach ($how in 'fault', 'trap', 'abort') {
        $open = Crash 'open' $how
        # The test means something: as any other process, this one leaves a dump with the secret in it.
        if (-not $open.Dump) { Fail "$how`: this machine writes no dump of a crash at all" }
        else {
            $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($open.Dump))
            if ($text.IndexOf('XLESS-SECRET-' + 'MARGLE', [StringComparison]::Ordinal) -lt 0) { Fail "$how`: the dump of the open process has not its memory" }
        }
        $secret = Crash 'secret' $how
        if ($secret.Dump) { Fail "$how`: a process that read a secret left a dump" }
        foreach ($run in $open, $secret) { if ($run.Code -eq 0) { Fail "$how`: exit code 0" } }
        Write-Host ("{0}: open {1:x8}, dump {2}; secret {3:x8}, dump {4}" -f $how, $open.Code, [bool]$open.Dump, $secret.Code, [bool]$secret.Dump)
    }
} finally {
    Remove-Item -Path $key -Recurse
    Remove-Item -Recurse -Force $dumps
}
if ($failures -gt 0) { exit 1 }
Write-Host 'ok'
exit 0
