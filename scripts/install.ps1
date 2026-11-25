# Installs xless for Windows from a GitHub release (Windows PowerShell 5.1 or PowerShell 7), for the user who runs it:
#   irm https://github.com/fmsouza/xless/releases/latest/download/install.ps1 | iex
#   install.ps1 [-Version x.y.z] [-Uninstall]
# XLESS_VERSION         release to install, x.y.z or vx.y.z (default: the latest)
# XLESS_UNINSTALL=1     takes the program away again, and nothing else: your secret store stays
# XLESS_ALLOW_ELEVATED=1  goes on in an elevated terminal (a machine without another kind, such as a CI runner)
# XLESS_RELEASE_BASE    where releases live (default https://github.com/fmsouza/xless/releases)
# The program goes into %LOCALAPPDATA%\Programs\xless and onto the user's PATH. Needs no administrator, changes no policy, installs
# nothing else. The zip is checked against the release's SHA256SUMS before anything is replaced. x64; on ARM64 the x64 program runs
# under Windows 11's emulation.
param([string]$Version = '', [switch]$Uninstall)

function Install-Xless([string]$Version, [bool]$Uninstall) {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'install.ps1: this PowerShell may not run programs of its own (ConstrainedLanguage): use another, or unpack the zip of the release by hand' }
    Set-StrictMode -Version 2
    $ErrorActionPreference = 'Stop'
    $base = 'https://github.com/fmsouza/xless/releases'
    if ($env:XLESS_RELEASE_BASE) { $base = $env:XLESS_RELEASE_BASE.TrimEnd('/') }
    if (-not $Version) { $Version = "$env:XLESS_VERSION" }
    if ($env:XLESS_UNINSTALL -eq '1') { $Uninstall = $true }
    $largest = 512MB

    function Stop-Install([string]$why) { throw "install.ps1: $why" }

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Stop-Install 'this is for Windows; install.sh is for Linux and macOS' }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 17763) { Stop-Install "xless needs Windows 10 1809 or later (this is build $build)" }
    # A 32-bit PowerShell says x86, and the machine's in the other.
    $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $machine) { $machine = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    if ($machine -ne 'AMD64' -and $machine -ne 'ARM64') { Stop-Install "xless releases are for x64 Windows (this is $machine)" }
    if ($machine -eq 'ARM64' -and $build -lt 22000) { Stop-Install 'xless is an x64 program, which Windows on ARM runs from Windows 11 on' }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $env:XLESS_ALLOW_ELEVATED -ne '1') {
        Stop-Install ('this terminal is elevated ("as administrator"), and what it installs may be another user''s: use one that is not. ' +
            'Where there is no other (a CI runner), set XLESS_ALLOW_ELEVATED=1')
    }
    $sid = $identity.User.Value

    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ($local -notmatch '^[A-Za-z]:\\') { Stop-Install "your LocalAppData folder is not on a drive: '$local'" }
    $programs = Join-Path $local 'Programs'
    $target = Join-Path $programs 'xless'
    $bin = Join-Path $target 'bin'
    $system = [Environment]::GetFolderPath('System')

    # --- what is there ---

    function Test-Link([string]$path) { return ([int][IO.File]::GetAttributes($path) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 }

    # The files of a directory, by their names in it. Nothing is followed out of it.
    function Get-Files([string]$directory, [string]$below) {
        foreach ($path in [IO.Directory]::GetFileSystemEntries($directory)) {
            $name = $below + [IO.Path]::GetFileName($path)
            if (Test-Link $path) { Stop-Install "$path is a link, which no xless put there" }
            if ([IO.Directory]::Exists($path)) { Get-Files $path "$name\" } else { $name }
        }
    }

    # The directory of the user's programs: a directory of the user's (or, as everything of it, of SYSTEM or the administrators).
    function Test-Programs {
        if (-not (Test-Path -LiteralPath $programs)) { return }
        if (Test-Link $programs) { Stop-Install "$programs is a link, which xless does not install through: make it a directory, or unpack the zip of the release by hand" }
        if (-not [IO.Directory]::Exists($programs)) { Stop-Install "$programs is no directory" }
        $owner = (Get-Acl -LiteralPath $programs).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if (@($sid, 'S-1-5-18', 'S-1-5-32-544') -notcontains $owner) { Stop-Install "$programs is another user's ($owner)" }
    }

    function Test-Installed {
        Test-Programs
        if (-not (Test-Path -LiteralPath $target)) { return $false }
        if (Test-Link $target) { Stop-Install "$target is a link" }
        if (-not [IO.Directory]::Exists($target)) { Stop-Install "$target is no directory" }
        if (@([IO.Directory]::GetFileSystemEntries($target)).Count -eq 0) { return $true }
        if (-not [IO.File]::Exists((Join-Path $target 'share\xless\VERSION'))) { Stop-Install "$target is there and is no installed xless: move it away" }
        return $true
    }

    function Remove-Tree([string]$path) {
        try { [IO.Directory]::Delete($path, $true); return $true } catch { return $false }
    }

    # Only the user, SYSTEM and the administrators may open what is put below it, whatever the directory above says.
    function New-OwnDirectory([string]$path) {
        [void][IO.Directory]::CreateDirectory($path)
        & (Join-Path $system 'icacls.exe') $path /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /q | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Install "cannot set who may open $path" }
    }

    # As one rename, or, where a file of it is in use (which may be renamed, while its directory may not), file by file.
    function Move-Tree([string]$from, [string]$to) {
        if (-not (Test-Path -LiteralPath $to)) { try { [IO.Directory]::Move($from, $to); return } catch { Write-Verbose 'in use: file by file' } }
        $moved = New-Object 'System.Collections.Generic.List[string]'
        try {
            foreach ($name in @(Get-Files $from '')) {
                $there = Join-Path $to $name
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($there))
                [IO.File]::Move((Join-Path $from $name), $there)
                $moved.Add($name)
            }
        } catch {
            $why = $_
            foreach ($name in $moved) { [IO.File]::Move((Join-Path $to $name), (Join-Path $from $name)) }
            throw $why
        }
    }

    function Move-Program([string]$to) {
        try { Move-Tree $target $to } catch { Stop-Install "cannot replace ${target}: $($_.Exception.Message) End the xless that runs, and run this again." }
    }

    # What earlier runs could not delete, as a program of it was running, or as they were ended.
    function Remove-Leftover {
        if (-not [IO.Directory]::Exists($programs)) { return }
        foreach ($path in [IO.Directory]::GetDirectories($programs, '.xless-*')) {
            $name = [IO.Path]::GetFileName($path)
            $left = $name -match '^\.xless-old\.[0-9a-f]{32}$' -or ($name -match '^\.xless-new\.[0-9a-f]{32}$' -and [IO.Directory]::GetLastWriteTimeUtc($path) -lt [DateTime]::UtcNow.AddDays(-1))
            if ($left -and -not (Test-Link $path)) { [void](Remove-Tree $path) }
        }
    }

    # --- the user's PATH: in the registry, as it is written there (%VARIABLES% are kept) ---

    # $true: it was changed.
    function Set-UserPath([bool]$present) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
            $value = ''
            if (@($key.GetValueNames()) -contains 'Path') {
                $kind = $key.GetValueKind('Path')
                $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
            if (($kind -ne 'ExpandString' -and $kind -ne 'String') -or $bin -match '[;%"]') {
                Write-Host "Your PATH was left as it is: $(if ($present) { 'add' } else { 'take away' }) $bin"
                return $false
            }
            $all = @($value -split ';')
            $others = @($all | Where-Object { [Environment]::ExpandEnvironmentVariables($_).Trim().Trim('"').TrimEnd('\') -ne $bin })
            $is = $others.Count -ne $all.Count
            if ($is -eq $present) { return $false }
            if ($present) { $new = if ($value.Trim(';')) { $value.TrimEnd(';') + ';' + $bin } else { $bin } } else { $new = $others -join ';' }
            $key.SetValue('Path', $new, $kind)
        } finally { $key.Close() }
        # Tells the programs that are running, by taking away a variable that is not there.
        [Environment]::SetEnvironmentVariable('XLESS_INSTALL', $null, 'User')
        return $true
    }

    if ($Uninstall) {
        if (Test-Installed) {
            $old = Join-Path $programs ('.xless-old.' + [Guid]::NewGuid().ToString('N'))
            Move-Program $old
            if ([IO.Directory]::Exists($target)) { [void](Remove-Tree $target) }
            if (Remove-Tree $old) { Write-Host "xless is no longer in $target" }
            else { Write-Host "xless is no longer in $target; a program of it is still running: once it ended, delete $old" }
        } else { Write-Host "there is no xless in $target" }
        Remove-Leftover
        if (Set-UserPath $false) { Write-Host 'and no longer on your PATH' }
        Write-Host "Your secret store and settings were kept (xless's folder in $local, or where the XDG_ variables say): delete them yourself if you want to."
        return
    }

    # --- the release ---

    function Get-Response([string]$url) {
        for ($hop = 0; $hop -lt 8; $hop++) {
            $uri = New-Object Uri $url
            if ($uri.Scheme -cne 'https') { Stop-Install "$url is not https" }
            $request = [Net.WebRequest]::Create($uri)
            $request.AllowAutoRedirect = $false   # each is looked at
            $request.UserAgent = 'xless-install'
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 60000
            try { $response = $request.GetResponse() } catch {
                $inner = $_.Exception
                while ($inner -and $inner -isnot [Net.WebException]) { $inner = $inner.InnerException }
                if (-not $inner) { throw }
                if ($inner.Response) {
                    $status = [int]$inner.Response.StatusCode
                    $inner.Response.Close()
                    if ($status -eq 404) { Stop-Install "there is no $url (404): is there such a release, and has it a package for Windows?" }
                    Stop-Install "$($uri.Host) answered $status for $url"
                }
                Stop-Install "cannot get ${url}: $($inner.Message)"
            }
            if ([int]$response.StatusCode -lt 300) { return $response }
            $next = $response.Headers['Location']
            $response.Close()
            if (-not $next) { Stop-Install "$url redirects to nowhere" }
            $url = (New-Object Uri $uri, $next).AbsoluteUri
        }
        Stop-Install 'too many redirects'
    }

    function Save-Asset([string]$url, [string]$path) {
        if ($url -match '^file://') { [IO.File]::Copy((New-Object Uri $url).LocalPath, $path); return }
        $response = Get-Response $url
        try {
            $from = $response.GetResponseStream()
            $to = New-Object IO.FileStream $path, 'CreateNew', 'Write', 'None'
            try { Copy-Limited $from $to $largest } finally { $to.Close() }
        } finally { $response.Close() }
    }

    function Copy-Limited($from, $to, [long]$most) {
        $buffer = New-Object byte[] 131072
        $all = 0L
        while (($n = $from.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $all += $n
            if ($all -gt $most) { Stop-Install 'a file of the release is too large' }
            $to.Write($buffer, 0, $n)
        }
    }

    # The lines of SHA256SUMS: name -> sum.
    function Get-Sum([string]$url, [string]$path) {
        Save-Asset $url $path
        $sums = @{}
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line -cmatch '^([0-9a-f]{64}) [ *]([A-Za-z0-9._+-]+)$') { $sums[$Matches[2]] = $Matches[1] }
        }
        [IO.File]::Delete($path)
        return $sums
    }

    # The entries of a zip whose names were looked at, below the directory.
    function Expand-Package($stream, [string]$top, [string]$directory) {
        Add-Type -AssemblyName System.IO.Compression
        $archive = New-Object IO.Compression.ZipArchive $stream, ([IO.Compression.ZipArchiveMode]::Read)
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $left = $largest
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ($name -cnotmatch "^$([regex]::Escape($top))/(([A-Za-z0-9_+-][A-Za-z0-9._+-]*/)*[A-Za-z0-9_+-][A-Za-z0-9._+-]*)`$" -or $name -match '\.(/|$)' -or -not $seen.Add($name)) {
                Stop-Install "the zip has an entry that no release has: '$name'"
            }
            $path = Join-Path $directory $Matches[1].Replace('/', '\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            $from = $entry.Open()
            $to = New-Object IO.FileStream $path, 'CreateNew', 'Write', 'None'
            try { Copy-Limited $from $to $left; $left -= $to.Length } finally { $to.Close(); $from.Close() }
        }
        foreach ($name in 'bin\xless.exe', 'share\xless\VERSION') {
            if (-not [IO.File]::Exists((Join-Path $directory $name))) { Stop-Install "the zip has no $name" }
        }
    }

    # What xless needs of System32 and Windows may not have, before anything is touched. Not on ARM64, where the files that are there do not
    # say whether an x64 program has them.
    $redistributable = 'winget install Microsoft.VCRedist.2015+.x64'
    if ($machine -ne 'ARM64') {
        # The real System32, for a 32-bit PowerShell too.
        $real = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { Join-Path ([Environment]::GetFolderPath('Windows')) 'Sysnative' } else { $system }
        $missing = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll' | Where-Object { -not [IO.File]::Exists((Join-Path $real $_)) })
        if ($missing.Count -gt 0) {
            Stop-Install ("xless needs the Visual C++ runtime of Microsoft, and this Windows lacks $($missing -join ', '); nothing was installed. " +
                "Install the runtime ($redistributable; or https://aka.ms/vs/17/release/vc_redist.x64.exe), then run this again.")
        }
    }

    $there = Test-Installed
    $Version = $Version -replace '^v', ''
    if ($Version -eq 'latest') { $Version = '' }
    if ($Version -and $Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?\z') { Stop-Install "'$Version' is no version (x.y.z)" }
    if ($base -notmatch '^(https|file)://') { Stop-Install "$base is not https" }

    [void][IO.Directory]::CreateDirectory($programs)
    Remove-Leftover
    $stage = Join-Path $programs ('.xless-new.' + [Guid]::NewGuid().ToString('N'))
    # TLS 1.2, which an old Windows PowerShell does not do by itself, and certificates as Windows sees them, for this run.
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    $callback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        New-OwnDirectory $stage
        $list = Join-Path $stage 'SHA256SUMS'
        if (-not $Version) {
            $names = @((Get-Sum "$base/latest/download/SHA256SUMS" $list).Keys | Where-Object { $_ -match '^xless-\d+\.\d+\.\d+[0-9A-Za-z.-]*-windows-x86_64\.zip$' })
            if ($names.Count -ne 1) { Stop-Install 'the latest release has no package for Windows' }
            # From here on that release: one that is published meanwhile must not mix its files with this one's checksums.
            $Version = $names[0] -replace '^xless-', '' -replace '-windows-x86_64\.zip$', ''
        }
        $top = "xless-$Version-windows-x86_64"
        $sums = Get-Sum "$base/download/v$Version/SHA256SUMS" $list
        if (-not $sums.ContainsKey("$top.zip")) { Stop-Install "SHA256SUMS does not list $top.zip" }
        Write-Host "downloading $top.zip"
        $zip = Join-Path $stage 'package.zip'
        Save-Asset "$base/download/v$Version/$top.zip" $zip
        $new = Join-Path $stage 'xless'
        New-OwnDirectory $new
        # What was checked is what is unpacked: nobody may write it meanwhile.
        $stream = New-Object IO.FileStream $zip, 'Open', 'Read', 'Read'
        try {
            $hash = [Security.Cryptography.SHA256]::Create()
            $sum = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
            if ($sum -cne $sums["$top.zip"]) { Stop-Install "sha256 mismatch for $top.zip (got $sum, want $($sums["$top.zip"])); nothing was installed" }
            $stream.Position = 0
            Expand-Package $stream $top $new
        } finally { $stream.Close() }

        $old = Join-Path $programs ('.xless-old.' + [Guid]::NewGuid().ToString('N'))
        if ($there) { Move-Program $old }
        try { Move-Tree $new $target } catch {
            $why = $_
            if ($there) { Move-Tree $old $target }
            throw $why
        }
        if ($there) { [void](Remove-Tree $old) }
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $protocol
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $callback
        if ([IO.Directory]::Exists($stage)) { [void](Remove-Tree $stage) }
    }
    Write-Host "xless $Version installed to $(Join-Path $bin 'xless.exe')"

    if (Set-UserPath $true) { Write-Host 'It is on your PATH in terminals that you open from now on.' }
    if (@($env:Path -split ';') -notcontains $bin) { $env:Path = $env:Path.TrimEnd(';') + ';' + $bin }

    if ($machine -eq 'ARM64') {
        Write-Host 'This is the x64 program, under emulation. It needs the x64 Visual C++ runtime of Microsoft; if you have not got that:'
        Write-Host "  $redistributable"
    }
    Write-Host 'next: the account commands (xless auth login, xless secrets init, xless provision, xless store, ...).'
    Write-Host 'Builds run inside WSL2 (install xless for Linux there) or on a Mac or Linux.'
}

# Nothing runs until here, so a download that was cut runs nothing.
Install-Xless $Version $Uninstall.IsPresent
