# cubesandbox-toolchain-versions.inc
# Selects the backported rust 1.89.0 / go 1.25.7 recipe sets shipped in
# meta-cubesandbox/recipes-devtools/ over oe-core langdale's rust 1.63.0 /
# go 1.22.8 (openembedded-core/meta/recipes-devtools/{rust,go}/).
#
# HOW TO ACTIVATE (this file is NOT auto-included by layer.conf):
#   add to the build's conf/local.conf:
#     require conf/distro/include/cubesandbox-toolchain-versions.inc
#   (meta-cubesandbox is on BBPATH once added to bblayers.conf, so the
#   require resolves — same pattern meta-xuantie uses for its includes.)
#
# WHY EXPLICIT PREFERRED_VERSION instead of "highest PV wins":
#   * Under the xuantie DISTROs TCMODE = "external"
#     (meta-xuantie/conf/distro/include/xuantie-base.inc L13), so oe-core's
#     tcmode-default.inc is never parsed and its RUSTVERSION ?= "1.63%" /
#     PREFERRED_VERSION_{rust,cargo,libstd-rs,rust-cross-*} chain
#     (tcmode-default.inc L30, L88-92) does not apply. Bitbake would fall
#     back to "highest PV", which silently flips every rust/go consumer in
#     the build (meta-xuantie recipes-electron/electron, ripgrep,
#     python3-cryptography, meta-virtualization containerd/docker-ce) the
#     moment our newer recipes are visible. Pinning makes the flip explicit
#     and reviewable, and lets an integrator keep 1.63/1.22.8 for the rest
#     of the distro while cube recipes build against the newer set by
#     NOT setting these (see DESIGN.md §9 risk 2 for the side-effect analysis).

# ---- Rust: one toolchain (1.89.0) satisfies every CubeSandbox component ----
# The pins in the repo are MINIMUMS:
#   hypervisor/Cargo.toml L13: rust-version = "1.77.0"   (MSRV field)
#   CubeShim/rust-toolchain.toml: channel = "1.77.2"      (but Makefile
#     shim-riscv64 L674 builds the merged workspace with `cargo +1.85`)
#   CubeAPI/rust-toolchain.toml: 1.85
#   agent/, agent/libs/, cubecow/rust-toolchain.toml: 1.89
#   docker/Dockerfile.builder L19-22: default 1.89 / hypervisor 1.77.2 /
#     e2b-api 1.85 / agent 1.89
# A single rust 1.89.0 >= all of them, so ONE backported toolchain replaces
# the three external prebuilt toolchains of the previous design.
# Hard floor is actually cargo's lockfile support: CubeShim/Cargo.lock,
# agent/Cargo.lock and guest-init/Cargo.lock are lockfile `version = 4`
# (line 3 of each), which cargo < 1.78 cannot parse -> `cargo build
# --locked` (Makefile L674) fails outright on oe-core's cargo 1.63.
RUSTVERSION ?= "1.89%"
PREFERRED_VERSION_rust ?= "1.89.0"
PREFERRED_VERSION_rust-native ?= "1.89.0"
PREFERRED_VERSION_rust-llvm-native ?= "1.89.0"
PREFERRED_VERSION_libstd-rs ?= "1.89.0"
# cargo is a separate PN in langdale (recipes-devtools/cargo/cargo_1.63.0.bb).
# In the oe-core release the 1.89 recipes are taken from, cargo may be built
# inside the rust recipe instead — keep both lines; a stale one is a no-op.
PREFERRED_VERSION_cargo ?= "1.89.0"
PREFERRED_VERSION_cargo-native ?= "1.89.0"
# TODO(verify): exact PN set (cargo_1.89.0.bb vs merged-into-rust) once the
# donor oe-core release is chosen; see recipes-devtools/rust/rust_1.89.0.bb.

# ---- Go: 1.25.7 (go.mod floor) ----
# Cubelet/CubeMaster/CubeOps/CubeTemplateCenter/cube-lifecycle-manager
# go.mod: `go 1.25.7`; CubeNet/cubevs go.mod: `go 1.24.8`;
# docker/Dockerfile.builder L12: ARG GO_VERSION=1.25.7.
# go.bbclass target builds DEPENDS on virtual/${TUNE_PKGARCH}-go +
# virtual/${TARGET_PREFIX}go-runtime (classes-recipe/go.bbclass L38-42),
# provided by go-cross-riscv64 / go-runtime — pin the whole family.
PREFERRED_VERSION_go ?= "1.25.7"
PREFERRED_VERSION_go-native ?= "1.25.7"
PREFERRED_VERSION_go-binary-native ?= "1.25.7"
PREFERRED_VERSION_go-cross-riscv64 ?= "1.25.7"
PREFERRED_VERSION_go-runtime ?= "1.25.7"
PREFERRED_VERSION_go-runtime-riscv64 ?= "1.25.7"
# TODO(verify): go-runtime PN spelling in the donor release (langdale builds
# go-runtime_1.22.8.bb; newer oe-core renamed/merged some variants).

# ---- Guest kernel: 6.6 (bring-up default) vs 7.2 (upstream-parity) ----
# Default is 6.6.x: source is already in-tree/buildable with the xuantie GCC
# (see recipes-kernel/linux/linux-cube-guest_6.6.bb). Select 7.2 with:
#   PREFERRED_VERSION_linux-cube-guest = "7.2"
# Both recipes also carry DEFAULT_PREFERENCE so the 6.6 one wins even without
# this include.
PREFERRED_VERSION_linux-cube-guest ?= "6.6"
