# cubecow: Rust copy-on-write staticlib consumed by Cubelet via CGO.
# Upstream line (Makefile cubecow-riscv64, MK L340-342):
#   rustup target add riscv64gc-unknown-linux-musl --toolchain 1.89 &&
#   CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_MUSL_LINKER=riscv64-linux-musl-gcc
#   cargo build --release -p cubecow --target riscv64gc-unknown-linux-musl
#   -> target/.../release/libcubecow.a + cubecow/include/cubecow.h
#
# OE-NATIVE BUILD (current directive): `inherit cargo` with the backported rust
# 1.89.0 (cubecow/rust-toolchain.toml channel = "1.89"). The --target and
# linker come from cargo.bbclass; we do NOT export them. cubecow is a
# `staticlib` crate (crate-type in cubecow/Cargo.toml) so `cargo build -p
# cubecow` produces libcubecow.a in ${B}/target/<triple>/release/.
#
# IMPORTANT — this is a LIBRARY consumed at Cubelet CGO link time, so its libc
# must MATCH cubelet's. Under the default glibc image both are glibc; under a
# TCLIBC=musl build both are musl. Keep the two recipes on the same libc.
# Staged for cubelet's do_configure (Cubelet/third_party/cubecow/{lib,include}).

require recipes-cube/cube-sandbox-common.inc

SUMMARY = "CubeSandbox cubecow static library (CoW disk support for Cubelet)"
HOMEPAGE = "https://github.com/TencentCloud/CubeSandbox"

S = "${WORKDIR}/git/cubecow"

inherit cargo

CARGO_DISABLE_BITBAKE_VENDORING = "1"
# TODO(verify): cubecow/ ships Cargo.lock; deliver crates via crate:// list or
# `cargo vendor` tarball (DESIGN.md §4.4).

# -p cubecow selects the staticlib member of the workspace (MK L342). Extra
# args go via CARGO_BUILD_FLAGS in langdale (cargo.bbclass L42,L54); --release
# is BUILD_MODE's default (L41). EXTRA_OECARGO_ARGS is newer-oe-core only.
CARGO_BUILD_FLAGS += "--locked -p cubecow"

# cargo.bbclass sets B out-of-tree and CARGO_TARGET_SUBDIR =
# ${RUST_HOST_SYS}/${BUILD_DIR} (cargo.bbclass L46-47). cargo_do_install
# installs *.so/*.rlib into rustlibdir but NOT *.a, so we install the staticlib
# + header ourselves for cubelet to consume.
RUST_TRIPLE_DIR = "${B}/target/${RUST_HOST_SYS}/release"
do_install() {
	install -d ${D}${libdir} ${D}${includedir}
	install -m 0644 ${RUST_TRIPLE_DIR}/libcubecow.a ${D}${libdir}/
	install -m 0644 ${S}/include/cubecow.h ${D}${includedir}/
}

# Static lib only — ship in a -staticdev package; no runtime package.
# crate-type = ["lib", "cdylib", "staticlib"] (cubecow/Cargo.toml L10) and the
# header lives at cubecow/include/cubecow.h (verified), so ${S}/include/
# cubecow.h resolves. cargo_do_install will also drop the cdylib .so into
# rustlibdir; harmless, but if QA objects restrict to the staticlib below.
PACKAGES =+ "${PN}-staticdev"
FILES:${PN}-staticdev = "${libdir}/libcubecow.a ${includedir}/cubecow.h"
ALLOW_EMPTY:${PN} = "1"
INSANE_SKIP:${PN}-staticdev += "staticdev"
COMPATIBLE_HOST = "(riscv64).*-linux"
