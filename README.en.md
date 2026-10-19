# NGINX Proxy Manager (NTLM) for Exchange 2019

**[Русская версия](README.md)** | English

Based on the article: [How to Get Exchange 2019 Working Behind NGINX Proxy Manager](https://blog.cortanadesign.com.au/2025/09/10/how_to_get_exchange_2019_working_behind_nginx_proxy_manager).

The image is built locally (see `Dockerfile`): the latest official [jc21/nginx-proxy-manager](https://hub.docker.com/r/jc21/nginx-proxy-manager) plus the open-source NTLM module compiled against the same OpenResty version as the NPM base image. The module comes from the [greetoz/nginx-ntlm-module](https://github.com/greetoz/nginx-ntlm-module) fork — it contains cached-connection queue fixes on top of the original [gabihodoroaga/nginx-ntlm-module](https://github.com/gabihodoroaga/nginx-ntlm-module). The stock NPM image does not work with Exchange without the NTLM module (the NTLM handshake breaks — Outlook, ActiveSync, Autodiscover, EWS, MAPI and RPC stop working).

## Structure

```
Dockerfile                    — build: official NPM + NTLM module
docker-entrypoint.sh          — renders http_top.conf from a template (envsubst) before NPM starts
docker-compose.yml            — NPM stack (built locally, image npm-ntlm:latest)
.env.example                  — environment variables example (copy to .env)
data/nginx/custom/http_top.conf.template — exch_ntlm upstream template with NTLM enabled
advanced-custom-nginx.conf    — block to paste into the UI: Proxy Host -> Advanced
```

## FQDN configuration

**Internal Exchange FQDN** (the `exch_ntlm` upstream) is set via the `EXCHANGE_FQDN` environment variable — copy `.env.example` to `.env` and fill in the real value (compose picks up `.env` automatically). At container start, `docker-entrypoint.sh` renders `data/nginx/custom/http_top.conf` from the template using `envsubst`. If the variable is not set, the template is copied as-is on first start and the FQDN can be replaced directly in `http_top.conf` manually.

> If `EXCHANGE_FQDN` is set, `http_top.conf` is overwritten on every start — edit the template or the variable, not the generated file.

**The remaining placeholders** (in `advanced-custom-nginx.conf` and when creating the Proxy Host) cannot be set via variables: that config is stored in the NPM database and pasted through the UI, so replace them manually when pasting:

| Placeholder | Replace with |
|---|---|
| `exchange.internal.example.com` | internal FQDN of the Exchange 2019 server |
| `owa.example.com` | public FQDN for OWA/ECP |
| `autodiscover.example.com` | public Autodiscover FQDN (when creating the Proxy Host) |

## Updating to a new NPM version

Versions are set as arguments at the top of the `Dockerfile`:

- `NPM_IMAGE` — official NPM image tag (currently `jc21/nginx-proxy-manager:2.16.0`);
- `OPENRESTY_VERSION` — OpenResty version from the [nginx-full](https://github.com/NginxProxyManager/docker-nginx-full/blob/master/docker/docker-bake.hcl) base image (currently `1.31.1.1`); it must match the one inside the NPM image — check with `docker run --rm jc21/nginx-proxy-manager:<tag> nginx -v`.

After changing: `docker compose build --no-cache && docker compose up -d`.

## Running

```bash
docker compose up -d --build
```

Validate the nginx config inside the container:

```bash
docker exec -it nginxproxymanager_app_1 nginx -t
```

## Web UI configuration

1. Open `http://<host>:81`, log in with `admin@example.com` / `changeme` and change the password immediately.
2. Create a Proxy Host:
   - **Domain Names:** `owa.example.com`, `autodiscover.example.com`
   - **Scheme:** HTTPS, **Forward Hostname/IP:** internal Exchange FQDN, **Port:** 443
   - **SSL:** Let's Encrypt certificate, enable **Force SSL**
3. On the **Advanced -> Custom Nginx Configuration** tab, paste the contents of `advanced-custom-nginx.conf`.

The upstream from `http_top.conf` is picked up by NPM automatically (the file is included at the top of the global `http {}` block).

## Exchange 2019 configuration

Align the URLs (Exchange Management Shell example):

```powershell
Set-OwaVirtualDirectory -Identity "EXCH01\owa (Default Web Site)" `
  -InternalUrl "https://owa.example.com/owa" `
  -ExternalUrl "https://owa.example.com/owa"

Set-EcpVirtualDirectory -Identity "EXCH01\ecp (Default Web Site)" `
  -InternalUrl "https://owa.example.com/ecp" `
  -ExternalUrl "https://owa.example.com/ecp"
```

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

## Testing

- `https://owa.example.com/owa` — the Microsoft 365 sign-in page (with HMA), not an NTLM prompt and not the OWA form.
- Outlook and ActiveSync connect via NTLM and Autodiscover.

## Troubleshooting

- **Redirect loops** — virtual directory URLs do not match public DNS, or wrong reply URLs in Entra ID.
- **400/502** — the stock NPM image without the NTLM module is being used.
- **Blank page after login** — legacy authentication methods are still enabled on the directories.
- **Browser NTLM prompt for OWA/ECP** — HMA is not enabled.

### NTLM logging

Uncomment `log_format ntlm_log` in `http_top.conf` (or in the template, if you use `EXCHANGE_FQDN`) and add to the NTLM location blocks:

```
access_log /var/log/nginx/ntlm_access.log ntlm_log;
error_log  /var/log/nginx/ntlm_error.log warn;
```

Then:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```
