# cube-hypervisor: vendored Cloud Hypervisor v28.0 fork (hypervisor/ dir),
# consumed by CubeShim as a Cargo path dependency with feature "lib_support"
# (CubeShim/shim/Cargo.toml L42: cube-hypervisor = {path = "../../hypervisor",
# features = ["lib_support"]}).
#
# DESIGN DECISION (DESIGN.md §5): the hypervisor is normally compiled INSIDE the
# containerd-shim-cube recipe, because Cargo path deps do not map onto the OE
# sysroot handoff model (no clean way to ship an rlib/staticlib + metadata
# between recipes). This stub exists for:
#   * documentation of the component boundary,
#   * optional host-side unit tests (`cargo test --features kvm --lib --bins`,
#     Makefile hypervisor-test target),
#   * a future split if a staticlib handoff proves desirable.
#
# It intentionally does NOT PROVIDE anything consumed by other recipes and is
# not in packagegroup-cubesandbox.

require recipes-cube/cube-sandbox-common.inc

SUMMARY = "CubeSandbox microVM backend (Cloud Hypervisor v28.0 fork), built as a library"
HOMEPAGE = "https://github.com/TencentCloud/CubeSandbox"

LICENSE = "Apache-2.0 & BSD-3-Clause"
LIC_FILES_CHKSUM = "file://hypervisor/LICENSE-APACHE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
                    file://hypervisor/LICENSE-BSD-3-Clause;md5=b1ed361f9fc790c1054d81a7ef041a34"

# Rust version: hypervisor/Cargo.toml L13 declares rust-version = "1.77.0"
# (an MSRV *minimum*); Dockerfile.builder L20 pins RUST_TOOLCHAIN_HYPERVISOR
# =1.77.2, but the riscv64 flow builds the merged CubeShim workspace (which
# path-depends on hypervisor/) with `cargo +1.85` (Makefile shim-riscv64,
# MK L674). The single backported OE rust 1.89.0 toolchain (>= 1.77.0,
# >= 1.85) satisfies all of them — no per-version external toolchain needed
# (DESIGN.md §4.1). hypervisor/Cargo.lock is lockfile version = 3 (line 3),
# readable by any cargo >= 1.53; the merged CubeShim workspace lock is
# version = 4 (needs cargo >= 1.78) — both covered by 1.89.
# No external DEPENDS: cargo.bbclass pulls rust-native + libstd-rs itself.

S = "${WORKDIR}/git/hypervisor"

inherit cargo

# Kept consistent with the other cube recipes (common.inc also sets it):
# langdale's cargo_common.bbclass forces bitbake-vendored crates offline
# (L54-60) unless disabled; hypervisor/ is a huge workspace with Cargo.lock —
# deliver crates via crate:// list or `cargo vendor` tarball (DESIGN.md §4.4).
CARGO_DISABLE_BITBAKE_VENDORING = "1"
# TODO(verify): vendor crate sources for the hypervisor workspace.

# Extra cargo args via CARGO_BUILD_FLAGS in langdale (cargo.bbclass L42,L54);
# --release is BUILD_MODE's default (L41). EXTRA_OECARGO_ARGS is newer-oe-core.
CARGO_BUILD_FLAGS += "--locked --features lib_support"

do_install() {
	# Library-only build; nothing to install into the target rootfs.
	# Kept as a no-op so the recipe is packageable for -dev/debug use.
	:
}

PACKAGES = ""
COMPATIBLE_HOST = "(riscv64).*-linux"
