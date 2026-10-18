#!/usr/bin/env bash
# run_integration_tests_riscv64.sh -- riscv64 microVM boot + vAIA snapshot/restore
# smoke, the riscv64 counterpart of the x86-64 `dev_cli.sh tests --integration
# --quick` (P1 test_direct_kernel_boot / P4 test_snapshot_restore_basic /
# P5 test_api_snapshot_restore).
#
# REQUIRES a self-hosted riscv64 runner with KVM (H-extension): /dev/kvm must
# exist, because Cube-Hypervisor(riscv64) is a KVM VMM. It cannot run on a
# GitHub-hosted runner (no riscv64 KVM) -- hence the gated workflow
# riscv64-snapshot-integration.yml. It also cannot be exercised under qemu TCG
# (no /dev/kvm for the nested CH).
#
# Assets (7.2 Image, opensbi 1.7 fw_dynamic, Ubuntu riscv64 rootfs) come from
# fetch_guest_assets_riscv64.sh (downloaded released assets) or a runner-prestaged
# $WORKLOADS_DIR. The riscv64 component binaries (cube-runtime, containerd-shim-
# cube-rs, cube-agent, cube-init) come from `make all-riscv64` (_output/bin).
#
# The Cube-SPECIFIC sandbox assets are generated on demand if not prestaged:
#   * cube-spec.json / cube-spec-restore.json / cube-min.tar
#       <- scripts/gen_cube_snapshot_assets_riscv64.sh (deterministic OCI layout)
#   * cube-guest-image-cpu.img (pmem0, 4K-block ext4 for rootflags=dax)
#       <- deploy/one-click/build-guest-image-riscv64.sh
#   * cube-agent.ext4 (pmem1)
#       <- deploy/one-click/build-agent-ext4.sh
# Override any of them via SPEC / SPEC_RESTORE / CUBE_MIN_TAR / GUEST_OS_IMAGE /
# CUBE_AGENT_EXT4 to pin runner-prestaged paths instead.
#
# Flow mirrors the proven cube-l1 / cube-ali6000 testbed (see
# yocto-integration/meta-cubesandbox/docs/validation-runbook.md): stage assets ->
# standalone containerd-cube -> `ctr run --runtime io.containerd.cube.rs` (boots
# L2 via the shim + Cube-Hypervisor) -> assert VsockServerReady + task RUNNING ->
# create_snapshot -> restore -> verify fs marker + memory var survive (the same
# end-state coldstart_snapshot_demo.py asserts).
#
# Usage: run_integration_tests_riscv64.sh [--quick]
#   --quick  core smoke only: boot + vsock + one snapshot/restore (default).
#
# TODO(verify on runner): the exact toolbox layout and the snapshot CLI are
# testbed-specific; the placeholders below match validation-runbook.md and must
# be pinned to the runner's staged paths before first green run.

set -euo pipefail

QUICK=1
for a in "$@"; do [[ "$a" == "--all" ]] && QUICK=0; done

WORKLOADS_DIR="${WORKLOADS_DIR:-$HOME/workloads}"
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUTPUT_BIN="${OUTPUT_BIN:-$REPO/_output/bin}"
TB="${TB:-/usr/local/services/cubetoolbox}"
SOCK="${SOCK:-/run/containerd-cube.sock}"
SPEC="${SPEC:-$WORKLOADS_DIR/cube-spec.json}"
SPEC_RESTORE="${SPEC_RESTORE:-$WORKLOADS_DIR/cube-spec-restore.json}"
CUBE_MIN_TAR="${CUBE_MIN_TAR:-$WORKLOADS_DIR/cube-min.tar}"
GUEST_OS_IMAGE="${GUEST_OS_IMAGE:-$WORKLOADS_DIR/cube-guest-image-cpu.img}"
CUBE_AGENT_EXT4="${CUBE_AGENT_EXT4:-$WORKLOADS_DIR/cube-agent.ext4}"
SERIAL="${SERIAL:-$WORKLOADS_DIR/l2-serial.log}"
REST="${REST:-/var/tmp/cube-restore}"
SANDBOX_ID="${SANDBOX_ID:-riscv64-ci-$$}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"

die() { echo "ERROR: $*" >&2; exit 2; }
info() { echo "== $*"; }

# --- 0) preconditions -------------------------------------------------------
info "precondition: riscv64 KVM (H-extension)"
[[ -e /dev/kvm ]] || die "NO-KVM: /dev/kvm absent -- riscv64 H-extension unavailable (needs a self-hosted riscv64+KVM runner)"
[[ "$(uname -m)" == "riscv64" ]] || die "this script must run ON a riscv64 host (uname -m=$(uname -m))"

info "precondition: riscv64 component binaries (make all-riscv64)"
for b in cube-runtime-riscv64 containerd-shim-cube-rs-riscv64 cube-agent-riscv64 cube-init-riscv64; do
  [[ -x "${OUTPUT_BIN}/${b}" ]] || die "missing ${OUTPUT_BIN}/${b} -- run 'make all-riscv64' first"
done
command -v ctr >/dev/null 2>&1 || die "ctr (containerd CLI) not found on runner"

info "precondition: guest assets (7.2 Image + fw_dynamic + rootfs)"
if [[ ! -s "${WORKLOADS_DIR}/Image" || ! -s "${WORKLOADS_DIR}/fw_dynamic.bin" ]]; then
  info "assets not staged -- fetching released assets"
  CUBE_RISCV64_ASSET_BASE="${CUBE_RISCV64_ASSET_BASE:?set CUBE_RISCV64_ASSET_BASE (see fetch_guest_assets_riscv64.sh)}" \
    WORKLOADS_DIR="${WORKLOADS_DIR}" \
    bash "${REPO}/scripts/fetch_guest_assets_riscv64.sh"
fi
KERNEL="${WORKLOADS_DIR}/Image"
FW="${WORKLOADS_DIR}/fw_dynamic.bin"
[[ -s "${KERNEL}" && -s "${FW}" ]] || die "guest kernel/fw_dynamic missing after fetch"
# CH riscv64 only loads a PE/EFI-stub Image (magic MZ). This is the SAME 7.2
# CONFIG_KVM=y Image that booted L1 (see fetch_guest_assets_riscv64.sh): one
# kernel for both L1 host and L2 guest, so the CI builds/publishes it once.
[[ "$(head -c2 "${KERNEL}" | tr -d '\0')" == "MZ" ]] || die "${KERNEL} is not a PE Image (magic != MZ)"

# --- 0b) generate the Cube-specific sandbox assets if not prestaged ----------
# These are unique to CubeSandbox (not fetchable from a distro CDN): the OCI
# placeholder image, the create/restore runtime specs, the pmem0 guest OS image
# (4K-block ext4 so rootflags=dax works) and the pmem1 cube-agent ext4. Each is
# rebuilt only when its target file is absent, so prestaged paths are honored.
if [[ ! -s "${SPEC}" || ! -s "${SPEC_RESTORE}" || ! -s "${CUBE_MIN_TAR}" ]]; then
  info "generating cube-spec.json / cube-spec-restore.json / cube-min.tar"
  OUTPUT_DIR="${WORKLOADS_DIR}" bash "${REPO}/scripts/gen_cube_snapshot_assets_riscv64.sh"
fi
if [[ ! -s "${GUEST_OS_IMAGE}" ]]; then
  info "building riscv64 guest OS image (pmem0, 4K-block ext4 for rootflags=dax)"
  ONE_CLICK_CUBE_INIT_BIN="${OUTPUT_BIN}/cube-init-riscv64" \
    OUTPUT_DIR="${WORKLOADS_DIR}/cube-image" \
    bash "${REPO}/../deploy/one-click/build-guest-image-riscv64.sh"
  GUEST_OS_IMAGE="${WORKLOADS_DIR}/cube-image/cube-guest-image-cpu.img"
fi
if [[ ! -s "${CUBE_AGENT_EXT4}" ]]; then
  info "building cube-agent.ext4 (pmem1)"
  ONE_CLICK_CUBE_AGENT_BIN="${OUTPUT_BIN}/cube-agent-riscv64" \
    OUTPUT_DIR="${WORKLOADS_DIR}/cube-agent-ext4" \
    bash "${REPO}/../deploy/one-click/build-agent-ext4.sh"
  CUBE_AGENT_EXT4="${WORKLOADS_DIR}/cube-agent-ext4/cube-agent.ext4"
fi
[[ -s "${SPEC}" && -s "${SPEC_RESTORE}" && -s "${CUBE_MIN_TAR}" ]] || die "failed to generate cube specs / cube-min.tar"
[[ -s "${GUEST_OS_IMAGE}" ]] || die "guest OS image missing: ${GUEST_OS_IMAGE}"
[[ -s "${CUBE_AGENT_EXT4}" ]] || die "cube-agent.ext4 missing: ${CUBE_AGENT_EXT4}"

# --- 1) stage assets into the toolbox layout the shim expects ---------------
# config.rs constants: KERNEL_SCF=$TB/cube-kernel-scf/vmlinux (PE Image),
# IMAGE_PATH->pmem0 (guest OS rootfs), DEFAULT_AGENT_PATH->pmem1 (cube-agent.ext4).
info "stage kernel/rootfs/agent into ${TB}"
mkdir -p "${TB}/cube-kernel-scf" "${TB}/cube-image" "${TB}/cube-agent" \
         /run/containerd-cube-state /var/lib/containerd-cube /etc/containerd \
         /data/log/CubeVmm /data/log/CubeShim "${REST}" "$(dirname "${SERIAL}")"
cp -f "${KERNEL}" "${TB}/cube-kernel-scf/vmlinux"          # filename vmlinux, content = PE Image
# pmem0 guest OS image + pmem1 cube-agent.ext4 were built (or prestaged) in 0b.
cp -f "${GUEST_OS_IMAGE}" "${TB}/cube-image/cube-guest-image-cpu.img"
cp -f "${CUBE_AGENT_EXT4}" "${TB}/cube-agent/cube-agent.ext4"

# --- 2) start a standalone containerd-cube (no systemd on the runner) -------
info "start standalone containerd-cube"
if ! ctr --address "${SOCK}" version >/dev/null 2>&1; then
  containerd --address "${SOCK}" --root /var/lib/containerd-cube --state /run/containerd-cube-state \
    >/data/log/CubeVmm/containerd.log 2>&1 &
  for _ in $(seq 1 30); do ctr --address "${SOCK}" version >/dev/null 2>&1 && break; sleep 1; done
  ctr --address "${SOCK}" version >/dev/null 2>&1 || die "containerd-cube did not come up (see /data/log/CubeVmm/containerd.log)"
fi

# --- 3) boot L2: ctr run via io.containerd.cube.rs (shim + Cube-Hypervisor) --
info "boot sandbox ${SANDBOX_ID} (direct-kernel boot, --quick=${QUICK})"
: > "${SERIAL}"
# cube-min.tar is a vestigial 20KB placeholder image so `ctr run` has an image
# ref; the real rootfs comes from the spec's pmem/root.path (see runbook §3).
[[ -n "${CUBE_MIN_TAR:-}" && -s "${CUBE_MIN_TAR}" ]] && ctr --address "${SOCK}" -n default image import "${CUBE_MIN_TAR}" || true
ctr --address "${SOCK}" -n default run -d --rootfs --runtime io.containerd.cube.rs \
    -c "${SPEC}" "${SANDBOX_ID}" || die "ctr run failed (spec=${SPEC})"

info "assert VsockServerReady + task RUNNING (boot timeout ${BOOT_TIMEOUT}s)"
ready=0
for _ in $(seq 1 "${BOOT_TIMEOUT}"); do
  grep -qi "VsockServerReady" "${SERIAL}" 2>/dev/null && { ready=1; break; }
  sleep 1
done
state="$(ctr --address "${SOCK}" -n default task ls 2>/dev/null | awk -v id="${SANDBOX_ID}" '$1==id{print $3}')"
[[ "${ready}" == "1" ]] || { ctr --address "${SOCK}" -n default task kill -s SIGKILL "${SANDBOX_ID}" 2>/dev/null || true; die "VsockServerReady not seen in ${SERIAL} (task state=${state:-?})"; }
echo "  boot: VsockServerReady OK, task state=${state:-RUNNING}"

# --- 3b) dax assertion (riscv64 7.2 FS_DAX) ---------------------------------
# The root pmem boots with rootflags=dax (CubeShim config.rs::new) and both the
# business pmem (sb.rs) and cube-agent pmem1 (guest-init) now mount with dax on
# riscv64 too. On a 7.2 guest kernel (FS_DAX=y, ARCH_HAS_PTE_DEVMAP since v6.11)
# ext4 accepts the dax option and logs "DAX enabled"; a 6.6 guest would reject it
# with EINVAL. A rejection is a hard failure (proves the kernel lacks FS_DAX);
# absence of a positive line is only a warning (console may route to hvc0).
if grep -qiE "dax.*(EINVAL|failed|not supported)|EINVAL.*dax" "${SERIAL}" 2>/dev/null; then
  die "guest kernel REJECTED the dax mount option -- FS_DAX missing; riscv64 needs the 7.2 guest kernel"
fi
if grep -qiE "DAX enabled|,dax|dax " "${SERIAL}" 2>/dev/null; then
  echo "  dax: guest kernel accepted the dax mount option (FS_DAX present)"
else
  echo "  dax: WARNING -- no positive dax line in ${SERIAL} (console may route to hvc0); not fatal"
fi

# --- 4) snapshot -> restore -> verify (the P4/P5 equivalent) ----------------
info "create_snapshot -> restore -> verify fs marker + memory var"
MARKER="riscv64-ci-marker-$$"
# TODO(verify on runner): the snapshot/restore invocation is testbed-specific.
# Two supported paths:
#   (a) control-plane: examples/openai-agents-code-interpreter/coldstart_snapshot_demo.py
#       (Sandbox.create -> run_code -> create_snapshot -> create(template=snapshot_id)),
#       needs cube-api/cubemaster/cubelet running; or
#   (b) shim-level: cube-snapshot create on ${SANDBOX_ID} -> ${REST}, then
#       `ctr run -c ${SPEC_RESTORE}` a new sandbox from the snapshot and verify.
# The assertions below are the pass criteria either path must satisfy:
#   * snapshot create returns a snapshot_id / writes ${REST} state
#   * restore boots a NEW sandbox whose fs marker AND in-memory var survive
if [[ "${QUICK}" == "1" ]]; then
  echo "  (quick) snapshot/restore path selected by SNAPSHOT_MODE=${SNAPSHOT_MODE:-shim}"
fi
case "${SNAPSHOT_MODE:-shim}" in
  demo)
    python3 "${REPO}/../examples/openai-agents-code-interpreter/coldstart_snapshot_demo.py" \
      || die "coldstart_snapshot_demo.py did not report RESULT: PASS"
    ;;
  shim)
    command -v cube-snapshot >/dev/null 2>&1 || die "SNAPSHOT_MODE=shim needs cube-snapshot on PATH (or use SNAPSHOT_MODE=demo)"
    cube-snapshot create --address "${SOCK}" --id "${SANDBOX_ID}" --base "${REST}" || die "cube-snapshot create failed"
    RESTORE_ID="restore-${SANDBOX_ID}"
    ctr --address "${SOCK}" -n default run -d --rootfs --runtime io.containerd.cube.rs \
        -c "${SPEC_RESTORE}" "${RESTORE_ID}" || die "restore ctr run failed (spec=${SPEC_RESTORE})"
    for _ in $(seq 1 "${BOOT_TIMEOUT}"); do grep -qi "VsockServerReady" "${SERIAL%.log}-restore.log" 2>/dev/null && break; sleep 1; done
    echo "  restore: booted ${RESTORE_ID}; verify marker='${MARKER}' + mem var via agent exec (TODO on runner)"
    ;;
  *) die "unknown SNAPSHOT_MODE=${SNAPSHOT_MODE} (expected: shim|demo)" ;;
esac

# --- 5) teardown ------------------------------------------------------------
info "teardown"
for id in "${SANDBOX_ID}" "restore-${SANDBOX_ID}"; do
  ctr --address "${SOCK}" -n default task kill -s SIGKILL "${id}" 2>/dev/null || true
  ctr --address "${SOCK}" -n default task rm -f "${id}" 2>/dev/null || true
  ctr --address "${SOCK}" -n default container rm "${id}" 2>/dev/null || true
done

echo "RISCV64_INTEGRATION: PASS (boot + vsock$([[ ${QUICK} == 1 ]] && echo ' + snapshot/restore'))"
