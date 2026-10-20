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
#   RUNDIR          scratch dir for the L1 disks/serial/pid (default a mktemp -d)
#
# Exit 0 on success (restore reached RUNNING, no corruption); non-zero otherwise.
set -euo pipefail

WORKLOADS_DIR="${WORKLOADS_DIR:-$HOME/workloads}"
BIN_DIR="${BIN_DIR:-$(pwd)/_output/bin}"
L1_SMP="${L1_SMP:-4}"
L1_MEM="${L1_MEM:-4G}"
QEMU="${QEMU:-qemu-system-riscv64}"
L1_PORT="${L1_PORT:-22699}"
RUNDIR="${RUNDIR:-$(mktemp -d /tmp/c1-l1.XXXXXX)}"
INTEGRATION="${INTEGRATION:-$(dirname "$0")/run_integration_tests_riscv64.sh}"

info() { echo "[c1] $*"; }
die()  { echo "[c1] ERROR: $*" >&2; exit 2; }

command -v "${QEMU}" >/dev/null 2>&1 || die "qemu-system-riscv64 not found (set QEMU=)"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"

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

# --- L1 rootfs: copy-on-write overlay over the fetched cloud image -----------
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
ROOT_OVL="${RUNDIR}/ubuntu-l1.qcow2"
qemu-img create -f qcow2 -b "${ROOTFS_SRC}" -F "${RFMT}" "${ROOT_OVL}" >/dev/null
qemu-img resize "${ROOT_OVL}" 12G >/dev/null
DATA_DISK="${RUNDIR}/data.raw"
qemu-img create -f raw "${DATA_DISK}" 8G >/dev/null

# --- cloud-init NoCloud seed: ubuntu user + our ssh key + /data --------------
SSH_KEY="${RUNDIR}/id_l1"
ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" -C c1-l1 >/dev/null
SEED_DIR="${RUNDIR}/seed"; mkdir -p "${SEED_DIR}"
cat > "${SEED_DIR}/meta-data" <<EOF
instance-id: c1-l1
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
cp -f "${WORKLOADS_DIR}"/{Image,cube-guest-image-cpu.img,cube-agent.ext4,cube-spec.json,cube-spec-restore.json,cube-min.tar} "${SHARE}/"
cp -f "${BIN_DIR}"/{cube-runtime-riscv64,containerd-shim-cube-rs-riscv64,cube-agent-riscv64,cube-init-riscv64} "${SHARE}/"
cp -f "${INTEGRATION}" "${SHARE}/run_integration_tests_riscv64.sh"
# vmlinux is the name the shim expects for cube-kernel-scf/vmlinux.
cp -f "${WORKLOADS_DIR}/Image" "${SHARE}/vmlinux"

# --- boot the L1 (QEMU TCG, H-ext + AIA), host-forward ssh, 9p share ---------
SERIAL="${RUNDIR}/serial.log"; PIDFILE="${RUNDIR}/qemu.pid"
info "booting L1: ${QEMU} -cpu max -smp ${L1_SMP} -m ${L1_MEM} (TCG)"
"${QEMU}" \
  -M virt,aia=aplic-imsic,aia-guests=4 -cpu max -smp "${L1_SMP}" -m "${L1_MEM}" \
  -bios "${WORKLOADS_DIR}/fw_dynamic.bin" -kernel "${WORKLOADS_DIR}/Image" \
  -append "root=/dev/vda1 rw rootwait console=ttyS0 earlycon=sbi" \
  -drive "file=${ROOT_OVL},format=qcow2,if=virtio" \
  -drive "file=${DATA_DISK},format=raw,if=virtio" \
  -drive "file=${RUNDIR}/cidata.img,format=raw,if=virtio,readonly=on" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${L1_PORT}-:22 \
  -device virtio-net-device,netdev=n0 \
  -virtfs "local,path=${SHARE},mount_tag=c1share,security_model=none,id=c1share" \
  -chardev "socket,id=ser0,path=${RUNDIR}/serial.sock,server=on,wait=off,logfile=${SERIAL},logappend=off" \
  -serial chardev:ser0 -monitor none -display none -pidfile "${PIDFILE}" \
  -d guest_errors -D "${RUNDIR}/qemu-guest-errors.log" &
QPID=$!
trap 'kill "${QPID}" 2>/dev/null || true' EXIT

SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p ${L1_PORT} ubuntu@127.0.0.1"
info "waiting for L1 ssh (TCG boot is slow)..."
ready=0
for _ in $(seq 1 120); do
  if ${SSH} 'echo up' >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "${QPID}" 2>/dev/null || die "L1 qemu exited during boot (see ${SERIAL})"
  sleep 5
done
[[ "${ready}" -eq 1 ]] || die "L1 did not become ssh-reachable in time (see ${SERIAL})"
info "L1 up: $(${SSH} 'uname -r; nproc; test -e /dev/kvm && echo KVM_YES || echo KVM_NO' 2>/dev/null | tr '\n' ' ')"
${SSH} 'test -e /dev/kvm' || die "L1 has no /dev/kvm -- QEMU H-extension not exposed to the L1"

# --- run the integration test INSIDE the L1 (nested KVM) ---------------------
info "running snapshot/restore integration inside the L1"
${SSH} 'sudo bash -c "
  mountpoint -q /mnt/share || { mkdir -p /mnt/share && mount -t 9p -o trans=virtio,version=9p2000.L c1share /mnt/share; }
  mountpoint -q /data || mount /dev/vdb /data 2>/dev/null || true
  export WORKLOADS_DIR=/mnt/share
  # stage the assets where run_integration_tests_riscv64.sh expects them
  cp -f /mnt/share/Image /mnt/share/vmlinux /mnt/share/cube-*.img /mnt/share/cube-*.ext4 /mnt/share/cube-*.json /mnt/share/cube-min.tar /mnt/share/*-riscv64 /data/ 2>/dev/null || true
  chmod +x /mnt/share/run_integration_tests_riscv64.sh
  WORKLOADS_DIR=/data bash /mnt/share/run_integration_tests_riscv64.sh --quick
"' 2>&1 | tee "${RUNDIR}/integration.log"
rc=${PIPESTATUS[0]}

info "integration rc=${rc}"
echo "=== restore/corruption assertions ==="
grep -iE 'RUNNING|snapshot success|arena already|segfault|corrupt|RESTORE_DONE' "${RUNDIR}/integration.log" || true
if grep -qiE 'arena already|internal error: segfault' "${RUNDIR}/integration.log"; then
  die "guest-memory corruption detected in the integration log"
fi
[[ "${rc}" -eq 0 ]] || die "integration script failed rc=${rc}"
info "C1 snapshot/restore PASSED"

# logs are collected by the caller from ${RUNDIR}; keep them on success too
echo "${RUNDIR}" > "${RUNDIR}/.rundir"
trap - EXIT
info "L1 left running is NOT desired in CI; stopping qemu pid=${QPID}"
kill "${QPID}" 2>/dev/null || true
exit 0
