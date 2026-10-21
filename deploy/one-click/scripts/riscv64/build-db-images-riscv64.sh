#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the riscv64 MySQL image (Strategy A). The MySQL 8.4.11 riscv64 deb is
# pulled from the XuanTie apt source (174) by default; set MYSQL_DEB_SRC to a
# local deb for offline/air-gapped builds.
# Redis and CoreDNS have official riscv64 images (redis:7-alpine,
# coredns/coredns:1.14.2) so they need no custom build — see env.riscv64.example.
#
# MUST run on a riscv64 Docker host (e.g. the L1 testbed) OR with buildx +
# qemu-user-static registered for linux/riscv64. It does NOT touch the build
# machine's architecture otherwise.
#
# Usage:
#   # default: pull the deb from the 174 apt source
#   IMAGE_TAG=cube-sandbox-mysql:8.4-riscv64 [BASE_IMAGE=ubuntu:25.04] \
#     bash build-db-images-riscv64.sh
#   # offline: use a local deb instead
#   MYSQL_DEB_SRC=/abs/path/mysql_8.4.11-r0_riscv64.deb bash build-db-images-riscv64.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="$(cd "${SCRIPT_DIR}/../../images/mysql-riscv64" && pwd)"

log() { printf '[build-db-riscv64] %s\n' "$*" >&2; }
die() { printf '[build-db-riscv64] ERROR: %s\n' "$*" >&2; exit 1; }

MYSQL_DEB_NAME="mysql_8.4.11-r0_riscv64.deb"
# XuanTie apt source (174) — the mysql deb is pulled from here by default.
XUANTIE_APT_URL="${XUANTIE_APT_URL:-http://114.55.254.174/xuantie/deb/release/1.4.0/kernel_6.6/rva23/common}"
MYSQL_DEB_URL="${MYSQL_DEB_URL:-${XUANTIE_APT_URL}/${MYSQL_DEB_NAME}}"
MYSQL_DEB_SRC="${MYSQL_DEB_SRC:-}"   # optional offline override (local deb)
IMAGE_TAG="${IMAGE_TAG:-cube-sandbox-mysql:8.4-riscv64}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:25.04}"
PLATFORM="${PLATFORM:-linux/riscv64}"

command -v docker >/dev/null 2>&1 || die "docker not found"

DEST="${IMAGE_DIR}/${MYSQL_DEB_NAME}"
if [[ -n "${MYSQL_DEB_SRC}" ]]; then
  [[ -f "${MYSQL_DEB_SRC}" ]] || die "MYSQL_DEB_SRC set but not a file: ${MYSQL_DEB_SRC}"
  log "using local deb (offline override): ${MYSQL_DEB_SRC}"
  cp -f "${MYSQL_DEB_SRC}" "${DEST}"
else
  log "pulling mysql deb from 174 apt source: ${MYSQL_DEB_URL}"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "${DEST}" "${MYSQL_DEB_URL}" || die "wget failed: ${MYSQL_DEB_URL}"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "${DEST}" "${MYSQL_DEB_URL}" || die "curl failed: ${MYSQL_DEB_URL}"
  else
    die "need wget or curl to pull ${MYSQL_DEB_URL} (or set MYSQL_DEB_SRC=/path/to.deb for offline build)"
  fi
fi
log "staged deb into build context: ${DEST}"

log "building ${IMAGE_TAG} (base=${BASE_IMAGE}, platform=${PLATFORM})"
docker build \
  --platform "${PLATFORM}" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg MYSQL_DEB="${MYSQL_DEB_NAME}" \
  -t "${IMAGE_TAG}" \
  "${IMAGE_DIR}"

# Don't leave the 40MB deb lying around in the source tree.
rm -f "${DEST}"

log "built ${IMAGE_TAG}"
docker image inspect "${IMAGE_TAG}" --format 'arch={{.Architecture}} os={{.Os}} size={{.Size}}' >&2 || true

cat >&2 <<DONE
[build-db-riscv64] Done. To use it (Strategy A), set in your .env:
  CUBE_SANDBOX_MYSQL_IMAGE=${IMAGE_TAG}
  CUBE_SANDBOX_MYSQL_COMMAND=["--mysql-native-password=ON", "--skip-name-resolve"]
  CUBE_SANDBOX_REDIS_IMAGE=redis:7-alpine
and comment out the CUBE_EXTERNAL_MYSQL_* / CUBE_EXTERNAL_REDIS_* block.
(Redis/CoreDNS use official riscv64 images; no custom build needed.)
DONE
