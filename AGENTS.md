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
                                  через envsubst (переменная EXCHANGE_FQDN), затем exec /init
docker-compose.yml              — единственный сервис `app`: build ., образ npm-ntlm:latest,
                                  порты 80/81/443, тома ./data и ./letsencrypt,
                                  environment EXCHANGE_FQDN (из .env)
.env.example                    — пример переменных окружения (копируется в .env)
data/nginx/custom/http_top.conf.template — шаблон upstream exch_ntlm с директивой ntlm;
                                  из него при старте генерируется http_top.conf, который NPM
                                  автоматически включает в начало глобального блока http {}
advanced-custom-nginx.conf      — шаблон для вставки в UI: Proxy Host -> Advanced ->
                                  Custom Nginx Configuration (порт 81)
README.md                       — основная инструкция (английский): плейсхолдеры,
                                  настройка UI, PowerShell-команды для Exchange, диагностика
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
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.example.com/npm-ntlm:latest --push .      # публикация в registry
```

Валидировать `docker-compose.yml` локально: `docker compose config -q` (требуется установленный Docker).

## Тестирование

Автотестов нет. Проверка — эксплуатационная:

1. `nginx -t` внутри контейнера после изменений конфигов.
2. `https://owa.example.com/owa` — при включённой HMA открывается страница входа Microsoft 365, а не NTLM-диалог.
3. Outlook/ActiveSync подключаются через NTLM и Autodiscover.

Типовые симптомы сбоев описаны в разделе «Диагностика» README.md (циклические редиректы, 400/502, пустая страница после входа, NTLM-диалог).

## Правила внесения изменений

- Комментарии в конфигах и документация — на русском (английские пометки вроде `# buffering and timeouts` уже встречаются в `advanced-custom-nginx.conf` — допустимо, но предпочтителен русский).
- Конфиги содержат плейсхолдеры, которые пользователь заменяет вручную — не заменять их конкретными значениями:
  - `${EXCHANGE_FQDN}` — внутренний FQDN Exchange 2019 в `data/nginx/custom/http_top.conf.template`; подставляется через переменную окружения `EXCHANGE_FQDN` (см. `.env.example`) либо вручную в сгенерированном `http_top.conf`;
  - `exchange.internal.example.com` — тот же FQDN в `advanced-custom-nginx.conf` (там env недоступен, конфиг хранится в базе NPM);
  - `owa.example.com` — публичный FQDN OWA/ECP;
  - `autodiscover.example.com` — публичный FQDN Autodiscover.
- При обновлении версии NPM в `Dockerfile` (ARG `NPM_IMAGE`) обязательно сверять ARG `OPENRESTY_VERSION` с версией OpenResty внутри нового образа (`docker run --rm jc21/nginx-proxy-manager:<тег> nginx -v`) — модуль собирается под конкретную версию, при рассинхроне nginx не загрузит .so.
- `http_top.conf.template` и `advanced-custom-nginx.conf` связаны: location-блоки в Advanced-конфиге проксируют на upstream `exch_ntlm`, объявленный в шаблоне. Изменения должны оставаться согласованными.
- Публикация образа в registry — только мультиплатформенной сборкой (`linux/amd64` + `linux/arm64`) через `docker buildx build --push`; одноархитектурный образ в registry не пушить. Учитывать, что на Apple Silicon сборка amd64 идёт через QEMU и существенно дольше нативной.
- При изменении структуры репозитория, плейсхолдеров или процедуры настройки — синхронно обновлять разделы «Structure» и «FQDN configuration» в README.md (английский, основной) и «Структура» / «Настройка FQDN» в README.ru.md (README двуязычный, версии должны совпадать по содержанию).

## Замечания по безопасности

- NPM после первого запуска доступен на порту 81 с учётными данными по умолчанию `admin@example.com` / `changeme` — пароль нужно сразу сменить (см. README.md).
- В репозитории не хранить реальные FQDN, IP-адреса, сертификаты и учётные данные — только плейсхолдеры.
- Каталог `./letsencrypt` монтируется в контейнер, но в репозиторий не входит; сертификаты туда не коммитить.
- Для NTLM location-блоков критичны `proxy_http_version 1.1` и пустой заголовок `Connection` — удаление сломает NTLM-аутентификацию. В OWA/ECP-блоках заголовок `Authorization` намеренно обрезается (`proxy_set_header Authorization "";`) — это осознанное решение, а не ошибка.
