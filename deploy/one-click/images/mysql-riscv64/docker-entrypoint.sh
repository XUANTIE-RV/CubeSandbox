#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Container entrypoint for the riscv64 MySQL 8.4 image (Strategy A).
# Initializes the datadir on first run, creates the CubeSandbox database/user
# with mysql_native_password (the CubeSandbox DSN uses plain TCP, no TLS, no
# allowPublicKeyRetrieval — caching_sha2_password would fail), then execs mysqld.
#
# Env (defaults match docker-compose.yaml.template placeholders):
#   MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD
set -euo pipefail

DATADIR=/var/lib/mysql
SOCK=/var/run/mysqld/mysqld.sock
mkdir -p /var/run/mysqld "${DATADIR}"

MYSQL_DATABASE="${MYSQL_DATABASE:-cube_mvp}"
MYSQL_USER="${MYSQL_USER:-cube}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-cube_pass}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-cube_root}"

if [[ ! -d "${DATADIR}/mysql" ]]; then
  echo "[cube-mysql] initializing datadir (insecure bootstrap)"
  mysqld --initialize-insecure --user=root --datadir="${DATADIR}"

  echo "[cube-mysql] starting temporary server to create users"
  mysqld --user=root --datadir="${DATADIR}" --socket="${SOCK}" \
    --skip-networking --mysql_native_password=ON &
  tmp_pid=$!
  for _ in $(seq 1 60); do
    mysqladmin ping --socket="${SOCK}" --silent 2>/dev/null && break
    sleep 1
  done

  mysql --socket="${SOCK}" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
ALTER USER '${MYSQL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  echo "[cube-mysql] users/db created; stopping temporary server"
  mysqladmin --socket="${SOCK}" -uroot -p"${MYSQL_ROOT_PASSWORD}" shutdown
  wait "${tmp_pid}" 2>/dev/null || true
fi

echo "[cube-mysql] starting mysqld (mysql_native_password=ON)"
exec mysqld --user=root --datadir="${DATADIR}" --socket="${SOCK}" \
  --mysql_native_password=ON --skip-name-resolve --bind-address=0.0.0.0 "$@"
