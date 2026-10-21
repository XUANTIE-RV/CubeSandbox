# SPDX-License-Identifier: Apache-2.0
#
# riscv64 MySQL 8.4 image for the CubeSandbox one-click data plane (Strategy A —
# compose parity; the RECOMMENDED riscv64 path is Strategy B, native install via
# scripts/riscv64/install-native-db.sh — see env.riscv64.example).
#
# There is no official riscv64 MySQL image, so we package the mysql_8.4.11
# riscv64 deb pulled from the XuanTie apt source (174) by the build script.
# That deb links OpenSSL 3.4 (libcrypto3/libssl3 >=
# 3.4.0), glibc >= 2.38, libstdc++6 >= 14.3 — so the BASE image must provide
# those. ubuntu:24.04 (OpenSSL 3.0) does NOT; use a base with OpenSSL 3.4.
# Override BASE_IMAGE if your registry mirrors a different one.
#
# Build on a riscv64 Docker host (e.g. the L1 testbed), or with buildx +
# qemu-user emulation:
#   docker build --platform linux/riscv64 \
#     --build-arg MYSQL_DEB=mysql_8.4.11-r0_riscv64.deb \
#     -t cube-sandbox-mysql:8.4-riscv64 .
# The MYSQL_DEB must be copied into this build context first (see
# scripts/riscv64/build-db-images-riscv64.sh).
ARG BASE_IMAGE=ubuntu:25.04
FROM ${BASE_IMAGE}

ARG MYSQL_DEB=mysql_8.4.11-r0_riscv64.deb
ARG DEBIAN_FRONTEND=noninteractive

COPY ${MYSQL_DEB} /tmp/${MYSQL_DEB}

RUN set -eux; \
    apt-get update; \
    # Install the deb; -f pulls any missing library deps from the base repo
    # (needs OpenSSL 3.4 + glibc 2.38+ + libstdc++6 14.3 in the base).
    dpkg -i /tmp/${MYSQL_DEB} || true; \
    apt-get -f install -y; \
    rm -f /tmp/${MYSQL_DEB}; \
    # Runtime tools used by the entrypoint/healthcheck.
    apt-get install -y --no-install-recommends curl netcat-openbsd; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /var/lib/mysql /var/run/mysqld; \
    chmod 0755 /var/run/mysqld

COPY docker-entrypoint.sh /usr/local/bin/cube-mysql-entrypoint.sh
RUN chmod +x /usr/local/bin/cube-mysql-entrypoint.sh

# Server config: enable mysql_native_password (off by default in 8.4) so the
# CubeSandbox TCP/no-TLS DSN can authenticate. MySQL 8.4 removed
# --default-authentication-plugin; users are created WITH mysql_native_password
# in the entrypoint instead, so no default-plugin knob is needed here.
RUN printf '%s\n' \
    '[mysqld]' \
    'mysql_native_password=ON' \
    'skip-name-resolve' \
    'datadir=/var/lib/mysql' \
    'socket=/var/run/mysqld/mysqld.sock' \
    'bind-address=0.0.0.0' \
    > /etc/my.cnf.d/cube.cnf || \
    { mkdir -p /etc/my.cnf.d && printf '%s\n' \
    '[mysqld]' \
    'mysql_native_password=ON' \
    'skip-name-resolve' \
    'datadir=/var/lib/mysql' \
    'socket=/var/run/mysqld/mysqld.sock' \
    'bind-address=0.0.0.0' \
    > /etc/my.cnf.d/cube.cnf; }

VOLUME /var/lib/mysql
EXPOSE 3306

ENV MYSQL_ROOT_PASSWORD=cube_root \
    MYSQL_DATABASE=cube_mvp \
    MYSQL_USER=cube \
    MYSQL_PASSWORD=cube_pass

HEALTHCHECK --interval=3s --timeout=3s --retries=20 \
  CMD mysqladmin ping -h 127.0.0.1 -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent || exit 1

ENTRYPOINT ["cube-mysql-entrypoint.sh"]
