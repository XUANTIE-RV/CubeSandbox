# packagegroup-cubesandbox: runtime package set for a CubeSandbox compute node.
# Component/binary names verified against Makefile RISCV64_BINARIES (MK L96-109)
# and deploy/one-click/install.sh layout.

SUMMARY = "CubeSandbox compute-node runtime components"
LICENSE = "Apache-2.0"

inherit packagegroup

# Core microVM path (Phase 1). Extend as Phase 2-4 recipes land:
#   cube-agent cube-init cube-api cubemaster cubeops cubetemplatecenter
#   cube-lifecycle-manager cube-volume-s3 cubevsmapdump
RDEPENDS:${PN} = " \
    containerd-shim-cube \
    containerd-opencontainers \
    cubelet \
"

# Non-package runtime assets staged by other means (DESIGN.md §7):
#   * guest kernel Image (linux-cube-guest) -> /usr/local/services/cubetoolbox/cube-kernel-scf/vmlinux
#     SELECTED via PREFERRED_VERSION_linux-cube-guest: 6.6 (default, in-tree
#     XuanTie source, gcc-buildable) or 7.2 (upstream-parity, clang-flavoured,
#     DEFAULT_PREFERENCE=-1). See DESIGN.md §5.1. Both deploy Image as `vmlinux`.
#   * guest OS image (cube-init as /sbin/init) + cube-agent.ext4 (cube-guest-assets recipe, TODO)
#     NOTE cube-agent MUST be a static ELF (deploy/one-click/lib/guest-image.sh
#     L376-399 install_static_agent_binary dies on any dynamic dep) => build it
#     under TCLIBC=musl with RUSTFLAGS -C target-feature=+crt-static (cube-agent recipe).
#   * containerd runtime registration for io.containerd.cube.rs (config fragment, TODO)
#   * host kernel: /dev/kvm (RISC-V H-ext + AIA), BPF syscall + BTF for cubevs
# TODO(verify): virtiofsd — no recipe exists anywhere in the xuantie tree;
# confirm whether the riscv64 shim spawns virtiofsd (DESIGN.md §7/§9.6).

COMPATIBLE_HOST = "(riscv64).*-linux"
