# AGENTS.md

Файл предназначен для AI-агентов, работающих с этим репозиторием. Основной язык проекта — русский: комментарии в конфигах, AGENTS.md и сообщения пишутся по-русски. Исключение — README: основной `README.md` на английском, русская версия — `README.ru.md`.

## Обзор проекта

Это не программный проект, а конфигурационный стек: готовое развёртывание Nginx Proxy Manager (NPM) с вкомпилированным NTLM-модулем для проксирования Microsoft Exchange 2019 (OWA/ECP, EWS, ActiveSync, Autodiscover, MAPI over HTTP, RPC). Стандартный образ NPM не содержит NTLM-модуля, поэтому NTLM-рукопожатие обрывается и клиенты Exchange (Outlook, ActiveSync и т.д.) перестают работать. Подробности — в `README.md`.

Используется локальная сборка (см. `Dockerfile`): свежий официальный образ `jc21/nginx-proxy-manager` (сейчас тег `2.16.0`) плюс NTLM-модуль, собранный из форка [greetoz/nginx-ntlm-module](https://github.com/greetoz/nginx-ntlm-module) (в нём фиксы сверх оригинала gabihodoroaga) под ту же версию OpenResty, что в базовом образе NPM (`nginxproxymanager/nginx-full`, сейчас OpenResty 1.31.1.1). Версии заданы ARG в шапке `Dockerfile`. Сборка сделана по статье: https://blog.cortanadesign.com.au/2025/09/10/how_to_get_exchange_2019_working_behind_nginx_proxy_manager

## Структура репозитория

```
Dockerfile                      — многоступенчатая сборка: компиляция NTLM-модуля
                                  под версию OpenResty базового образа NPM + копирование
                                  .so и load_module в официальный образ NPM
docker-entrypoint.sh            — обёртка entrypoint: рендерит http_top.conf из шаблона
                                  через envsubst (переменная EXCHANGE_FQDN), запускает
                                  в фоне seed-proxy-host.sh, затем exec /init
seed-proxy-host.sh              — сидер: при NPM_SEED_PROXY_HOST=true создаёт Proxy Host
                                  для Exchange через API NPM (http://127.0.0.1:81/api,
                                  логин по INITIAL_ADMIN_*); идемпотентен — пропускает,
                                  если хост с OWA_FQDN уже существует
docker-compose.yml              — единственный сервис `app`: build ., образ npm-ntlm:latest,
                                  порты 80/81/443, тома ./data и ./letsencrypt,
                                  environment EXCHANGE_FQDN, INITIAL_ADMIN_*,
                                  NPM_SEED_PROXY_HOST, OWA_FQDN, AUTODISCOVER_FQDN (из .env)
.env.example                    — пример переменных окружения (копируется в .env)
data/nginx/custom/http_top.conf.template — шаблон upstream exch_ntlm с директивой ntlm;
                                  из него при старте генерируется http_top.conf, который NPM
                                  автоматически включает в начало глобального блока http {}.
                                  Шаблон также вшит в образ (/templates/http_top.conf.template):
                                  entrypoint восстанавливает его в том, если файла там нет
advanced-custom-nginx.conf.template — шаблон Advanced-конфига хоста с плейсхолдерами
                                  ${EXCHANGE_FQDN} и ${OWA_FQDN}; вшивается в образ
                                  (/templates/), рендерится сидером через envsubst либо
                                  вручную для вставки в UI: Proxy Host -> Advanced (порт 81)
ssl-ciphers.conf                — TLS-политика, вшивается в образ поверх одноимённого файла
                                  nginx-full (глобально для всех хостов): TLS 1.2/1.3,
                                  набор Mozilla-intermediate + CBC-сьюты из списка
                                  Microsoft 365 (для старых клиентов Schannel)
README.md                       — основная инструкция (английский): плейсхолдеры,
                                  настройка UI, PowerShell-команды для Exchange, диагностика
Test-ExchangeProxy.ps1          — PowerShell-скрипт сквозной валидации снаружи: DNS,
                                  TLS/RSA-сертификат, edge-харденинг (403 на /powershell и
                                  /ecp), Autodiscover POST с разбором XML-ответа
README.ru.md                    — русская версия README.md
.github/workflows/docker-publish.yml — CI: мультиплатформенная сборка и пуш
                                  vkosin/npm-ntlm:latest в Docker Hub при пуше в main
                                  (секреты DOCKERHUB_USERNAME / DOCKERHUB_TOKEN)
```

Нет исходного кода приложения, тестов и менеджеров пакетов — только Dockerfile, конфигурация nginx, Docker Compose и CI-workflow.

## Команды

```bash
docker compose up -d --build                            # сборка образа и запуск стека
docker exec -it nginxproxymanager_app_1 nginx -t        # проверка конфига nginx
docker exec -it nginxproxymanager_app_1 tail -f /var/log/nginx/ntlm_access.log  # NTLM-логи (после включения)
envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' \
  < advanced-custom-nginx.conf.template                 # ручной рендер Advanced-конфига
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.example.com/npm-ntlm:latest --push .      # публикация в registry
```

Валидировать `docker-compose.yml` локально: `docker compose config -q` (требуется установленный Docker).

## Тестирование

Автотестов нет. Проверка — эксплуатационная:

1. `nginx -t` внутри контейнера после изменений конфигов.
2. `https://owa.example.com/owa` — при включённой HMA открывается страница входа Microsoft 365, а не NTLM-диалог.
3. Outlook/ActiveSync подключаются через NTLM и Autodiscover.
4. Autodiscover: первый ответ 401 с `WWW-Authenticate: Basic, Negotiate, NTLM` — норма (этап согласования аутентификации). Аутентифицированный прогон: `curl --ntlm -u 'user:pass' https://autodiscover.example.com/Autodiscover/Autodiscover.xml` — финальный статус ≠ 401 означает, что NTLM прошёл; рукопожатия видны в `/var/log/nginx/ntlm_access.log`.

Типовые симптомы сбоев описаны в разделе «Диагностика» README.md (циклические редиректы, 400/502, пустая страница после входа, NTLM-диалог).

## Правила внесения изменений

- Комментарии в конфигах и документация — на русском (английские пометки вроде `# buffering and timeouts` уже встречаются в `advanced-custom-nginx.conf.template` — допустимо, но предпочтителен русский).
- Конфиги содержат плейсхолдеры — не заменять их конкретными значениями:
  - `${EXCHANGE_FQDN}` — внутренний FQDN Exchange 2019; в `data/nginx/custom/http_top.conf.template` и в `advanced-custom-nginx.conf.template`. Подставляется через env `EXCHANGE_FQDN`: первый рендерит entrypoint при старте, второй — сидер (`seed-proxy-host.sh`) через envsubst либо пользователь вручную перед вставкой в UI;
  - `${OWA_FQDN}` — публичный FQDN OWA/ECP в `advanced-custom-nginx.conf.template`; подставляется сидером из env `OWA_FQDN` либо вручную;
  - `autodiscover.example.com` — публичный FQDN Autodiscover (только в примерах документации; реальное значение — env `AUTODISCOVER_FQDN`, необязательна: если пуста, Proxy Host создаётся только с `OWA_FQDN`).
- Сидер (`seed-proxy-host.sh`) работает через API NPM на `http://127.0.0.1:81/api` (на порт 3000 backend не отвечает). Payload создания Proxy Host строго по схеме NPM 2.16: лишние поля (например, `custom_ssl_redirect`) API отвергает с "must NOT have additional properties". Сертификат LE и Force SSL сидер НЕ запрашивает — это ручной шаг в UI. Сидер create-only: существующий хост (проверка по `OWA_FQDN`) никогда не обновляет — изменение env после сидирования применяется только удалением хоста в UI и рестартом контейнера. Пустой `AUTODISCOVER_FQDN` означает «без autodiscover» (домен не добавляется).
- При обновлении версии NPM в `Dockerfile` (ARG `NPM_IMAGE`) обязательно сверять ARG `OPENRESTY_VERSION` с версией OpenResty внутри нового образа (`docker run --rm jc21/nginx-proxy-manager:<тег> nginx -v`) — модуль собирается под конкретную версию, при рассинхроне nginx не загрузит .so.
- `http_top.conf.template` и `advanced-custom-nginx.conf.template` связаны: location-блоки в Advanced-конфиге проксируют на upstream `exch_ntlm`, объявленный в шаблоне. Изменения должны оставаться согласованными.
- Публикация образа в registry — только мультиплатформенной сборкой (`linux/amd64` + `linux/arm64`) через `docker buildx build --push`; одноархитектурный образ в registry не пушить. Учитывать, что на Apple Silicon сборка amd64 идёт через QEMU и существенно дольше нативной.
- При изменении структуры репозитория, плейсхолдеров или процедуры настройки — синхронно обновлять разделы «Structure» и «FQDN configuration» в README.md (английский, основной) и «Структура» / «Настройка FQDN» в README.ru.md (README двуязычный, версии должны совпадать по содержанию).

## Замечания по безопасности

- В свежих версиях NPM (включая 2.16) дефолтный админ `admin@example.com` / `changeme` НЕ создаётся: при первом запуске на пустой базе UI показывает setup wizard, а для автоматизации есть env `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` (действуют только на пустую таблицу пользователей). На существующей базе NPM их игнорирует, но сидер (`seed-proxy-host.sh`) использует их для логина в API — там должны быть креды реального администратора. Реальный пароль не хранить в репозитории — только через `.env`.
- В репозитории не хранить реальные FQDN, IP-адреса, сертификаты и учётные данные — только плейсхолдеры.
- Каталог `./letsencrypt` монтируется в контейнер, но в репозиторий не входит; сертификаты туда не коммитить.
- Для NTLM location-блоков критичны `proxy_http_version 1.1` и пустой заголовок `Connection` — удаление сломает NTLM-аутентификацию. Они выставляются только per-location: в общем блоке Advanced-конфига их быть не должно — NPM 2.16 сам генерирует эти директивы на уровне `server {}`, а дубликат даёт `nginx: [emerg] duplicate ... directive`. В OWA-блоке заголовок `Authorization` намеренно обрезается (`proxy_set_header Authorization "";`) — это осознанное решение, а не ошибка. `/powershell` и `/ecp` закрыты (403) намеренно — харденинг edge'а; не открывать без явного запроса пользователя.
- Сертификат LE для Exchange-хоста выпускать с Key Type: RSA: все TLS 1.2-сьюты из списка Microsoft 365 — `ECDHE-RSA-*`, с ECDSA-сертификатом общих сьютов на TLS 1.2 нет (работает только TLS 1.3). CBC-сьюты в `ssl-ciphers.conf` — осознанное расширение под старые клиенты Schannel, не удалять.
