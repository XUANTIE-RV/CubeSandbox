#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the riscv64 MySQL image (Strategy A) from the Yocto-prebuilt deb.
# Redis and CoreDNS have official riscv64 images (redis:7-alpine,
# coredns/coredns:1.14.2) so they need no custom build — see env.riscv64.example.
#
# MUST run on a riscv64 Docker host (e.g. the L1 testbed) OR with buildx +
# qemu-user-static registered for linux/riscv64. It does NOT touch the build
# machine's architecture otherwise.
#
# Usage:
#   MYSQL_DEB_SRC=/abs/path/mysql_8.4.11-r0_riscv64.deb \
#   IMAGE_TAG=cube-sandbox-mysql:8.4-riscv64 \
#   [BASE_IMAGE=ubuntu:25.04] \
#     bash build-db-images-riscv64.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="$(cd "${SCRIPT_DIR}/../../images/mysql-riscv64" && pwd)"

log() { printf '[build-db-riscv64] %s\n' "$*" >&2; }
die() { printf '[build-db-riscv64] ERROR: %s\n' "$*" >&2; exit 1; }

MYSQL_DEB_SRC="${MYSQL_DEB_SRC:-}"
IMAGE_TAG="${IMAGE_TAG:-cube-sandbox-mysql:8.4-riscv64}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:25.04}"
PLATFORM="${PLATFORM:-linux/riscv64}"

command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -n "${MYSQL_DEB_SRC}" && -f "${MYSQL_DEB_SRC}" ]] || \
  die "MYSQL_DEB_SRC not set or not a file. Point it at the Yocto riscv64 deb, e.g.
  xuantie-build/repro-rva23/tmp-glibc/work/xt-c930v-cp-oe-linux/mysql/8.4.11-r0/deploy-debs/xt-c930v-cp/mysql_8.4.11-r0_riscv64.deb"

log "staging deb into build context: ${IMAGE_DIR}"
cp -f "${MYSQL_DEB_SRC}" "${IMAGE_DIR}/mysql_8.4.11-r0_riscv64.deb"

log "building ${IMAGE_TAG} (base=${BASE_IMAGE}, platform=${PLATFORM})"
docker build \
  --platform "${PLATFORM}" \
  --build-arg BASE_IMAGE="${BASE_IMAGE}" \
  --build-arg MYSQL_DEB=mysql_8.4.11-r0_riscv64.deb \
  -t "${IMAGE_TAG}" \
  "${IMAGE_DIR}"

# Don't leave the 40MB deb lying around in the source tree.
rm -f "${IMAGE_DIR}/mysql_8.4.11-r0_riscv64.deb"

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
