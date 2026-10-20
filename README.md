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
advanced-custom-nginx.conf.template — per-host Advanced config template (baked into the image,
                              rendered with envsubst; applied by the seeder or pasted manually)
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
| `AUTODISCOVER_FQDN` | public Autodiscover FQDN (default: `autodiscover.<domain of OWA_FQDN>`) |

On container start `seed-proxy-host.sh` waits for the NPM backend, logs in via the API and creates a Proxy Host: domains `OWA_FQDN` + `AUTODISCOVER_FQDN`, HTTPS forward to `EXCHANGE_FQDN:443`, with the rendered Advanced config (NTLM locations and logging included). It is idempotent — if a Proxy Host with `OWA_FQDN` already exists, it does nothing.

> If the Proxy Host was created earlier **manually** (e.g. with an old hand-edited Advanced config), the seeder will skip it. Either delete the host in the UI and restart the container, or replace its Advanced config with the freshly rendered template.

`INITIAL_ADMIN_*` play two roles. On a **fresh install** (empty database) NPM itself creates the admin account with these credentials — set them before the very first start and there will be no setup wizard; the seeder then logs in with the same values, so everything matches by construction. On an **existing installation** NPM ignores them (the admin already exists), but the seeder still uses them to log in — so they must contain the real credentials of the admin account you use in the UI.

If the seeder cannot run, nothing breaks — NPM starts normally, only the automatic Proxy Host creation is skipped. Which branch happened is visible in the container log (`docker logs nginxproxymanager_app_1 | grep SEED`):

- `SEED: пропуск — не заданы переменные: ...` — a required variable is missing (e.g. `INITIAL_ADMIN_*`); the seeder exits immediately, without waiting. On a fresh install NPM then shows the setup wizard and the Proxy Host is created manually.
- `SEED: не удалось авторизоваться в API NPM ...` — the credentials do not match the real admin (typical for an existing database); the seeder retries for ~5 minutes, then gives up. NPM itself keeps working.
- No `SEED` lines at all — `NPM_SEED_PROXY_HOST` is not `true`, the seeder never started.

The Let's Encrypt certificate and **Force SSL** are still enabled manually in the UI (Hosts → Proxy Hosts → Edit → SSL) — after DNS for both FQDNs points at the NPM host.

### Manual paste (fallback)

Render the template and paste the result into Proxy Host → Advanced → Custom Nginx Configuration:

```bash
export EXCHANGE_FQDN=exchange.internal.example.com OWA_FQDN=owa.example.com
envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' < advanced-custom-nginx.conf.template
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
- **`host not found in upstream "exch_ntlm"` when saving a Proxy Host** — `/data/nginx/custom/http_top.conf` is missing or not rendered: check that `http_top.conf.template` exists in the `data/nginx/custom/` volume and that `EXCHANGE_FQDN` is set, then restart the container. The entrypoint logs a warning when the variable is set but the template is missing.
- **UI stuck on "The API is not healthy" after a clean start** — first boot migrations take a minute or two; if it persists, check the container log: when the last lines are `Fetching IP Ranges from online services...`, outbound HTTPS to amazonaws.com/cloudflare.com is hanging (firewall) and the backend does not start listening. Disable the fetch with `IP_RANGES_FETCH_ENABLED=false` (it only feeds Access Lists with AWS/Cloudflare ranges — useless for Exchange).

### NTLM logging

NTLM handshake logging is enabled out of the box: `log_format ntlm_log` is defined in the upstream template, and every NTLM location block in `advanced-custom-nginx.conf.template` writes to `/var/log/nginx/ntlm_access.log` (errors go to `/var/log/nginx/ntlm_error.log`). Watch the handshakes:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```

To disable, remove the `access_log` / `error_log` lines from the NTLM location blocks in the Proxy Host advanced config.
