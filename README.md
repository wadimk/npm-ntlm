# NGINX Proxy Manager (NTLM) for Exchange 2019

English | **[Русская версия](README.ru.md)**

Based on the article: [How to Get Exchange 2019 Working Behind NGINX Proxy Manager](https://blog.cortanadesign.com.au/2025/09/10/how_to_get_exchange_2019_working_behind_nginx_proxy_manager).

The image is built locally (see `Dockerfile`): the latest official [jc21/nginx-proxy-manager](https://hub.docker.com/r/jc21/nginx-proxy-manager) plus the open-source NTLM module compiled against the same OpenResty version as the NPM base image. The module comes from the [greetoz/nginx-ntlm-module](https://github.com/greetoz/nginx-ntlm-module) fork — it contains cached-connection queue fixes on top of the original [gabihodoroaga/nginx-ntlm-module](https://github.com/gabihodoroaga/nginx-ntlm-module). The stock NPM image does not work with Exchange without the NTLM module (the NTLM handshake breaks — Outlook, ActiveSync, Autodiscover, EWS, MAPI and RPC stop working).

## Structure

```
Dockerfile                    — build: official NPM + NTLM module
docker-entrypoint.sh          — renders http_top.conf from a template (envsubst) before NPM starts
seed-proxy-host.sh            — optional: creates the Exchange Proxy Host via the NPM API on first start
docker-compose.yml            — NPM stack (built locally, image npm-ntlm:latest)
.env.example                  — environment variables example (copy to .env)
data/nginx/custom/http_top.conf.template — exch_ntlm upstream template with NTLM enabled
                              (also baked into the image; the entrypoint restores it into
                              the volume on start if missing)
ssl-ciphers.conf              — TLS policy baked into the image (global): TLS 1.2/1.3,
                              Mozilla-intermediate + CBC suites from the Microsoft 365 list
advanced-custom-nginx.conf.template — per-host Advanced config template (baked into the image,
                              rendered with envsubst; applied by the seeder or pasted manually)
Test-ExchangeProxy.ps1          — end-to-end validation script: DNS, TLS/RSA certificate,
                              edge hardening, authenticated Autodiscover POST
```

## FQDN configuration

**Internal Exchange FQDN** (the `exch_ntlm` upstream) is set via the `EXCHANGE_FQDN` environment variable — copy `.env.example` to `.env` and fill in the real value (compose picks up `.env` automatically). At container start, `docker-entrypoint.sh` renders `data/nginx/custom/http_top.conf` from the template using `envsubst`. If the variable is not set, the template is copied as-is on first start and the FQDN can be replaced directly in `http_top.conf` manually.

> If `EXCHANGE_FQDN` is set, `http_top.conf` is overwritten on every start — edit the template or the variable, not the generated file.

**Public FQDNs and the per-host Advanced config** live in `advanced-custom-nginx.conf.template`, which uses two placeholders: `${EXCHANGE_FQDN}` (internal Exchange FQDN) and `${OWA_FQDN}` (public OWA/ECP FQDN). There are two ways to apply it:

### Automatic Proxy Host creation (recommended)

Set in `.env` (in addition to `EXCHANGE_FQDN`):

| Variable | Purpose |
|---|---|
| `NPM_SEED_PROXY_HOST=true` | enable the seeder |
| `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` | first admin (required for API login; applied only on an empty database) |
| `OWA_FQDN` | public OWA/ECP FQDN |
| `AUTODISCOVER_FQDN` | public Autodiscover FQDN (optional: if empty, the Proxy Host is created with `OWA_FQDN` only — no autodiscover domain, no certificate for it) |

On container start `seed-proxy-host.sh` waits for the NPM backend, logs in via the API and creates a Proxy Host: domain `OWA_FQDN` (plus `AUTODISCOVER_FQDN` if set), HTTPS forward to `EXCHANGE_FQDN:443`, with the rendered Advanced config (NTLM locations and logging included). It is idempotent — if a Proxy Host with `OWA_FQDN` already exists, it does nothing.

> If the Proxy Host was created earlier **manually** (e.g. with an old hand-edited Advanced config), the seeder will skip it. Either delete the host in the UI and restart the container, or replace its Advanced config with the freshly rendered template.

`INITIAL_ADMIN_*` play two roles. On a **fresh install** (empty database) NPM itself creates the admin account with these credentials — set them before the very first start and there will be no setup wizard; the seeder then logs in with the same values, so everything matches by construction. On an **existing installation** NPM ignores them (the admin already exists), but the seeder still uses them to log in — so they must contain the real credentials of the admin account you use in the UI.

If the seeder cannot run, nothing breaks — NPM starts normally, only the automatic Proxy Host creation is skipped. Which branch happened is visible in the container log (`docker logs nginxproxymanager_app_1 | grep SEED`):

- `SEED: пропуск — не заданы переменные: ...` — a required variable is missing (e.g. `INITIAL_ADMIN_*`); the seeder exits immediately, without waiting. On a fresh install NPM then shows the setup wizard and the Proxy Host is created manually.
- `SEED: не удалось авторизоваться в API NPM ...` — the credentials do not match the real admin (typical for an existing database); the seeder retries for ~5 minutes, then gives up. NPM itself keeps working.
- No `SEED` lines at all — `NPM_SEED_PROXY_HOST` is not `true`, the seeder never started.

The Let's Encrypt certificate and **Force SSL** are still enabled manually in the UI (Hosts → Proxy Hosts → Edit → SSL) — after DNS for every FQDN in the host points at the NPM host.

### Manual paste (fallback)

Render the template and paste the result into Proxy Host → Advanced → Custom Nginx Configuration:

```bash
export EXCHANGE_FQDN=exchange.internal.example.com OWA_FQDN=owa.example.com
envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' < advanced-custom-nginx.conf.template
```

### What the seeded config includes

- `/` redirects (302) to `/owa`; `/healthz` returns `200 ok` for monitoring;
- **HTTP/2 is disabled** on the created Proxy Host: NTLM is connection-oriented and breaks over h2 (curl silently downgrades to HTTP/1.1, WinHTTP/Outlook does not — symptom: Outlook cannot connect / loops on the password prompt while `curl --ntlm` works);
- **`/powershell` and `/ecp` return 403** — Remote PowerShell and the Exchange admin panel are not exposed to the internet. To open ECP (e.g. restricted to your IPs), edit the Advanced config per the comment inside the template;
- every NTLM location logs handshakes to `/var/log/nginx/ntlm_access.log` (see "NTLM logging" below).

### Seeder lifecycle (what changes on restart)

The seeder is **create-only**: existence is checked by `OWA_FQDN`, and an existing Proxy Host is never modified — your UI edits (certificate, Force SSL, …) are safe across restarts.

- Changing `AUTODISCOVER_FQDN` after seeding (empty → set → another value → empty) changes **nothing**; the domain list is fixed at creation time. To apply: delete the Proxy Host in the UI and `docker compose restart` — the seeder recreates it with the current values (re-attach the certificate and Force SSL afterwards).
- Changing `EXCHANGE_FQDN` applies only **partially** on restart: the `exch_ntlm` upstream in `http_top.conf` is re-rendered on every start, but the Advanced config stored in the NPM database keeps the value baked in at seed time (the `proxy_pass` of the `/owa/` block). Recreate the host or fix the Advanced config in the UI.
- Changing `OWA_FQDN` creates a **second** Proxy Host instead of renaming the old one — the existence check keys on it.
- Certificates: Let's Encrypt validates **every** domain in `domain_names` over HTTP-01. If any domain (e.g. autodiscover) has no A record pointing at the NPM host, the whole request fails with "Internal Error" — an already issued certificate is not affected. Create DNS first (`dig +short autodiscover.example.com @8.8.8.8`), then request the certificate.

### TLS and Microsoft 365 compatibility

Per [Microsoft 365 encryption reference](https://learn.microsoft.com/en-us/purview/technical-reference-details-about-encryption), the Microsoft 365 side speaks TLS 1.2/1.3 with a fixed cipher list — all TLS 1.2 suites there are `ECDHE-RSA-*`. The image aligns with it:

- `ssl-ciphers.conf` (baked into the image, global for all Proxy Hosts) enables TLS 1.2 + 1.3 and extends the stock Mozilla-intermediate list with `ECDHE-RSA-AES256-SHA384` / `ECDHE-RSA-AES128-SHA256` (CBC) — needed by legacy Schannel clients (older Windows/Outlook) that lack AES-GCM. GCM suites stay preferred;
- **request the certificate with Key Type: RSA** (the UI shows the selector in the certificate request form). With an ECDSA certificate no `ECDHE-RSA-*` suite can be negotiated on TLS 1.2 — only TLS 1.3 would work, and legacy clients would fail. If the certificate was already issued as ECDSA: re-request it with RSA (UI → SSL Certificates → Add, then bind it to the Proxy Host) — no host recreation needed.

Verify against the live host:

```bash
echo | openssl s_client -connect owa.example.com:443 -servername owa.example.com -tls1_2 \
  -cipher ECDHE-RSA-AES256-SHA384 2>/dev/null | grep 'Cipher is'   # must show the cipher, not 0000
```

## Updating to a new NPM version

Versions are set as arguments at the top of the `Dockerfile`:

- `NPM_IMAGE` — official NPM image tag (currently `jc21/nginx-proxy-manager:2.16.0`);
- `OPENRESTY_VERSION` — OpenResty version from the [nginx-full](https://github.com/NginxProxyManager/docker-nginx-full/blob/master/docker/docker-bake.hcl) base image (currently `1.31.1.1`); it must match the one inside the NPM image — check with `docker run --rm jc21/nginx-proxy-manager:<tag> nginx -v`.

After changing: `docker compose build --no-cache && docker compose up -d`.

## Publishing to a registry

Images are always published as multi-platform builds (`linux/amd64` + `linux/arm64`), pushed straight from buildx:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t registry.example.com/npm-ntlm:latest --push .
```

Note: on Apple Silicon the amd64 build runs under QEMU emulation and takes much longer than a native one. `docker compose up -d --build` builds only the host architecture — fine for a local stack, but never push single-architecture images to a registry.

### Docker Hub via GitHub Actions

On every push to `main` the workflow `.github/workflows/docker-publish.yml` builds both platforms and pushes `vkosin/npm-ntlm:latest` to Docker Hub — no local build needed. One-time setup: add repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (access token: hub.docker.com → Account Settings → Security).

## Running

```bash
docker compose up -d --build
```

Validate the nginx config inside the container:

```bash
docker exec -it nginxproxymanager_app_1 nginx -t
```

## Web UI configuration

1. Open `http://<host>:81`. On the first run with an empty database, current NPM versions show a **setup wizard** — create the admin account there. The legacy `admin@example.com` / `changeme` credentials are no longer created automatically; they exist only if you set `INITIAL_ADMIN_EMAIL` and `INITIAL_ADMIN_PASSWORD` (e.g. in `.env`) before the very first start.
2. Create a Proxy Host (done automatically when `NPM_SEED_PROXY_HOST=true` — see above):
   - **Domain Names:** `owa.example.com`, `autodiscover.example.com`
   - **Scheme:** HTTPS, **Forward Hostname/IP:** internal Exchange FQDN, **Port:** 443
3. On the **Advanced -> Custom Nginx Configuration** tab, paste the rendered `advanced-custom-nginx.conf.template` (also done automatically by the seeder).
4. **SSL** tab: request a Let's Encrypt certificate and enable **Force SSL** — always manual; both FQDNs must already resolve to the NPM host.

The upstream from `http_top.conf` is picked up by NPM automatically (the file is included at the top of the global `http {}` block).

## Exchange 2019 configuration

Align the URLs (Exchange Management Shell example): ExternalUrl — the public FQDN behind the proxy, InternalUrl — the internal Exchange FQDN (no split DNS needed):

```powershell
Set-OwaVirtualDirectory -Identity "EXCH01\owa (Default Web Site)" `
  -InternalUrl "https://exchange.internal.example.com/owa" `
  -ExternalUrl "https://owa.example.com/owa"

Set-EcpVirtualDirectory -Identity "EXCH01\ecp (Default Web Site)" `
  -InternalUrl "https://exchange.internal.example.com/ecp" `
  -ExternalUrl "https://owa.example.com/ecp"
```

Align the URLs of the remaining client-facing services the same way (otherwise Autodiscover answers with errors like "No external URL is available to access this mailbox with Exchange ActiveSync"):

```powershell
$server  = "EXCH01"
$fqdn    = "owa.example.com"                    # public, behind the proxy
$intfqdn = "exchange.internal.example.com"      # internal Exchange FQDN

Set-ActiveSyncVirtualDirectory -Identity "$server\Microsoft-Server-ActiveSync (Default Web Site)" `
  -ExternalUrl "https://$fqdn/Microsoft-Server-ActiveSync" -InternalUrl "https://$intfqdn/Microsoft-Server-ActiveSync"

Set-WebServicesVirtualDirectory -Identity "$server\EWS (Default Web Site)" `
  -ExternalUrl "https://$fqdn/EWS/exchange.asmx" -InternalUrl "https://$intfqdn/EWS/exchange.asmx"

Set-OabVirtualDirectory -Identity "$server\OAB (Default Web Site)" `
  -ExternalUrl "https://$fqdn/OAB" -InternalUrl "https://$intfqdn/OAB"

Set-MapiVirtualDirectory -Identity "$server\mapi (Default Web Site)" `
  -ExternalUrl "https://$fqdn/mapi" -InternalUrl "https://$intfqdn/mapi"

Set-OutlookAnywhere -Identity "$server\Rpc (Default Web Site)" `
  -ExternalHostname $fqdn -InternalHostname $intfqdn `
  -ExternalClientsRequireSsl $true -InternalClientsRequireSsl $true `
  -ExternalClientAuthenticationMethod Negotiate -InternalClientAuthenticationMethod NTLM `
  -SSLOffloading $false
```

> With InternalUrl on the internal FQDN, LAN clients talk to Exchange directly — the IIS certificate on Exchange must be valid for the internal name (internal CA or an already trusted one). If you later add **split DNS** (the public name resolving to the NPM host inside the LAN), you can point InternalUrl at the public FQDN as well.

**Extended Protection must be `None`** on every client-facing virtual directory. TLS terminates at NPM, so an EPA-capable client (Windows Schannel: RCA, Windows Outlook) computes the channel binding token from the **proxy's** certificate while Exchange validates it against **its own IIS** certificate → mismatch → 401 after the NTLM Type-3. EPA-incapable clients (curl, Mac Outlook) slip through under `Allow` — a deceptive symptom: "curl works, Windows/RCA does not":

```powershell
$server = "EXCH01"
Set-AutodiscoverVirtualDirectory -Identity "$server\Autodiscover (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-WebServicesVirtualDirectory  -Identity "$server\EWS (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-MapiVirtualDirectory         -Identity "$server\mapi (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-ActiveSyncVirtualDirectory   -Identity "$server\Microsoft-Server-ActiveSync (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-OabVirtualDirectory          -Identity "$server\OAB (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-OwaVirtualDirectory          -Identity "$server\owa (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-EcpVirtualDirectory          -Identity "$server\ecp (Default Web Site)" -ExtendedProtectionTokenChecking None
Set-OutlookAnywhere              -Identity "$server\Rpc (Default Web Site)" -ExtendedProtectionTokenChecking None
iisreset /noforce
```

This is not a security downgrade in this topology: EP protects the TLS leg against MITM/relay, and that leg terminates at the proxy.

If you run a hybrid configuration with Microsoft 365 — switch OWA/ECP to Hybrid Modern Authentication (OAuth), disabling legacy methods:

```powershell
Get-OwaVirtualDirectory -Server "EXCH01" | Set-OwaVirtualDirectory `
  -AdfsAuthentication $false -BasicAuthentication $false `
  -FormsAuthentication $false -DigestAuthentication $false `
  -WindowsAuthentication $false -OAuthAuthentication $true

Get-EcpVirtualDirectory -Server "EXCH01" | Set-EcpVirtualDirectory `
  -AdfsAuthentication $false -BasicAuthentication $false `
  -FormsAuthentication $false -DigestAuthentication $false `
  -WindowsAuthentication $false -OAuthAuthentication $true
```

> Without Entra ID hybrid, HMA is not available: OWA/ECP will stay on NTLM and the browser will show the system login prompt. This is expected.

Verify:

```powershell
Get-OwaVirtualDirectory -Server "EXCH01" | fl server,*auth*
Get-EcpVirtualDirectory -Server "EXCH01" | fl server,*auth*
```

### Verifying via Autodiscover

The most informative end-to-end check of the Exchange-side URLs is an authenticated Autodiscover POST from outside (NTLM username = **UPN** `user@office.example.com` or `DOMAIN\user` — it may differ from the mailbox's SMTP address; the SMTP address goes only into `EMailAddress` inside the XML):

```bash
printf '%s' '<?xml version="1.0" encoding="utf-8"?><Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006"><Request><EMailAddress>user@example.com</EMailAddress><AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema></Request></Autodiscover>' > /tmp/autod.xml

curl -s --ntlm -u 'DOMAIN\user' -H 'Content-Type: text/xml' \
  --data @/tmp/autod.xml https://autodiscover.example.com/Autodiscover/Autodiscover.xml
```

Expected: `200 OK` with a `<Response>` containing the user's `<Account>` and `<Protocol>` blocks. What to check:

- `EXPR → <Server>` must be the **public** FQDN (`owa.example.com`). If it shows the internal FQDN, `Set-OutlookAnywhere -ExternalHostname` was not applied — external Outlook will fail to connect. Re-run the cmdlet, `iisreset /noforce`, re-test.
- `WEB/External → OWAUrl` and `EXPR → OABUrl` must be public URLs; `EXCH → <Server>` being the mailbox GUID (`<guid>@example.com`) is normal for Exchange 2013+.
- `<ErrorCode>600</ErrorCode>` ("Invalid Request") means the XML payload itself is broken (e.g. line wraps inside `EMailAddress` from copy-paste) — authentication has already passed at that point.

## Testing

- `https://owa.example.com/owa` — the Microsoft 365 sign-in page (with HMA), not an NTLM prompt and not the OWA form.
- Outlook and ActiveSync connect via NTLM and Autodiscover.

### Automated validation (Test-ExchangeProxy.ps1)

`Test-ExchangeProxy.ps1` runs the whole external check in one go (PowerShell 5.1+ / 7+): DNS records, TLS 1.2/1.3 handshake, RSA certificate with SAN coverage and expiry, edge hardening (`/healthz`, `/` → `/owa` redirect, 403 on `/powershell` and `/ecp/`, http→https redirect), auth challenges on ActiveSync/Autodiscover and — with credentials — the authenticated Autodiscover POST with EXPR/OWA URL validation:

```powershell
.\Test-ExchangeProxy.ps1 -OwaFqdn owa.example.com -AutodiscoverFqdn autodiscover.example.com `
    -MailAddress user@example.com -ExpectedIp 203.0.113.10
```

The NTLM credentials are prompted interactively (UPN `user@office.example.com` or `DOMAIN\user` — not necessarily the SMTP address). Every check prints PASS/FAIL/SKIP; exit code is 0 only when nothing failed.

### Autodiscover and NTLM authentication

- A bare request to `https://autodiscover.example.com/Autodiscover/Autodiscover.xml` returning **401** with `WWW-Authenticate: Basic, Negotiate, NTLM` is the **expected first stage**, not an error — Exchange answers through the proxy and offers auth methods. The client must then repeat the request with credentials.
- Verify the authenticated leg from outside (any final status other than 401 — usually 400/405 for a GET — means NTLM auth passed through the proxy):

```bash
curl -v --ntlm -u 'user@example.com:PASSWORD' \
  https://autodiscover.example.com/Autodiscover/Autodiscover.xml -o /dev/null
```

- In the Microsoft Connectivity Analyzer, the **User Name** field takes the UPN (`user@office.example.com`) or `DOMAIN\user` — it can differ from the mailbox's SMTP address, which goes into the **Email Address** field. If it reports "failed to obtain an Autodiscover XML response" with a 401, first re-check the credentials — and while re-running the test, watch the NTLM handshakes in `ntlm_access.log` (see "NTLM logging" below): 401 → 401 → 200/400 means the handshake works, silence or a stall after the first 401 means it does not.
- RCA always probes `https://<domain>/Autodiscover/...` and `https://www.<domain>/...` before `autodiscover.<domain>` — a 404 there (answered by your regular website) is expected and not a failure; only the `autodiscover.<domain>` stage matters.

## Troubleshooting

- **Redirect loops** — virtual directory URLs do not match public DNS, or wrong reply URLs in Entra ID.
- **400/502** — the stock NPM image without the NTLM module is being used.
- **Blank page after login** — legacy authentication methods are still enabled on the directories.
- **Browser NTLM prompt for OWA/ECP** — HMA is not enabled.
- **`host not found in upstream "exch_ntlm"` when saving a Proxy Host** — `/data/nginx/custom/http_top.conf` is missing or not rendered: check that `EXCHANGE_FQDN` is set and restart the container (the entrypoint restores the template from the image into the volume if it is missing). If the variable is set but rendering was skipped, the entrypoint logs a warning.
- **UI stuck on "The API is not healthy" after a clean start** — first boot migrations take a minute or two; if it persists, check the container log: when the last lines are `Fetching IP Ranges from online services...`, outbound HTTPS to amazonaws.com/cloudflare.com is hanging (firewall) and the backend does not start listening. Disable the fetch with `IP_RANGES_FETCH_ENABLED=false` (it only feeds Access Lists with AWS/Cloudflare ranges — useless for Exchange).
- **Outlook cannot connect / loops on the password prompt, while `curl --ntlm` succeeds** — HTTP/2 is enabled on the Proxy Host: NTLM is connection-oriented and breaks over h2 (curl downgrades to HTTP/1.1 on its own, WinHTTP does not). Fix: host edit → uncheck **HTTP/2 Support** → Save (the seeder creates new hosts with it already off).
- **401 after a fully completed NTLM handshake (curl and Mac Outlook work, RCA / Windows Outlook get 401)** — Extended Protection on the Exchange virtual directories is not `None`: TLS terminates at the proxy, so the channel binding token the client computes (from the LE certificate) never matches the IIS certificate. Fix: `ExtendedProtectionTokenChecking None` on all client-facing vdirs — see "Exchange 2019 configuration".
- **502 on ActiveSync (FolderSync) ~20s in, while IIS logged the same request as 200 with `time-taken` ≈ 20000 ms** — Exchange itself is stalling on the request and the proxy cuts it off. A proven cause: disabled AD permission inheritance on the mailbox user (Application log: "MSExchange ActiveSync doesn't have sufficient permissions to create the ... container" — typically after the account was in a protected group; AdminSDHolder re-breaks it hourly). Fix: re-enable inheritance (`SetAccessRuleProtection($false,$true)` on the user ACL) and check transitive membership in protected groups. The nginx side is not at fault — always check the IIS log `time-taken` first.
- **401 after NTLM Type-3 on EWS/OAB only, while Autodiscover/MAPI work with the same credentials; IIS log shows `401 1 2148074248` (SEC_E_INVALID_TOKEN)** — the request path case (`/EWS/`, `/OAB/` — clients use the case from the Exchange vdir URLs) did not match a case-sensitive nginx prefix location, so the request bypassed the NTLM-pinned location and the Type-3 went over a different upstream connection. Fixed in the template: all Exchange locations are case-insensitive regexes (`location ~* ...`). Update the host's Advanced config.
- **Connection refused on all ports (even the UI)** — `EXCHANGE_FQDN` does not resolve from inside the container: nginx fails at startup with `host not found in upstream "<fqdn>:443"` and never starts. Fix DNS for the Exchange FQDN (or use an IP) and restart.

### NTLM logging

NTLM handshake logging is enabled out of the box: `log_format ntlm_log` is defined in the upstream template, and every NTLM location block in `advanced-custom-nginx.conf.template` writes to `/var/log/nginx/ntlm_access.log` (errors go to `/var/log/nginx/ntlm_error.log`). The log records only the **auth scheme** (`auth="NTLM|Basic|Negotiate|Bearer"`) — never the `Authorization` header itself: Basic credentials are reversible base64 and must not end up in logs (for deep debugging you can temporarily switch `$auth_scheme` to `$http_authorization` in the template — treat the log as a secret then). Watch the handshakes:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```

To disable, remove the `access_log` / `error_log` lines from the NTLM location blocks in the Proxy Host advanced config.

## Security and monitoring

Exchange behind a public reverse proxy is a high-value target: expect constant password brute force against Basic/NTLM endpoints (OWA, EWS, ActiveSync) and background scanner noise. The fallback server answering 404 to `/phpunit/...` or `/device.rsp` probes on port 80 is normal — what matters is that nothing there ever returns 200.

### Hardening checklist

- **Admin UI (port 81)** must never be published to the internet — restrict it to the LAN/VPN at the firewall. The API is the control plane of the proxy.
- **`INITIAL_ADMIN_PASSWORD`** — remove from `.env`/compose once the admin exists; rotate any credential that ever appeared in logs or chat (Basic credentials seen in a misconfigured log are base64, i.e. plaintext).
- **`/powershell` and `/ecp` stay 403** (already in the template). If you open ECP, put an NPM **Access List** (IP allowlist) in front of it.
- **HSTS** — add to the Proxy Host Advanced config once HTTPS is stable: `add_header Strict-Transport-Security "max-age=63072000" always;`
- **Rate limiting** on auth endpoints — add a zone to the `http_top.conf` template and reference it in the NTLM locations, e.g. `limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/s;` + `limit_req zone=auth burst=20 nodelay;`.
- **On Exchange itself**: disable TLS 1.0/1.1 (IIS Crypto or registry), keep up with Exchange CU/SU and Windows updates.
- **Updates of this image**: rebuild monthly (`docker compose build --no-cache` picks up base-image patches; CI rebuilds on every push to `main`). Watch releases of [jc21/nginx-proxy-manager](https://github.com/NginxProxyManager/nginx-proxy-manager/releases) and bump the `Dockerfile` ARGs.
- **Certificate expiry**: LE renewal logs are in `/data/logs/letsencrypt*.log`; alert if a certificate has < 14 days left (`openssl s_client -connect owa.example.com:443 -servername owa.example.com 2>/dev/null | openssl x509 -enddate -noout`).

### What to monitor

- **`/var/log/nginx/ntlm_access.log`** — the primary source. Brute force looks like a burst of 401s from one IP; foreign paths are recon. Quick checks:

  ```bash
  # top IPs by 401 count
  docker exec -it nginxproxymanager_app_1 sh -c \
    "grep '\" 401 ' /var/log/nginx/ntlm_access.log | awk '{print \$1}' | sort | uniq -c | sort -rn | head"
  # requests to non-Exchange paths
  docker exec -it nginxproxymanager_app_1 sh -c \
    "grep -v -Ei 'owa|/ews|autodiscover|/mapi|/rpc|activesync|/oab|/ecp|healthz' /var/log/nginx/ntlm_access.log | tail"
  ```

- **`/data/logs/fallback_*_access.log`** — scanner noise; a 200 here would be a red flag.
- **IIS logs on Exchange** — every client arrives with the proxy's IP. To keep real client IPs, add the `X-Forwarded-For` field to IIS logging (IIS Manager → Logging → Select Fields) — the proxy already sends the header.
- **Windows event log** — 4624/4625 (logon success/failure) for mailbox and service accounts, `MSExchange ActiveSync` permission errors, IIS/WAS warnings.
- **Availability** — the template exposes `/healthz` on the Proxy Host exactly for this: monitor `https://owa.example.com/healthz` from outside (200 = proxy + host config alive) and alert on failure; pair it with a 401-check on `/Microsoft-Server-ActiveSync` (401 with challenge = auth path alive, anything else = trouble).

### Fail2ban on the Docker host

The NTLM log lives inside the container; to feed host-side fail2ban either point the template's log paths at `/data/logs/` (the `./data` volume) — e.g. `access_log /data/logs/ntlm_access.log ntlm_log;` — or mount an extra volume for `/var/log/nginx`. Then:

```ini
# /etc/fail2ban/filter.d/npm-ntlm.conf
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]+\] "[^"]*" 401 .*$
datepattern = %%d/%%b/%%Y:%%H:%%M:%%S %%z
```

```ini
# /etc/fail2ban/jail.d/npm-ntlm.conf
[npm-ntlm]
enabled  = true
filter   = npm-ntlm
logpath  = /srv/npm/data/logs/ntlm_access.log
maxretry = 20
findtime = 3600
bantime  = 3600
action   = iptables-multiport[name=npm-ntlm, port="http,https"]
```

Keep `maxretry` lenient and `findtime` long: an Outlook client with a stale saved password also produces 401 bursts — aggressive banning locks out your own users. An alternative that needs no host setup at all is nginx rate limiting (see above).
