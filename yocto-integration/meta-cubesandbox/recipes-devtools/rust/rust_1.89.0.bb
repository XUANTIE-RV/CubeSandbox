# rust_1.89.0.bb — SKELETON: backported rust recipe set for meta-cubesandbox.
#
# PURPOSE
#   CubeSandbox needs rust/cargo >= 1.85 everywhere and lockfile-version-4
#   support (cargo >= 1.78): CubeShim/Cargo.lock, agent/Cargo.lock,
#   guest-init/Cargo.lock all start with `version = 4` (line 3). The pins are
#   MINIMUMS (hypervisor/Cargo.toml L13 rust-version = "1.77.0";
#   rust-toolchain.toml channels 1.77.2/1.85/1.89), so ONE 1.89.0 toolchain
#   satisfies every component. This replaces the rejected external-prebuilt
#   rustup stubs of the prior design; recipes keep `inherit cargo` and build
#   with OE's standard cross machinery (rust-native + cargo-native +
#   libstd-rs target std — the exact model that already built
#   meta-xuantie/recipes-electron/ripgrep/ripgrep_13.0.0.bb in this tree:
#   xuantie-build/ngf/tmp-glibc/work/riscv64-oe-linux/ripgrep/13.0.0-r0/
#   and work/x86_64-linux/{rust-native,cargo-native,rust-llvm-native}).
#
# WHAT MUST BE BACKPORTED (do NOT hand-write; copy as a coherent set)
#   Donor: an oe-core release that ships rust 1.89.0. TODO(verify) which
#   release that is (>= whinlatter/master era; the local tree is langdale:
#   openembedded-core/meta/conf/layer.conf L10 LAYERSERIES_CORENAMES =
#   "langdale", bitbake 2.2.0 per openembedded-core/bitbake/lib/bb/__init__.py
#   L12). Copy, at minimum, from the donor's meta/recipes-devtools/:
#     rust/rust_1.89.0.bb  rust.inc  rust-source.inc  rust-snapshot.inc
#     rust-llvm_1.89.0.bb  rust-llvm.inc  libstd-rs_1.89.0.bb  libstd-rs.inc
#     rust-target.inc  rust/ (patch dir)
#     cargo/cargo_1.89.0.bb + cargo.inc  (ONLY if the donor still has a
#       separate cargo PN; newer oe-core builds cargo inside rust — in that
#       case langdale's cargo.bbclass `BASEDEPENDS:append = " cargo-native"`
#       (classes-recipe/cargo.bbclass L19) must be satisfied by the rust
#       recipe PROVIDES cargo-native, or the cargo/rust bbclasses must be
#       backported alongside — see RISKS).
#   Plus the matching bbclasses if the donor's recipes need them:
#   classes*/{rust-common,rust-target-config,cargo,cargo_common}.bbclass.
#   NOTE: meta/classes-cube/ overrides are NOT possible without editing
#   bitbake.conf's BBPATH order; instead ship them as same-name files under
#   meta-cubesandbox/classes-recipe/ — our BBFILE_PRIORITY 7 does NOT affect
#   bbclass search order (BBPATH does: our layer is appended after oe-core,
#   so oe-core's classes WIN). => If the donor rust set requires newer
#   bbclasses, the workable route is a "mixin" overlay directory placed on
#   BBPATH *before* oe-core, or a full second oe-core (donor) layer added to
#   bblayers.conf above openembedded-core. TODO(verify) at implementation.
#
# WHY THIS IS HARD ON LANGDALE (grounded, from the tree's own precedent)
#   meta-xuantie-ngf/recipes-devtools/rust/rust-standalone-native_1.95.0.bb
#   L1-20 documents the same wall and chose prebuilt rust-lang.org binaries
#   instead: langdale's rust-source.inc/rust-snapshot.inc bootstrap is pinned
#   at 1.62.0 (openembedded-core/meta/recipes-devtools/rust/rust-snapshot.inc
#   L8-9), the 1.89 bootstrap chain needs its own stage0 snapshot tarballs,
#   and the donor recipes may use bitbake features newer than 2.2.0. That
#   prebuilt route is the FALLBACK if the backport proves unbuildable, but
#   per directive it is NOT the design: we use OE's own cargo/go machinery.
#
# SELECTION
#   conf/distro/include/cubesandbox-toolchain-versions.inc pins
#   PREFERRED_VERSION_{rust,rust-native,cargo-native,libstd-rs,...} = 1.89.0.
#   Under TCMODE="external" (meta-xuantie/conf/distro/include/xuantie-base.inc
#   L13) oe-core's tcmode-default.inc RUSTVERSION chain (L30, L88-92) is not
#   parsed at all, so without our include the mere presence of this recipe
#   flips rust globally by highest-PV — the include makes that explicit.
#
# GLOBAL-BUMP SIDE EFFECTS (accepted; see DESIGN.md §4.4)
#   rust-native consumers rebuilt against 1.89: ripgrep (meta-xuantie,
#   `inherit cargo`), electron (meta-xuantie/recipes-electron/electron.bb
#   DEPENDS rust-native — per rust-standalone-native_1.95.0.bb L26-28),
#   python3-cryptography (built with libstd-rs 1.63 in the ngf tmp).
#   Newer rustc compiling older crates is normally fine; electron/vendored
#   -sys crates are the risk. TODO(verify) by rebuilding them once.
#
# The actual recipe body is intentionally absent until the donor release is
# picked; this stub exists so the layout/BBFILES globs and the version
# selection mechanism are reviewable now.
#
# LICENSE of rust itself: "Apache-2.0 WITH LLVM-exception | Apache-2.0 | MIT"
# (keep the donor's LIC_FILES_CHKSUM).

SUMMARY = "Rust 1.89.0 backport placeholder (see file header for the donor-copy instructions)"
LICENSE = "CLOSED"
PN = "rust"
PV = "1.89.0"
# Safety: until the donor copy lands, this stub must NEVER win over oe-core's
# working rust_1.63.0.bb by highest-PV. DEFAULT_PREFERENCE -2 keeps 1.63 the
# default; the PREFERRED_VERSION pins in cubesandbox-toolchain-versions.inc
# override DEFAULT_PREFERENCE explicitly once the recipe is real.
DEFAULT_PREFERENCE = "-2"
# TODO(verify): replace this whole file with the donor rust_1.89.0.bb copy.
