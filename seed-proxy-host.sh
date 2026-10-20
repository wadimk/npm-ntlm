#!/bin/bash
# Сидирование Proxy Host для Exchange через API NPM.
# Запускается entrypoint'ом в фоне при каждом старте контейнера.
# Работает, только если NPM_SEED_PROXY_HOST=true и заданы все нужные
# переменные; идемпотентен: если Proxy Host с OWA_FQDN уже есть — выходит.

set -u

if [ "${NPM_SEED_PROXY_HOST:-false}" != "true" ]; then
	exit 0
fi

MISSING=""
for v in EXCHANGE_FQDN OWA_FQDN INITIAL_ADMIN_EMAIL INITIAL_ADMIN_PASSWORD; do
	eval "val=\${$v:-}"
	if [ -z "$val" ]; then
		MISSING="$MISSING $v"
	fi
done
if [ -n "$MISSING" ]; then
	echo "SEED: пропуск — не заданы переменные:$MISSING" >&2
	exit 0
fi

AUTODISCOVER_FQDN="${AUTODISCOVER_FQDN:-autodiscover.${OWA_FQDN#*.}}"
# API backend'а доступен через nginx на 81 порту (на 3000 он не отвечает)
API=http://127.0.0.1:81/api

# Ждём backend NPM и создание первого администратора (он создаётся
# асинхронно из INITIAL_ADMIN_*), максимум ~5 минут.
TOKEN=""
for _ in $(seq 1 60); do
	TOKEN=$(curl -sf -X POST "$API/tokens" -H 'Content-Type: application/json' \
		-d "{\"identity\":\"${INITIAL_ADMIN_EMAIL}\",\"secret\":\"${INITIAL_ADMIN_PASSWORD}\"}" \
		| jq -r '.token // empty' 2>/dev/null) || TOKEN=""
	[ -n "$TOKEN" ] && break
	sleep 5
done

if [ -z "$TOKEN" ]; then
	echo "SEED: не удалось авторизоваться в API NPM (backend не поднялся или неверные INITIAL_ADMIN_*)" >&2
	exit 0
fi

# Идемпотентность: не создаём хост повторно.
EXISTS=$(curl -sf "$API/nginx/proxy-hosts" -H "Authorization: Bearer $TOKEN" \
	| jq --arg d "$OWA_FQDN" '[.[] | select(.domain_names | index($d))] | length')
if [ "${EXISTS:-0}" != "0" ]; then
	echo "SEED: Proxy Host для $OWA_FQDN уже существует — пропуск"
	exit 0
fi

ADVANCED=$(envsubst '${EXCHANGE_FQDN} ${OWA_FQDN}' < /templates/advanced-custom-nginx.conf.template)

RESPONSE=$(jq -n \
	--arg owa "$OWA_FQDN" \
	--arg ad "$AUTODISCOVER_FQDN" \
	--arg fwd "$EXCHANGE_FQDN" \
	--arg adv "$ADVANCED" \
	'{
		domain_names: [$owa, $ad],
		forward_scheme: "https",
		forward_host: $fwd,
		forward_port: 443,
		caching_enabled: false,
		block_exploits: true,
		allow_websocket_upgrade: true,
		access_list_id: 0,
		certificate_id: 0,
		ssl_forced: false,
		http2_support: true,
		hsts_enabled: false,
		hsts_subdomains: false,
		meta: { letsencrypt_agree: false, dns_challenge: false },
		advanced_config: $adv,
		locations: []
	}' \
	| curl -sf -X POST "$API/nginx/proxy-hosts" -H "Authorization: Bearer $TOKEN" \
		-H 'Content-Type: application/json' -d @- \
	| jq -r '.id // empty' 2>/dev/null) || RESPONSE=""

if [ -n "$RESPONSE" ]; then
	echo "SEED: создан Proxy Host #$RESPONSE ($OWA_FQDN, $AUTODISCOVER_FQDN -> $EXCHANGE_FQDN)"
	echo "SEED: сертификат Let's Encrypt и Force SSL включите в UI (Hosts -> Proxy Hosts -> Edit -> SSL)"
else
	echo "SEED: не удалось создать Proxy Host — см. лог backend" >&2
fi
