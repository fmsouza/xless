# The installed xless, as it is released, in a console (a pseudoconsole that is made here): it makes a secret store, opens it with the
# passphrase and not with another, shows nothing of it, and says where builds run. It takes no library from anywhere but its own directory
# and System32. Makes the user's real store: only on a machine that is thrown away. Windows only, PowerShell 7.
#   pwsh Tests/windows/installed.test.ps1 <xless.exe>
param([Parameter(Mandatory = $true)][string]$Xless)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$xless = (Resolve-Path $Xless).Path
$env:PATH = Join-Path $env:SystemRoot 'System32'   # no toolchain's

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class XlessConsole {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Startup {
        public int cb; public string reserved, desktop, title; public int x, y, xSize, ySize, xChars, yChars, fill, flags;
        public short show, reserved2; public IntPtr reserved3, input, output, error, attributes;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Information { public IntPtr process, thread; public int pid, tid; }
    [DllImport("kernel32", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, IntPtr security, int size);
    [DllImport("kernel32")] static extern int CreatePseudoConsole(int size, SafeFileHandle input, SafeFileHandle output, int flags, out IntPtr console);
    [DllImport("kernel32")] static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, int flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string application, StringBuilder line, IntPtr process, IntPtr thread, bool inherit, int flags, IntPtr environment, string directory, ref Startup startup, out Information information);
    [DllImport("kernel32", SetLastError = true)] static extern int WaitForSingleObject(IntPtr handle, int milliseconds);
    [DllImport("kernel32", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out int code);
    [DllImport("kernel32", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, int code);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32")] static extern int SetErrorMode(int mode);

    // What cannot be started says so to whoever started it, and to nobody else (in a window).
    public static void NoWindows() { SetErrorMode(0x8003); }

    readonly IntPtr console, process;
    readonly FileStream input;
    readonly StringBuilder all = new StringBuilder();

    public XlessConsole(string line) {
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new Win32Exception();
        int result = CreatePseudoConsole(120 | 40 << 16, inRead, outWrite, 0, out console);
        if (result != 0) throw new Win32Exception(result);
        var size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        var startup = new Startup { cb = Marshal.SizeOf(typeof(Startup)), flags = 0x100, input = new IntPtr(-1), output = new IntPtr(-1), error = new IntPtr(-1), attributes = Marshal.AllocHGlobal(size) };
        if (!InitializeProcThreadAttributeList(startup.attributes, 1, 0, ref size)) throw new Win32Exception();
        if (!UpdateProcThreadAttribute(startup.attributes, 0, new IntPtr(0x20016), console, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception();
        Information information;
        if (!CreateProcessW(null, new StringBuilder(line), IntPtr.Zero, IntPtr.Zero, false, 0x80000, IntPtr.Zero, null, ref startup, out information)) throw new Win32Exception();
        process = information.process;
        CloseHandle(information.thread);
        inRead.Dispose();
        outWrite.Dispose();
        input = new FileStream(inWrite, FileAccess.Write);
        var output = new FileStream(outRead, FileAccess.Read);
        var thread = new Thread(() => {
            var buffer = new byte[4096];
            try {
                int n;
                while ((n = output.Read(buffer, 0, buffer.Length)) > 0) lock (all) all.Append(Encoding.UTF8.GetString(buffer, 0, n));
            } catch (Exception) { }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    [DllImport("kernel32", SetLastError = true)] static extern bool SetHandleInformation(SafeFileHandle handle, int mask, int flags);

    // Its exit code with a standard output and error that nobody reads any more.
    public static int Unread(string line) {
        SafeFileHandle read, write;
        if (!CreatePipe(out read, out write, IntPtr.Zero, 0) || !SetHandleInformation(write, 1, 1)) throw new Win32Exception();
        read.Dispose();
        var startup = new Startup { cb = Marshal.SizeOf(typeof(Startup)) - IntPtr.Size, flags = 0x100, output = write.DangerousGetHandle(), error = write.DangerousGetHandle() };
        Information information;
        if (!CreateProcessW(null, new StringBuilder(line), IntPtr.Zero, IntPtr.Zero, true, 0x08000000, IntPtr.Zero, null, ref startup, out information)) throw new Win32Exception();
        write.Dispose();
        int code = -1;
        if (WaitForSingleObject(information.process, 60000) == 0) GetExitCodeProcess(information.process, out code); else TerminateProcess(information.process, 1);
        CloseHandle(information.thread);
        CloseHandle(information.process);
        return code;
    }

    public string Shown { get {
        lock (all) return Regex.Replace(Regex.Replace(all.ToString(), "\x1b\\[[0-9]*C", " "), "\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07]*\x07", "");
    } }

    // Until it is shown so many times.
    public bool WaitFor(string text, int times, int seconds) {
        for (int i = 0; i < seconds * 10; i++) { if (Regex.Matches(Shown, Regex.Escape(text)).Count >= times) return true; Thread.Sleep(100); }
        return false;
    }

    public void Type(string text) { var bytes = Encoding.UTF8.GetBytes(text); input.Write(bytes, 0, bytes.Length); input.Flush(); }

    public int Finish(int seconds) {
        int code = -1;
        if (WaitForSingleObject(process, seconds * 1000) == 0) GetExitCodeProcess(process, out code); else TerminateProcess(process, 1);
        Thread.Sleep(500);
        ClosePseudoConsole(console);
        CloseHandle(process);
        return code;
    }
}
'@
[XlessConsole]::NoWindows()

function Assert([string]$what, [bool]$holds, [string]$more = '') {
    if (-not $holds) { throw "FAIL: $what $more" }
    Write-Host "ok: $what"
}

# Runs xless in a console and answers what it asks: (what it asks, the answer) pairs. Its exit code and what was shown.
function Invoke-Asked([string]$arguments, [string[][]]$answers) {
    $console = New-Object XlessConsole "`"$xless`" $arguments"
    $at = $true
    $times = @{}
    foreach ($pair in $answers) {
        $times[$pair[0]] = 1 + $times[$pair[0]]
        if (-not $console.WaitFor($pair[0], $times[$pair[0]], 60)) { $at = $false; break }
        Start-Sleep -Milliseconds 300
        $console.Type($pair[1] + "`r")
    }
    [int]$seconds = if ($at) { 60 } else { 1 }
    [int]$code = $console.Finish($seconds)
    return @{ code = $code; shown = $console.Shown; asked = $at }
}

$passphrase = 'made-up words of a test'
$vault = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'xless\vault'
Assert 'there is no store yet' (-not (Test-Path -LiteralPath $vault)) $vault

$said = & $xless build 2>&1 | Out-String
$refusal = $LASTEXITCODE
Assert 'builds are said to run in WSL2' ($refusal -ne 0 -and $said -match 'WSL') "$refusal $said"
& "$env:SystemRoot\System32\cmd.exe" /d /c "`"`"$xless`" build >NUL 2>NUL`""
Assert 'also where nothing is shown' ($LASTEXITCODE -eq $refusal) "$LASTEXITCODE"

$made = Invoke-Asked 'secrets init' @(@('New secret store passphrase: ', $passphrase), @('Type it again: ', $passphrase))
Assert 'a store is made' ($made.code -eq 0) "$($made.code) $($made.shown)"
Assert 'the passphrase is not shown' (-not $made.shown.Contains('made-up') -and -not $made.shown.Contains($passphrase)) $made.shown
$files = @(Get-ChildItem -LiteralPath $vault -Recurse -Force -File)
Assert 'it is in files' ($files.Count -gt 0) $vault
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($path in @($vault) + @($files | ForEach-Object FullName)) {
    $acl = Get-Acl -LiteralPath $path
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    Assert "$path is the user's only" ($acl.AreAccessRulesProtected -and "$sids" -eq $me -and $owner -eq $me) "$owner $sids"
}
foreach ($file in $files) {
    $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
    Assert "$($file.Name) has no passphrase in it" (-not $text.Contains($passphrase))
}

# A secret goes into the store, its file goes away, and it comes out for that passphrase only.
$value = 'a made-up value of a test'
$ask = 'Secret store passphrase: '
$given = Join-Path ([IO.Path]::GetTempPath()) "xless-given-$([Guid]::NewGuid().ToString('N'))"
$taken = "$given.out"
[IO.File]::WriteAllText($given, $value)
$imported = Invoke-Asked "secrets import MADE_UP --kind generic --file `"$given`"" @(@($ask, $passphrase), @('Delete', 'y'))
Assert 'a secret is imported' ($imported.code -eq 0 -and $imported.asked) "$($imported.code) $($imported.shown)"
Assert 'its file is deleted' (-not (Test-Path -LiteralPath $given)) $imported.shown
Assert 'neither it nor the passphrase is shown' (-not $imported.shown.Contains('made-up v') -and -not $imported.shown.Contains('made-up w')) $imported.shown
foreach ($file in Get-ChildItem -LiteralPath $vault -Recurse -Force -File) {
    $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
    Assert "$($file.Name) has neither in it" (-not $text.Contains($passphrase) -and -not $text.Contains($value))
    $acl = Get-Acl -LiteralPath $file.FullName
    Assert "$($file.Name) is still the user's only" ($acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $me -and @($acl.Access).Count -eq 1)
}
$refused = Invoke-Asked "secrets export MADE_UP --out `"$taken`"" @(@($ask, 'another passphrase'), @($ask, 'another passphrase'), @($ask, 'another passphrase'))
Assert 'not with another passphrase' ($refused.asked -and $refused.code -notin 0, -1 -and -not $refused.shown.Contains('another p') -and -not (Test-Path -LiteralPath $taken)) "$($refused.code) $($refused.shown)"
$exported = Invoke-Asked "secrets export MADE_UP --out `"$taken`"" @(, @($ask, $passphrase))
Assert 'with the passphrase it is exported' ($exported.code -eq 0 -and [IO.File]::ReadAllText($taken) -eq $value) "$($exported.code) $($exported.shown)"
$acl = Get-Acl -LiteralPath $taken
Assert 'to a file that is the user''s only' ($acl.AreAccessRulesProtected -and "$($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })" -eq $me) $acl.Sddl
Remove-Item -LiteralPath $taken
$listed = & $xless secrets list 2>&1 | Out-String
Assert 'it is listed, without its value' ($LASTEXITCODE -eq 0 -and $listed.Contains('MADE_UP') -and -not $listed.Contains($value)) $listed
# Where there is no console to ask on, it says so: nothing is read from standard input.
$said = $passphrase | & $xless secrets export MADE_UP --out $taken --no-input 2>&1 | Out-String
Assert 'a passphrase is not read from standard input' ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $taken)) "$LASTEXITCODE $said"

# Whose output nobody reads any more ends as any program does, without a fault.
foreach ($arguments in 'build', 'secrets list') {
    $code = [XlessConsole]::Unread("`"$xless`" $arguments")
    Assert "xless $arguments ends when nobody reads what it says" ($code -eq 1) "$code"
}

# Its libraries are its own directory's and System32's, whatever is on PATH and in the current directory: those that xless.exe asks for,
# those that only its libraries ask for, and the Visual C++ runtime of System32.
$bin = Split-Path -Parent $xless
function Assert-NotTaken([string]$name, [string]$from, [string]$aside) {
    $elsewhere = Join-Path ([IO.Path]::GetTempPath()) "xless-elsewhere-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $elsewhere | Out-Null
    Copy-Item -LiteralPath (Join-Path $from $name) -Destination $elsewhere
    $here = [Environment]::CurrentDirectory
    $path = $env:PATH
    [IO.File]::Move((Join-Path $from $name), $aside)
    try {
        [Environment]::CurrentDirectory = $elsewhere
        $env:PATH = "$elsewhere;$path"
        $console = New-Object XlessConsole "`"$xless`" --version"
        [int]$code = $console.Finish(60)
    } finally {
        [Environment]::CurrentDirectory = $here
        $env:PATH = $path
        [IO.File]::Move($aside, (Join-Path $from $name))
        Remove-Item -LiteralPath $elsewhere -Recurse
    }
    Assert "$name on PATH and in the current directory is not taken" ($code -eq -1073741515) "$code $($console.Shown)"
}
foreach ($name in 'swiftCore.dll', '_FoundationICU.dll', 'swiftCRT.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $bin $name))) { continue }
    Assert-NotTaken $name $bin (Join-Path $bin 'aside.tmp')
}
$system = [Environment]::GetFolderPath('System')
foreach ($name in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll') {
    $aside = Join-Path $system 'xless-test-aside.tmp'
    try {
        [IO.File]::Move((Join-Path $system $name), $aside)
        [IO.File]::Move($aside, (Join-Path $system $name))
    } catch {
        Write-Host "$name of System32 cannot be moved by this user: not tried"
        continue
    }
    Assert-NotTaken $name $system $aside
}
$said = & $xless --version
Assert 'with it it starts' ($LASTEXITCODE -eq 0) "$said"
Write-Host 'installed: ok'
exit 0
