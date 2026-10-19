# syntax=docker/dockerfile:1

# Самый свежий официальный образ Nginx Proxy Manager
ARG NPM_IMAGE=jc21/nginx-proxy-manager:2.16.0
# Версия OpenResty должна совпадать с той, что в базовом образе
# nginxproxymanager/nginx-full:certbot-node (см. docker/docker-bake.hcl
# в репозитории NginxProxyManager/docker-nginx-full)
ARG OPENRESTY_VERSION=1.31.1.1

#############
# Сборка NTLM-модуля под ту же версию OpenResty
#############

FROM debian:trixie-slim AS ntlm-builder

ARG OPENRESTY_VERSION
ENV OPENRESTY_VERSION=${OPENRESTY_VERSION}

# Тот же набор зависимостей, что и у официальной сборки nginx-full
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
	build-essential \
	ca-certificates \
	libncurses-dev \
	libpcre2-dev \
	libreadline-dev \
	libssl-dev \
	openssl unzip \
	wget \
	zlib1g-dev \
	git \
	libmaxminddb-dev \
	dos2unix \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# Исходники OpenResty (по тегу на GitHub, как в официальном build-openresty.sh)
# и NTLM-модуль. Берём форк greetoz: в нём исправления очереди кэшированных
# соединений (флаг in_queue) сверх оригинала gabihodoroaga/nginx-ntlm-module.
RUN wget "https://github.com/openresty/openresty/archive/refs/tags/v${OPENRESTY_VERSION}.tar.gz" -O "openresty-${OPENRESTY_VERSION}.tar.gz" \
	&& tar -xzf "openresty-${OPENRESTY_VERSION}.tar.gz" \
	&& mv "/tmp/openresty-${OPENRESTY_VERSION}" /tmp/openresty \
	&& git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git \
	&& mv /tmp/ngx_http_geoip2_module /tmp/openresty/ngx_http_geoip2_module \
	&& git clone --depth 1 https://github.com/greetoz/nginx-ntlm-module.git \
	&& mv /tmp/nginx-ntlm-module /tmp/openresty/nginx-ntlm-module

# Makefile верхнего уровня скачивает собственно бандл OpenResty
RUN cd /tmp/openresty && make

# Аргументы configure повторяют официальную сборку nginx-full один в один
# (плюс --add-dynamic-module для NTLM), чтобы модуль был совместим.
RUN cd "/tmp/openresty/openresty-${OPENRESTY_VERSION}" \
	&& ./configure \
	--prefix=/etc/nginx \
	--sbin-path=/usr/sbin/nginx \
	--modules-path=/usr/lib/nginx/modules \
	--conf-path=/etc/nginx/nginx.conf \
	--error-log-path=/var/log/nginx/error.log \
	--http-log-path=/var/log/nginx/access.log \
	--pid-path=/var/run/nginx.pid \
	--lock-path=/var/run/nginx.lock \
	--http-client-body-temp-path=/var/cache/nginx/client_temp \
	--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
	--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
	--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
	--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
	--user=nginx \
	--group=nginx \
	--with-compat \
	--with-threads \
	--with-http_addition_module \
	--with-http_auth_request_module \
	--with-http_dav_module \
	--with-http_flv_module \
	--with-http_gunzip_module \
	--with-http_gzip_static_module \
	--with-http_mp4_module \
	--with-http_random_index_module \
	--with-http_realip_module \
	--with-http_secure_link_module \
	--with-http_slice_module \
	--with-http_ssl_module \
	--with-http_stub_status_module \
	--with-http_sub_module \
	--with-http_v2_module \
	--with-mail \
	--with-mail_ssl_module \
	--with-stream \
	--with-stream_realip_module \
	--with-stream_ssl_module \
	--with-stream_ssl_preread_module \
	--with-http_v3_module \
	--add-dynamic-module=/tmp/openresty/ngx_http_geoip2_module \
	--add-dynamic-module=/tmp/openresty/nginx-ntlm-module

# Пытаемся собрать только динамические модули (быстро);
# если не получилось — собираем всё, как делает официальная сборка.
RUN cd "/tmp/openresty/openresty-${OPENRESTY_VERSION}" \
	&& (make -C build/nginx-* modules || make -j"$(nproc)") \
	&& find /tmp/openresty -name ngx_http_upstream_ntlm_module.so -exec cp {} /ngx_http_upstream_ntlm_module.so \;

#############
# Финальный образ: свежий официальный NPM + NTLM-модуль
#############

FROM ${NPM_IMAGE}

COPY --from=ntlm-builder /ngx_http_upstream_ntlm_module.so /usr/lib/nginx/modules/ngx_http_upstream_ntlm_module.so

# nginx.conf NPM подключает /etc/nginx/modules/*.conf — модуль загрузится при старте
RUN mkdir -p /etc/nginx/modules \
	&& echo 'load_module /usr/lib/nginx/modules/ngx_http_upstream_ntlm_module.so;' > /etc/nginx/modules/ntlm.conf

# Обёртка entrypoint: рендерит шаблоны конфигов (envsubst) перед запуском /init
RUN apt-get update \
	&& apt-get install -y --no-install-recommends gettext-base \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
