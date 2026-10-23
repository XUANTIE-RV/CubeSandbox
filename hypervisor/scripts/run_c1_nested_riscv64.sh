#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_c1_nested_riscv64.sh -- C1 backend orchestrator for the riscv64 snapshot
# integration test (plan 件 4, C1 = GitHub-hosted x86 runner + in-job QEMU/TCG L1).
#
# It boots a riscv64 L1 under QEMU TCG with -cpu max (H-extension) + AIA
# (aplic-imsic), so the L1 kernel (7.2, CONFIG_KVM=y) gets /dev/kvm from QEMU's
# emulated H-extension. cube-runtime / Cube-Hypervisor then run INSIDE that L1 and
# boot an L2 microVM over the L1's nested KVM, exercising vAIA snapshot/restore --
# no self-hosted riscv64 hardware required. All-TCG, hence slow.
#
# This is the CI codification of the hand-run cube-72-snap-bed testbed
# (start-l1-*.sh + run-create4.sh + run-restore.sh + verify), which was validated
# end-to-end: L1 boot -> create+snapshot -> restore reaches RUNNING, at -smp 1 and
# (with the KVM dirty-log zero-page backport in the guest Image) at -smp 4.
#
# Inputs (env):
#   WORKLOADS_DIR   dir with the fetched/built assets (default $HOME/workloads):
#                     Image            7.2 PE guest/L1 kernel (KVM=y, + backport)
#                     fw_dynamic.bin   OpenSBI 1.7
#                     ubuntu-riscv64.raw  Ubuntu noble riscv64 rootfs (raw; from fetch)
#                     cube-guest-image-cpu.img  L2 guest OS rootfs (pmem0)
#                     cube-agent.ext4           cube-agent (pmem1)
#                     cube-spec.json / cube-spec-restore.json / cube-min.tar
#   BIN_DIR         dir with the riscv64 component binaries (default _output/bin):
#                     cube-runtime-riscv64 containerd-shim-cube-rs-riscv64
#                     cube-agent-riscv64 cube-init-riscv64
#   L1_SMP          L1 vCPU count (default 4; needs the zero-page backport Image)
#   L1_MEM          L1 memory (default 4G)
#   QEMU            qemu-system-riscv64 (default: from PATH)
#   L1_PORT         host ssh port forwarded to L1:22 (default 22699)
#   L1_PREEMPT      L1 kernel runtime preemption model (default none; the config
#                   has CONFIG_PREEMPT_DYNAMIC=y, so none|voluntary|full|lazy all
#                   work). The nested-TCG L2 wedge rate is strongly dependent on
#                   this (lazy ~50%, none ~5%); use lazy for wedge-debug runs.
#   L1_GDBSTUB      1 = launch the L0 QEMU with a gdbstub on 127.0.0.1:L1_GDB_PORT
#                   and, on in-L1 failure, hold the L1 up and dump per-vCPU
#                   state (info threads / registers / backtraces) before
#                   poweroff (default 0). Needs gdb-multiarch on the host; if
#                   L1_VMLINUX points at the L1 kernel's vmlinux (debug_info),
#                   backtraces resolve against L1 kernel symbols.
#   L1_GDB_PORT     gdbstub TCP port (default 12999)
#   L1_VMLINUX      optional path to the L1 kernel vmlinux for gdb symbols
#                   (auto-discovered from a fixed WORK_DIR kernel build)
#   RUNDIR          scratch dir for the L1 disks/serial/pid (default a mktemp -d)
#   RUN_MODE        integration (default): run the shim-level snapshot/restore
#                   smoke inside the L1 (run_integration_tests_riscv64.sh);
#                   control-plane: bring up the full CubeSandbox control plane
#                   (mysql/redis/cubeops/cubemaster/templatecenter/cubelet/
#                   cube-api) inside the L1, register a code-interpreter
#                   template via a local registry, and run the no-LLM
#                   coldstart_snapshot_demo.py end-to-end
#                   (run_control_plane_riscv64.sh). Control-plane mode expects
#                   ${WORKLOADS_DIR}/control-plane/{registry-riscv64,
#                   crane-riscv64,sandbox-riscv64.tar,py3-ci-layer-persist.tar.gz}
#                   (the workflow fetches them from the ci-assets release).
#
# Exit 0 on success (restore reached RUNNING, no corruption); non-zero otherwise.
set -euo pipefail

WORKLOADS_DIR="${WORKLOADS_DIR:-$HOME/workloads}"
BIN_DIR="${BIN_DIR:-$(pwd)/_output/bin}"
L1_SMP="${L1_SMP:-4}"
L1_MEM="${L1_MEM:-4G}"
QEMU="${QEMU:-qemu-system-riscv64}"
L1_PORT="${L1_PORT:-22699}"
L1_PREEMPT="${L1_PREEMPT:-none}"
L1_GDBSTUB="${L1_GDBSTUB:-0}"
L1_GDB_PORT="${L1_GDB_PORT:-12999}"
RUNDIR="${RUNDIR:-$(mktemp -d /tmp/c1-l1.XXXXXX)}"
INTEGRATION="${INTEGRATION:-$(dirname "$0")/run_integration_tests_riscv64.sh}"
RUN_MODE="${RUN_MODE:-integration}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CONTROL_PLANE="${CONTROL_PLANE:-$(dirname "$0")/run_control_plane_riscv64.sh}"
CP_ASSETS_DIR="${CP_ASSETS_DIR:-${WORKLOADS_DIR}/control-plane}"

info() { echo "[c1] $*"; }
die()  { echo "[c1] ERROR: $*" >&2; exit 2; }

# Attach to the L0 QEMU gdbstub and dump the full per-vCPU state of the
# (still running, wedged) L1: thread list, backtraces (symbolized when
# L1_VMLINUX is available) and registers. This is the L0-side complement of
# the in-L1 wedge forensics: it shows WHERE each L1 vCPU is stuck (L1 kernel
# sleep vs. executing L2 guest code).
dump_gdbstub_forensics() {
  local log="${RUNDIR}/gdbstub-forensics.log"
  local gdb vmlinux c
  gdb=$(command -v gdb-multiarch 2>/dev/null || command -v gdb 2>/dev/null || true)
  if [[ -z "${gdb}" ]]; then
    echo "no gdb/gdb-multiarch on the host; gdbstub forensics skipped" >"${log}"
    return
  fi
  vmlinux="${L1_VMLINUX:-}"
  if [[ -z "${vmlinux}" ]]; then
    for c in "${RUNDIR}/../kernel-build/build/vmlinux"; do
      [[ -s "${c}" ]] && { vmlinux="${c}"; break; }
    done
  fi
  info "gdbstub forensics: gdb=${gdb} vmlinux=${vmlinux:-none} -> ${log}"
  {
    echo "=== gdbstub forensics ($(date -u +%FT%TZ)) ==="
    echo "gdb: ${gdb}"
    echo "vmlinux: ${vmlinux:-<none, registers will be raw>}"
    "${gdb}" -nx -batch \
      ${vmlinux:+"${vmlinux}"} \
      -ex "set pagination off" \
      -ex "set architecture riscv:rv64" \
      -ex "target remote 127.0.0.1:${L1_GDB_PORT}" \
      -ex "monitor info status" \
      -ex "monitor info cpus" \
      -ex "info threads" \
      -ex "thread apply all bt" \
      -ex "thread apply all info registers" \
      -ex "detach" 2>&1
    echo "=== end gdbstub forensics ==="
  } >"${log}" 2>&1
}

command -v "${QEMU}" >/dev/null 2>&1 || die "qemu-system-riscv64 not found (set QEMU=)"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"

qemu_maj="$("${QEMU}" --version | sed -n 's/.*version \([0-9]\+\).*/\1/p' | head -1)"
if [ -n "${qemu_maj}" ] && [ "${qemu_maj}" -lt 11 ]; then
  info "WARN: ${QEMU} is qemu ${qemu_maj}.x -- qemu < 11 TCG IMSIC/AIA is broken for the nested"
  info "      7.2 L1 (KVM_CAP_IRQCHIP never reported; shim panics at check_required_extensions)."
  info "      Build community qemu 11 with hypervisor/scripts/build_qemu_riscv64.sh."
fi

# --- preflight: required assets ---------------------------------------------
for a in Image fw_dynamic.bin cube-guest-image-cpu.img cube-agent.ext4 \
         cube-spec.json cube-spec-restore.json cube-min.tar; do
  [[ -s "${WORKLOADS_DIR}/${a}" ]] || die "missing asset ${WORKLOADS_DIR}/${a}"
done
for b in cube-runtime-riscv64 containerd-shim-cube-rs-riscv64 cube-agent-riscv64 cube-init-riscv64; do
  [[ -x "${BIN_DIR}/${b}" ]] || die "missing component binary ${BIN_DIR}/${b}"
done
[[ -x "${INTEGRATION}" ]] || chmod +x "${INTEGRATION}" 2>/dev/null || die "integration script not found: ${INTEGRATION}"
# The L1 kernel must be a PE/EFI-stub Image (CH riscv64 load_kernel rejects ELF).
magic=$(head -c2 "${WORKLOADS_DIR}/Image" 2>/dev/null || true)
[[ "${magic}" == "MZ" ]] || die "Image is not a PE/EFI-stub (magic='${magic}'); CH would reject it"

# --- control-plane mode preflight --------------------------------------------
if [[ "${RUN_MODE}" == "control-plane" ]]; then
  [[ -s "${CONTROL_PLANE}" ]] || die "control-plane script not found: ${CONTROL_PLANE}"
  [[ -d "${REPO}/hypervisor/scripts/control-plane-riscv64" ]] || die "missing ${REPO}/hypervisor/scripts/control-plane-riscv64"
  [[ -s "${REPO}/deploy/one-click/config-cube.toml" ]] || die "missing ${REPO}/deploy/one-click/config-cube.toml"
  [[ -s "${REPO}/examples/openai-agents-code-interpreter/coldstart_snapshot_demo.py" ]] || die "missing coldstart_snapshot_demo.py in the checkout"
  for b in cubemaster-riscv64 cubemastercli-riscv64 templatecenter-riscv64 \
           cubeops-riscv64 cubelet-riscv64 cube-api-riscv64 cube-volume-s3-riscv64 \
           cubevsmapdump-riscv64; do
    [[ -x "${BIN_DIR}/${b}" ]] || die "missing control-plane binary ${BIN_DIR}/${b} -- run 'make all-riscv64'"
  done
  for a in registry-riscv64 crane-riscv64 coredns-riscv64 mkcert-riscv64 \
           cube-proxy-image.tar sandbox-riscv64.tar py3-ci-layer-persist.tar.gz; do
    [[ -s "${CP_ASSETS_DIR}/${a}" ]] || die "missing control-plane asset ${CP_ASSETS_DIR}/${a} (ci-assets release)"
  done
fi

# --- L1 rootfs: copy-on-write overlay over the fetched cloud image -----------
# RUNDIR may not exist yet (CI passes ${runner.temp}/c1-l1, and nothing else
# creates it; the local replay driver happened to mkdir it for us).
mkdir -p "${RUNDIR}"
info "preparing L1 disks in ${RUNDIR}"
ROOTFS_SRC="${ROOTFS:-}"
if [[ -z "${ROOTFS_SRC}" ]]; then
  # fetch_guest_assets_riscv64.sh produces ubuntu-riscv64.raw; accept a qcow2 too.
  for c in "${WORKLOADS_DIR}/ubuntu-riscv64.raw" "${WORKLOADS_DIR}/rootfs.img"; do
    [[ -s "${c}" ]] && { ROOTFS_SRC="${c}"; break; }
  done
fi
[[ -n "${ROOTFS_SRC}" && -s "${ROOTFS_SRC}" ]] || die "no L1 rootfs (set ROOTFS= or provide ubuntu-riscv64.raw / rootfs.img)"
RFMT=$(qemu-img info --output=json "${ROOTFS_SRC}" | sed -n 's/.*"format": *"\([^"]*\)".*/\1/p' | head -1)
[[ -n "${RFMT}" ]] || RFMT=raw
# Use the fetched image as a read-only backing; the overlay absorbs all writes.
# L1_GOLDEN_QCOW2: a previously saved post-apt disk (see SAVE_GOLDEN_QCOW2
# below) -- booting a copy of it lets the in-L1 script skip the ~40-min
# apt install. The golden disk is pre-control-plane, so no per-run state
# (mysql rows, templates, sandboxes) leaks between runs.
ROOT_OVL="${RUNDIR}/ubuntu-l1.qcow2"
if [[ -n "${L1_GOLDEN_QCOW2:-}" && -s "${L1_GOLDEN_QCOW2}" ]]; then
  info "using golden L1 disk ${L1_GOLDEN_QCOW2} (apt stage pre-installed)"
  cp --reflink=auto "${L1_GOLDEN_QCOW2}" "${ROOT_OVL}"
else
  qemu-img create -f qcow2 -b "${ROOTFS_SRC}" -F "${RFMT}" "${ROOT_OVL}" >/dev/null
  qemu-img resize "${ROOT_OVL}" 12G >/dev/null
fi
DATA_DISK="${RUNDIR}/data.raw"
qemu-img create -f raw "${DATA_DISK}" 8G >/dev/null

# --- cloud-init NoCloud seed: ubuntu user + our ssh key + /data --------------
SSH_KEY="${RUNDIR}/id_l1"
ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" -C c1-l1 >/dev/null
SEED_DIR="${RUNDIR}/seed"; mkdir -p "${SEED_DIR}"
cat > "${SEED_DIR}/meta-data" <<EOF
# Unique instance-id per run: with L1_GOLDEN_QCOW2 the disk already ran
# cloud-init under the old id, and a matching id makes cloud-init skip the
# per-instance modules -- the fresh pubkey would never be injected and the
# ssh wait loop would time out (hit in replay-ali6000-r6).
instance-id: c1-l1-$(date +%s)
local-hostname: c1l1
EOF
cat > "${SEED_DIR}/user-data" <<EOF
#cloud-config
hostname: c1l1
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${SSH_KEY}.pub")
ssh_pwauth: true
chpasswd: { expire: false }
runcmd:
  - [ mkfs.btrfs, -f, -L, cubedata, /dev/vdb ]
  - [ mkdir, -p, /data ]
  - [ mount, /dev/vdb, /data ]
  - [ mkdir, -p, /usr/local/services/cubetoolbox/cube-image, /usr/local/services/cubetoolbox/cube-agent, /usr/local/services/cubetoolbox/cube-kernel-scf, /tmp/snapshot-share-dir ]
# NB: \$UPTIME must stay literal -- it is a cloud-init template variable rendered
# by the L1, and this heredoc is unquoted while the script runs under set -u.
final_message: "c1 L1 cloud-init done after \$UPTIME seconds"
EOF
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "${RUNDIR}/cidata.img" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
else
  # Fallback: a FAT "iso" NoCloud seed (cloud-init also reads vfat-labeled cidata).
  SEED_IMG="${RUNDIR}/cidata.img"
  truncate -s 8M "${SEED_IMG}"
  mkfs.vfat -n cidata "${SEED_IMG}" >/dev/null
  command -v mcopy >/dev/null 2>&1 || die "need cloud-localds (cloud-image-utils) or mtools for the seed"
  mcopy -i "${SEED_IMG}" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" ::
fi

# --- 9p share: assets + binaries + integration script handed to the L1 -------
SHARE="${RUNDIR}/share"; mkdir -p "${SHARE}"
cp -f "${WORKLOADS_DIR}"/{Image,fw_dynamic.bin,cube-guest-image-cpu.img,cube-agent.ext4,cube-spec.json,cube-spec-restore.json,cube-min.tar} "${SHARE}/"
cp -f "${BIN_DIR}"/{cube-runtime-riscv64,containerd-shim-cube-rs-riscv64,cube-agent-riscv64,cube-init-riscv64} "${SHARE}/"
cp -f "${INTEGRATION}" "${SHARE}/run_integration_tests_riscv64.sh"
# vmlinux is the name the shim expects for cube-kernel-scf/vmlinux.
cp -f "${WORKLOADS_DIR}/Image" "${SHARE}/vmlinux"

# The Ubuntu cloudimg L1 ships no containerd; stage the official release
# tarball (public, same fetch style as fetch_guest_assets_riscv64.sh). The
# integration script starts `containerd --address ${SOCK}` itself inside the L1.
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.20}"
CONTAINERD_TAR="${WORKLOADS_DIR}/containerd-${CONTAINERD_VERSION}-linux-riscv64.tar.gz"
if [[ ! -s "${CONTAINERD_TAR}" ]]; then
  info "fetching containerd ${CONTAINERD_VERSION} (linux-riscv64, official release)"
  curl -fSL --retry 3 -o "${CONTAINERD_TAR}" \
    "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-riscv64.tar.gz"
fi
cp -f "${CONTAINERD_TAR}" "${SHARE}/"

# Sweep helper run between integration attempts (nested-TCG flake retry): kill a
# zombie VMM left behind by a timed-out create and drop its containerd
# task/container, so the retry starts with the L1's full RAM. Kept as a file in
# the 9p share (not an inline ssh command) to avoid triple-nested quoting; the
# pkill patterns use the [r] bracket trick so the sweep cannot match itself.
cat > "${SHARE}/c1-sweep.sh" <<'EOF'
#!/usr/bin/env bash
pkill -f 'cube-hyperviso[r]' 2>/dev/null || true
sleep 2
for tid in $(ctr --address /run/containerd-cube.sock -n default task ls 2>/dev/null | awk 'NR>1{print $1}'); do
  ctr --address /run/containerd-cube.sock -n default task kill -s SIGKILL "${tid}" 2>/dev/null || true
  ctr --address /run/containerd-cube.sock -n default task rm -f "${tid}" 2>/dev/null || true
done
for cid in $(ctr --address /run/containerd-cube.sock -n default container ls 2>/dev/null | awk 'NR>1{print $1}'); do
  ctr --address /run/containerd-cube.sock -n default container rm "${cid}" 2>/dev/null || true
done
pkill -f 'containerd-shim-cube-r[s]' 2>/dev/null || true
EOF

# --- control-plane mode: extra payload for the in-L1 bring-up -----------------
if [[ "${RUN_MODE}" == "control-plane" ]]; then
  info "staging control-plane payload into the 9p share"
  cp -f "${CONTROL_PLANE}" "${SHARE}/run_control_plane_riscv64.sh"
  chmod +x "${SHARE}/run_control_plane_riscv64.sh"
  cp -f "${BIN_DIR}"/{cubemaster-riscv64,cubemastercli-riscv64,templatecenter-riscv64,cubeops-riscv64,cubelet-riscv64,cube-api-riscv64,cube-volume-s3-riscv64,cubevsmapdump-riscv64} "${SHARE}/"
  mkdir -p "${SHARE}/cpconf" "${SHARE}/cpassets"
  cp -f "${REPO}"/hypervisor/scripts/control-plane-riscv64/* "${SHARE}/cpconf/"
  cp -f "${REPO}/deploy/one-click/config-cube.toml" "${SHARE}/config-cube.toml"
  cp -f "${REPO}/examples/openai-agents-code-interpreter/coldstart_snapshot_demo.py" "${SHARE}/coldstart_snapshot_demo.py"
  cp -f "${CP_ASSETS_DIR}"/{registry-riscv64,crane-riscv64,coredns-riscv64,mkcert-riscv64,cube-proxy-image.tar,sandbox-riscv64.tar,py3-ci-layer-persist.tar.gz} "${SHARE}/cpassets/"
  mkdir -p "${SHARE}/cpproxy"
  cp -f "${REPO}/CubeProxy/nginx.conf" "${SHARE}/cpproxy/nginx.conf"
  cp -f "${REPO}/deploy/one-click/cubeproxy/global.conf.template" "${SHARE}/cpproxy/global.conf.template"
  # CP_STOP_AFTER_STAGE=1: the in-L1 script exits right after toolbox staging
  # (special rc 77) so the caller can save the disk as a golden image.
  if [[ "${CP_STOP_AFTER_STAGE:-0}" == "1" ]]; then
    : > "${SHARE}/.stop-after-stage"
  else
    rm -f "${SHARE}/.stop-after-stage"
  fi
fi

# --- boot the L1 (QEMU TCG, H-ext + AIA), host-forward ssh, 9p share ---------
SERIAL="${RUNDIR}/serial.log"; PIDFILE="${RUNDIR}/qemu.pid"
info "booting L1: ${QEMU} -cpu max -smp ${L1_SMP} -m ${L1_MEM} (TCG, preempt=${L1_PREEMPT}, gdbstub=${L1_GDBSTUB})"
GDB_ARGS=()
if [[ "${L1_GDBSTUB}" == "1" ]]; then
  GDB_ARGS=(-gdb "tcp:127.0.0.1:${L1_GDB_PORT}")
fi
# preempt=${L1_PREEMPT}: the nested-TCG L2 boot wedge rate is highly sensitive
# to the L1 kernel's preemption model (measured on 232 bootloop: PREEMPT_LAZY
# L1 ~50% wedge, preempt=none+HZ100 L1 ~5%). The 7.2 guest kernel config ships
# CONFIG_PREEMPT_DYNAMIC=y so the L1 selects the model at boot; this only
# affects the L1 host, the L2 guest keeps its own defaults.
# NOTE: this comment must stay OUTSIDE the qemu line-continuation chain --
# a comment line inside a `\`-continued command terminates the command early.
"${QEMU}" \
  -M virt,aia=aplic-imsic,aia-guests=4 -cpu max -smp "${L1_SMP}" -m "${L1_MEM}" \
  -bios "${WORKLOADS_DIR}/fw_dynamic.bin" -kernel "${WORKLOADS_DIR}/Image" \
  -append "root=/dev/vda1 rw rootwait console=ttyS0 earlycon=sbi preempt=${L1_PREEMPT}" \
  -drive "file=${ROOT_OVL},format=qcow2,if=virtio" \
  -drive "file=${DATA_DISK},format=raw,if=virtio" \
  -drive "file=${RUNDIR}/cidata.img,format=raw,if=virtio,readonly=on" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${L1_PORT}-:22 \
  -device virtio-net-device,netdev=n0 \
  -virtfs "local,path=${SHARE},mount_tag=c1share,security_model=none,id=c1share" \
  -chardev "socket,id=ser0,path=${RUNDIR}/serial.sock,server=on,wait=off,logfile=${SERIAL},logappend=off" \
  -serial chardev:ser0 -monitor none -display none -pidfile "${PIDFILE}" \
  "${GDB_ARGS[@]}" \
  -d guest_errors -D "${RUNDIR}/qemu-guest-errors.log" &
QPID=$!
trap 'kill "${QPID}" 2>/dev/null || true' EXIT

SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p ${L1_PORT} ubuntu@127.0.0.1"
info "waiting for L1 ssh (TCG boot is slow)..."
ready=0
for _ in $(seq 1 120); do
  if ${SSH} 'echo up' >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "${QPID}" 2>/dev/null || { echo "=== full serial.log (L1 qemu exited) ==="; cat "${SERIAL}"; die "L1 qemu exited during boot"; }
  sleep 5
done
[[ "${ready}" -eq 1 ]] || { echo "=== full serial.log (L1 ssh timeout) ==="; cat "${SERIAL}"; die "L1 did not become ssh-reachable in time"; }
info "L1 up: $(${SSH} 'uname -r; nproc; test -e /dev/kvm && echo KVM_YES || echo KVM_NO' 2>/dev/null | tr '\n' ' ')"
${SSH} 'test -e /dev/kvm' || die "L1 has no /dev/kvm -- QEMU H-extension not exposed to the L1"

# Full L1 boot log (OpenSBI + kernel + cloud-init up to ssh-up), unfiltered --
# on a CI runner the job log is the primary debug surface. SER_OFF records how
# much was shown; the post-integration delta dump below prints the remainder.
echo "=== L1 boot: full serial.log (unfiltered) ==="
cat "${SERIAL}"
echo "=== end L1 boot serial.log ==="
SER_OFF=$(stat -c%s "${SERIAL}" 2>/dev/null || echo 0)

# --- run the in-L1 phase ------------------------------------------------------
case "${RUN_MODE}" in
  integration)
    # --- run the integration test INSIDE the L1 (nested KVM) ------------------
    # Nested TCG intermittently wedges the L2 vCPUs entirely (observed twice: zero
    # guest progress for 291s and 900s right after guest-init prints "init mount
    # finish", i.e. inside the dax mount of /dev/pmem1; a hung guest never recovers
    # while an identical retry boots in ~20-60s). Attempt the in-L1 integration up
    # to INTEGRATION_ATTEMPTS times, sweeping leftover VMM/tasks/containers between
    # attempts so a zombie guest does not eat the L1's RAM. All attempts append to
    # the same integration.log.
    INTEGRATION_ATTEMPTS="${INTEGRATION_ATTEMPTS:-3}"
    rc=1
    tee_flags=""
    for attempt in $(seq 1 "${INTEGRATION_ATTEMPTS}"); do
      if [[ "${attempt}" -gt 1 ]]; then
        info "sweeping leftovers in the L1 before attempt ${attempt}/${INTEGRATION_ATTEMPTS}"
        ${SSH} 'sudo bash /mnt/share/c1-sweep.sh' || true
        tee_flags="-a"
      fi
      info "running snapshot/restore integration inside the L1 (attempt ${attempt}/${INTEGRATION_ATTEMPTS})"
      set +e
      ${SSH} 'sudo bash -c "
        # sshd answers before cloud-init runcmd finishes (mkfs.btrfs /dev/vdb +
        # mkdir/mount /data); observed: attempt 1 died on \"cp: target /data/: No
        # such file or directory\". Wait for cloud-init (bounded) before staging.
        timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
        mkdir -p /data
        mountpoint -q /data || mount /dev/vdb /data 2>/dev/null || true
        export WORKLOADS_DIR=/mnt/share
        # The /data race above is the observed attempt-1 killer; the 9p mount has
        # not been seen failing, but verify the share is populated anyway and retry
        # the mount before staging -- a cheap guard that fails fast so the outer
        # retry gets a real attempt instead of a staging ghost.
        for i in 1 2 3 4 5; do
          mountpoint -q /mnt/share || { mkdir -p /mnt/share && mount -t 9p -o trans=virtio,version=9p2000.L c1share /mnt/share; }
          if [[ -s /mnt/share/cube-runtime-riscv64 && -s /mnt/share/Image ]]; then break; fi
          echo \"share not populated (try $i); remounting\"
          mountpoint -q /mnt/share && umount /mnt/share
          sleep 3
        done
        [[ -s /mnt/share/cube-runtime-riscv64 && -s /mnt/share/Image ]] || { echo \"FATAL: 9p share never populated\"; exit 1; }
        # stage the assets where run_integration_tests_riscv64.sh expects them
        cp -f /mnt/share/Image /mnt/share/vmlinux /mnt/share/fw_dynamic.bin /mnt/share/cube-*.img /mnt/share/cube-*.ext4 /mnt/share/cube-*.json /mnt/share/cube-min.tar /mnt/share/*-riscv64 /data/ || { echo \"FATAL: asset cp from 9p share failed\"; exit 1; }
        # provision containerd/ctr + register the cube shim (io.containerd.cube.rs ->
        # containerd-shim-cube-rs per containerd shim naming)
        tar -xzf /mnt/share/containerd-*.tar.gz -C /usr/local
        install -m 0755 /data/containerd-shim-cube-rs-riscv64 /usr/local/bin/containerd-shim-cube-rs
        chmod +x /mnt/share/run_integration_tests_riscv64.sh
        # The integration script resolves REPO from its own path (/mnt/share), so its
        # default OUTPUT_BIN=/mnt/_output/bin never exists; the binaries live in /data.
        WORKLOADS_DIR=/data OUTPUT_BIN=/data bash /mnt/share/run_integration_tests_riscv64.sh --quick
      "' 2>&1 | tee ${tee_flags} "${RUNDIR}/integration.log"
      # Without set +e, pipefail aborts at the pipeline above on integration failure,
      # making the rc capture and the log assertions below dead code.
      rc=${PIPESTATUS[0]}
      set -e
      info "integration attempt ${attempt} rc=${rc}"
      [[ "${rc}" -eq 0 ]] && break
    done

    echo "=== full integration.log ==="
    cat "${RUNDIR}/integration.log"
    echo "=== end integration.log ==="
    if grep -qiE 'arena already|internal error: segfault' "${RUNDIR}/integration.log"; then
      die "guest-memory corruption detected in the integration log"
    fi
    [[ "${rc}" -eq 0 ]] || die "integration script failed rc=${rc} after ${attempt} attempt(s)"
    info "C1 snapshot/restore PASSED"
    ;;

  control-plane)
    # --- full control-plane bring-up + no-LLM demo INSIDE the L1 ---------------
    # No retry loop here (unlike the integration mode): the control-plane phase
    # is dispatched manually and runs once per L1; a nested-TCG wedge surfaces as
    # a failed job whose full logs are dumped by the in-L1 script's EXIT trap.
    info "running the control-plane demo inside the L1 (RUN_MODE=control-plane)"
    set +e
    # gdbstub wedge watcher: when enabled, the in-L1 script touches
    # /mnt/share/.l1-wedged at the start of its failure path and then holds the
    # L1 up (instead of an immediate poweroff) waiting for .hold-l1-release.
    # This watcher races that window: attach to the L0 QEMU gdbstub, dump the
    # per-vCPU state of the wedged L1, then release the L1 to power off.
    WATCHER=""
    if [[ "${L1_GDBSTUB}" == "1" ]]; then
      rm -f "${SHARE}/.l1-wedged" "${SHARE}/.hold-l1-release"
      touch "${SHARE}/.hold-l1-on-fail"
      ( for _ in $(seq 1 2100); do
          if [[ -e "${SHARE}/.l1-wedged" ]]; then
            sleep 10
            dump_gdbstub_forensics
            touch "${SHARE}/.hold-l1-release"
            exit 0
          fi
          kill -0 "${QPID}" 2>/dev/null || exit 0
          sleep 5
        done ) &
      WATCHER=$!
    fi
    # timeout: bound any L1-side wedge well under the 330-min job cap; the
    # scripted internal budgets (bring-up ~30m + template poll 90m + demo 15m
    # + dumps) sum to ~2.5h. stdin is detached both here and per-daemon in the
    # in-L1 script: daemons inheriting the ssh channel's stdin held the session
    # open for 2.5h after the script had FAILED (run 39640853172).
    timeout 10200 ${SSH} 'sudo bash -c "
      timeout 300 cloud-init status --wait >/dev/null 2>&1 || true
      mkdir -p /data
      mountpoint -q /data || mount /dev/vdb /data 2>/dev/null || true
      for i in 1 2 3 4 5; do
        mountpoint -q /mnt/share || { mkdir -p /mnt/share && mount -t 9p -o trans=virtio,version=9p2000.L c1share /mnt/share; }
        if [[ -s /mnt/share/run_control_plane_riscv64.sh && -s /mnt/share/cpassets/sandbox-riscv64.tar ]]; then break; fi
        echo \"share not populated (try $i); remounting\"
        mountpoint -q /mnt/share && umount /mnt/share
        sleep 3
      done
      [[ -s /mnt/share/run_control_plane_riscv64.sh ]] || { echo \"FATAL: 9p share never populated\"; exit 1; }
      bash /mnt/share/run_control_plane_riscv64.sh < /dev/null
      echo \$? > /mnt/share/control-plane.rc
      sync
      poweroff -f
    "' </dev/null 2>&1 | tee "${RUNDIR}/control-plane.log"
    # The L1 powers off when the in-L1 script finishes, which drops the ssh
    # session (rc 255) regardless of lingering daemon fds -- the real in-L1
    # exit code is plumbed through the 9p share. The timeout above stays as
    # the backstop for an in-L1 wedge (poweroff never runs then).
    rc=$(cat "${SHARE}/control-plane.rc" 2>/dev/null || echo 255)
    set -e
    [[ -z "${WATCHER}" ]] || { kill "${WATCHER}" 2>/dev/null || true; wait "${WATCHER}" 2>/dev/null || true; }
    rm -f "${SHARE}/.hold-l1-on-fail" "${SHARE}/.hold-l1-release" "${SHARE}/.l1-wedged"
    if [[ -s "${RUNDIR}/gdbstub-forensics.log" ]]; then
      echo "=== gdbstub forensics (full, unfiltered) ==="
      cat "${RUNDIR}/gdbstub-forensics.log"
      echo "=== end gdbstub forensics ==="
    fi

    if [[ "${rc}" -eq 77 && -n "${SAVE_GOLDEN_QCOW2:-}" ]]; then
      cp --reflink=auto "${ROOT_OVL}" "${SAVE_GOLDEN_QCOW2}"
      info "golden L1 disk saved to ${SAVE_GOLDEN_QCOW2}"
      echo "=== full control-plane.log ==="
      cat "${RUNDIR}/control-plane.log"
      echo "=== end control-plane.log ==="
      trap - EXIT
      kill "${QPID}" 2>/dev/null || true
      exit 0
    fi

    echo "=== full control-plane.log ==="
    cat "${RUNDIR}/control-plane.log"
    echo "=== end control-plane.log ==="
    [[ "${rc}" -eq 0 ]] || die "control-plane demo failed rc=${rc}"
    grep -q "CONTROL_PLANE_DEMO: PASS" "${RUNDIR}/control-plane.log" \
      || die "control-plane demo did not report PASS"
    info "C1 control-plane demo PASSED"
    ;;

  *) die "unknown RUN_MODE=${RUN_MODE} (expected: integration|control-plane)" ;;
esac

# L1 serial output since the ssh-up dump above (cloud-init completion, any L1
# kernel oops/warning during the nested run), unfiltered.
ser_size=$(stat -c%s "${SERIAL}" 2>/dev/null || echo 0)
echo "=== L1 serial.log during the in-L1 phase: bytes ${SER_OFF}..${ser_size} (unfiltered) ==="
if [[ "${ser_size}" -gt "${SER_OFF}" ]]; then tail -c +$((SER_OFF + 1)) "${SERIAL}"; else echo "(no new output)"; fi
echo "=== end L1 serial delta ==="
if [[ -s "${RUNDIR}/qemu-guest-errors.log" ]]; then
  echo "=== qemu -d guest_errors log (full, unfiltered) ==="
  cat "${RUNDIR}/qemu-guest-errors.log"
  echo "=== end qemu guest_errors ==="
fi

# logs are collected by the caller from ${RUNDIR}; keep them on success too
echo "${RUNDIR}" > "${RUNDIR}/.rundir"
trap - EXIT
info "L1 left running is NOT desired in CI; stopping qemu pid=${QPID}"
kill "${QPID}" 2>/dev/null || true
exit 0
