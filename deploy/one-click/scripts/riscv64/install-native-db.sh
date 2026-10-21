#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Install MySQL 8.4 + Redis natively on a riscv64 host, then initialize them for
# CubeSandbox. MySQL is pulled from the XuanTie apt source (174) by default; the
# Redis deb stays local. This is Strategy B of the riscv64 data
# plane (see deploy/one-click/env.riscv64.example): CubeSandbox then connects via
# CUBE_EXTERNAL_MYSQL_* / CUBE_EXTERNAL_REDIS_* and install.sh skips the bundled
# docker-compose mysql/redis/minio services.
#
# WHY native and not a container: the Yocto MySQL 8.4.11 riscv64 deb links
# against OpenSSL 3.4 (libcrypto3/libssl3 >= 3.4.0) and glibc >= 2.38. A riscv64
# Yocto rootfs already provides those exact libs; a generic ubuntu:24.04 base
# (OpenSSL 3.0) does not. Installing natively on the Yocto-built host avoids the
# dependency mismatch entirely.
#
# Run as root ON THE RISCV64 HOST (e.g. the L1 testbed). MySQL is fetched from the
# XuanTie apt source (174) over the network; the Redis deb must already be present
# on that host (copy it via the 9p share / scp first).
#
# Usage:
#   # default: pull MySQL from the 174 apt source
#   sudo REDIS_DEB=/path/redis_8.10.0-r0_riscv64.deb bash install-native-db.sh
#   # offline: use a local MySQL deb instead
#   sudo MYSQL_DEB=/path/mysql_8.4.11-r0_riscv64.deb \
#        REDIS_DEB=/path/redis_8.10.0-r0_riscv64.deb bash install-native-db.sh
#
# Env:
#   XUANTIE_APT_URL  174 rva23 common feed (default release/1.4.0); MySQL pull source
#   MYSQL_PKG        apt package name to install (default: mysql)
#   DEB_DIR          optional dir of dependency debs for the OFFLINE MYSQL_DEB path
#                    (`dpkg -i "$DEB_DIR"/*.deb`); unneeded when pulling from 174
#                    since apt resolves deps from the same feed.
set -euo pipefail

log() { printf '[install-native-db] %s\n' "$*" >&2; }
die() { printf '[install-native-db] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "must run as root"
[[ "$(uname -m)" == "riscv64" ]] || die "this script targets riscv64 hosts (found $(uname -m))"
command -v dpkg >/dev/null 2>&1 || die "dpkg not found"

MYSQL_DEB="${MYSQL_DEB:-}"          # optional: local deb for offline install
REDIS_DEB="${REDIS_DEB:-}"
DEB_DIR="${DEB_DIR:-}"
XUANTIE_APT_URL="${XUANTIE_APT_URL:-http://114.55.254.174/xuantie/deb/release/1.4.0/kernel_6.6/rva23/common}"
MYSQL_PKG="${MYSQL_PKG:-mysql}"
MYSQL_APT_LIST="${MYSQL_APT_LIST:-/etc/apt/sources.list.d/xuantie-rva23.list}"

# Cube DB credentials — must match env.riscv64.example / CUBE_EXTERNAL_*.
MYSQL_DB="${CUBE_EXTERNAL_MYSQL_DB:-cube_mvp}"
MYSQL_USER="${CUBE_EXTERNAL_MYSQL_USER:-cube}"
MYSQL_PASSWORD="${CUBE_EXTERNAL_MYSQL_PASSWORD:-cube_pass}"
MYSQL_ROOT_PASSWORD="${CUBE_EXTERNAL_MYSQL_ROOT_PASSWORD:-cube_root}"
REDIS_PASSWORD="${CUBE_EXTERNAL_REDIS_PASSWORD:-ceuhvu123}"

[[ -z "${MYSQL_DEB}" || -f "${MYSQL_DEB}" ]] || die "MYSQL_DEB set but not a file: '${MYSQL_DEB}'"
[[ -n "${REDIS_DEB}" && -f "${REDIS_DEB}" ]] || die "REDIS_DEB not set or not a file: '${REDIS_DEB}'"

# ── 1. Install dependency debs first (if provided), then MySQL + Redis ────────
if [[ -n "${DEB_DIR}" && -d "${DEB_DIR}" ]]; then
  log "installing dependency debs from ${DEB_DIR}"
  dpkg -i "${DEB_DIR}"/*.deb 2>&1 | tail -5 || true
  apt-get -f install -y 2>/dev/null || true
fi

if [[ -n "${MYSQL_DEB}" ]]; then
  log "installing MySQL from local deb (offline): ${MYSQL_DEB}"
  dpkg -i "${MYSQL_DEB}" 2>&1 | tail -5 || die "dpkg -i MySQL failed (are its library deps present? pass DEB_DIR=...)"
  apt-get -f install -y 2>/dev/null || true
else
  log "pulling MySQL from 174 apt source: ${XUANTIE_APT_URL}"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; set MYSQL_DEB=/path/to.deb for offline install"
  printf 'deb [trusted=yes] %s ./\n' "${XUANTIE_APT_URL}" > "${MYSQL_APT_LIST}"
  apt-get update 2>&1 | tail -4 || true   # tolerate unrelated/broken host sources
  apt-get install -y "${MYSQL_PKG}" 2>&1 | tail -10 || die "apt-get install ${MYSQL_PKG} from 174 failed"
fi
log "installing Redis: ${REDIS_DEB}"
dpkg -i "${REDIS_DEB}" 2>&1 | tail -5 || die "dpkg -i Redis failed"

command -v mysqld >/dev/null 2>&1 || die "mysqld not on PATH after install"
command -v redis-server >/dev/null 2>&1 || die "redis-server not on PATH after install"
log "mysqld: $(mysqld --version 2>&1 | head -1)"
log "redis-server: $(redis-server --version 2>&1 | head -1)"

# ── 2. Initialize MySQL data directory (first run only) ───────────────────────
MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
MYSQL_CONF="${MYSQL_CONF:-/etc/my.cnf.d/cube.cnf}"
mkdir -p "$(dirname "${MYSQL_CONF}")" "${MYSQL_DATADIR}"

# MySQL 8.4 removed --default-authentication-plugin (and caching_sha2_password is
# the built-in default). The CubeSandbox DSN uses plain TCP with no TLS and no
# allowPublicKeyRetrieval, so the cube user must use mysql_native_password. Enable
# the plugin server-side here; the users are created explicitly WITH
# mysql_native_password below, so no server default-plugin knob is needed.
if [[ ! -f "${MYSQL_CONF}" ]]; then
  log "writing ${MYSQL_CONF}"
  cat > "${MYSQL_CONF}" <<'CNF'
[mysqld]
# Enable mysql_native_password (disabled by default in MySQL 8.4) so the
# CubeSandbox TCP/no-TLS DSN can authenticate.
mysql_native_password=ON
skip-name-resolve
datadir=/var/lib/mysql
socket=/var/run/mysqld/mysqld.sock
bind-address=127.0.0.1
CNF
fi

if [[ ! -d "${MYSQL_DATADIR}/mysql" ]]; then
  log "initializing MySQL datadir at ${MYSQL_DATADIR} (insecure bootstrap)"
  mkdir -p /var/run/mysqld
  mysqld --initialize-insecure --user=root --datadir="${MYSQL_DATADIR}" >&2
else
  log "MySQL datadir already initialized; skipping --initialize"
fi

# ── 3. Start mysqld, create users/db ─────────────────────────────────────────
start_mysqld() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^mysqld\|^mysql\.service'; then
    systemctl start mysqld 2>/dev/null || systemctl start mysql 2>/dev/null || true
  fi
  if ! mysqladmin ping --silent 2>/dev/null; then
    log "starting mysqld directly (no systemd unit)"
    mkdir -p /var/run/mysqld
    nohup mysqld --user=root --datadir="${MYSQL_DATADIR}" \
      --socket=/var/run/mysqld/mysqld.sock --bind-address=127.0.0.1 \
      >/var/log/cube-mysqld.log 2>&1 &
  fi
  local i=0
  until mysqladmin ping --silent 2>/dev/null; do
    i=$((i+1)); [[ ${i} -ge 60 ]] && die "mysqld did not become ready (see /var/log/cube-mysqld.log)"
    sleep 1
  done
  log "mysqld ready after ${i}s"
}
start_mysqld

log "creating database + users (mysql_native_password)"
mysql --protocol=socket --socket=/var/run/mysqld/mysqld.sock -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\` CHARACTER SET utf8mb4;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
log "MySQL users/db ready (db=${MYSQL_DB} user=${MYSQL_USER})"

# ── 4. Configure + start Redis with requirepass ──────────────────────────────
REDIS_CONF="${REDIS_CONF:-/etc/redis/cube-redis.conf}"
mkdir -p "$(dirname "${REDIS_CONF}")" /var/lib/cube-redis
if [[ ! -f "${REDIS_CONF}" ]]; then
  log "writing ${REDIS_CONF}"
  cat > "${REDIS_CONF}" <<RCNF
bind 127.0.0.1
port 6379
requirepass ${REDIS_PASSWORD}
dir /var/lib/cube-redis
daemonize no
RCNF
fi
if ! redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
  log "starting redis-server"
  nohup redis-server "${REDIS_CONF}" >/var/log/cube-redis.log 2>&1 &
  local_i=0
  until redis-cli -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG; do
    local_i=$((local_i+1)); [[ ${local_i} -ge 30 ]] && die "redis did not become ready (see /var/log/cube-redis.log)"
    sleep 1
  done
  log "redis ready after ${local_i}s"
fi

# ── 5. Verify ────────────────────────────────────────────────────────────────
log "verifying MySQL auth as ${MYSQL_USER} over TCP"
mysql -h127.0.0.1 -P3306 -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -e "SELECT VERSION();" "${MYSQL_DB}" >&2 \
  || die "MySQL TCP auth failed for ${MYSQL_USER}"
log "verifying Redis PING over TCP"
redis-cli -h 127.0.0.1 -p 6379 -a "${REDIS_PASSWORD}" ping 2>/dev/null | grep -q PONG \
  || die "Redis TCP PING failed"

cat >&2 <<DONE
[install-native-db] SUCCESS. Next: put these in your deployment .env
  CUBE_EXTERNAL_MYSQL_HOST=127.0.0.1
  CUBE_EXTERNAL_MYSQL_PORT=3306
  CUBE_EXTERNAL_MYSQL_USER=${MYSQL_USER}
  CUBE_EXTERNAL_MYSQL_PASSWORD=${MYSQL_PASSWORD}
  CUBE_EXTERNAL_MYSQL_DB=${MYSQL_DB}
  CUBE_EXTERNAL_REDIS_HOST=127.0.0.1
  CUBE_EXTERNAL_REDIS_PORT=6379
  CUBE_EXTERNAL_REDIS_PASSWORD=${REDIS_PASSWORD}
  CUBE_SANDBOX_MINIO_ENABLED=0
  CUBE_ARTIFACT_STORE_BACKEND=fs
  CUBE_OPS_STORE_BACKEND=fs
then run install.sh — it will skip the bundled docker-compose DB services.
DONE
