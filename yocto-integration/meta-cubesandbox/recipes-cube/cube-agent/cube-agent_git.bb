# cube-agent: in-guest agent binary. Runs INSIDE the microVM (shipped via
# cube-agent.ext4 / guest OS image), not on the Yocto host rootfs — packaged
# here for assembly into the guest assets (see cube-guest-assets, DESIGN.md §5).
#
# OE-NATIVE BUILD (current directive): `inherit cargo` with the backported rust
# 1.89.0 toolchain (agent/rust-toolchain.toml channel = "1.89";
# Dockerfile.builder L22 RUST_TOOLCHAIN_AGENT=1.89). Upstream line
# (Makefile agent-riscv64, MK L496-498):
#   TRIPLE=riscv64gc-unknown-linux-musl \
#   LIBSECCOMP_LIB_PATH=/usr/local/riscv64-linux-musl/libseccomp/lib make -j1
# The TRIPLE / linker are now supplied by cargo.bbclass for whichever libc the
# distro selects; we no longer hard-code them.
#
# STATIC-musl note: upstream cube-agent is a fully static musl ELF and
# deploy/one-click/lib/guest-image.sh L376-399 (install_static_agent_binary)
# HARD-REQUIRES that: it runs ldd/file on the binary and `die`s if any dynamic
# dep is found ("must be a static ELF"). So for the guest-image path the agent
# MUST be static. Two OE ways to satisfy that:
#   (a) build this recipe in a TCLIBC=musl distro variant, and add
#       RUSTFLAGS "-C target-feature=+crt-static" so cargo emits a static
#       musl binary; libseccomp.a is available (oe-core libseccomp 2.5.4 sets
#       DISABLE_STATIC = "" at libseccomp_2.5.4.bb L25). This is the faithful
#       reproduction of upstream and is RECOMMENDED for the guest payload.
#   (b) for a plain glibc image the agent is dynamic; that only matters if you
#       re-use install_static_agent_binary — the guest-image build would reject
#       it. See DESIGN.md §4.3.
# The default below targets the glibc image (dynamic); the static-musl knobs
# are gated on libc-musl overrides so one recipe serves both.

require recipes-cube/cube-sandbox-common.inc

SUMMARY = "CubeSandbox in-guest agent (runs inside the microVM)"
HOMEPAGE = "https://github.com/TencentCloud/CubeSandbox"

S = "${WORKDIR}/git/agent"

# libseccomp consumed as a TARGET lib via pkg-config (oe-core 2.5.4, riscv64).
# Under musl we want the static archive; under glibc, shared.
DEPENDS += "libseccomp"

inherit cargo

CARGO_DISABLE_BITBAKE_VENDORING = "1"
# TODO(verify): agent/ ships Cargo.lock (lockfile version = 4, line 3) and a
# .cargo/config.toml that only sets x86_64/aarch64 musl linkers (verified) —
# no riscv64 stanza, no vendor dir. Supply crates via crate:// list or a
# `cargo vendor` tarball (DESIGN.md §4.4).

# "seccomp" feature is on by default in agent/Makefile (SECCOMP := yes).
# langdale cargo.bbclass takes extra args via CARGO_BUILD_FLAGS (L42, L54);
# --release comes from BUILD_MODE (L41). EXTRA_OECARGO_ARGS does NOT exist in
# langdale (newer oe-core only) — if the backported class set provides it,
# prefer it there.
CARGO_BUILD_FLAGS += "--locked --features seccomp"

# --- libc handling for libseccomp-sys ---
# GLIBC (default): libseccomp-sys links the shared lib via pkg-config; the
#   target sysroot carries libseccomp.pc and cargo_common.bbclass already sets
#   PKG_CONFIG_ALLOW_CROSS=1 (L26). NO extra env needed.
# MUSL static (opt-in guest payload, guest-image.sh L376-399 requires a static
#   ELF): tell libseccomp-sys to link the static archive and force rustc to
#   statically link musl libc. Both are injected ONLY for the musl build so a
#   glibc build never sees an empty/half-set env.
RUSTFLAGS:append:libc-musl = " -C target-feature=+crt-static"
do_compile:prepend:libc-musl() {
	export LIBSECCOMP_LINK_TYPE="static"
	export LIBSECCOMP_LIB_PATH="${STAGING_DIR_TARGET}${libdir}"
}
# oe-core libseccomp 2.5.4 produces the static archive (DISABLE_STATIC = "",
# libseccomp_2.5.4.bb L25), so libseccomp.a is present in the musl sysroot.

# cargo.bbclass installs the built executable(s) into ${bindir}
# (cargo_do_install L63-88), yielding cube-agent automatically. B is
# out-of-tree (cargo.bbclass L27).

COMPATIBLE_HOST = "(riscv64).*-linux"

# ---- sibling stub: cube-init (guest PID1, guest-init/ dir, rust 1.89) ----
# Makefile cube-init-riscv64 (MK L505-507): TRIPLE=riscv64gc-unknown-linux-musl
# make -j1 -> target/.../release/cube-init installed as _output/bin/cube-init.
# guest-init/Cargo.lock is also lockfile version = 4 (line 3). cube-init is
# PID1 of the guest OS image; like cube-agent it should be static-musl.
# TODO: create recipes-cube/cube-init/cube-init_git.bb as a copy of this recipe
# with S = "${WORKDIR}/git/guest-init", NO libseccomp dep, binary "cube-init",
# and the same libc-musl crt-static gating.
