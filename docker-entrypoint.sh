#!/bin/bash
set -e

# Обёртка над стандартным entrypoint NPM (/init): перед запуском рендерит
# nginx-конфиги из шаблонов, подставляя переменные окружения.

TEMPLATE=/data/nginx/custom/http_top.conf.template
TARGET=/data/nginx/custom/http_top.conf

if [ -n "${EXCHANGE_FQDN:-}" ] && [ -f "$TEMPLATE" ]; then
	# EXCHANGE_FQDN задан: рендерим шаблон. TARGET перезаписывается при каждом
	# старте — правьте шаблон или переменную, а не сгенерированный файл.
	echo "Рендеринг $TARGET (EXCHANGE_FQDN=${EXCHANGE_FQDN})"
	envsubst '${EXCHANGE_FQDN}' < "$TEMPLATE" > "$TARGET"
elif [ -n "${EXCHANGE_FQDN:-}" ]; then
	# Переменная задана, а шаблона нет (например, в /data примонтирован
	# неполный репозиторий) — предупреждаем, иначе рендеринг молча не случится.
	echo "ВНИМАНИЕ: EXCHANGE_FQDN задан, но шаблон $TEMPLATE не найден — рендеринг пропущен, используется $TARGET как есть" >&2
elif [ ! -f "$TARGET" ] && [ -f "$TEMPLATE" ]; then
	# Первый запуск без переменной: кладём шаблон как есть (с плейсхолдером),
	# чтобы было что править вручную.
	cp "$TEMPLATE" "$TARGET"
fi

# Сидирование Proxy Host для Exchange через API NPM (в фоне; само решит,
# нужно ли что-то делать — см. seed-proxy-host.sh).
/usr/local/bin/seed-proxy-host.sh &

exec /init "$@"
