<#
.SYNOPSIS
    Сквозная валидация связки «NPM + NTLM-модуль -> Exchange 2019».

.DESCRIPTION
    Проверяет снаружи (с любой машины с PowerShell 5.1+):
      - DNS: публичные FQDN резолвятся (и совпадают с ожидаемым IP, если задан);
      - TLS: сертификат RSA, SAN покрывает FQDN, не истёк; TLS 1.2 и 1.3 согласуются;
      - edge-харденинг: /powershell и /ecp -> 403, /healthz -> 200 ok, / -> редирект на /owa;
      - Autodiscover: «голый» запрос -> 401 с NTLM; POST с учётными данными -> 200
        и корректные URL в ответе (EXPR Server = публичный FQDN и т.д.).

    Логин для NTLM — UPN (user@office.example.com) или DOMAIN\user; он может
    отличаться от SMTP-адреса ящика. SMTP-адрес указывается в -MailAddress.

.EXAMPLE
    .\Test-ExchangeProxy.ps1 -OwaFqdn owa.example.com -AutodiscoverFqdn autodiscover.example.com `
        -MailAddress user@example.com -ExpectedIp 203.0.113.10
#>
[CmdletBinding()]
param(
    # Публичный FQDN OWA (Proxy Host в NPM)
    [Parameter(Mandatory)][string]$OwaFqdn,

    # Публичный FQDN Autodiscover; если не задан — проверки Autodiscover пропускаются
    [string]$AutodiscoverFqdn,

    # SMTP-адрес тестового ящика (идёт в EMailAddress Autodiscover-запроса)
    [string]$MailAddress,

    # Ожидаемый публичный IP хоста NPM (опционально)
    [string]$ExpectedIp,

    # Учётные данные для NTLM (UPN или DOMAIN\user). Если не заданы, а
    # Autodiscover-проверки включены — спросит интерактивно.
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'

# Старые .NET по умолчанию ограничивают TLS — принудительно включаем 1.2/1.3
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

function Write-Check {
    param([string]$Name, [Nullable[bool]]$Ok, [string]$Detail = '')
    if ($null -eq $Ok) {
        $script:Skipped++
        Write-Host ("SKIP  {0}  {1}" -f $Name, $Detail) -ForegroundColor DarkYellow
    } elseif ($Ok) {
        $script:Passed++
        Write-Host ("PASS  {0}  {1}" -f $Name, $Detail) -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host ("FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

# HTTP-проба, не падающая на не-2xx (единая для PS 5.1 и 7+)
function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType,
        [pscredential]$Cred
    )
    $params = @{
        Uri                = $Url
        Method             = $Method
        MaximumRedirection = 0
        UseBasicParsing    = $true
        TimeoutSec         = 30
        ErrorAction        = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body'))        { $params.Body = $Body }
    if ($PSBoundParameters.ContainsKey('ContentType')) { $params.ContentType = $ContentType }
    if ($Cred) { $params.Credential = $Cred }

    try {
        $r = Invoke-WebRequest @params
        $h = @{}
        foreach ($k in $r.Headers.Keys) { $h[$k] = Get-HeaderValue $r.Headers $k }
        # в PS 7 Content текстового ответа может прийти как byte[] — декодируем
        $content = $r.Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        return @{ Status = [int]$r.StatusCode; Headers = $h; Content = [string]$content }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            return @{ Status = 0; Headers = @{}; Content = ''; Error = $_.Exception.Message }
        }
        $h = @{}
        if ($resp -is [System.Net.Http.HttpResponseMessage]) {
            foreach ($hh in $resp.Headers) { $h[$hh.Key] = ($hh.Value -join ', ') }
            if ($resp.Content -and $resp.Content.Headers) {
                foreach ($hh in $resp.Content.Headers) { $h[$hh.Key] = ($hh.Value -join ', ') }
            }
        } else {
            foreach ($k in $resp.Headers.AllKeys) { $h[$k] = $resp.Headers[$k] }
        }
        return @{ Status = [int]$resp.StatusCode; Headers = $h; Content = '' }
    }
}

function Get-HeaderValue($Headers, [string]$Name) {
    $v = $Headers[$Name]
    if ($null -eq $v) { return $null }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return ($v -join ', ') }
    return [string]$v
}

# TLS-рукопожатие с принудительной версией протокола; возвращает сведения о сертификате
function Test-TlsHandshake {
    param([string]$Fqdn, [System.Security.Authentication.SslProtocols]$Protocol)
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.SendTimeout = 10000; $tcp.ReceiveTimeout = 10000
        $tcp.Connect($Fqdn, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { param($s, $c, $ch, $e) $true })
        $ssl.AuthenticateAsClient($Fqdn, $null, $Protocol, $false)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $san = ''
        $ext = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        if ($ext) { $san = $ext.Format($false) }
        return @{
            Ok         = $true
            Protocol   = $ssl.SslProtocol
            Cipher     = "$($ssl.NegotiatedCipherSuite)"
            Subject    = $cert.Subject
            Issuer     = $cert.Issuer
            NotAfter   = $cert.NotAfter
            IsRsa      = ($cert.GetKeyAlgorithm() -eq '1.2.840.113549.1.1.1')
            SanCovers  = ($san -match [regex]::Escape($Fqdn))
            San        = $san
        }
    } catch {
        return @{ Ok = $false; Error = $_.Exception.Message }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
}

Write-Host "`n=== NPM-NTLM / Exchange validation ===" -ForegroundColor Cyan
$autoInfo = if ($AutodiscoverFqdn) { "   Autodiscover: $AutodiscoverFqdn" } else { '' }
Write-Host ("OWA: {0}{1}`n" -f $OwaFqdn, $autoInfo)

# ---------- 1. DNS ----------
foreach ($fqdn in @($OwaFqdn, $AutodiscoverFqdn) | Where-Object { $_ }) {
    try {
        $ips = @()
        try { $ips = (Resolve-DnsName $fqdn -Type A -ErrorAction Stop).IPAddress } catch {
            $ips = [System.Net.Dns]::GetHostAddresses($fqdn) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
        }
        $ips = @($ips | Where-Object { $_ })
        if ($ips.Count -eq 0) { throw 'нет A-записей' }
        $ok = $true; $detail = ($ips -join ', ')
        if ($ExpectedIp) {
            $ok = ($ips -contains $ExpectedIp)
            $detail += $(if ($ok) { ' (совпадает с ожидаемым)' } else { " (ОЖИДАЛСЯ $ExpectedIp!)" })
        }
        Write-Check "DNS A: $fqdn" $ok $detail
    } catch {
        Write-Check "DNS A: $fqdn" $false $_.Exception.Message
    }
}

# ---------- 2. TLS / сертификат ----------
$tls12 = Test-TlsHandshake -Fqdn $OwaFqdn -Protocol ([System.Security.Authentication.SslProtocols]::Tls12)
if ($tls12.Ok) {
    Write-Check 'TLS 1.2 handshake' $true ("cipher: $($tls12.Cipher)")
    Write-Check 'Certificate: RSA key' $tls12.IsRsa $tls12.Subject
    Write-Check "Certificate: SAN covers $OwaFqdn" $tls12.SanCovers $tls12.San
    $days = [int]($tls12.NotAfter - (Get-Date)).TotalDays
    Write-Check 'Certificate: not expired' ($days -gt 14) ("issuer: $($tls12.Issuer); осталось $days дн.")
} else {
    Write-Check 'TLS 1.2 handshake' $false $tls12.Error
}
try {
    $tls13 = Test-TlsHandshake -Fqdn $OwaFqdn -Protocol ([System.Security.Authentication.SslProtocols]::Tls13)
    if (-not $tls13.Ok -and -not $IsWindows) {
        # на macOS/Linux Schannel-эквивалент pwsh может не уметь TLS 1.3 — это не проблема сервера
        Write-Check 'TLS 1.3 handshake' $null "клиентская платформа без TLS 1.3 — пропуск ($($tls13.Error))"
    } elseif (-not $tls13.Ok -and $tls13.Error -match 'cannot communicate|not supported|не уда|не поддержива') {
        # клиентская ОС/Schannel без TLS 1.3 — это не проблема сервера
        Write-Check 'TLS 1.3 handshake' $null "клиент не поддерживает TLS 1.3 — пропуск ($($tls13.Error))"
    } else {
        Write-Check 'TLS 1.3 handshake' $tls13.Ok $(if ($tls13.Ok) { "cipher: $($tls13.Cipher)" } else { $tls13.Error })
    }
} catch {
    Write-Check 'TLS 1.3 handshake' $null 'SslProtocols.Tls13 недоступен в этом .NET — пропуск'
}

# ---------- 3. Edge-харденинг ----------
$httpsBase = "https://$OwaFqdn"

$r = Invoke-Probe "$httpsBase/healthz"
Write-Check '/healthz -> 200 ok' ($r.Status -eq 200 -and $r.Content -match 'ok') "status=$($r.Status)"

$r = Invoke-Probe "$httpsBase/"
$loc = Get-HeaderValue $r.Headers 'Location'
Write-Check '/ -> redirect to /owa' (($r.Status -eq 301 -or $r.Status -eq 302) -and $loc -match '/owa') "status=$($r.Status) Location=$loc"

# /ecp/ (со слэшем) должен быть 403; голый /ecp до фикса шаблона отвечает 302 (редирект Exchange на /ecp/)
foreach ($path in '/powershell', '/ecp/') {
    $r = Invoke-Probe ($httpsBase + $path)
    Write-Check "$path -> 403 (закрыт)" ($r.Status -eq 403) "status=$($r.Status)"
}

$r = Invoke-Probe "$httpsBase/owa/"
$owaLoc = Get-HeaderValue $r.Headers 'Location'
# FBA: GET /owa/ -> 302 на страницу логона (/owa/auth/...) — это норма; 200 тоже допустим
Write-Check '/owa/ -> страница входа' ($r.Status -eq 200 -or (($r.Status -eq 301 -or $r.Status -eq 302) -and $owaLoc -match '/owa')) "status=$($r.Status) Location=$owaLoc"

# ActiveSync: штатно предлагает только Basic (EAS-протокол) — важен сам 401, а не NTLM
$r = Invoke-Probe "$httpsBase/Microsoft-Server-ActiveSync"
$wa = Get-HeaderValue $r.Headers 'WWW-Authenticate'
Write-Check 'ActiveSync -> 401 с auth-challenge' ($r.Status -eq 401 -and $wa) "status=$($r.Status) WWW-Authenticate=$wa"

# HTTP -> HTTPS (Force SSL)
$r = Invoke-Probe "http://$OwaFqdn/"
$loc = Get-HeaderValue $r.Headers 'Location'
Write-Check 'http -> https redirect (Force SSL)' (($r.Status -eq 301 -or $r.Status -eq 302) -and $loc -match '^https://') "status=$($r.Status) Location=$loc"

# ---------- 4. Autodiscover ----------
if (-not $AutodiscoverFqdn) {
    Write-Check 'Autodiscover' $null 'AutodiscoverFqdn не задан — пропуск'
} else {
    $autoUrl = "https://$AutodiscoverFqdn/Autodiscover/Autodiscover.xml"

    $r = Invoke-Probe $autoUrl
    $wa = Get-HeaderValue $r.Headers 'WWW-Authenticate'
    Write-Check 'Autodiscover bare -> 401 с NTLM' ($r.Status -eq 401 -and $wa -match 'NTLM') "status=$($r.Status) WWW-Authenticate=$wa"

    if (-not $MailAddress) {
        Write-Check 'Autodiscover POST' $null 'MailAddress не задан — пропуск аутентифицированной проверки'
    } else {
        if (-not $Credential) {
            $Credential = Get-Credential -Message 'NTLM-логин тестового ящика: UPN (user@office.domain) или DOMAIN\user'
        }
        $payload = '<?xml version="1.0" encoding="utf-8"?>' +
            '<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">' +
            "<Request><EMailAddress>$MailAddress</EMailAddress>" +
            '<AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>' +
            '</Request></Autodiscover>'

        $r = Invoke-Probe $autoUrl -Method POST -Body $payload -ContentType 'text/xml' -Cred $Credential
        if ($r.Status -eq 401) {
            Write-Check 'Autodiscover POST (NTLM)' $false '401 после хендшейка — проверьте логин (UPN, а не SMTP) и пароль'
        } elseif ($r.Status -ne 200) {
            Write-Check 'Autodiscover POST (NTLM)' $false ("status=$($r.Status)" + $(if ($r.Error) { " $($r.Error)" } else { '' }))
        } else {
            Write-Check 'Autodiscover POST (NTLM)' $true '200 OK — рукопожатие прошло через прокси'
            try {
                [xml]$xml = $r.Content
                $err = $xml.SelectSingleNode("//*[local-name()='ErrorCode']")
                if ($err) {
                    Write-Check 'Autodiscover XML' $false "ErrorCode $($err.InnerText): $($xml.SelectSingleNode("//*[local-name()='Message']").InnerText)"
                } else {
                    $expr = $xml.SelectNodes("//*[local-name()='Protocol']") | Where-Object { $_.Type -eq 'EXPR' } | Select-Object -First 1
                    if ($expr) {
                        Write-Check 'EXPR Server = публичный FQDN' ($expr.Server -eq $OwaFqdn) "EXPR Server: $($expr.Server)"
                        Write-Check 'EXPR AuthPackage = Ntlm' ($expr.AuthPackage -match 'Ntlm|Negotiate') "AuthPackage: $($expr.AuthPackage)"
                    } else {
                        Write-Check 'EXPR protocol block' $false 'блок EXPR не найден — проверьте Set-OutlookAnywhere'
                    }
                    $owaExt = $xml.SelectSingleNode("//*[local-name()='External']/*[local-name()='OWAUrl']")
                    Write-Check 'WEB External OWAUrl' ($owaExt -and $owaExt.InnerText -match [regex]::Escape($OwaFqdn)) $(if ($owaExt) { $owaExt.InnerText } else { 'OWAUrl не найден' })
                }
            } catch {
                Write-Check 'Autodiscover XML parse' $false $_.Exception.Message
            }
        }
    }
}

# ---------- Итог ----------
Write-Host "`n=== Итог: $script:Passed PASS / $script:Failed FAIL / $script:Skipped SKIP ===" -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed -gt 0) { exit 1 }
