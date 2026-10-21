#!/usr/bin/env bash
# build_qemu_riscv64.sh -- build COMMUNITY qemu (qemu-system-riscv64 only) from
# the official qemu.org source release.
#
# WHY not the distro qemu: ubuntu-24.04's apt qemu is 8.2.2, whose TCG IMSIC
# emulation is broken for our nested setup: inside the L1 the 7.2 kernel's imsic
# irqchip never becomes the IPI device ("Platform IPI Device: aia-imsic" and
# "kvm [1]: AIA available ..." never print), so kvm_riscv_aia_init() never
# completes and /dev/kvm reports KVM_CAP_IRQCHIP=0 -- the shim then panics at
# check_required_extensions. Community qemu 11 carries the riscv AIA fixes; with
# it the same kernel reports IRQCHIP=1 and the whole nested snapshot/restore
# chain passes (verified end-to-end 2026-10-20).
#
# The aligned CI environment (all three legs pinned to upstream/community):
#   kernel : kernel.org v7.2 + configs/patches/{riscv64-dax-zeropage-folio,
#            riscv64-kvm-zeropage-dirtylog} (build_guest_kernel_riscv64.sh; the
#            same two patches as yocto linux-xuantie_7.2.bb)
#   qemu   : community 11.x from download.qemu.org  (THIS script)
#   opensbi: community v1.7 release fw_dynamic.bin  (fetch_guest_assets_riscv64.sh)
#
# Env (all optional):
#   QEMU_VERSION     qemu.org release to build (default 11.1.1)
#   QEMU_PREFIX      install prefix   (default ${WORKLOADS_DIR:-$PWD}/qemu-install)
#   QEMU_SRC_DIR     src/build cache  (default ${WORKLOADS_DIR:-$PWD}/qemu-src)
#   QEMU_BUILD_JOBS  parallel make jobs (default $(nproc))
#   SKIP_APT_DEPS=1  do not apt-get the build deps (already installed)
#
# Idempotent: if $QEMU_PREFIX/bin/qemu-system-riscv64 already reports
# QEMU_VERSION, the build is skipped (this is what makes the workflow's
# actions/cache of QEMU_PREFIX effective).

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

QEMU_VERSION="${QEMU_VERSION:-11.1.1}"
WORKLOADS_DIR="${WORKLOADS_DIR:-$PWD}"
QEMU_PREFIX="${QEMU_PREFIX:-${WORKLOADS_DIR}/qemu-install}"
QEMU_SRC_DIR="${QEMU_SRC_DIR:-${WORKLOADS_DIR}/qemu-src}"
QEMU_BUILD_JOBS="${QEMU_BUILD_JOBS:-$(nproc)}"
QEMU_BIN="${QEMU_PREFIX}/bin/qemu-system-riscv64"

mkdir -p "${QEMU_SRC_DIR}"

if [[ -x "${QEMU_BIN}" ]]; then
  iv="$("${QEMU_BIN}" --version 2>/dev/null | head -1 || true)"
  case "${iv}" in
    "QEMU emulator version ${QEMU_VERSION}"|"QEMU emulator version ${QEMU_VERSION} "*)
      echo "[qemu] ${QEMU_BIN} already at ${QEMU_VERSION} -- skipping build"
      exit 0 ;;
  esac
fi

# 1) build deps (debian/ubuntu). qemu 11 wants meson>=1.5; ubuntu-24.04 ships
#    1.3.2, so meson comes from a pip venv below (proven in the local build).
if [[ "${SKIP_APT_DEPS:-0}" != "1" ]]; then
  SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
  # Full apt/pip/build output flows to the CI log on purpose: on a runner the
  # job log is the ONLY debug surface, so nothing here may be silenced.
  ${SUDO} apt-get update
  ${SUDO} apt-get install -y --no-install-recommends \
    build-essential ninja-build pkg-config python3 python3-venv python3-pip \
    libglib2.0-dev libpixman-1-dev libslirp-dev zlib1g-dev libfdt-dev \
    xz-utils curl ca-certificates
fi
for t in ninja pkg-config python3 curl tar xz; do
  command -v "$t" >/dev/null 2>&1 || die "missing build tool: $t (unset SKIP_APT_DEPS or install it)"
done

# 2) meson >= 1.5 via venv (pip index must be reachable)
VENV="${QEMU_SRC_DIR}/meson-venv"
if [[ ! -x "${VENV}/bin/meson" ]]; then
  echo "[qemu] creating meson venv: ${VENV}"
  python3 -m venv "${VENV}"
  # meson>=1.5 for qemu 11; tomli is needed by qemu's mkvenv on python<3.11
  # (3.11+ has stdlib tomllib); pycotap/qemu.qmp are mkvenv test deps.
  "${VENV}/bin/pip" install "meson==1.8.1" tomli pycotap "qemu.qmp==0.0.6" setuptools wheel
fi
export PATH="${VENV}/bin:${PATH}"

# 3) fetch + extract the official source release
TARBALL="${QEMU_SRC_DIR}/qemu-${QEMU_VERSION}.tar.xz"
SRC="${QEMU_SRC_DIR}/qemu-${QEMU_VERSION}"
if [[ ! -s "${TARBALL}" ]]; then
  echo "[qemu] download https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
  curl -fSL --retry 3 -o "${TARBALL}" "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
fi
[[ -d "${SRC}" ]] || { echo "[qemu] extract -> ${SRC}"; tar -xf "${TARBALL}" -C "${QEMU_SRC_DIR}"; }

# 4) configure + build riscv64-softmmu only (slirp = user networking for the
#    C1 hostfwd; everything graphical off). configure/make output is NOT
#    redirected: a qemu build failure must be diagnosable from the job log.
echo "[qemu] configure + build (riscv64-softmmu, jobs=${QEMU_BUILD_JOBS})"
mkdir -p "${SRC}/build"
cd "${SRC}/build"
../configure --target-list=riscv64-softmmu --enable-slirp --disable-docs \
  --disable-gtk --disable-sdl --disable-opengl --disable-virglrenderer \
  --prefix="${QEMU_PREFIX}"
make -j"${QEMU_BUILD_JOBS}"
make install

# 5) verify
[[ -x "${QEMU_BIN}" ]] || die "build did not produce ${QEMU_BIN}"
ver_line="$("${QEMU_BIN}" --version | head -1)"
case "${ver_line}" in
  "QEMU emulator version ${QEMU_VERSION}"|"QEMU emulator version ${QEMU_VERSION}"\ *) ;;
  *) die "unexpected version: ${ver_line}" ;;
esac
echo "[qemu] OK: ${QEMU_BIN} (${ver_line})"
