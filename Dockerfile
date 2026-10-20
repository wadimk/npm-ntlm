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
# (git и dos2unix не нужны: всё скачивается tarball'ами — git clone под
# QEMU-эмуляцией при мультиплатформенной сборке периодически падает по TLS)
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
	libmaxminddb-dev \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

# Релизный tarball OpenResty с openresty.org (уже содержит все компоненты,
# в отличие от GitHub-тега не требует шага mirror-tarballs) и tarball'ы модулей.
# Берём форк greetoz: в нём исправления очереди кэшированных
# соединений (флаг in_queue) сверх оригинала gabihodoroaga/nginx-ntlm-module.
RUN wget "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" -O "openresty-${OPENRESTY_VERSION}.tar.gz" \
	&& tar -xzf "openresty-${OPENRESTY_VERSION}.tar.gz" \
	&& mv "/tmp/openresty-${OPENRESTY_VERSION}" /tmp/openresty \
	&& wget -qO- "https://codeload.github.com/leev/ngx_http_geoip2_module/tar.gz/refs/heads/master" | tar -xz \
	&& mv /tmp/ngx_http_geoip2_module-master /tmp/ngx_http_geoip2_module \
	&& wget -qO- "https://codeload.github.com/greetoz/nginx-ntlm-module/tar.gz/refs/heads/master" | tar -xz \
	&& mv /tmp/nginx-ntlm-module-master /tmp/nginx-ntlm-module

# Аргументы configure повторяют официальную сборку nginx-full один в один
# (плюс --add-dynamic-module для NTLM), чтобы модуль был совместим.
RUN cd /tmp/openresty \
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
	--add-dynamic-module=/tmp/ngx_http_geoip2_module \
	--add-dynamic-module=/tmp/nginx-ntlm-module

# Пытаемся собрать только динамические модули (быстро);
# если не получилось — собираем всё, как делает официальная сборка.
RUN cd /tmp/openresty \
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

# Шаблоны конфигов Exchange и сидер Proxy Host (через API NPM).
# http_top.conf.template вшит в образ: entrypoint восстановит его в
# /data/nginx/custom/, если в томе его нет (например, после чистой установки).
COPY advanced-custom-nginx.conf.template /templates/advanced-custom-nginx.conf.template
COPY data/nginx/custom/http_top.conf.template /templates/http_top.conf.template
COPY seed-proxy-host.sh /usr/local/bin/seed-proxy-host.sh

# TLS-политика: intermediate-набор Mozilla + CBC-сьюты из списка Microsoft 365
# (переопределяет файл образа nginx-full, глобально для всех Proxy Hosts)
COPY ssl-ciphers.conf /etc/nginx/conf.d/include/ssl-ciphers.conf

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh /usr/local/bin/seed-proxy-host.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
