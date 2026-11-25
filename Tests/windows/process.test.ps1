# What can only be seen of xless as a process of its own: a lock that ends with its holder, DLLs that are not looked for where anybody may
# put one, and that a key is derived in a process that reads secrets. Windows only.
#   pwsh Tests/windows/process.test.ps1 <XlessWindowsProbe.exe>
param([Parameter(Mandatory = $true)][string]$Probe)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$probe = (Resolve-Path $Probe).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ("xless-process-" + [Guid]::NewGuid())
$failures = 0

function Fail([string]$why) {
    Write-Host "FAIL: $why"
    $script:failures++
}

function Start-Probe([string[]]$arguments, [string]$out) {
    Start-Process -FilePath $probe -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
}

function Wait-Line([string]$out, [string]$text, [int]$seconds) {
    foreach ($i in 1..($seconds * 5)) {
        if ((Get-Content -Raw $out -ErrorAction SilentlyContinue) -match $text) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

New-Item -ItemType Directory $temp | Out-Null
$started = @()
try {
    # A lock of one process keeps another waiting, and is gone with it, however it ended.
    $file = Join-Path $temp 'secrets.lock'
    $first = Start-Probe @('lock', "`"$file`"") "$temp\1.txt"
    $started += $first
    if (-not (Wait-Line "$temp\1.txt" 'locked' 20)) { Fail "the first process got no lock: $(Get-Content -Raw "$temp\1.txt.err")" }
    $second = Start-Probe @('lock', "`"$file`"") "$temp\2.txt"
    $started += $second
    if (Wait-Line "$temp\2.txt" 'locked' 3) { Fail 'two processes have one lock' }
    $first.Kill()
    $first.WaitForExit()
    if (-not (Wait-Line "$temp\2.txt" 'locked' 20)) { Fail 'the lock outlived the process that had it' }

    # A DLL in the current directory and on PATH is found by any program, and not by xless.
    $planted = Join-Path $temp 'planted'
    New-Item -ItemType Directory $planted | Out-Null
    Copy-Item "$env:SystemRoot\System32\winmm.dll" "$planted\xless-planted.dll"
    $path = $env:PATH
    Push-Location $planted
    try {
        $env:PATH = "$planted;$path"
        $open = & $probe load-open xless-planted.dll
        if ($open -ne 'found') { Fail "the test means nothing: a planted DLL is not found by any program ($open)" }
        $xless = & $probe load xless-planted.dll
        if ($xless -ne 'not found') { Fail "a planted DLL is loaded ($xless)" }
        $system = & $probe load winmm.dll
        if ($system -ne 'found') { Fail "System32's DLLs are not found ($system)" }
    } finally {
        $env:PATH = $path
        Pop-Location
    }

    $derived = & $probe derive
    if ($derived -ne 'hardened 0 1') { Fail "deriving a key: $derived" }
} finally {
    foreach ($process in $started) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } }
    Remove-Item -Recurse -Force $temp
}
if ($failures -gt 0) { exit 1 }
Write-Host 'ok'
exit 0
