#!/usr/bin/env bash
# fetch_guest_assets_riscv64.sh -- obtain the two riscv64 guest assets that HAVE
# official public prebuilts (OpenSBI 1.7 fw_dynamic, Ubuntu riscv64 rootfs), using
# the SAME mechanism the x86-64 integration tests use (see
# run_integration_tests_x86_64.sh): plain `wget`/`curl` from official public
# sources, cached under $WORKLOADS_DIR with `if [ ! -f ]` guards, then post-process
# (extract / qemu-img convert) and verify.
#
# The Linux 7.2 guest kernel Image is NOT fetched here: kernel.org ships SOURCE
# ONLY for riscv64 (no prebuilt Image), so it is built IN-PLACE by
# build_guest_kernel_riscv64.sh (fetch v7.2 source -> apply the two CubeSandbox
# patches -> cross-compile). Call that script to produce ${WORKLOADS_DIR}/Image.
#
# This script does NOT build anything and does NOT need KVM -- it only proves the
# fetchable assets are intact and assembleable. Booting them and running
# snapshot/restore is run_c1_nested_riscv64.sh's job.
#
# VERIFIED public sources (all HTTP 200 as of authoring):
#   * OpenSBI 1.7 fw_dynamic (PREBUILT, official release asset):
#       https://github.com/riscv-software-src/opensbi/releases/download/v1.7/opensbi-1.7-rv-bin.tar.xz
#       -> extract opensbi-1.7-rv-bin/share/opensbi/lp64/generic/firmware/fw_dynamic.bin
#   * Ubuntu 24.04 (noble) riscv64 server cloud image (official Canonical):
#       https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-riscv64.img
#
# Optional env (verified public defaults; override to pin a mirror/version):
#   OPENSBI_URL               default: the v1.7 release tarball above
#   CUBE_RISCV64_ROOTFS_URL   default: the noble riscv64 cloudimg above
#   WORKLOADS_DIR             cache dir (default: $HOME/workloads)

set -euo pipefail

WORKLOADS_DIR="${WORKLOADS_DIR:-$HOME/workloads}"
mkdir -p "${WORKLOADS_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHA1SUMS="${SCRIPT_DIR}/sha1sums-riscv64"

# Official OpenSBI 1.7 prebuilt release asset (contains fw_dynamic.bin per platform).
OPENSBI_URL="${OPENSBI_URL:-https://github.com/riscv-software-src/opensbi/releases/download/v1.7/opensbi-1.7-rv-bin.tar.xz}"
OPENSBI_FW_RELPATH="share/opensbi/lp64/generic/firmware/fw_dynamic.bin"
# Official Canonical Ubuntu 24.04 (noble) riscv64 server cloud image.
DEFAULT_ROOTFS_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-riscv64.img"
ROOTFS_URL="${CUBE_RISCV64_ROOTFS_URL:-${DEFAULT_ROOTFS_URL}}"

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch <url> <dest>
  local url="$1" dest="$2"
  if [[ -f "${dest}" && -s "${dest}" ]]; then echo "cached: ${dest}"; return; fi
  echo "download: ${url}"
  if have wget; then ( cd "${WORKLOADS_DIR}" && wget --quiet "${url}" -O "$(basename "${dest}")" );
  elif have curl; then curl -fsSL "${url}" -o "${dest}";
  else die "neither wget nor curl available"; fi
  [[ -s "${dest}" ]] || die "downloaded file is empty: ${dest} (url=${url})"
}

# 1) firmware: OpenSBI 1.7 fw_dynamic.bin (extract from the official prebuilt tarball)
FW_DEST="${WORKLOADS_DIR}/fw_dynamic.bin"
if [[ ! -s "${FW_DEST}" ]]; then
  OPENSBI_TAR="${WORKLOADS_DIR}/$(basename "${OPENSBI_URL}")"
  fetch "${OPENSBI_URL}" "${OPENSBI_TAR}"
  echo "extract ${OPENSBI_FW_RELPATH}"
  tar -xf "${OPENSBI_TAR}" -C "${WORKLOADS_DIR}" "*/${OPENSBI_FW_RELPATH}" --wildcards 2>/dev/null \
    || tar -xf "${OPENSBI_TAR}" -C "${WORKLOADS_DIR}"
  found="$(find "${WORKLOADS_DIR}" -path "*/lp64/generic/firmware/fw_dynamic.bin" | head -1)"
  [[ -n "${found}" ]] && cp -f "${found}" "${FW_DEST}"
fi
[[ -s "${FW_DEST}" ]] || die "fw_dynamic.bin not obtained from OpenSBI 1.7 tarball"

# 2) rootfs: Ubuntu riscv64 cloud image -> raw (mirror x86 qemu-img convert step)
# The ~800MB qcow2 download sits INSIDE the guard: when ubuntu-riscv64.raw is
# already present (warm actions/cache) there is nothing to convert, so skip the
# download too -- re-fetching it every run defeats the cache.
ROOTFS_RAW="${WORKLOADS_DIR}/ubuntu-riscv64.raw"
if [[ ! -f "${ROOTFS_RAW}" ]]; then
  ROOTFS_DL="${WORKLOADS_DIR}/$(basename "${ROOTFS_URL}")"
  fetch "${ROOTFS_URL}" "${ROOTFS_DL}"
  case "${ROOTFS_DL}" in
    *.zip) ( cd "${WORKLOADS_DIR}" && unzip -o "${ROOTFS_DL}" )
           ROOTFS_DL="$(ls -1t "${WORKLOADS_DIR}"/*.qcow2 "${WORKLOADS_DIR}"/*.img 2>/dev/null | head -1)" ;;
  esac
  have qemu-img || die "qemu-img not found (install qemu-utils)"
  fmt="raw"; case "${ROOTFS_DL}" in *.qcow2|*.img) fmt="qcow2";; esac
  echo "qemu-img convert -f ${fmt} -O raw ${ROOTFS_DL} -> ${ROOTFS_RAW}"
  qemu-img convert -p -f "${fmt}" -O raw "${ROOTFS_DL}" "${ROOTFS_RAW}" || die "qemu-img convert failed"
fi

# 3) integrity: sha1sums-riscv64 (skip if it has no sum lines yet)
if [[ -s "${SHA1SUMS}" ]] && grep -qE '^[0-9a-f]{40}' "${SHA1SUMS}"; then
  echo "verifying sha1sums-riscv64"
  ( cd "${WORKLOADS_DIR}" && sha1sum -c --ignore-missing "${SHA1SUMS}" ) || die "sha1 verification failed"
else
  echo "note: ${SHA1SUMS} has no checksums yet -- skipping integrity check"
fi

# 4) assertions (the kernel Image is built separately by build_guest_kernel_riscv64.sh)
echo "=== assertions ==="
[[ -s "${FW_DEST}" ]] || die "fw_dynamic.bin missing/empty"
echo "  fw_dynamic.bin (opensbi 1.7): OK ($(stat -c%s "${FW_DEST}") bytes)"
[[ -s "${ROOTFS_RAW}" ]] || die "rootfs raw missing/empty"
qemu-img info "${ROOTFS_RAW}" >/dev/null 2>&1 || die "rootfs ${ROOTFS_RAW} not recognized by qemu-img"
echo "  rootfs (ubuntu noble riscv64): OK ($(stat -c%s "${ROOTFS_RAW}") bytes)"

echo "ASSET_DIR=${WORKLOADS_DIR}"
echo "riscv64 fetchable assets OK (opensbi 1.7 fw_dynamic + Ubuntu noble rootfs)."
echo "note: build the 7.2 guest kernel Image with build_guest_kernel_riscv64.sh (-> ${WORKLOADS_DIR}/Image)."
