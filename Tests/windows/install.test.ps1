# scripts/install.ps1, with releases made here (their xless.exe is a program of Windows): what it installs and where, what it refuses,
# and that it leaves everything else alone. Installs for the user who runs it: only on a machine that is thrown away.
#   powershell|pwsh Tests/windows/install.test.ps1
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $root 'scripts\install.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) "xless-install-test-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $dir | Out-Null
$local = [Environment]::GetFolderPath('LocalApplicationData')
$programs = Join-Path $local 'Programs'
$target = Join-Path $programs 'xless'
$bin = Join-Path $target 'bin'
$exe = Join-Path $bin 'xless.exe'
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (Test-Path -LiteralPath $target) { throw "there is an xless in $target" }
Add-Type -AssemblyName System.IO.Compression

function Write-Package([string]$version, $files) {
    $path = Join-Path $dir "release\download\v$version"
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    $zip = Join-Path $path "xless-$version-windows-x86_64.zip"
    $stream = [IO.File]::Create($zip)
    $archive = New-Object IO.Compression.ZipArchive $stream, ([IO.Compression.ZipArchiveMode]::Create)
    foreach ($name in $files.Keys) {
        $to = $archive.CreateEntry($name).Open()
        $bytes = $files[$name]
        $to.Write($bytes, 0, $bytes.Length)
        $to.Close()
    }
    $archive.Dispose()
    $stream.Close()
    $sum = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $path 'SHA256SUMS'), "$('0' * 64)  xless-$version-linux-x86_64.tar.gz`n$sum  xless-$version-windows-x86_64.zip`n")
    $latest = Join-Path $dir 'release\latest\download'
    New-Item -ItemType Directory -Force -Path $latest | Out-Null
    Copy-Item -LiteralPath (Join-Path $path 'SHA256SUMS') -Destination $latest
}
$program = [IO.File]::ReadAllBytes((Join-Path $env:SystemRoot 'System32\PING.EXE'))
function Get-Files([string]$version) {
    $top = "xless-$version-windows-x86_64"
    $files = New-Object 'System.Collections.Generic.Dictionary[string,byte[]]'   # case tells two names apart
    $files["$top/bin/xless.exe"] = $program
    $files["$top/bin/swiftCore.dll"] = [Text.Encoding]::ASCII.GetBytes("core $version")
    $files["$top/LICENSE"] = [byte[]](65, 10)
    $files["$top/share/xless/VERSION"] = [Text.Encoding]::ASCII.GetBytes("$version`n")
    $files["$top/share/xless/licenses/a.txt"] = [byte[]](66, 10)
    return $files
}
# Runs the installer in a PowerShell of its own, as `irm | iex` does; what it said, its exit code after it.
function Invoke-Install([hashtable]$variables, [string]$script = $installer) {
    $all = @{ XLESS_RELEASE_BASE = ([Uri](Join-Path $dir 'release')).AbsoluteUri; XLESS_VERSION = ''; XLESS_UNINSTALL = ''; XLESS_ALLOW_ELEVATED = '1' }
    foreach ($name in $variables.Keys) { $all[$name] = $variables[$name] }
    foreach ($name in $all.Keys) { [Environment]::SetEnvironmentVariable($name, $all[$name]) }
    $before = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # a word on standard error is no exception
    $said = & $shell -NoProfile -NonInteractive -Command "Invoke-Expression ([IO.File]::ReadAllText('$script'))" 2>&1 | Out-String
    $ErrorActionPreference = $before
    return "$said`nexit $LASTEXITCODE"
}
function Assert([string]$what, [bool]$holds, [string]$more = '') {
    if (-not $holds) { throw "FAIL: $what $more" }
    Write-Host "ok: $what"
}
# An error is wrapped to the width of a terminal that is none, also within a word, with bars before the lines.
function Get-Plain([string]$text) { return ($text -replace '[\s|]+', '') }
function Assert-Refused([string]$what, [hashtable]$variables, [string]$why, [string]$script = $installer) {
    $said = Get-Plain (Invoke-Install $variables $script)
    Assert $what (($said -match 'exit1') -and ($said -match $why.Replace(' ', ''))) $said
}
$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
$had = @($key.GetValueNames()) -contains 'Path'
$path = if ($had) { $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames') } else { '' }
$kind = if ($had) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
function Get-UserPath { return $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames') }
function Get-Leftover { return Get-ChildItem -LiteralPath $programs -Force -Filter '.xless-*' }
$store = Join-Path $local 'xless'
$hadStore = Test-Path -LiteralPath $store
$running = $null
try {
    $mine = '%USERPROFILE%\xless-test;C:\another;'
    $key.SetValue('Path', $mine, 'ExpandString')
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    [IO.File]::WriteAllText((Join-Path $store 'test.txt'), 'mine')

    Write-Package '1.2.3' (Get-Files '1.2.3')
    Assert-Refused 'an elevated terminal is refused' @{ XLESS_ALLOW_ELEVATED = '' } 'this terminal is elevated'
    Assert-Refused 'http is refused' @{ XLESS_RELEASE_BASE = 'http://localhost:9/releases' } 'is not https'
    Assert-Refused 'what is no version is refused' @{ XLESS_VERSION = '../1.2.3' } 'is no version'
    Assert-Refused 'a version that there is not is refused' @{ XLESS_VERSION = '9.9.9' } 'SHA256SUMS'
    Assert-Refused 'nor a version with a line more' @{ XLESS_VERSION = "1.2.3`n" } 'is no version'
    # A Windows without a part of the Visual C++ runtime: an installer that asks for one that there is not.
    $text = [IO.File]::ReadAllText($installer)
    $lacking = Join-Path $dir 'lacking.ps1'
    foreach ($part in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
        Assert "the installer asks for $part once" ([regex]::Matches($text, "'$([regex]::Escape($part))'").Count -eq 1)
        [IO.File]::WriteAllText($lacking, $text.Replace("'$part'", "'xless-no-$part'"))
        Assert-Refused "a Windows without $part is refused" @{} "lacks xless-no-$([regex]::Escape($part)); nothing was installed.*winget install Microsoft\.VCRedist\.2015\+\.x64" $lacking
    }
    [IO.File]::WriteAllText($lacking, $text.Replace("'msvcp140.dll'", "'xless-no.dll'").Replace("if (`$machine -ne 'AMD64'", "`$machine = 'ARM64'; if (`$machine -ne 'AMD64'"))
    Assert 'nothing was installed' (-not (Test-Path -LiteralPath $target))
    Assert 'and nothing left' (@(Get-Leftover).Count -eq 0)

    $said = Invoke-Install @{}
    Assert 'the latest is installed' ($said -match 'xless 1\.2\.3 installed to' -and $said -match 'exit 0') $said
    Assert 'with its files' ([IO.File]::ReadAllText("$bin\swiftCore.dll") -eq 'core 1.2.3' -and (Test-Path "$target\share\xless\licenses\a.txt") -and (Test-Path "$target\LICENSE"))
    Assert 'on the PATH, which is as it was otherwise' ((Get-UserPath) -ceq "%USERPROFILE%\xless-test;C:\another;$bin" -and $key.GetValueKind('Path') -eq 'ExpandString') (Get-UserPath)
    $acl = Get-Acl -LiteralPath $target
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
    $want = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544' | Sort-Object)
    Assert 'only the user, SYSTEM and the administrators may open it' ($acl.AreAccessRulesProtected -and "$sids" -eq "$want") "$sids"
    $inner = Get-Acl -LiteralPath $exe
    $sids = @($inner.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
    Assert 'nor its program' ("$sids" -eq "$want") "$sids"
    Assert 'nothing is left' (@(Get-Leftover).Count -eq 0)

    # On ARM64 nobody can tell by the files, and it says what is needed.
    $said = Invoke-Install @{} $lacking
    if ([Environment]::OSVersion.Version.Build -ge 22000) { Assert 'on ARM64 it installs and says what it needs' ($said -match 'exit 0' -and $said -match 'under emulation' -and $said -match 'VCRedist') $said }
    else { Assert 'an ARM64 Windows that is too old is refused' ($said -match 'exit 1' -and $said -match 'from Windows 11 on') $said }
    [IO.File]::WriteAllText($lacking, $text.Replace("'msvcp140.dll'", "'xless-no.dll'"))
    Assert-Refused 'one that is there is not replaced without the runtime' @{} 'lacks xless-no\.dll' $lacking
    Assert 'and works as before' ([IO.File]::ReadAllText("$bin\swiftCore.dll") -eq 'core 1.2.3' -and @(Get-Leftover).Count -eq 0)
    $said = Invoke-Install @{ XLESS_UNINSTALL = '1' } $lacking
    Assert 'it is taken away without the runtime too' ($said -match 'exit 0' -and -not (Test-Path -LiteralPath $target)) $said
    $said = Invoke-Install @{}
    Assert 'and installed again' ($said -match 'exit 0' -and (Test-Path -LiteralPath $exe)) $said

    # Another one over it, while a program of it runs.
    Write-Package '1.3.0' (Get-Files '1.3.0')
    [IO.File]::WriteAllText("$bin\old.dll", 'of the old one')
    $running = Start-Process -FilePath $exe -ArgumentList '-n', '600', '127.0.0.1' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $said = Invoke-Install @{ XLESS_VERSION = 'v1.3.0' }
    Assert 'a newer one is installed over one that runs' ($said -match 'xless 1\.3\.0 installed' -and $said -match 'exit 0') $said
    Assert 'with its files, and none of the old' ([IO.File]::ReadAllText("$bin\swiftCore.dll") -eq 'core 1.3.0' -and -not (Test-Path "$bin\old.dll") -and (Test-Path $exe))
    Assert 'the program that ran still runs' (-not $running.HasExited)
    Assert 'once on the PATH' ((Get-UserPath) -ceq "%USERPROFILE%\xless-test;C:\another;$bin") (Get-UserPath)
    $running.Kill()
    $running.WaitForExit()
    $said = Invoke-Install @{ XLESS_VERSION = '1.2.3' }
    Assert 'an older one is installed when it is asked for' ($said -match 'xless 1\.2\.3 installed' -and [IO.File]::ReadAllText("$bin\swiftCore.dll") -eq 'core 1.2.3') $said
    Assert 'and what could not be deleted is deleted' (@(Get-Leftover).Count -eq 0)

    # Refused, with the installed one untouched.
    $zip = Join-Path $dir 'release\download\v1.3.0\xless-1.3.0-windows-x86_64.zip'
    $bytes = [IO.File]::ReadAllBytes($zip)
    $bytes[40] = $bytes[40] -bxor 1
    [IO.File]::WriteAllBytes($zip, $bytes)
    Assert-Refused 'a zip that is not that of SHA256SUMS is refused' @{ XLESS_VERSION = '1.3.0' } 'sha256 mismatch'
    [IO.File]::WriteAllText((Join-Path $dir 'release\download\v1.3.0\SHA256SUMS'), "$('0' * 64)  xless-1.3.0-linux-x86_64.tar.gz`n")
    Assert-Refused 'a zip that SHA256SUMS does not list is refused' @{ XLESS_VERSION = '1.3.0' } 'does not list'
    foreach ($name in '../evil.txt', 'xless-1.4.0-windows-x86_64/../../evil.txt', '/evil.txt', 'C:/evil.txt', 'xless-1.4.0-windows-x86_64\bin\evil.dll', 'xless-1.4.0-windows-x86_64/bin/x:y',
        'xless-1.4.0-windows-x86_64/bin/', 'xless-1.4.0-windows-x86_64/bin/.hidden', 'xless-1.4.0-windows-x86_64/bin/dot.', 'other/x', 'xless-1.4.0-windows-x86_64/BIN/XLESS.EXE') {
        $files = Get-Files '1.4.0'
        $files[$name] = [byte[]](1)
        Write-Package '1.4.0' $files
        Assert-Refused "an entry $name is refused" @{ XLESS_VERSION = '1.4.0' } 'an entry that no release has'
    }
    $files = Get-Files '1.4.0'
    [void]$files.Remove('xless-1.4.0-windows-x86_64/bin/xless.exe')
    Write-Package '1.4.0' $files
    Assert-Refused 'a zip without xless.exe is refused' @{ XLESS_VERSION = '1.4.0' } 'has no bin'
    [IO.File]::WriteAllText((Join-Path $dir 'release\latest\download\SHA256SUMS'), "$('0' * 64)  xless-1.3.0-linux-x86_64.tar.gz`n")
    Assert-Refused 'a release without Windows is refused' @{} 'has no package for Windows'
    Assert 'the installed one is as it was' ([IO.File]::ReadAllText("$bin\swiftCore.dll") -eq 'core 1.2.3' -and @(Get-Leftover).Count -eq 0)
    Assert 'nothing got out' (@(Get-ChildItem -LiteralPath $local, $programs, $dir -Filter 'evil*' -Recurse -Depth 2 -ErrorAction SilentlyContinue).Count -eq 0)

    # What is not an xless is not touched.
    Write-Package '1.5.0' (Get-Files '1.5.0')
    $away = Join-Path $dir 'away'
    Move-Item -LiteralPath $target -Destination $away
    New-Item -ItemType Directory -Path $target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'mine.txt'), 'mine')
    Assert-Refused 'a directory of something else is refused' @{} 'is no installed xless'
    Assert-Refused 'also to take away' @{ XLESS_UNINSTALL = '1' } 'is no installed xless'
    Remove-Item -LiteralPath $target -Recurse
    New-Item -ItemType Junction -Path $target -Value $away | Out-Null
    Assert-Refused 'a link is refused' @{} 'is a link'
    Assert-Refused 'also to take away' @{ XLESS_UNINSTALL = '1' } 'is a link'
    [IO.Directory]::Delete($target)
    Assert 'what it leads to is as it was' (Test-Path -LiteralPath "$away\bin\xless.exe")
    Move-Item -LiteralPath $away -Destination $target

    # Nor is it put through a link, or into what is another user's.
    $aside = Join-Path $local "Programs-xless-test-$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::Move($programs, $aside)
    try {
        New-Item -ItemType Junction -Path $programs -Value $aside | Out-Null
        Assert-Refused 'a link for the directory of programs is refused' @{} 'Programs is a link'
        Assert-Refused 'also to take away' @{ XLESS_UNINSTALL = '1' } 'Programs is a link'
        [IO.Directory]::Delete($programs)
        [IO.File]::WriteAllText($programs, 'a file')
        Assert-Refused 'and a file' @{} 'is no directory'
        [IO.File]::Delete($programs)
        New-Item -ItemType Directory -Path $programs | Out-Null
        & "$env:SystemRoot\System32\icacls.exe" $programs /setowner '*S-1-5-32-546' /q | Out-Null   # the guests
        if ($LASTEXITCODE -ne 0) { throw 'cannot give a directory to the guests' }
        Assert-Refused 'and a directory of another user' @{} 'is another user.s \(S-1-5-32-546\)'
    } finally {
        if (Test-Path -LiteralPath $programs) { if ((Get-Item -LiteralPath $programs -Force) -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($programs) } else { [IO.File]::Delete($programs) } }
        [IO.Directory]::Move($aside, $programs)
    }

    # Taken away: the program and its PATH entry, and nothing else.
    $running = Start-Process -FilePath $exe -ArgumentList '-n', '600', '127.0.0.1' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $said = Invoke-Install @{ XLESS_UNINSTALL = '1' }
    Assert 'one that runs is taken away' ($said -match 'still running' -and $said -match 'exit 0' -and -not (Test-Path -LiteralPath $target)) $said
    $running.Kill()
    $running.WaitForExit()
    Assert 'from the PATH too' ((Get-UserPath) -ceq '%USERPROFILE%\xless-test;C:\another' -or (Get-UserPath) -ceq $mine) (Get-UserPath)
    $said = Invoke-Install @{ XLESS_UNINSTALL = '1' }
    Assert 'nothing to take away is no error' ($said -match 'there is no xless' -and $said -match 'exit 0' -and @(Get-Leftover).Count -eq 0) $said
    Assert 'the secret store is kept' ([IO.File]::ReadAllText((Join-Path $store 'test.txt')) -eq 'mine')

    # Without a PATH of the user's, and with one of another kind.
    $key.DeleteValue('Path')
    $said = Invoke-Install @{}
    Assert 'a user without a PATH gets one' ((Get-UserPath) -ceq $bin) $said
    $key.SetValue('Path', "C:\x;$($bin.ToUpperInvariant())\", 'String')
    $said = Invoke-Install @{}
    Assert 'one that has it keeps it as it is' ((Get-UserPath) -ceq "C:\x;$($bin.ToUpperInvariant())\" -and $key.GetValueKind('Path') -eq 'String') (Get-UserPath)
    $said = Invoke-Install @{ XLESS_UNINSTALL = '1' }
    Assert 'a PATH of plain text stays so' ((Get-UserPath) -ceq 'C:\x' -and $key.GetValueKind('Path') -eq 'String') (Get-UserPath)

    # A download that was cut, wherever, runs nothing.
    foreach ($part in 0.3, 0.6, 0.95) {
        $cut = $text.Substring(0, [int]($text.Length * $part))
        [IO.File]::WriteAllText((Join-Path $dir 'cut.ps1'), $cut)
        $said = & $shell -NoProfile -NonInteractive -Command "try { Invoke-Expression ([IO.File]::ReadAllText('$dir\cut.ps1')) } catch { 'cut' }" | Out-String
        Assert "a script that ends after $part of it does nothing" ($said.Trim() -eq 'cut' -and -not (Test-Path -LiteralPath $target)) $said
    }
    Assert 'it is plain ASCII, which irm and iex take as it is' ($text -cmatch '\A[\x09\x0a\x20-\x7e]+\z')
} finally {
    if ($running -and -not $running.HasExited) { $running.Kill(); $running.WaitForExit() }
    if ($had) { $key.SetValue('Path', $path, $kind) } else { $key.DeleteValue('Path', $false) }
    if (-not $hadStore) { Remove-Item -LiteralPath $store -Recurse -Force }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Remove-Item -LiteralPath $dir -Recurse -Force
}
Write-Host 'install: ok'
exit 0
