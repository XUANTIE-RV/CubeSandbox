# Common settings for all CubeSandbox component recipes.
# All components live in one mono-repo; each recipe fetches the whole repo and
# points S at its subdirectory (needed for cross-dir path deps: CubeShim ->
# ../../hypervisor, Cubelet -> CubeNet/cubevs + third_party/cubecow, go.mod
# replace ../pkgs/*).
# Provenance: repo Makefile targets *-riscv64. Source is the INTERNAL mirror of
# the CubeSandbox fork on Aone Code (gitlab.alibaba-inc.com/yocto-linux-sdk/
# cubesandbox), which carries the full upstream history + the riscv64 port.
# Branch feat/riscv64-port = base add_riscv_support (bedc618, the official
# "experimental RISC-V" commit) + the 10 signed port commits; CUBE_SRCREV pins
# its tip. After the CR merges feat/riscv64-port into add_riscv_support, switch
# CUBE_BRANCH to add_riscv_support and bump CUBE_SRCREV to the merge commit.

CUBE_REPO ?= "gitlab.alibaba-inc.com/yocto-linux-sdk/cubesandbox"
CUBE_BRANCH ?= "feat/riscv64-port"
CUBE_SRCREV ?= "1a19eadebdd5ae2ae3dc840c79cbebfa6bacb0e2"

# For air-gapped builds publish a tarball of the branch and use PREMIRRORS:
#   PREMIRRORS:append = " ${CUBE_REPO} .* http://<mirror>/CubeSandbox-${CUBE_SRCREV}.tar.gz"
# TODO(verify): tarball mirror location.

# protocol=ssh matches the tree convention for internal Aone Code repos (see
# meta-xuantie-ngf zsb / opensbi / linux-xuantie and torq/tpe-driver recipes);
# the build host's ssh key must have read access to yocto-linux-sdk/cubesandbox.
SRC_URI = "git://git@gitlab.alibaba-inc.com/yocto-linux-sdk/cubesandbox.git;protocol=ssh;branch=${CUBE_BRANCH};destsuffix=git"
SRCREV = "${CUBE_SRCREV}"
PV = "0.0.0-dev+git${SRCPV}"

S = "${WORKDIR}/git"
# destsuffix=git is explicit so go.bbclass's go_do_unpack does NOT relocate the
# checkout to ${S}/src/${GO_IMPORT} (go.bbclass L92-94 only rewrites destsuffix
# when it is unset). Cargo recipes already default to ${WORKDIR}/git, so this is
# a no-op for them and a fix for the `inherit go` recipes (cubelet et al.), which
# build in MODULE mode directly from ${S}/<component> — no GOPATH/src layout.

LICENSE = "Apache-2.0"
# md5 of the repo root LICENSE (verified with md5sum on branch bedc618).
LIC_FILES_CHKSUM = "file://LICENSE;md5=8cb1257418f6703a382b660af831c8fc"
# Note: hypervisor/ is dual-licensed Apache-2.0 & BSD-3-Clause (LICENSE-APACHE
# md5=3b83ef96387f14655fc854ddc3c6bd57, LICENSE-BSD-3-Clause
# md5=b1ed361f9fc790c1054d81a7ef041a34). Recipes bundling hypervisor/ must add:
#   LICENSE = "Apache-2.0 & BSD-3-Clause"
#   LIC_FILES_CHKSUM += "file://hypervisor/LICENSE-APACHE;md5=3b83ef96387f14655fc854ddc3c6bd57" \
#                       "file://hypervisor/LICENSE-BSD-3-Clause;md5=b1ed361f9fc790c1054d81a7ef041a34"

# ---- OE-native toolchains (DESIGN.md §4) ----
# Per the current directive we build with OE's OWN rust/go machinery — recipes
# `inherit cargo` / `inherit go-mod` and use rust-native + cargo-native +
# libstd-rs (target std) / go-cross, exactly like the working
# meta-xuantie ripgrep and meta-virtualization containerd recipes already do in
# this tree. The external-prebuilt-native stubs of the previous design
# (rust-cube-*-native, go-cube-*-native, musl-cross-cube-native,
# cube-musl-staticlibs-native) are GONE.
#
# Version walls (OE langdale ships rust 1.63.0 / go 1.22.8, both too old) are
# handled by backporting newer recipe SETS into this layer's recipes-devtools/
# and selecting them with PREFERRED_VERSION — see
# conf/distro/include/cubesandbox-toolchain-versions.inc, which the integrator
# `require`s from conf/local.conf. ONE rust (1.89.0) satisfies every component
# because the pins are MINIMUMS: hypervisor rust-version = "1.77.0"
# (Cargo.toml L13), CubeShim channel 1.77.2 (but Makefile shim-riscv64 L674
# uses `cargo +1.85`), CubeAPI 1.85, agent/cubecow 1.89
# (docker/Dockerfile.builder L19-22). The real hard floor is cargo's ability
# to read the committed Cargo.lock: CubeShim/agent/guest-init all carry
# lockfile `version = 4` (line 3), needing cargo >= 1.78 — oe-core's 1.63
# would fail `--locked` regardless of rustc version.

CUBE_TARGET_ARCH = "riscv64"
# Upstream cross-builds userspace for a STATIC musl triple (Dockerfile.builder
# L17 RISCV64_MUSL_CROSS_URL, Makefile *-riscv64 targets pass
# --target riscv64gc-unknown-linux-musl). In OE that triple is produced by the
# normal rust/go target machinery whenever TCLIBC=musl; rust-common.bbclass
# (L67-70) maps TARGET_OS containing "musl" to the -musl suffix and
# rust-target-config.bbclass (L241-246, L359-360) already defines
# riscv64gc-unknown-linux-musl. We therefore DO NOT hard-code a triple here;
# the distro's libc selection drives it. See DESIGN.md §4.3 for the
# musl-vs-glibc decision (glibc-dynamic accepted for the Yocto image;
# static-musl parity is an opt-in TCLIBC=musl rebuild).
CUBE_MUSL_TRIPLE = "riscv64gc-unknown-linux-musl"   # informational only

# ---- STATIC build (current directive: RUSTFLAGS=-C target-feature=+crt-static) ----
# Goal: every cube Rust component (shim/cube-runtime, cube-api, cubecow, agent,
# cube-init) is a FULLY-STATIC ELF, so the host-side binaries need NO musl
# runtime shipped onto the (glibc) L1 rootfs — a static ELF is libc-agnostic at
# runtime. Verified on the Docker cross-build: musl target + crt-static turns
# containerd-shim-cube-rs from "dynamically linked, interpreter
# /lib/ld-musl-riscv64.so.1, NEEDED{libc.so,libgcc_s.so.1}" into "statically
# linked, 0 NEEDED" (matches how Firecracker / Cloud Hypervisor / kata-agent ship).
#
# crt-static yields a CLEAN static binary only on the musl target; glibc +
# crt-static is fragile (NSS/getaddrinfo dlopen, needs glibc-staticdev). So build
# these recipes in a TCLIBC=musl variant — XuanTie DISTRO routing LIBC=muslc ->
# xuantie-toolchain-gcc-muslc — then inject the resulting static ELFs into the
# glibc L1 image (multiconfig or a prebuilt-binary recipe; DESIGN.md §4.3).
# Gated on :libc-musl so a plain glibc build is untouched. Applies to all cube
# Rust recipes via this shared inc (Go recipes ignore RUSTFLAGS; cubelet uses
# CGO_ENABLED=0 for its static, see cubelet_git.bb).
RUSTFLAGS:append:libc-musl = " -C target-feature=+crt-static"
# The -sys crates (libseccomp-sys, libcap-ng-sys) must link the STATIC archives
# under crt-static, else the link fails or stays dynamic. oe-core libseccomp 2.5.4
# (DISABLE_STATIC = "") and libcap-ng both ship .a into the target sysroot.
# Each Rust recipe that pulls these deps also exports LIB*_LINK_TYPE=static +
# LIB*_LIB_PATH in its own do_compile:prepend:libc-musl (see cube-agent /
# containerd-shim-cube) so the crate build script finds the archives.

# Vendoring: langdale's cargo_common.bbclass forces offline bitbake vendoring
# ([source.crates-io] replace-with = "bitbake", local-registry = "/nonexistant",
# L54-60) unless CARGO_DISABLE_BITBAKE_VENDORING = "1" (L31). We keep that
# decision — see DESIGN.md §4.4 — because CubeShim/ ships a workspace
# Cargo.lock and a [patch.crates-io] path dep (CubeShim/Cargo.toml L9-10:
# containerd-shim = { path = "../third_party/containerd-shim" }) that
# cargo-bitbake's crate:// model handles poorly. Each recipe re-sets it below.
CARGO_DISABLE_BITBAKE_VENDORING = "1"
