# What xless takes for a secure connection: a certificate of an authority that Windows trusts, of that name and time, with TLS 1.2 or later;
# anything else ends it before a request is sent. The same for what scripts/install.ps1 downloads from. Puts an authority of its own among those that this machine trusts, and takes it away again:
# only on a machine that is thrown away. Windows only, as an administrator.
#   pwsh Tests/windows/https.test.ps1 <XlessWindowsProbe.exe>
param([Parameter(Mandatory = $true)][string]$Probe)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$PSNativeCommandUseErrorActionPreference = $false

$probe = (Resolve-Path $Probe).Path
$failures = 0

function Fail([string]$why) {
    Write-Host "FAIL: $why"
    $script:failures++
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

public sealed class XlessTestServer {
    public int Port;
    public int Requests;
    public int ClientCertificates;
    public string Protocol = "";
    public string Reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);

    public XlessTestServer(X509Certificate2 certificate, SslProtocols protocols, bool ask) {
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var thread = new Thread(() => {
            while (true) {
                TcpClient client;
                try { client = listener.AcceptTcpClient(); } catch { return; }
                try {
                    using (client)
                    using (var tls = new SslStream(client.GetStream(), false, (s, c, chain, e) => true)) {
                        tls.AuthenticateAsServer(certificate, ask, protocols, false);
                        Protocol = tls.SslProtocol.ToString();
                        var buffer = new byte[4096];
                        int n = tls.Read(buffer, 0, buffer.Length);
                        if (n <= 0) continue;
                        Interlocked.Increment(ref Requests);
                        if (tls.RemoteCertificate != null) Interlocked.Increment(ref ClientCertificates);
                        var reply = Encoding.ASCII.GetBytes(Reply);
                        tls.Write(reply, 0, reply.Length);
                        tls.Flush();
                    }
                } catch (Exception) { }
            }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    public void Stop() { listener.Stop(); }

    // Whether a client that takes anything gets a connection with these protocols.
    public bool Reachable(SslProtocols protocols) {
        try {
            using (var client = new TcpClient("127.0.0.1", Port))
            using (var tls = new SslStream(client.GetStream(), false, (s, c, chain, e) => true)) {
                tls.AuthenticateAsClient("localhost", null, protocols, false);
                return true;
            }
        } catch (Exception) { return false; }
    }
}
'@

$x509 = 'System.Security.Cryptography.X509Certificates'
$hash = [Security.Cryptography.HashAlgorithmName]::SHA256
$padding = [Security.Cryptography.RSASignaturePadding]::Pkcs1

function Usable($certificate) {
    New-Object "$x509.X509Certificate2" -ArgumentList $certificate.Export('Pfx', 'x'), 'x', ([Security.Cryptography.X509Certificates.X509KeyStorageFlags]'Exportable, UserKeySet')
}

# A certificate for `$name`, of `$issuer` ($null: its own).
function New-Certificate([string]$name, $issuer, [int]$from, [int]$to, [bool]$authority) {
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = New-Object "$x509.CertificateRequest" -ArgumentList "CN=$name", $key, $hash, $padding
    $request.CertificateExtensions.Add((New-Object "$x509.X509BasicConstraintsExtension" -ArgumentList $authority, $false, 0, $true))
    if (-not $authority) {
        $names = New-Object "$x509.SubjectAlternativeNameBuilder"
        $names.AddDnsName($name)
        $request.CertificateExtensions.Add($names.Build())
        $uses = New-Object Security.Cryptography.OidCollection
        $uses.Add((New-Object Security.Cryptography.Oid -ArgumentList '1.3.6.1.5.5.7.3.1')) | Out-Null
        $request.CertificateExtensions.Add((New-Object "$x509.X509EnhancedKeyUsageExtension" -ArgumentList $uses, $false))
    }
    $now = [DateTimeOffset]::UtcNow
    if (-not $issuer) { return Usable ($request.CreateSelfSigned($now.AddDays($from), $now.AddDays($to))) }
    $serial = [Guid]::NewGuid().ToByteArray()
    $serial[0] = $serial[0] -band 0x7f
    $signed = $request.Create($issuer, $now.AddDays($from), $now.AddDays($to), $serial)
    Usable ([Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($signed, $key))
}

$tls12 = [Security.Authentication.SslProtocols]::Tls12
$authority = New-Certificate "xless test authority $([Guid]::NewGuid())" $null -30 30 $true
$root = New-Object "$x509.X509Store" -ArgumentList 'Root', 'LocalMachine'
$root.Open('ReadWrite')
$public = New-Object "$x509.X509Certificate2" -ArgumentList (, $authority.Export('Cert'))
$root.Add($public)
try {
    # what it is, its certificate, the server's protocols, whether it asks for the client's certificate, what is expected
    $good = New-Certificate 'localhost' $authority -1 20 $false
    $cases = @(
        @('a trusted certificate', $good, $tls12, $false, '^status 200$'),
        @('a trusted certificate, TLS 1.3', $good, [Security.Authentication.SslProtocols]::Tls13, $false, '^status 200$'),
        @('a server that asks for a certificate', $good, $tls12, $true, '^status 200$'),
        @('a self-signed certificate', (New-Certificate 'localhost' $null -1 20 $false), $tls12, $false, '^error -120[0-9] .*not from an authority that Windows trusts'),
        @('another name', (New-Certificate 'other.example' $authority -1 20 $false), $tls12, $false, '^error -120[0-9] .*another name'),
        @('an expired certificate', (New-Certificate 'localhost' $authority -20 -2 $false), $tls12, $false, '^error -120[0-9] .*expired'),
        @('a certificate that is not yet valid', (New-Certificate 'localhost' $authority 5 20 $false), $tls12, $false, '^error -120[0-9] .*expired, or is not yet valid')
    )
    foreach ($case in $cases) {
        $what, $certificate, $protocols, $ask, $expected = $case
        $server = New-Object XlessTestServer -ArgumentList $certificate, $protocols, $ask
        try {
            if (-not $server.Reachable($protocols)) {
                # Not to be served by this Windows at all (TLS 1.3 on an old one): nothing to tell.
                Write-Host "$what`: cannot be tried here"
                if ($protocols -eq $tls12) { Fail "$what`: the test server does not work" }
                continue
            }
            $said = & $probe get "https://localhost:$($server.Port)/secret"
            Write-Host "$what`: $said ($($server.Protocol))"
            if ($said -notmatch $expected) { Fail "$what`: $said" }
            $requests = if ($expected -match 'status') { 1 } else { 0 }
            if ($server.Requests -ne $requests) { Fail "$what`: $($server.Requests) requests were sent" }
            if ($server.ClientCertificates -ne 0) { Fail "$what`: a certificate of the user's was sent" }
        } finally {
            $server.Stop()
        }
    }

    # TLS 1.1 is no secure connection, of a server that speaks nothing else (OpenSSL's, of Git for Windows: Windows' own does not here). The same
    # server with TLS 1.2 is taken, and a client that takes TLS 1.1 gets it.
    $openssl = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Git\*\bin\openssl.exe') | Where-Object { $_.FullName -notmatch '\\usr\\' } | Select-Object -First 1)
    if ($openssl.Count -ne 1) { throw 'no OpenSSL of Git for Windows' }
    $openssl = $openssl[0].FullName
    $pem = Join-Path ([IO.Path]::GetTempPath()) "xless-tls-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $pem | Out-Null
    $key = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($good)
    [IO.File]::WriteAllText("$pem\cert.pem", $good.ExportCertificatePem())
    [IO.File]::WriteAllText("$pem\key.pem", $key.ExportRSAPrivateKeyPem())
    [IO.File]::WriteAllText("$pem\none", '')
    foreach ($case in @('tls1_2', '^status 200$'), @('tls1_1', '^error -\d+ .*no secure connection')) {
        $protocol, $expected = $case
        $free = New-Object Net.Sockets.TcpListener -ArgumentList ([Net.IPAddress]::Loopback), 0
        $free.Start()
        $port = $free.LocalEndpoint.Port
        $free.Stop()
        $arguments = 's_server', '-accept', "127.0.0.1:$port", '-cert', "$pem\cert.pem", '-key', "$pem\key.pem", "-$protocol", '-cipher', 'ALL:@SECLEVEL=0', '-www'
        $server = Start-Process -FilePath $openssl -ArgumentList $arguments -NoNewWindow -PassThru -RedirectStandardInput "$pem\none" -RedirectStandardOutput "$pem\$protocol.out" -RedirectStandardError "$pem\$protocol.err"
        try {
            $spoken = ''
            foreach ($i in 1..50) {
                $spoken = Get-Content "$pem\none" | & $openssl s_client -connect "127.0.0.1:$port" "-$protocol" -cipher 'ALL:@SECLEVEL=0' 2>&1 | Out-String
                if ($spoken -match 'Cipher is [A-Z0-9-]+') { break }
                Start-Sleep -Milliseconds 200
            }
            if ($spoken -notmatch 'New, TLSv1[.0-9]*, Cipher is (?!\(NONE)' ) { Fail "${protocol}: the test server does not work: $spoken $(Get-Content -Raw "$pem\$protocol.err")" }
            $said = & $probe get "https://localhost:$port/"
            Write-Host "${protocol}: $said"
            if ($said -notmatch $expected) { Fail "${protocol}: $said" }
            if ($server.HasExited) { Fail "${protocol}: the test server ended" }
        } finally {
            if (-not $server.HasExited) { $server.Kill() }
            $server.WaitForExit()
        }
    }
    Remove-Item -LiteralPath $pem -Recurse -Force

    # The installer: from a trusted server only, and through no redirect to something else than https.
    $env:XLESS_ALLOW_ELEVATED = '1'
    $env:XLESS_VERSION = '1.2.3'
    $installer = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\install.ps1'
    $plain = New-Object Net.Sockets.TcpListener -ArgumentList ([Net.IPAddress]::Loopback), 0
    $plain.Start()
    $away = "HTTP/1.1 302 Found`r`nLocation: http://localhost:$($plain.LocalEndpoint.Port)/x`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
    $installs = @(
        @('a trusted server', $good, "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n", 1, 'install.ps1: there is no https://localhost:\d+/download/v1\.2\.3/SHA256SUMS \(404\)'),
        @('a server that fails', $good, "HTTP/1.1 503 Service Unavailable`r`nContent-Length: 0`r`nConnection: close`r`n`r`n", 1, 'install.ps1: localhost answered 503'),
        @('a self-signed certificate', (New-Certificate 'localhost' $null -1 20 $false), $away, 0, 'install.ps1: cannot get https.*(SSL|TLS|trust)'),
        @('another name', (New-Certificate 'other.example' $authority -1 20 $false), $away, 0, 'install.ps1: cannot get https.*(SSL|TLS|trust)'),
        @('a redirect to http', $good, $away, 1, 'is not https')
    )
    foreach ($case in $installs) {
        $what, $certificate, $reply, $requests, $expected = $case
        foreach ($shell in 'powershell.exe', 'pwsh.exe') {
            $server = New-Object XlessTestServer -ArgumentList $certificate, $tls12, $false
            try {
                $server.Reply = $reply
                $env:XLESS_RELEASE_BASE = "https://localhost:$($server.Port)"
                # A callback of the session's that takes anything is not asked.
                $said = & $shell -NoProfile -NonInteractive -Command "[Net.ServicePointManager]::ServerCertificateValidationCallback = { `$true }; Invoke-Expression ([IO.File]::ReadAllText('$installer'))" 2>&1 | Out-String
                $code = $LASTEXITCODE
                Write-Host "install.ps1 with $shell, ${what}: exit $code, $($server.Requests) requests: $(($said -replace '\s+', ' ').Trim())"
                if ($code -eq 0 -or ($said -replace '[\s|]+', '') -notmatch $expected.Replace(' ', '')) { Fail "install.ps1 with $shell, $what" }
                if ($server.Requests -ne $requests) { Fail "install.ps1 with $shell, ${what}: $($server.Requests) requests were sent" }
            } finally {
                $server.Stop()
            }
        }
    }
    if ($plain.Pending()) { Fail 'install.ps1 went to a server without TLS' }
    $plain.Stop()
} finally {
    $root.Remove($public)
    $root.Close()
}
if ($failures -gt 0) { exit 1 }
Write-Host 'ok'
exit 0
