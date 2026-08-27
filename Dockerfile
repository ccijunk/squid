# syntax=docker/dockerfile:1
#
# Squid v7.7.1 source-built image (v7 branch + PR 2401 "Bug 5538").
#
# Stage dependency chain:
#
#   ubuntu:24.04 (build)
#     └── build   # apt: autotools + compiler + dev libs
#                 #   sed configure.ac (version stamp) → ./bootstrap.sh
#                 #   → ./configure --with-openssl ... → make → make install
#                 #   → /usr/local/squid
#
#   squid (ubuntu:24.04)                    ← --target squid
#     ├── apt: runtime libs only (ca-certificates, libssl3, ...)
#     ├── COPY --from=build /usr/local/squid → /usr/local/squid
#     ├── COPY squid.conf, entrypoint.sh
#     ├── USER squid (uid 3128)
#     └── ENTRYPOINT ["/entrypoint.sh"]      # squid -z init then squid -N

# ---------------------------------------------------------------------------
# build: compile Squid from the patched v7 source
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

# Build-time dependencies: autotools (for ./bootstrap.sh), compiler, dev libs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        libcap-dev \
        libkrb5-dev \
        libldap2-dev \
        libltdl-dev \
        libpam0g-dev \
        libssl-dev \
        libtool \
        libtool-bin \
        libxml2-dev \
        perl \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Version stamping: bake the exact release number into configure.ac so that
# `squid -v` reports the tag version instead of "7.7-VCS".
ARG SQUID_VERSION=7.7.1

WORKDIR /src
COPY . .

RUN sed -i "s/\[7\.7-VCS\]/[${SQUID_VERSION}]/" configure.ac \
    && ./bootstrap.sh \
    && ./configure \
        --prefix=/usr/local/squid \
        --sysconfdir=/etc/squid \
        --datadir=/usr/local/squid/share \
        --localstatedir=/var \
        --with-default-user=squid \
        --with-openssl \
        --enable-ssl-crtd \
        --enable-linux-netfilter \
        --enable-async-io=8 \
        --enable-storeio=ufs,aufs,rock,null \
        --enable-removal-policies=lru,heap \
        --enable-epoll \
        --enable-poll \
        --enable-select \
        --enable-delay-pools \
        --enable-cache-digests \
        --enable-icap-client \
    && make -j"$(nproc)" \
    && make install

# ---------------------------------------------------------------------------
# squid: minimal runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS squid

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/squid/sbin:${PATH}"

# Runtime libraries only (no compiler / autotools).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libcap2 \
        libgssapi-krb5-2 \
        libkrb5-3 \
        libldap2 \
        libltdl7 \
        libpam0g \
        libssl3 \
        libxml2 \
        openssl \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the compiled Squid tree.
COPY --from=build /usr/local/squid /usr/local/squid

# Copy config files that `make install` placed into /etc/squid (mime table,
# documented config, default config).
COPY --from=build /etc/squid/mime.conf /etc/squid/mime.conf
COPY --from=build /etc/squid/squid.conf.default /etc/squid/squid.conf.default
COPY --from=build /etc/squid/squid.conf.documented /etc/squid/squid.conf.documented

# Unprivileged runtime user + state directories.
RUN groupadd --system --gid 31 squid \
    && useradd --system --gid 31 --uid 31 \
        --home-dir /var/cache/squid --shell /usr/sbin/nologin squid \
    && mkdir -p /var/cache/squid /var/log/squid /var/run/squid /etc/squid \
    && chown -R squid:squid /var/cache/squid /var/log/squid /var/run/squid

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && chown -R squid:squid /etc/squid

EXPOSE 3128

# Rootful: container process runs as root (root shell via `docker exec`).
# The squid daemon itself still drops to the unprivileged `squid` user —
# Squid 7 refuses to run the daemon as root.
USER root
ENTRYPOINT ["/entrypoint.sh"]
