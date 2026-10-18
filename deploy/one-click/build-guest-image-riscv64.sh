#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the riscv64 guest rootfs image (cube-guest-image-cpu.img + version).
#
# WHY a dedicated riscv64 script (not build-guest-image.sh):
#   build-guest-image.sh assembles the guest rootfs by `docker build`-ing
#   deploy/guest-image/Dockerfile (FROM tencentos/tencentos4-minimal + yum
#   busybox/util-linux) and `docker export`-ing it. That Dockerfile has no
#   --platform and pulls amd64-only packages, so it cannot produce a riscv64
#   rootfs. The riscv64 guest image is also far simpler: the reference image
#   (cube-l1 testbed) contains ONLY a fully-static cube-init as /sbin/init plus
#   an empty FHS skeleton and the /cube-root container mount point -- no
#   busybox, no util-linux, no libc. cube-init is a static musl ELF and mounts
#   /proc /sys /dev/shm /dev/pts /run itself (guest-init/src/init_env.rs
#   INIT_ROOTFS_MOUNTS + mount_sys), so nothing else is needed in the rootfs.
#
# Layout inside the ext4 image:
#   /sbin/init      # static riscv64 cube-init (guest PID1)
#   /etc/hostname   # "localhost"
#   /cube-root/     # empty skeleton; the OCI container (cube-min.tar) rootfs
#                   #   is unpacked here at runtime (cube-spec root.path)
#   /bin /dev /lib /proc /root /run /sys /tmp /usr /var  # empty mount points
#
# Block size is FORCED to 4096: CubeShim boots the guest kernel with
# rootflags=dax, and DAX does not support 1K/2K ext4 block sizes (would panic
# at mount). The final image size is 2 MiB aligned because the hypervisor's
# device_manager rejects pmem regions not aligned to the 2 MiB guest-hugepage
# granularity (hypervisor/vmm/src/device_manager.rs PmemSizeNotAligned).
#
# Usage:
#   OUTPUT_DIR=/path/to/cube-image \
#     [ONE_CLICK_CUBE_INIT_BIN=/path/to/cube-init-riscv64] \
#     [ONE_CLICK_GUEST_IMAGE_TAR=/path/to/cube-guest-image-riscv64.tar.gz] \
#     [CUBE_VERSION=v0.7.2] ./deploy/one-click/build-guest-image-riscv64.sh
#
# When ONE_CLICK_CUBE_INIT_BIN is unset, cube-init is built for riscv64 via
# `make cube-init-riscv64` (cross-compiled in the riscv64 builder image).
# When ONE_CLICK_GUEST_IMAGE_TAR is set, the {img,version} pair is also packed
# into that tar.gz so build-release-bundle-riscv64.sh can consume it via its
# ONE_CLICK_GUEST_IMAGE_TAR override (closing the riscv64 release loop).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
load_build_env

WORK_ROOT="${ONE_CLICK_WORK_ROOT:-${SCRIPT_DIR}/.work-riscv64}"
OUTPUT_DIR="${OUTPUT_DIR:-${ONE_CLICK_GUEST_IMAGE_OUTPUT_DIR:-}}"
[[ -n "${OUTPUT_DIR}" ]] || die "OUTPUT_DIR (or ONE_CLICK_GUEST_IMAGE_OUTPUT_DIR) is required"

# Default image size matches the riscv64 reference (64 MiB, already 2 MiB
# aligned). The minimal rootfs is <1 MiB, so this is mostly dax/pmem headroom.
GUEST_IMAGE_SIZE_BYTES="${ONE_CLICK_GUEST_IMAGE_SIZE_BYTES:-$((64 * 1024 * 1024))}"
PMEM_ALIGN_BYTES=$((2 * 1024 * 1024))

LATEST_RELEASE_TAG="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
: "${CUBE_VERSION:=${LATEST_RELEASE_TAG:-0.0.0-dev}}"
: "${CUBE_COMMIT:=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo 'unknown')}"
: "${CUBE_BUILD_TIME:=$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"
export CUBE_VERSION CUBE_COMMIT CUBE_BUILD_TIME

GUEST_IMAGE_WORK_DIR="${WORK_ROOT}/guest-image-riscv64-build"
GUEST_ROOTFS_DIR="${GUEST_IMAGE_WORK_DIR}/rootfs"
GUEST_IMAGE_VERSION="${ONE_CLICK_GUEST_IMAGE_VERSION:-${CUBE_VERSION}}"

# shellcheck source=./lib/guest-image.sh
source "${SCRIPT_DIR}/lib/guest-image.sh"

require_cmd python3
require_cmd truncate
require_cmd mkfs.ext4
require_cmd e2fsck
require_cmd tar
require_cmd file

ensure_mkfs_ext4_supports_populate_dir

if (( GUEST_IMAGE_SIZE_BYTES % PMEM_ALIGN_BYTES != 0 )); then
  die "guest image size ${GUEST_IMAGE_SIZE_BYTES} is not 2 MiB aligned"
fi

# Resolve a STATIC riscv64 cube-init. build-guest-image.sh's build_cube_init
# runs `make` in guest-init/ for the HOST arch; for riscv64 we need the cross
# target, so resolve it here (override wins, else `make cube-init-riscv64`).
resolve_cube_init_riscv64() {
  if [[ -n "${ONE_CLICK_CUBE_INIT_BIN:-}" ]]; then
    ensure_file "${ONE_CLICK_CUBE_INIT_BIN}"
    log "using prebuilt riscv64 cube-init: ${ONE_CLICK_CUBE_INIT_BIN}"
    printf '%s\n' "${ONE_CLICK_CUBE_INIT_BIN}"
    return 0
  fi

  require_cmd make
  log "building riscv64 cube-init via 'make cube-init-riscv64'"
  (cd "${ROOT_DIR}" && make cube-init-riscv64) >&2
  ensure_file "${ROOT_DIR}/_output/bin/cube-init-riscv64"
  printf '%s\n' "${ROOT_DIR}/_output/bin/cube-init-riscv64"
}

# Refuse a dynamic or non-riscv64 init: the guest rootfs ships no libc/loader,
# so /sbin/init MUST be a self-contained static RISC-V ELF.
verify_static_riscv64_init() {
  local bin="$1"
  local desc
  desc="$(file -b "${bin}")"
  if ! printf '%s' "${desc}" | grep -qi 'RISC-V'; then
    die "cube-init is not a RISC-V ELF: ${bin} (${desc})"
  fi
  if ! printf '%s' "${desc}" | grep -qi 'statically linked'; then
    die "cube-init must be a STATIC ELF for the minimal riscv64 guest rootfs: ${bin} (${desc})"
  fi
}

INIT_BIN="$(resolve_cube_init_riscv64)"
verify_static_riscv64_init "${INIT_BIN}"

remove_path_with_optional_sudo "${GUEST_IMAGE_WORK_DIR}"
mkdir -p "${OUTPUT_DIR}" "${GUEST_ROOTFS_DIR}"

# FHS skeleton: empty mount points + the /cube-root container root. cube-init
# create_dir_all's its own mount dests at boot, but shipping the skeleton keeps
# the image self-describing and matches the reference layout.
log "assembling minimal riscv64 guest rootfs at ${GUEST_ROOTFS_DIR}"
mkdir -p \
  "${GUEST_ROOTFS_DIR}"/{bin,dev,etc,lib,proc,root,run,sbin,sys,tmp,usr,var} \
  "${GUEST_ROOTFS_DIR}"/cube-root/{bin,dev,etc,proc,run,sbin,sys,tmp,usr}

install -m 0755 "${INIT_BIN}" "${GUEST_ROOTFS_DIR}/sbin/init"
[[ -x "${GUEST_ROOTFS_DIR}/sbin/init" ]] || die "failed to install /sbin/init"

printf 'localhost\n' > "${GUEST_ROOTFS_DIR}/etc/hostname"
printf '127.0.0.1 localhost\n' > "${GUEST_ROOTFS_DIR}/etc/hosts"

OUTPUT_IMG="${OUTPUT_DIR}/cube-guest-image-cpu.img"
OUTPUT_VERSION_FILE="${OUTPUT_DIR}/version"

log "creating ext4 guest image (4K block for dax) at ${OUTPUT_IMG}"
truncate -s "${GUEST_IMAGE_SIZE_BYTES}" "${OUTPUT_IMG}"
# -b 4096 is mandatory for rootflags=dax (see header); -d populates from the
# staged rootfs without a loop mount.
run_mkfs_ext4_with_optional_sudo -F -b 4096 -d "${GUEST_ROOTFS_DIR}" "${OUTPUT_IMG}" >&2
run_as_root e2fsck -fy "${OUTPUT_IMG}" >&2 || true

printf '%s\n' "${GUEST_IMAGE_VERSION}" > "${OUTPUT_VERSION_FILE}"

# Verify the block size really is 4096 (dax hard requirement) and 2 MiB align.
block_size="$(dump_ext4_header "${OUTPUT_IMG}" | awk -F': *' '/^Block size/ {print $2; exit}')"
[[ "${block_size}" == "4096" ]] || die "guest image block size is ${block_size:-unknown}, expected 4096 (dax)"
img_size="$(stat -c '%s' "${OUTPUT_IMG}" 2>/dev/null || stat -f '%z' "${OUTPUT_IMG}")"
if (( img_size % PMEM_ALIGN_BYTES != 0 )); then
  die "guest image size ${img_size} is not 2 MiB aligned (pmem requirement)"
fi

remove_path_with_optional_sudo "${GUEST_ROOTFS_DIR}"

# Optionally pack {img,version} into the tar.gz the riscv64 release bundle reads.
if [[ -n "${ONE_CLICK_GUEST_IMAGE_TAR:-}" ]]; then
  log "packing guest image tar: ${ONE_CLICK_GUEST_IMAGE_TAR}"
  mkdir -p "$(dirname "${ONE_CLICK_GUEST_IMAGE_TAR}")"
  tar -czf "${ONE_CLICK_GUEST_IMAGE_TAR}" \
    -C "${OUTPUT_DIR}" cube-guest-image-cpu.img version
fi

log "riscv64 guest image artifacts ready: ${OUTPUT_DIR}"
log "  cube-guest-image-cpu.img (${img_size} bytes, ext4 4K block, 2MiB aligned)"
log "  version = ${GUEST_IMAGE_VERSION}"
