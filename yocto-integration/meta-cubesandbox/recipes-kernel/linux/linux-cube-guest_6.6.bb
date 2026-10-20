# linux-cube-guest 6.6: the READY, bring-up/stable microVM *guest* kernel.
# This is the DEFAULT (7.2 carries DEFAULT_PREFERENCE = "-1").
#
# WHY 6.6 IS THE DEFAULT
#  * The source is ALREADY in the tree and known to build for riscv64 with the
#    XuanTie GCC: meta-xuantie/recipes-kernel/linux/linux-xuantie_6.6.y.bb
#    L4 SRC_URI = "git://github.com/ruyisdk/linux-xuantie-kernel.git;
#    branch=linux-6.6.36;protocol=https", SRCREV = ${XUANTIE_LINUX_TAG}
#    (default AUTOREV, L37-38), Linux 6.6.36 (Makefile VERSION/PATCHLEVEL/
#    SUBLEVEL = 6/6/36 in the built workdir). It is built by
#    PREFERRED_VERSION_linux-xuantie = "6.6.y" for every 6.6 DISTRO
#    (xuantie-base.inc L417; KERNEL ?= "6.6-default" L394). So we REUSE a
#    proven, gcc-buildable 6.6 kernel instead of fetching fresh.
#  * 7.2 (linux-cube-guest_7.2.bb) matches the upstream CubeSandbox guest
#    config but is newer and clang-17-flavoured; it is the opt-in variant.
#
# SRCREV PIN: the recipe default is AUTOREV, but a real integration MUST pin.
# The in-tree ngf build checked out commit
#   ccb3ccf128b7d423b98a0b07b0cb2b409b44dea6   (git describe: XuanTie_V1.4.0-14-gccb3ccf128b7)
# from ssh://gitlab.alibaba-inc.com/xuantie-linux/linux-xuantie-kernel.git
# (workdir: xuantie-build/ngf/tmp-glibc/work/rva23u64_k6.6xt_kcdefault_tcxt-oe-linux/
#  linux-xuantie/6.6.y-r0/linux-6.6.y/.git). We pin that SHA below so the guest
# kernel is reproducible. TODO(verify): confirm the same commit is reachable on
# the public github ruyisdk/linux-xuantie-kernel linux-6.6.36 branch (the recipe
# SRC_URI uses github; the ngf build used the internal gitlab mirror) — if the
# SHAs differ per remote, pin the github one or override XUANTIE_LINUX_TAG.

SUMMARY = "CubeSandbox microVM guest kernel 6.6 (riscv64, in-tree XuanTie source, Image deployed as vmlinux)"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"
# md5 verified against the in-tree linux-6.6.36 COPYING.

inherit kernel

# Reuse the SAME source as meta-xuantie's 6.6 kernel (linux-xuantie_6.6.y.bb L4).
# NOTE: linux-xuantie_6.6.y.bb uses S = "${WORKDIR}/linux-${PV}" (its L42) —
# the built ngf workdir indeed contains linux-6.6.y/, so something in its
# fetch path (linux-yocto.inc / kernel fetch handling) names the checkout that
# way. For THIS recipe we set the git destsuffix explicitly so S is
# unambiguous. TODO(verify) at first parse/build.
SRC_URI = " \
    git://github.com/ruyisdk/linux-xuantie-kernel.git;branch=linux-6.6.36;protocol=https;destsuffix=git \
    file://cube-guest-riscv64-defconfig \
"
# Pinned to the commit the tree already builds (see SRCREV PIN above).
SRCREV = "ccb3ccf128b7d423b98a0b07b0cb2b409b44dea6"

LINUX_VERSION = "6.6"
LINUX_VERSION_EXTENSION = "-cube-guest"
PV = "${LINUX_VERSION}.36${LINUX_VERSION_EXTENSION}"

S = "${WORKDIR}/git"

KCONFIG_MODE = "--alldefconfig"

# Defconfig derivation (DESIGN.md §5.2). We START from the SAME
# cube-guest-riscv64-defconfig (= configs/kernel-oc9.riscv64.config, a
# Linux/riscv 7.2.0-rc7 clang-17 config) and let 6.6's `olddefconfig` drop
# everything the 6.6 Kconfig does not know. Symbols that MUST be dropped for
# 6.6 (7.x / clang-17 / in-kernel-Rust only), all handled by olddefconfig or
# explicitly disabled here:
#   * compiler stamps: CONFIG_CC_IS_CLANG, CONFIG_GCC_VERSION, CONFIG_CLANG_
#     VERSION, CONFIG_AS_IS_LLVM, CONFIG_LD_IS_LLD, CONFIG_LD_VERSION
#     (regenerated from the actual 6.6 build compiler).
#   * in-kernel Rust: CONFIG_HAVE_RUST (7.x config L641) and any CONFIG_RUST* —
#     6.6.36 riscv does not enable Rust; olddefconfig clears them.
#   * clang hardening already "# not set" in the source config: CONFIG_LTO_CLANG*,
#     CONFIG_SHADOW_CALL_STACK, CONFIG_CFI_CLANG — no-op for a GCC 6.6 build.
#   * 7.x-only KVM generic helpers (e.g. CONFIG_KVM_GENERIC_HARDWARE_ENABLING,
#     CONFIG_KVM_GENERIC_DIRTYLOG_READ_PROTECT — 7.x config L558-568) that do
#     not exist in 6.6 are dropped; confirm the 6.6 KVM guest bits we DO need
#     (CONFIG_KVM, CONFIG_RISCV_SBI L306, CONFIG_VIRTIO* L1296-5306) survive.
# TODO(verify): after the first 6.6 build, run `savedefconfig` and commit a
# minimal 6.6-native defconfig so guest features are explicit rather than
# inherited-then-pruned from a 7.x config.
do_configure() {
	install -m 0644 ${WORKDIR}/cube-guest-riscv64-defconfig ${B}/.config
	oe_runmake_call -C ${S} O=${B} olddefconfig
}

KERNEL_IMAGETYPE = "Image"
# Deploy Image AS `vmlinux` (identical artifact name to the 7.2 recipe) so the
# shim / cube-kernel-scf/vmlinux consumer is agnostic to which guest kernel is
# selected (scripts/build-kernel.sh L73-82).
do_deploy:append() {
	install -m 0644 ${B}/arch/${ARCH}/boot/Image ${DEPLOYDIR}/vmlinux
}

# Never the machine kernel: PREFERRED_PROVIDER_virtual/kernel stays
# "linux-xuantie" (xuantie-base.inc L25); give our packages a distinct name.
KERNEL_PACKAGE_NAME = "cube-guest-kernel"
KERNEL_VERSION_SANITY_SKIP = "1"

# pahole/BTF: linux-xuantie_6.6.y.bb L100 adds pahole-native for BTF; the
# CubeVS host eBPF path wants CONFIG_DEBUG_INFO_BTF on the HOST kernel, not the
# guest. Keep the guest lean; add pahole-native only if guest BTF is required.
# TODO(verify): does the cube guest need CONFIG_DEBUG_INFO_BTF? (probably not).

COMPATIBLE_HOST = "(riscv64).*-linux"
