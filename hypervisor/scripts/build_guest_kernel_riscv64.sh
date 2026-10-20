#!/usr/bin/env bash
# build_guest_kernel_riscv64.sh -- build the riscv64 Linux 7.2 guest kernel Image
# IN-PLACE, with no dependency on a pre-published Release asset.
#
# kernel.org ships SOURCE ONLY for riscv64 (no prebuilt Image), so the guest kernel
# is the one asset that must be built rather than wget'd. The other two riscv64
# guest assets (OpenSBI 1.7 fw_dynamic.bin and the Ubuntu noble riscv64 rootfs) DO
# have official public prebuilts and are fetched by fetch_guest_assets_riscv64.sh.
#
# This script is the SINGLE implementation of "fetch v7.2 source -> apply the two
# out-of-tree CubeSandbox patches -> cross-compile the PE/EFI-stub Image", shared by:
#   * .github/workflows/riscv64-snapshot-integration.yml (件 4: the C1 L1 host kernel
#     AND the L2 guest kernel -- one CONFIG_KVM=y Image serves both layers)
#   * .github/workflows/release-kernel.yml build_riscv64_guest leg (product Release)
#
# Building from source+patches every run also guarantees the KVM dirty-log backport
# (configs/patches/riscv64-kvm-zeropage-dirtylog.patch) is present, so -smp>1 in the
# C1 nested test is safe (without it the L2 write through a read-only ZERO_PAGE
# G-stage leaf corrupts the L1 empty_zero_page).
#
# Required toolchain on the build host (x86 cross-compiling to riscv64):
#   gcc-riscv64-linux-gnu + kernel build deps (build-essential bc bison flex
#   libelf-dev libssl-dev libncurses-dev dwarves cpio kmod rsync) + xz-utils + patch.
#   scripts/build-kernel.sh auto-selects CROSS_COMPILE=riscv64-linux-gnu- and errors
#   out if that compiler is not on PATH.
#
# Env (all optional):
#   KERNEL_SRC_URL     default https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz
#   OUTPUT_IMAGE       output Image path (default ${WORKLOADS_DIR:-$PWD}/Image)
#   WORKLOADS_DIR      base dir for the default OUTPUT_IMAGE (default $PWD)
#   KERNEL_BUILD_JOBS  parallel make jobs (default $(nproc))
#   KERNEL_CONFIG      guest .config (default <repo>/configs/kernel-oc9.riscv64.config)
#   KERNEL_SRC_DIR     reuse an existing PRISTINE v7.2 tree instead of downloading
#                      (it will still be patched in place; point at a throwaway copy)
#   WORK_DIR           scratch dir for download/extract/build (default: a mktemp dir)
#
# Output: a PE/EFI-stub Image (magic "MZ") at OUTPUT_IMAGE.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KERNEL_SRC_URL="${KERNEL_SRC_URL:-https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz}"
KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS:-$(nproc)}"
WORKLOADS_DIR="${WORKLOADS_DIR:-$PWD}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${WORKLOADS_DIR}/Image}"
KERNEL_CONFIG="${KERNEL_CONFIG:-${REPO_ROOT}/configs/kernel-oc9.riscv64.config}"
KERNEL_SRC_DIR="${KERNEL_SRC_DIR:-}"
BUILD_KERNEL_SH="${REPO_ROOT}/scripts/build-kernel.sh"

PATCHES=(
  "${REPO_ROOT}/configs/patches/riscv64-dax-zeropage-folio.patch"
  "${REPO_ROOT}/configs/patches/riscv64-kvm-zeropage-dirtylog.patch"
)

[ -f "${KERNEL_CONFIG}" ]  || die "kernel config not found: ${KERNEL_CONFIG}"
[ -f "${BUILD_KERNEL_SH}" ] || die "build-kernel.sh not found: ${BUILD_KERNEL_SH}"
for p in "${PATCHES[@]}"; do
  [ -f "${p}" ] || die "patch not found: ${p}"
done
command -v patch >/dev/null 2>&1 || die "patch(1) not installed"

WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
mkdir -p "${WORK_DIR}"

# 1) obtain a pristine v7.2 source tree
if [ -n "${KERNEL_SRC_DIR}" ]; then
  [ -f "${KERNEL_SRC_DIR}/Makefile" ] || die "KERNEL_SRC_DIR '${KERNEL_SRC_DIR}' is not a kernel tree (no Makefile)"
  echo "[kernel] reusing existing source tree: ${KERNEL_SRC_DIR}"
else
  tarball="${WORK_DIR}/linux-riscv64.tar.xz"
  echo "[kernel] download ${KERNEL_SRC_URL}"
  curl -fL "${KERNEL_SRC_URL}" -o "${tarball}"
  KERNEL_SRC_DIR="${WORK_DIR}/kernel-source"
  rm -rf "${KERNEL_SRC_DIR}"
  mkdir -p "${KERNEL_SRC_DIR}"
  echo "[kernel] extract -> ${KERNEL_SRC_DIR}"
  tar -xf "${tarball}" -C "${KERNEL_SRC_DIR}" --strip-components=1
  [ -f "${KERNEL_SRC_DIR}/Makefile" ] || die "extracted tree has no Makefile (bad archive layout?)"
fi

# 2) apply the two out-of-tree CubeSandbox patches (skip cleanly if already applied)
for p in "${PATCHES[@]}"; do
  echo "[kernel] === apply $(basename "${p}") ==="
  if patch -p1 -d "${KERNEL_SRC_DIR}" --dry-run --forward --no-backup-if-mismatch < "${p}" >/dev/null 2>&1; then
    patch -p1 -d "${KERNEL_SRC_DIR}" --forward --no-backup-if-mismatch < "${p}"
  else
    # --forward dry-run fails when the patch is already applied; verify that is the
    # case (reverse dry-run succeeds) rather than silently skipping a real conflict.
    if patch -p1 -d "${KERNEL_SRC_DIR}" --dry-run -R --no-backup-if-mismatch < "${p}" >/dev/null 2>&1; then
      echo "[kernel]     already applied, skipping"
    else
      die "patch does not apply (and is not already applied): ${p}"
    fi
  fi
done

# 3) cross-compile the riscv64 Image (build-kernel.sh normalizes Image -> vmlinux)
BUILD_OUT="${WORK_DIR}/build"
echo "[kernel] build (ARCH=riscv, CROSS_COMPILE=riscv64-linux-gnu-, jobs=${KERNEL_BUILD_JOBS})"
KERNEL_SRC_DIR="${KERNEL_SRC_DIR}" \
KERNEL_TARGET_ARCH=riscv64 \
KERNEL_CONFIG="${KERNEL_CONFIG}" \
KERNEL_OUTPUT_DIR="${BUILD_OUT}" \
KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS}" \
  bash "${BUILD_KERNEL_SH}"

[ -f "${BUILD_OUT}/vmlinux" ] || die "build did not produce ${BUILD_OUT}/vmlinux"

# 4) install to OUTPUT_IMAGE and verify it is a PE/EFI-stub Image (magic "MZ").
#    Cube-Hypervisor riscv64 load_kernel rejects an ELF vmlinux (InvalidImageMagicNumber).
mkdir -p "$(dirname "${OUTPUT_IMAGE}")"
install -D -m 0644 "${BUILD_OUT}/vmlinux" "${OUTPUT_IMAGE}"
magic="$(head -c2 "${OUTPUT_IMAGE}" | tr -d '\0')"
[ "${magic}" = "MZ" ] || die "${OUTPUT_IMAGE} is not a PE/EFI-stub Image (magic='${magic}', expected 'MZ')"
echo "[kernel] OK: ${OUTPUT_IMAGE} (PE magic MZ, $(stat -c%s "${OUTPUT_IMAGE}") bytes)"
