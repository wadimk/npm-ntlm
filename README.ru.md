# NGINX Proxy Manager (NTLM) для Exchange 2019

Русский | **[English version](README.md)**

Сборка по статье: [How to Get Exchange 2019 Working Behind NGINX Proxy Manager](https://blog.cortanadesign.com.au/2025/09/10/how_to_get_exchange_2019_working_behind_nginx_proxy_manager).

Образ собирается локально (см. `Dockerfile`): свежий официальный [jc21/nginx-proxy-manager](https://hub.docker.com/r/jc21/nginx-proxy-manager) плюс open-source NTLM-модуль, скомпилированный под ту же версию OpenResty, что и в базовом образе NPM. Берётся форк модуля [greetoz/nginx-ntlm-module](https://github.com/greetoz/nginx-ntlm-module) — в нём исправления очереди кэшированных соединений сверх оригинала [gabihodoroaga/nginx-ntlm-module](https://github.com/gabihodoroaga/nginx-ntlm-module). Стандартный образ NPM без NTLM-модуля с Exchange не работает (NTLM-рукопожатие обрывается — ломаются Outlook, ActiveSync, Autodiscover, EWS, MAPI, RPC).

## Структура

```
Dockerfile                    — сборка: официальный NPM + NTLM-модуль
docker-entrypoint.sh          — рендерит http_top.conf из шаблона (envsubst) перед запуском NPM
docker-compose.yml            — стек NPM (собирается локально, образ npm-ntlm:latest)
.env.example                  — пример переменных окружения (скопировать в .env)
data/nginx/custom/http_top.conf.template — шаблон upstream exch_ntlm с включённым NTLM
advanced-custom-nginx.conf    — блок для вставки в UI: Proxy Host -> Advanced
```

## Настройка FQDN

**Внутренний FQDN Exchange** (upstream `exch_ntlm`) задаётся переменной окружения `EXCHANGE_FQDN` — скопируйте `.env.example` в `.env` и подставьте реальное значение (compose подхватывает `.env` автоматически). При старте контейнера `docker-entrypoint.sh` рендерит `data/nginx/custom/http_top.conf` из шаблона через `envsubst`. Если переменная не задана, при первом запуске шаблон копируется как есть и FQDN можно заменить прямо в `http_top.conf` вручную.

> Если `EXCHANGE_FQDN` задан, `http_top.conf` перезаписывается при каждом старте — правьте шаблон или переменную, а не сгенерированный файл.

**Остальные плейсхолдеры** (в `advanced-custom-nginx.conf` и при создании Proxy Host) переменными задать нельзя: этот конфиг хранится в базе NPM и вставляется через UI, поэтому заменяйте их вручную при вставке:

| Плейсхолдер | Что подставить |
|---|---|
| `exchange.internal.example.com` | внутренний FQDN сервера Exchange 2019 |
| `owa.example.com` | публичный FQDN для OWA/ECP |
| `autodiscover.example.com` | публичный FQDN Autodiscover (при создании Proxy Host) |

## Обновление до новой версии NPM

В `Dockerfile` версии заданы аргументами в шапке:

- `NPM_IMAGE` — тег официального образа NPM (сейчас `jc21/nginx-proxy-manager:2.16.0`);
- `OPENRESTY_VERSION` — версия OpenResty из базового образа [nginx-full](https://github.com/NginxProxyManager/docker-nginx-full/blob/master/docker/docker-bake.hcl) (сейчас `1.31.1.1`); должна совпадать с той, что внутри образа NPM — проверить можно командой `docker run --rm jc21/nginx-proxy-manager:<тег> nginx -v`.

После изменения: `docker compose build --no-cache && docker compose up -d`.

## Публикация в registry

Образы публикуются всегда мультиплатформенной сборкой (`linux/amd64` + `linux/arm64`), push идёт напрямую из buildx:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t registry.example.com/npm-ntlm:latest --push .
```

Учтите: на Apple Silicon сборка amd64 идёт через QEMU-эмуляцию и занимает заметно больше времени, чем нативная. `docker compose up -d --build` собирает только архитектуру текущего хоста — для локального стека это нормально, но одноархитектурный образ в registry не пушить.

### Docker Hub через GitHub Actions

При каждом пуше в `main` workflow `.github/workflows/docker-publish.yml` собирает обе платформы и пушит `vkosin/npm-ntlm:latest` в Docker Hub — локальная сборка не нужна. Разовая настройка: добавить в репозиторий секреты `DOCKERHUB_USERNAME` и `DOCKERHUB_TOKEN` (access token: hub.docker.com → Account Settings → Security).

## Запуск

```bash
docker compose up -d --build
```

Проверка конфига nginx внутри контейнера:

```bash
docker exec -it nginxproxymanager_app_1 nginx -t
```

## Настройка в веб-интерфейсе

1. Откройте `http://<host>:81`. При первом запуске на пустой базе свежие версии NPM показывают **мастер настройки** (setup wizard) — создайте учётную запись администратора в нём. Легаси-учётные данные `admin@example.com` / `changeme` автоматически больше не создаются; они появятся, только если задать `INITIAL_ADMIN_EMAIL` и `INITIAL_ADMIN_PASSWORD` (например, в `.env`) до самого первого старта.
2. Создайте Proxy Host:
   - **Domain Names:** `owa.example.com`, `autodiscover.example.com`
   - **Scheme:** HTTPS, **Forward Hostname/IP:** внутренний FQDN Exchange, **Port:** 443
   - **SSL:** сертификат Let's Encrypt, включить **Force SSL**
3. На вкладке **Advanced -> Custom Nginx Configuration** вставьте содержимое `advanced-custom-nginx.conf`.

Upstream из `http_top.conf` подхватывается NPM автоматически (файл включается в начало глобального блока `http {}`).

## Настройка на стороне Exchange 2019

Выровнять URL (пример с Exchange Management Shell):

```powershell
Set-OwaVirtualDirectory -Identity "EXCH01\owa (Default Web Site)" `
  -InternalUrl "https://owa.example.com/owa" `
  -ExternalUrl "https://owa.example.com/owa"

Set-EcpVirtualDirectory -Identity "EXCH01\ecp (Default Web Site)" `
  -InternalUrl "https://owa.example.com/ecp" `
  -ExternalUrl "https://owa.example.com/ecp"
```

Если включена гибридная конфигурация с Microsoft 365 — перевести OWA/ECP на Hybrid Modern Authentication (OAuth), отключив legacy-методы:

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

> Без гибрида с Entra ID HMA недоступна: OWA/ECP останутся на NTLM — браузер будет показывать системный диалог ввода логина/пароля. Это ожидаемо.

Проверка:

```powershell
Get-OwaVirtualDirectory -Server "EXCH01" | fl server,*auth*
Get-EcpVirtualDirectory -Server "EXCH01" | fl server,*auth*
```

## Проверка

- `https://owa.example.com/owa` — страница входа Microsoft 365 (при HMA), а не NTLM-диалог и не форма OWA.
- Outlook и ActiveSync подключаются через NTLM и Autodiscover.

## Диагностика

- **Циклические редиректы** — URL виртуальных каталогов не совпадают с публичным DNS или неверные reply URL в Entra ID.
- **400/502** — используется стоковый образ NPM без NTLM-модуля.
- **Пустая страница после входа** — на каталогах остались включены legacy-методы аутентификации.
- **NTLM-диалог в браузере для OWA/ECP** — не включена HMA.
- **`host not found in upstream "exch_ntlm"` при сохранении Proxy Host** — отсутствует или не отрендерился `/data/nginx/custom/http_top.conf`: проверьте, что в томе `data/nginx/custom/` есть шаблон `http_top.conf.template` и задан `EXCHANGE_FQDN`, затем перезапустите контейнер. Если переменная задана, а шаблона нет, entrypoint пишет предупреждение в лог.

### Логирование NTLM

Раскомментируйте `log_format ntlm_log` в `http_top.conf` (или в шаблоне `http_top.conf.template`, если используете `EXCHANGE_FQDN`) и добавьте в NTLM location-блоки:

```
access_log /var/log/nginx/ntlm_access.log ntlm_log;
error_log  /var/log/nginx/ntlm_error.log warn;
```

Затем:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```
