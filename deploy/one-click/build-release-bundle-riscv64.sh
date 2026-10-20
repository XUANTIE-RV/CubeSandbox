#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the one-click release bundle for riscv64 by consuming prebuilt
# `make all-riscv64` artifacts (_output/bin/*-riscv64) + the riscv64 guest
# kernel (PE Image) and guest rootfs tar. build-release-bundle.sh's
# build_or_copy_{go,rust}_binary helpers honor the ONE_CLICK_*_BIN overrides,
# so no native compilation happens for riscv64 — it packages prebuilt binaries.
#
# Prereq:  make all-riscv64      (12 components -> _output/bin/*-riscv64)
#          mkcert-riscv64 built   (go install filippo.io/mkcert@v1.4.4, GOARCH=riscv64)
#          guest rootfs tar prepared (tar czf ... -C <pmem0root> .)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; source "${SCRIPT_DIR}/build.env.riscv64"; set +a
export ONE_CLICK_ARCH=riscv64
# sanity: every overridden binary must exist and be RISC-V
for v in ONE_CLICK_CUBEMASTER_BIN ONE_CLICK_CUBELET_BIN ONE_CLICK_CUBE_API_BIN \
         ONE_CLICK_CUBESHIM_BIN ONE_CLICK_CUBE_AGENT_BIN ONE_CLICK_CUBE_INIT_BIN \
         ONE_CLICK_MKCERT_BIN ONE_CLICK_CUBE_KERNEL_VMLINUX ONE_CLICK_GUEST_IMAGE_TAR; do
  p="${!v}"; [[ -e "$p" ]] || { echo "MISSING $v=$p (run 'make all-riscv64' / build mkcert-riscv64 first)" >&2; exit 1; }
done
exec "${SCRIPT_DIR}/build-release-bundle.sh" "$@"
