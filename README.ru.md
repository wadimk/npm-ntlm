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
                              (вшит в образ; entrypoint восстанавливает его в том при старте,
                              если файл отсутствует)
ssl-ciphers.conf              — TLS-политика, вшитая в образ (глобально): TLS 1.2/1.3,
                              Mozilla-intermediate + CBC-сьюты из списка Microsoft 365
advanced-custom-nginx.conf.template — шаблон Advanced-конфига хоста (вшит в образ,
                              рендерится через envsubst; применяется сидером или вставляется вручную)
Test-ExchangeProxy.ps1          — скрипт сквозной валидации: DNS, TLS/RSA-сертификат,
                              edge-харденинг, аутентифицированный Autodiscover POST
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
| `AUTODISCOVER_FQDN` | публичный FQDN Autodiscover (необязательно: если пуст — Proxy Host создаётся только с `OWA_FQDN`, без домена autodiscover и сертификата на него) |

При старте контейнера `seed-proxy-host.sh` ждёт backend NPM, авторизуется в API и создаёт Proxy Host: домен `OWA_FQDN` (плюс `AUTODISCOVER_FQDN`, если задан), HTTPS-проксирование на `EXCHANGE_FQDN:443`, с отрендеренным Advanced-конфигом (NTLM-локации и логирование уже внутри). Сидер идемпотентен — если Proxy Host с `OWA_FQDN` уже существует, он ничего не делает.

> Если Proxy Host был создан раньше **вручную** (например, со старым Advanced-конфигом, правленным руками), сидер его пропустит. Либо удалите хост в UI и перезапустите контейнер, либо вручную замените его Advanced-конфиг на свежеотрендеренный шаблон.

`INITIAL_ADMIN_*` работают в двух ролях. При **новой установке** (пустая база) NPM сам создаёт администратора с этими учётными данными — задайте их до самого первого старта, и мастера настройки не будет; сидер затем логинится теми же значениями, то есть всё совпадает по построению. На **существующей установке** NPM эти переменные игнорирует (админ уже есть), но сидер всё равно использует их для входа — поэтому туда нужно вписать реальные учётные данные администратора, под которым вы входите в UI.

Если сидер не сработал, ничего не ломается — NPM стартует как обычно, пропускается только автоматическое создание Proxy Host. Какая ветка случилась, видно в логе контейнера (`docker logs nginxproxymanager_app_1 | grep SEED`):

- `SEED: пропуск — не заданы переменные: ...` — не задана одна из обязательных переменных (например, `INITIAL_ADMIN_*`); сидер выходит сразу, без ожидания. При новой установке NPM тогда покажет мастер настройки, а Proxy Host создаётся вручную.
- `SEED: не удалось авторизоваться в API NPM ...` — учётные данные не совпадают с реальным администратором (типично для существующей базы); сидер пробует ~5 минут и сдаётся. На работу NPM это не влияет.
- Строк `SEED` нет совсем — `NPM_SEED_PROXY_HOST` не равен `true`, сидер не запускался.

Сертификат Let's Encrypt и **Force SSL** по-прежнему включаются вручную в UI (Hosts → Proxy Hosts → Edit → SSL) — после того как DNS всех доменов хоста указывает на NPM.

### Ручная вставка (запасной путь)

Отрендерьте шаблон и вставьте результат в Proxy Host → Advanced → Custom Nginx Configuration:

```bash
export EXCHANGE_FQDN=exchange.internal.example.com OWA_FQDN=owa.example.com
envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' < advanced-custom-nginx.conf.template
```

### Что входит в создаваемый конфиг

- `/` редиректит (302) на `/owa`; `/healthz` отдаёт `200 ok` для мониторинга;
- **HTTP/2 выключен** на создаваемом Proxy Host: NTLM привязан к TCP-соединению и поверх h2 ломается (curl молча скидывается на HTTP/1.1, WinHTTP/Outlook — нет; симптом: Outlook не подключается / крутит запрос пароля, хотя `curl --ntlm` работает);
- **`/powershell` и `/ecp` возвращают 403** — Remote PowerShell и админка Exchange не выставлены в интернет. Чтобы открыть ECP (например, только для своих IP), отредактируйте Advanced-конфиг по комментарию в шаблоне;
- каждая NTLM-локация пишет рукопожатия в `/var/log/nginx/ntlm_access.log` (см. «Логирование NTLM» ниже).

### Жизненный цикл сидера (что меняется при рестартах)

Сидер работает в режиме **только создание**: существование хоста проверяется по `OWA_FQDN`, и существующий Proxy Host никогда не изменяется — ваши правки в UI (сертификат, Force SSL, …) переживают рестарты.

- Изменение `AUTODISCOVER_FQDN` после сидирования (пусто → задан → другое значение → снова пусто) не меняет **ничего**: список доменов фиксируется при создании. Чтобы применить: удалите Proxy Host в UI и сделайте `docker compose restart` — сидер пересоздаст его с актуальными значениями (сертификат и Force SSL затем привяжите заново).
- Изменение `EXCHANGE_FQDN` применяется при рестарте лишь **частично**: upstream `exch_ntlm` в `http_top.conf` перерендеривается при каждом старте, но Advanced-конфиг в базе NPM хранит значение, подставленное при сидировании (`proxy_pass` в блоке `/owa/`). Пересоздайте хост или поправьте Advanced-конфиг в UI.
- Изменение `OWA_FQDN` создаёт **второй** Proxy Host вместо переименования старого — проверка существования привязана к этому значению.
- Сертификаты: Let's Encrypt проверяет по HTTP-01 **каждый** домен из `domain_names`. Если у любого домена (например, autodiscover) нет A-записи на хост NPM, весь выпуск падает с «Internal Error» — уже выпущенный сертификат при этом не страдает. Сначала создайте DNS-запись (`dig +short autodiscover.example.com @8.8.8.8`), потом запрашивайте сертификат.

### TLS и совместимость с Microsoft 365

По [документу Microsoft 365 про шифрование](https://learn.microsoft.com/en-us/purview/technical-reference-details-about-encryption) сторона Microsoft 365 говорит TLS 1.2/1.3 с фиксированным списком шифров — все TLS 1.2-сьюты там `ECDHE-RSA-*`. Образ выровнен под него:

- `ssl-ciphers.conf` (вшит в образ, глобально для всех Proxy Hosts) включает TLS 1.2 + 1.3 и расширяет стоковый набор Mozilla-intermediate сьютами `ECDHE-RSA-AES256-SHA384` / `ECDHE-RSA-AES128-SHA256` (CBC) — они нужны старым клиентам Schannel (старые Windows/Outlook) без AES-GCM. GCM-сьюты остаются приоритетными;
- **сертификат запрашивайте с Key Type: RSA** (селектор есть в форме выпуска сертификата в UI). С ECDSA-сертификатом ни один `ECDHE-RSA-*` сьют на TLS 1.2 не согласуется — останется только TLS 1.3, и старые клиенты не подключатся. Если сертификат уже выпущен как ECDSA: перевыпустите с RSA (UI → SSL Certificates → Add, затем привяжите к Proxy Host) — пересоздание хоста не требуется.

Проверка на живом хосте:

```bash
echo | openssl s_client -connect owa.example.com:443 -servername owa.example.com -tls1_2 \
  -cipher ECDHE-RSA-AES256-SHA384 2>/dev/null | grep 'Cipher is'   # должен показать сьют, а не 0000
```

## Обновление до новой версии NPM

В `Dockerfile` версии заданы аргументами в шапке:

- `NPM_IMAGE` — тег официального образа NPM (сейчас `jc21/nginx-proxy-manager:2.16.0`);
- `OPENRESTY_VERSION` — версия OpenResty из базового образа [nginx-full](https://github.com/NginxProxyManager/docker-nginx-full/blob/master/docker/docker-bake.hcl) (сейчас `1.31.1.1`); должна совпадать с той, что внутри образа NPM — проверить можно командой `docker run --rm --entrypoint nginx jc21/nginx-proxy-manager:<тег> -v`.

После изменения: `docker compose build --no-cache && docker compose up -d`.

Обе части обновления автоматизированы (см. «Docker Hub через GitHub Actions»): плановая пересборка раз в месяц подтягивает свежие слои базового образа и патчи ОС (`apt-get upgrade` в финальной стадии `Dockerfile`), а workflow `version-check` при выходе нового релиза NPM открывает PR с поднятием ARG — в описании PR перечислено, что проверить перед мерджем.

## Публикация в registry

Образы публикуются всегда мультиплатформенной сборкой (`linux/amd64` + `linux/arm64`), push идёт напрямую из buildx:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t registry.example.com/npm-ntlm:latest --push .
```

Учтите: на Apple Silicon сборка amd64 идёт через QEMU-эмуляцию и занимает заметно больше времени, чем нативная. `docker compose up -d --build` собирает только архитектуру текущего хоста — для локального стека это нормально, но одноархитектурный образ в registry не пушить.

### Docker Hub через GitHub Actions

При каждом пуше в `main` workflow `.github/workflows/docker-publish.yml` собирает обе платформы и пушит `vkosin/npm-ntlm:latest` в Docker Hub — локальная сборка не нужна. Разовая настройка: добавить в репозиторий секреты `DOCKERHUB_USERNAME` и `DOCKERHUB_TOKEN` (access token: hub.docker.com → Account Settings → Security).

Тот же workflow запускается и **по расписанию раз в месяц** (подтягивает свежие слои базового образа и патчи ОС через `apt-get upgrade` в `Dockerfile`), и на **pull request'ах** (только сборка, без пуша).

Отдельный workflow `.github/workflows/version-check.yml` раз в месяц проверяет свежие [релизы NPM](https://github.com/NginxProxyManager/nginx-proxy-manager/releases): при появлении нового определяет версию OpenResty внутри нового образа (`nginx -v`), поднимает оба ARG в `Dockerfile` и открывает pull request. GitHub не запускает workflow на PR, созданные от `GITHUB_TOKEN`, поэтому для автоматической сборки таких PR добавьте секрет `PAT_TOKEN` (classic PAT, scope `repo` + `workflow`) — либо стартуйте сборку вручную: закрыть/переоткрыть PR или запушить в его ветку.

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

Выровнять URL (пример с Exchange Management Shell): ExternalUrl — публичный FQDN за прокси, InternalUrl — внутренний FQDN Exchange (split-DNS не нужен):

```powershell
Set-OwaVirtualDirectory -Identity "EXCH01\owa (Default Web Site)" `
  -InternalUrl "https://exchange.internal.example.com/owa" `
  -ExternalUrl "https://owa.example.com/owa"

Set-EcpVirtualDirectory -Identity "EXCH01\ecp (Default Web Site)" `
  -InternalUrl "https://exchange.internal.example.com/ecp" `
  -ExternalUrl "https://owa.example.com/ecp"
```

Так же выровняйте URL остальных клиентских служб (иначе Autodiscover отвечает ошибками вида «No external URL is available to access this mailbox with Exchange ActiveSync»):

```powershell
$server  = "EXCH01"
$fqdn    = "owa.example.com"                    # публичный, за прокси
$intfqdn = "exchange.internal.example.com"      # внутренний FQDN Exchange

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

> При InternalUrl на внутренний FQDN клиенты из LAN ходят на Exchange напрямую — IIS-сертификат Exchange должен быть валиден для внутреннего имени (внутренний CA или уже доверенный). Если позже появится **split-DNS** (публичное имя внутри LAN резолвится на хост NPM), InternalUrl можно тоже перевести на публичный FQDN.

**Extended Protection должна быть `None`** на всех клиентских виртуальных каталогах. TLS терминируется на NPM, поэтому EPA-совместимый клиент (Windows Schannel: RCA, Windows Outlook) считает channel binding token от сертификата **прокси**, а Exchange проверяет его против **своего** IIS-сертификата → несовпадение → 401 после NTLM Type-3. Клиенты без EPA (curl, Mac Outlook) при `Allow` проскальзывают — обманчивый симптом: «curl работает, а Windows/RCA — нет»:

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

Это не ослабление безопасности в данной топологии: EP защищает TLS-ногу от MITM/relay, а эта нога терминируется на прокси.

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

### Проверка через Autodiscover

Самая информативная сквозная проверка URL на стороне Exchange — аутентифицированный Autodiscover POST снаружи (логин для NTLM — **UPN** `user@office.example.com` или `DOMAIN\user`; он может отличаться от SMTP-адреса ящика — SMTP-адрес указывается только в `EMailAddress` внутри XML):

```bash
printf '%s' '<?xml version="1.0" encoding="utf-8"?><Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006"><Request><EMailAddress>user@example.com</EMailAddress><AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema></Request></Autodiscover>' > /tmp/autod.xml

curl -s --ntlm -u 'DOMAIN\user' -H 'Content-Type: text/xml' \
  --data @/tmp/autod.xml https://autodiscover.example.com/Autodiscover/Autodiscover.xml
```

Ожидается: `200 OK` с `<Response>`, содержащим `<Account>` пользователя и блоки `<Protocol>`. На что смотреть:

- `EXPR → <Server>` должен быть **публичным** FQDN (`owa.example.com`). Если там внутренний FQDN — `Set-OutlookAnywhere -ExternalHostname` не применился, и внешний Outlook не подключится. Повторите командлет, сделайте `iisreset /noforce`, проверьте снова.
- `WEB/External → OWAUrl` и `EXPR → OABUrl` должны быть публичными URL; `EXCH → <Server>` в виде GUID ящика (`<guid>@example.com`) — норма для Exchange 2013+.
- `<ErrorCode>600</ErrorCode>` («Invalid Request») означает, что сломан сам XML-запрос (например, переносы строк внутри `EMailAddress` из-за копипасты) — аутентификация к этому моменту уже прошла.

## Проверка

- `https://owa.example.com/owa` — страница входа Microsoft 365 (при HMA), а не NTLM-диалог и не форма OWA.
- Outlook и ActiveSync подключаются через NTLM и Autodiscover.

### Автоматическая валидация (Test-ExchangeProxy.ps1)

`Test-ExchangeProxy.ps1` выполняет всю внешнюю проверку одним запуском (PowerShell 5.1+ / 7+): DNS-записи, рукопожатия TLS 1.2/1.3, RSA-сертификат (SAN, срок), edge-харденинг (`/healthz`, редирект `/` → `/owa`, 403 на `/powershell` и `/ecp/`, редирект http→https), auth-challenge на ActiveSync/Autodiscover и — с учётными данными — аутентифицированный Autodiscover POST с проверкой URL (EXPR/OWA) в ответе:

```powershell
.\Test-ExchangeProxy.ps1 -OwaFqdn owa.example.com -AutodiscoverFqdn autodiscover.example.com `
    -MailAddress user@example.com -ExpectedIp 203.0.113.10
```

NTLM-учётные данные спрашиваются интерактивно (UPN `user@office.example.com` или `DOMAIN\user` — не обязательно совпадает с SMTP-адресом). Каждая проверка печатает PASS/FAIL/SKIP; код выхода 0 — только когда нет ни одного FAIL.

### Autodiscover и NTLM-аутентификация

- «Голый» запрос к `https://autodiscover.example.com/Autodiscover/Autodiscover.xml`, отвечающий **401** с `WWW-Authenticate: Basic, Negotiate, NTLM` — это **ожидаемый первый этап**, а не ошибка: Exchange отвечает через прокси и предлагает методы аутентификации. Дальше клиент должен повторить запрос уже с учётными данными.
- Проверка аутентифицированного запроса снаружи (любой финальный статус, кроме 401 — обычно 400/405 для GET — означает, что NTLM-аутентификация прошла через прокси):

```bash
curl -v --ntlm -u 'user@example.com:ПАРОЛЬ' \
  https://autodiscover.example.com/Autodiscover/Autodiscover.xml -o /dev/null
```

- В Microsoft Connectivity Analyzer поле **User Name** — это UPN (`user@office.example.com`) или `DOMAIN\user`; он может отличаться от SMTP-адреса ящика, который указывается в поле **Email Address**. Если тест сообщает «failed to obtain an Autodiscover XML response» с 401 — сначала перепроверьте учётные данные; параллельно с повторным тестом смотрите рукопожатия в `ntlm_access.log` (см. «Логирование NTLM» ниже): последовательность 401 → 401 → 200/400 означает, что рукопожатие работает, тишина или обрыв после первого 401 — что нет.
- RCA всегда сначала пробует `https://<домен>/Autodiscover/...` и `https://www.<домен>/...`, прежде чем идти на `autodiscover.<домен>` — 404 там (ответ вашего обычного веб-сайта) — это ожидаемо и не является ошибкой; значение имеет только этап `autodiscover.<домен>`.

## Диагностика

- **Циклические редиректы** — URL виртуальных каталогов не совпадают с публичным DNS или неверные reply URL в Entra ID.
- **400/502** — используется стоковый образ NPM без NTLM-модуля.
- **Пустая страница после входа** — на каталогах остались включены legacy-методы аутентификации.
- **NTLM-диалог в браузере для OWA/ECP** — не включена HMA.
- **`host not found in upstream "exch_ntlm"` при сохранении Proxy Host** — отсутствует или не отрендерился `/data/nginx/custom/http_top.conf`: проверьте, что задан `EXCHANGE_FQDN`, и перезапустите контейнер (entrypoint сам восстановит шаблон из образа в том, если его там нет). Если переменная задана, а рендеринг пропущен, entrypoint пишет предупреждение в лог.
- **UI завис на "The API is not healthy" после чистого запуска** — миграции первого запуска занимают минуту-две; если дольше, смотрите лог контейнера: когда последние строки — `Fetching IP Ranges from online services...`, исходящий HTTPS до amazonaws.com/cloudflare.com висит (файрвол) и backend не начинает слушать порт. Отключите выгрузку переменной `IP_RANGES_FETCH_ENABLED=false` (она нужна только для Access Lists по диапазонам AWS/Cloudflare — для Exchange бесполезна).
- **Outlook не подключается / крутит запрос пароля, хотя `curl --ntlm` работает** — на Proxy Host включён HTTP/2: NTLM привязан к TCP-соединению и поверх h2 ломается (curl сам скидывается на HTTP/1.1, WinHTTP — нет). Лечение: правка хоста → снять галку **HTTP/2 Support** → Save (сидер создаёт новые хосты уже с выключенным h2).
- **401 после полностью завершённого NTLM-рукопожатия (curl и Mac Outlook работают, RCA / Windows Outlook получают 401)** — Extended Protection на каталогах Exchange не `None`: TLS терминируется на прокси, поэтому channel binding token клиента (от сертификата LE) никогда не совпадёт с IIS-сертификатом. Лечение: `ExtendedProtectionTokenChecking None` на всех клиентских vdir — см. «Настройка на стороне Exchange 2019».
- **502 на ActiveSync (FolderSync) спустя ~20с, при этом в IIS-логе тот же запрос завершён 200 с `time-taken` ≈ 20000 мс** — Exchange сам «висит» над запросом, а прокси его отсекает. Доказанная причина: отключённое наследование разрешений AD на учётке ящика (лог Application: «MSExchange ActiveSync doesn't have sufficient permissions to create the ... container» — типично после членства в защищённой группе; AdminSDHolder ломает наследование обратно раз в час). Лечение: включить наследование (`SetAccessRuleProtection($false,$true)` на ACL пользователя) и проверить транзитивное членство в защищённых группах. Nginx здесь ни при чём — сначала всегда смотрите `time-taken` в IIS-логе.
- **401 после NTLM Type-3 только на EWS/OAB, при рабочих Autodiscover/MAPI с теми же кредами; в IIS-логе `401 1 2148074248` (SEC_E_INVALID_TOKEN)** — регистр пути запроса (`/EWS/`, `/OAB/` — клиенты берут регистр из URL виртуальных каталогов Exchange) не совпал с case-sensitive префиксной локацией nginx, запрос обошёл NTLM-локацию и Type-3 ушёл по другому апстрим-соединению. Исправлено в шаблоне: все Exchange-локации — регистронезависимые regex (`location ~* ...`). Обновите Advanced-конфиг хоста.
- **Connection refused на всех портах (даже UI не открывается)** — `EXCHANGE_FQDN` не резолвится из контейнера: nginx падает при старте с `host not found in upstream "<fqdn>:443"` и вообще не запускается. Почините DNS для FQDN Exchange (или используйте IP) и перезапустите.

### Логирование NTLM

Логирование NTLM-рукопожатий включено из коробки: `log_format ntlm_log` объявлен в шаблоне upstream'а, а каждый NTLM location-блок в `advanced-custom-nginx.conf.template` пишет в `/var/log/nginx/ntlm_access.log` (ошибки — в `/var/log/nginx/ntlm_error.log`). В лог пишется только **схема** аутентификации (`auth="NTLM|Basic|Negotiate|Bearer"`), сам заголовок `Authorization` не логируется: Basic — это обратимый base64 логина и пароля (для глубокой отладки можно временно заменить `$auth_scheme` на `$http_authorization` в шаблоне — тогда лог считать секретом). Смотреть рукопожатия:

```bash
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log
```

Чтобы выключить — уберите строки `access_log` / `error_log` из NTLM location-блоков в Advanced-конфиге Proxy Host.

## Безопасность и мониторинг

Exchange за публичным reverse proxy — ценная цель: постоянный брутфорс паролей на Basic/NTLM-эндпоинтах (OWA, EWS, ActiveSync) и фоновый шум сканеров гарантированы. То, что fallback-сервер отвечает 404 на пробы `/phpunit/...` или `/device.rsp` на порту 80 — норма; важно лишь, чтобы там никогда не было 200.

### Чеклист харденинга

- **Админка NPM (порт 81)** никогда не публикуется в интернет — только LAN/VPN на файрволе. API — это пульт управления прокси.
- **`INITIAL_ADMIN_PASSWORD`** — убрать из `.env`/compose после создания администратора; любые учётные данные, попавшие в логи или переписку, считать скомпрометированными и сменить (Basic в неверно настроенном логе — это base64, то есть открытый текст).
- **`/powershell` и `/ecp` остаются закрытыми (403)** — уже в шаблоне. Если ECP открываете, поставьте перед ним **Access List** (allowlist по IP) средствами NPM.
- **HSTS** — после стабилизации HTTPS добавить в Advanced-конфиг хоста: `add_header Strict-Transport-Security "max-age=63072000" always;`
- **Rate limiting** на auth-эндпоинты — зону добавить в шаблон `http_top.conf`, ссылку — в NTLM-локации: `limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/s;` + `limit_req zone=auth burst=20 nodelay;`.
- **На самом Exchange**: выключить TLS 1.0/1.1 (IIS Crypto или реестр), своевременно ставить CU/SU Exchange и обновления Windows.
- **Обновления этого образа**: пересборка раз в месяц (`docker compose build --no-cache` подтянет патчи базового образа; CI пересобирает на каждый пуш в `main`). Следить за релизами [jc21/nginx-proxy-manager](https://github.com/NginxProxyManager/nginx-proxy-manager/releases) и поднимать ARG в `Dockerfile`.
- **Срок сертификатов**: логи продления LE — `/data/logs/letsencrypt*.log`; алерт, если сертификату осталось < 14 дней (`openssl s_client -connect owa.example.com:443 -servername owa.example.com 2>/dev/null | openssl x509 -enddate -noout`).

### Что мониторить

- **`/var/log/nginx/ntlm_access.log`** — основной источник. Брутфорс выглядит как пачка 401 с одного IP; чужие пути — разведка. Быстрые проверки:

  ```bash
  # топ IP по количеству 401
  docker exec -it nginxproxymanager_app_1 sh -c \
    "grep '\" 401 ' /var/log/nginx/ntlm_access.log | awk '{print \$1}' | sort | uniq -c | sort -rn | head"
  # запросы к не-Exchange путям
  docker exec -it nginxproxymanager_app_1 sh -c \
    "grep -v -Ei 'owa|/ews|autodiscover|/mapi|/rpc|activesync|/oab|/ecp|healthz' /var/log/nginx/ntlm_access.log | tail"
  ```

- **`/data/logs/fallback_*_access.log`** — шум сканеров; 200 здесь — красный флаг.
- **IIS-логи на Exchange** — все клиенты приходят с IP прокси. Чтобы видеть реальные адреса, добавьте поле `X-Forwarded-For` в настройки логирования IIS (IIS Manager → Logging → Select Fields) — прокси этот заголовок уже передаёт.
- **Журнал событий Windows** — 4624/4625 (успех/ошибка входа) по почтовым и сервисным учёткам, ошибки прав `MSExchange ActiveSync`, предупреждения IIS/WAS.
- **Доступность** — в шаблоне есть `/healthz` именно для этого: мониторьте `https://owa.example.com/healthz` снаружи (200 = прокси и конфиг хоста живы) с алертом на отказ; полезно дополнить проверкой 401 на `/Microsoft-Server-ActiveSync` (401 с challenge = auth-контур жив, всё остальное — беда).

### Fail2ban на Docker-хосте

NTLM-лог живёт внутри контейнера; чтобы скормить его fail2ban на хосте, либо перенаправьте пути логов в шаблоне на `/data/logs/` (том `./data`) — например `access_log /data/logs/ntlm_access.log ntlm_log;` — либо примонтируйте отдельный том на `/var/log/nginx`. Дальше:

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

Держите `maxretry` щадящим, а `findtime` длинным: Outlook с протухшим сохранённым паролем тоже генерирует пачки 401 — агрессивный бан заблокирует собственных пользователей. Альтернатива без настройки на хосте — rate limiting средствами nginx (см. выше).
