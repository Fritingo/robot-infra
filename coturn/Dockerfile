# 階段 1：從官方映像檔提取原版 entrypoint，確保啟動參數與環境變數 100% 相容
FROM coturn/coturn:4.6.2-alpine AS orig

# 階段 2：在最新受支援的 Alpine 上編譯 Coturn 4.6.2
FROM alpine:latest AS builder

ARG COTURN_VERSION=4.6.2

RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache \
      autoconf \
      automake \
      build-base \
      coreutils \
      curl \
      tar \
      libevent-dev \
      openssl-dev \
      sqlite-dev \
      postgresql-dev \
      mariadb-connector-c-dev \
      hiredis-dev \
      linux-headers

WORKDIR /tmp/coturn
RUN curl -fsSL "https://github.com/coturn/coturn/archive/refs/tags/${COTURN_VERSION}.tar.gz" \
    | tar -xz --strip-components=1 && \
    CFLAGS="-O2 -Wno-error" ./configure \
      --prefix=/usr/local \
      --confdir=/etc/coturn \
      --examplesdir=/usr/local/share/examples/coturn \
      --manprefix=/usr/local/share && \
    make -j"$(nproc)" && \
    make install

# 階段 3：最小化執行期映像檔（剔除 bind-libs、gnutls、libxml2 等多餘套件）
FROM alpine:latest

RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache \
      ca-certificates \
      bash \
      su-exec \
      libevent \
      libssl3 \
      libcrypto3 \
      sqlite-libs \
      libpq \
      mariadb-connector-c \
      hiredis && \
    addgroup -S turnserver && \
    adduser -S -G turnserver -H -h /var/lib/coturn turnserver && \
    mkdir -p /var/lib/coturn /etc/coturn && \
    chown -R turnserver:turnserver /var/lib/coturn /etc/coturn

COPY --from=builder /usr/local /usr/local
COPY --from=orig /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER turnserver

EXPOSE 3478 3478/udp 5349 5349/udp
VOLUME ["/var/lib/coturn"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["turnserver"]