# NGINX Proxy Manager (NTLM) для Exchange 2019

Русский | **[English version](README.md)**

Сборка по статье: [How to Get Exchange 2019 Working Behind NGINX Proxy Manager](https://blog.cortanadesign.com.au/2025/09/10/how_to_get_exchange_2019_working_behind_nginx_proxy_manager).

Образ собирается локально (см. `Dockerfile`): свежий официальный [jc21/nginx-proxy-manager](https://hub.docker.com/r/jc21/nginx-proxy-manager) плюс open-source NTLM-модуль, скомпилированный под ту же версию OpenResty, что и в базовом образе NPM. Берётся форк модуля [greetoz/nginx-ntlm-module](https://github.com/greetoz/nginx-ntlm-module) — в нём исправления очереди кэшированных соединений сверх оригинала [gabihodoroaga/nginx-ntlm-module](https://github.com/gabihodoroaga/nginx-ntlm-module). Стандартный образ NPM без NTLM-модуля с Exchange не работает (NTLM-рукопожатие обрывается — ломаются Outlook, ActiveSync, Autodiscover, EWS, MAPI, RPC).

## Структура

```
Dockerfile                    — сборка: официальный NPM + NTLM-модуль
docker-entrypoint.sh          — рендерит http_top.conf из шаблона (envsubst) перед запуском NPM
seed-proxy-host.sh            — необязательно: создаёт Proxy Host для Exchange через API NPM при первом старте
docker-compose.yml            — стек NPM (собирается локально, образ npm-ntlm:latest)
.env.example                  — пример переменных окружения (скопировать в .env)
data/nginx/custom/http_top.conf.template — шаблон upstream exch_ntlm с включённым NTLM
advanced-custom-nginx.conf.template — шаблон Advanced-конфига хоста (вшит в образ,
                              рендерится через envsubst; применяется сидером или вставляется вручную)
```

## Настройка FQDN

**Внутренний FQDN Exchange** (upstream `exch_ntlm`) задаётся переменной окружения `EXCHANGE_FQDN` — скопируйте `.env.example` в `.env` и подставьте реальное значение (compose подхватывает `.env` автоматически). При старте контейнера `docker-entrypoint.sh` рендерит `data/nginx/custom/http_top.conf` из шаблона через `envsubst`. Если переменная не задана, при первом запуске шаблон копируется как есть и FQDN можно заменить прямо в `http_top.conf` вручную.

> Если `EXCHANGE_FQDN` задан, `http_top.conf` перезаписывается при каждом старте — правьте шаблон или переменную, а не сгенерированный файл.

**Публичные FQDN и Advanced-конфиг хоста** находятся в `advanced-custom-nginx.conf.template`, где используются два плейсхолдера: `${EXCHANGE_FQDN}` (внутренний FQDN Exchange) и `${OWA_FQDN}` (публичный FQDN OWA/ECP). Применить шаблон можно двумя способами:

### Автоматическое создание Proxy Host (рекомендуется)

Задайте в `.env` (в дополнение к `EXCHANGE_FQDN`):

| Переменная | Назначение |
|---|---|
| `NPM_SEED_PROXY_HOST=true` | включить сидер |
| `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` | первый администратор (нужен для входа в API; действует только на пустую базу) |
| `OWA_FQDN` | публичный FQDN OWA/ECP |
| `AUTODISCOVER_FQDN` | публичный FQDN Autodiscover (по умолчанию `autodiscover.<домен OWA_FQDN>`) |

При старте контейнера `seed-proxy-host.sh` ждёт backend NPM, авторизуется в API и создаёт Proxy Host: домены `OWA_FQDN` + `AUTODISCOVER_FQDN`, HTTPS-проксирование на `EXCHANGE_FQDN:443`, с отрендеренным Advanced-конфигом (NTLM-локации и логирование уже внутри). Сидер идемпотентен — если Proxy Host с `OWA_FQDN` уже существует, он ничего не делает.

> Если Proxy Host был создан раньше **вручную** (например, со старым Advanced-конфигом, правленным руками), сидер его пропустит. Либо удалите хост в UI и перезапустите контейнер, либо вручную замените его Advanced-конфиг на свежеотрендеренный шаблон.

`INITIAL_ADMIN_*` работают в двух ролях. При **новой установке** (пустая база) NPM сам создаёт администратора с этими учётными данными — задайте их до самого первого старта, и мастера настройки не будет; сидер затем логинится теми же значениями, то есть всё совпадает по построению. На **существующей установке** NPM эти переменные игнорирует (админ уже есть), но сидер всё равно использует их для входа — поэтому туда нужно вписать реальные учётные данные администратора, под которым вы входите в UI.

Если сидер не сработал, ничего не ломается — NPM стартует как обычно, пропускается только автоматическое создание Proxy Host. Какая ветка случилась, видно в логе контейнера (`docker logs nginxproxymanager_app_1 | grep SEED`):

- `SEED: пропуск — не заданы переменные: ...` — не задана одна из обязательных переменных (например, `INITIAL_ADMIN_*`); сидер выходит сразу, без ожидания. При новой установке NPM тогда покажет мастер настройки, а Proxy Host создаётся вручную.
- `SEED: не удалось авторизоваться в API NPM ...` — учётные данные не совпадают с реальным администратором (типично для существующей базы); сидер пробует ~5 минут и сдаётся. На работу NPM это не влияет.
- Строк `SEED` нет совсем — `NPM_SEED_PROXY_HOST` не равен `true`, сидер не запускался.

Сертификат Let's Encrypt и **Force SSL** по-прежнему включаются вручную в UI (Hosts → Proxy Hosts → Edit → SSL) — после того как DNS обоих FQDN указывает на хост NPM.

### Ручная вставка (запасной путь)

Отрендерьте шаблон и вставьте результат в Proxy Host → Advanced → Custom Nginx Configuration:

```bash
export EXCHANGE_FQDN=exchange.internal.example.com OWA_FQDN=owa.example.com
envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' < advanced-custom-nginx.conf.template
```

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
2. Создайте Proxy Host (при `NPM_SEED_PROXY_HOST=true` создаётся автоматически — см. выше):
   - **Domain Names:** `owa.example.com`, `autodiscover.example.com`
   - **Scheme:** HTTPS, **Forward Hostname/IP:** внутренний FQDN Exchange, **Port:** 443
3. На вкладке **Advanced -> Custom Nginx Configuration** вставьте отрендеренный `advanced-custom-nginx.conf.template` (сидер делает это автоматически).
4. Вкладка **SSL**: запросите сертификат Let's Encrypt и включите **Force SSL** — всегда вручную; оба FQDN уже должны резолвиться на хост NPM.

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

Логирование NTLM-рукопожатий включено из коробки: `log_format ntlm_log` объявлен в шаблоне upstream'а, а каждый NTLM location-блок в `advanced-custom-nginx.conf.template` пишет в `/var/log/nginx/ntlm_access.log` (ошибки — в `/var/log/nginx/ntlm_error.log`). Смотреть рукопожатия:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```

Чтобы выключить — уберите строки `access_log` / `error_log` из NTLM location-блоков в Advanced-конфиге Proxy Host.
