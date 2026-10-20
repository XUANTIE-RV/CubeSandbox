# containerd-shim-cube: CubeShim (containerd shim v2, runtime type
# "io.containerd.cube.rs" per deploy/one-click/config-cube.toml) bundling the
# cube-hypervisor library (Cloud Hypervisor v28 fork) via Cargo path dep.
#
# OE-NATIVE BUILD (current directive): `inherit cargo` and build with the
# tree's own rust-native + cargo-native + libstd-rs — NOT an external pinned
# rustup toolchain. Upstream cross line (Makefile shim-riscv64, MK L672-674):
#   cargo +1.85 build --release --locked --target riscv64gc-unknown-linux-musl
# with LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=... LIBCAPNG_*...
# In OE the `--target`/linker/CC wiring is provided by cargo.bbclass +
# cargo_common.bbclass (CARGO_BUILD_FLAGS uses RUST_HOST_SYS; the linker and
# CC/CXX/AR come from oe_cargo_fix_env, cargo_common.bbclass L119-137), so we
# do NOT export CARGO_BUILD_TARGET / *_LINKER by hand any more. The triple is
# whatever the distro's libc selects (gnu for a glibc image, musl under
# TCLIBC=musl). See DESIGN.md §4.3.
#
# Version wall: requires rust/cargo >= 1.85 and cargo >= 1.78 (CubeShim/
# Cargo.lock is lockfile version = 4, line 3). Provided by the backported
# rust_1.89.0 set selected via conf/distro/include/
# cubesandbox-toolchain-versions.inc (PREFERRED_VERSION_rust-native etc.).
# Outputs: containerd-shim-cube-rs, cube-runtime.

require recipes-cube/cube-sandbox-common.inc

SUMMARY = "CubeSandbox containerd shim v2 (with in-process cube-hypervisor microVM backend)"
HOMEPAGE = "https://github.com/TencentCloud/CubeSandbox"

LICENSE = "Apache-2.0 & BSD-3-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=8cb1257418f6703a382b660af831c8fc \
                    file://hypervisor/LICENSE-APACHE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
                    file://hypervisor/LICENSE-BSD-3-Clause;md5=b1ed361f9fc790c1054d81a7ef041a34"

# Whole-repo fetch (common.inc); workspace root is CubeShim/, which references
# ../hypervisor and ../third_party/containerd-shim ([patch.crates-io] in
# CubeShim/Cargo.toml L9-10) — hence the mono-repo S layout.
S = "${WORKDIR}/git/CubeShim"

# libseccomp / libcap-ng are consumed as TARGET libs (the -sys crates use
# pkg-config against the target sysroot), not as external static musl blobs.
# oe-core provides both for riscv64: libseccomp 2.5.4
# (recipes-support/libseccomp/libseccomp_2.5.4.bb, no COMPATIBLE_HOST block,
#  DISABLE_STATIC = "" at L25 so a static libseccomp.a IS produced) and
# libcap-ng 0.8.3 (recipes-support/libcap-ng/libcap-ng_0.8.3.bb). We link
# them DYNAMICALLY by default (glibc image) and drop the LIBSECCOMP_LINK_TYPE
# =static / LIB*_LIB_PATH hand-off that the musl cross-build needed.
DEPENDS += "libseccomp libcap-ng"

inherit cargo

# cargo-native + rust-native + libstd-rs (target std) are pulled in by
# cargo.bbclass (BASEDEPENDS L19; DEPENDS:append:class-target L22). PREFERRED_
# VERSION pins from cubesandbox-toolchain-versions.inc choose 1.89.0.
# Keep bitbake vendoring OFF and supply crates via a `cargo vendor` tarball or
# crate:// list (DESIGN.md §4.4); CubeShim/.cargo/config only sets
# git-fetch-with-cli (verified), so there is no pre-existing vendor dir.
CARGO_DISABLE_BITBAKE_VENDORING = "1"
# TODO(verify): crate delivery — CubeShim is a big workspace with Cargo.lock;
# generate a crate:// SRC_URI list (ripgrep-style) or a vendored tarball.

# langdale's cargo.bbclass has NO EXTRA_OECARGO_ARGS hook (that is newer
# oe-core); extra cargo args go through CARGO_BUILD_FLAGS, which
# oe_cargo_build expands verbatim (cargo.bbclass L42, L54). --release is
# already default via BUILD_MODE (L41) unless DEBUG_BUILD=1.
# --locked mirrors Makefile shim-riscv64 (MK L674) and pins the committed
# Cargo.lock; requires cargo >= 1.78 (lockfile v4). --target/linker are added
# by CARGO_BUILD_FLAGS itself, so we do not repeat them here.
CARGO_BUILD_FLAGS += "--locked"
# TODO(verify): feature set used by the riscv64 branch (Makefile passes none;
# hypervisor "kvm" selection happens via the workspace default features).

# ---- static-musl (current directive; crt-static comes from common.inc) ----
# Under LIBC=muslc the shim/cube-runtime must link the STATIC libseccomp /
# libcap-ng archives so +crt-static yields a 0-NEEDED ELF (verified on the
# Docker cross-build). Mirrors Makefile shim-riscv64 (MK L672-674) which set
# LIBSECCOMP_LINK_TYPE=static / LIBCAPNG_LINK_TYPE=static + LIB*_LIB_PATH.
do_compile:prepend:libc-musl() {
	export LIBSECCOMP_LINK_TYPE="static"
	export LIBSECCOMP_LIB_PATH="${STAGING_DIR_TARGET}${libdir}"
	export LIBCAPNG_LINK_TYPE="static"
	export LIBCAPNG_LIB_PATH="${STAGING_DIR_TARGET}${libdir}"
}

# cargo.bbclass's cargo_do_install walks ${B}/target/${CARGO_TARGET_SUBDIR} and
# installs every executable into ${bindir} (classes-recipe/cargo.bbclass L63-88),
# which yields containerd-shim-cube-rs + cube-runtime automatically. B is set
# out-of-tree by cargo.bbclass (L27), so the explicit musl path of the old
# design is gone.
do_install:append() {
	# Runtime expects the shim discoverable as containerd-shim-cube-rs in
	# PATH for runtime_type "io.containerd.cube.rs"
	# (deploy/one-click/install.sh symlinks it to /usr/local/bin). Nothing
	# extra to do here; kept as a hook for config file packaging.
	:
}

# Packaging/QA depends on the libc variant:
#  - LIBC=muslc + crt-static (current directive): shim/cube-runtime are FULLY
#    static (0 NEEDED) -> no shared-lib RDEPENDS are auto-added; relax the
#    static-ELF QA that would otherwise flag them.
#  - plain glibc build: dynamic -> normal shared-lib QA, no skips.
INSANE_SKIP:${PN}:append:libc-musl = " already-stripped staticdev"
RDEPENDS:${PN} += "containerd-opencontainers"
# TODO(verify): containerd config fragment registering runtime
# io.containerd.cube.rs (see deploy/one-click/config-cube.toml) — add as a
# config file package or bbappend on containerd-opencontainers in Phase 1.

COMPATIBLE_HOST = "(riscv64).*-linux"
