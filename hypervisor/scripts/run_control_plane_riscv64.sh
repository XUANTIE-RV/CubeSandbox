#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_control_plane_riscv64.sh -- bring up the FULL CubeSandbox control plane
# inside the C1 riscv64 L1 (nested TCG) and run the no-LLM example
# examples/openai-agents-code-interpreter/coldstart_snapshot_demo.py against it:
#
#   mysql + redis (native, Ubuntu ports debs)
#   -> cubeops (:3010) -> cubemaster (:8089) -> templatecenter (:8090)
#   -> cubelet (:9999, drives containerd-shim-cube-rs -> Cube-Hypervisor)
#   -> cube-api (:3000)
#   -> local OCI registry (:1338) + crane: compose sandbox-code-riscv64
#   -> cubemastercli tpl create-from-image (poll to READY)
#   -> coldstart_snapshot_demo.py: cold start -> run_code -> create_snapshot
#      -> warm restore -> verify fs marker + memory var.
#
# This is the CI codification of the hand-validated cube-l1 bed flow
# (CODE-INTERPRETER-FULLCHAIN-STARTUP.log, RESULT: PASS 6/6, template
# tpl-329fd47a232849059fe4bae9): same configs (control-plane-riscv64/, derived
# from bed-cubetoolbox.tgz), same image recipe (crane append the py3/ci layer
# onto sandbox-riscv64 + mutate to the envd-wrapped long-running entrypoint,
# persist-build.sh), same create-from-image flags (probe 49999 /health).
#
# Runs as root INSIDE the L1. Inputs via the 9p share at /mnt/share:
#   *-riscv64                       all `make all-riscv64` binaries
#   Image, fw_dynamic.bin, cube-guest-image-cpu.img, cube-agent.ext4
#   cpconf/                         cubemaster-conf.yaml, templatecenter-conf.yaml,
#                                   cubelet-config.toml, cubelet-dynamicconf.yaml
#   config-cube.toml                shim runtime config (deploy/one-click)
#   coldstart_snapshot_demo.py      the no-LLM demo
#   cpassets/                       registry-riscv64, crane-riscv64,
#                                   sandbox-riscv64.tar, py3-ci-layer-persist.tar.gz
#
# Every phase prints its full unfiltered log; on failure a trap dumps every
# control-plane log in full before exiting non-zero.
set -euo pipefail

SHARE="${SHARE:-/mnt/share}"
TB="${TB:-/usr/local/services/cubetoolbox}"
DEMO_TIMEOUT="${DEMO_TIMEOUT:-900}"
TPL_POLL_MAX="${TPL_POLL_MAX:-270}"   # 270 * 20s = 90 min (bed: 18-35 min under TCG)
# TRACE_KVM=1: capture kvm_entry/kvm_exit tracepoints from the template VM
# create onward (the wedge-prone window); the ring buffer keeps the tail, i.e.
# the last guest exits before a wedge -- including the final WFI exits and the
# guest PCs (sepc) at entry.
TRACE_KVM="${TRACE_KVM:-0}"
TRACE_DIR=/sys/kernel/tracing
TRACE_ACTIVE=0

trace_kvm_start() {
  [[ "${TRACE_KVM}" == "1" ]] || return 0
  [[ -d "${TRACE_DIR}/events" ]] || mount -t tracefs tracefs "${TRACE_DIR}" 2>/dev/null || true
  if [[ ! -e "${TRACE_DIR}/events/kvm/kvm_entry/enable" ]]; then
    info "WARN: kvm tracepoints unavailable in this L1 kernel; TRACE_KVM ignored"
    return 0
  fi
  echo 131072 > "${TRACE_DIR}/buffer_size_kb" 2>/dev/null || true
  echo nop > "${TRACE_DIR}/current_tracer" 2>/dev/null || true
  : > "${TRACE_DIR}/trace"
  echo 1 > "${TRACE_DIR}/events/kvm/kvm_entry/enable"
  echo 1 > "${TRACE_DIR}/events/kvm/kvm_exit/enable"
  echo 1 > "${TRACE_DIR}/tracing_on"
  TRACE_ACTIVE=1
  info "kvm entry/exit tracepoint capture enabled"
}

trace_kvm_stop_dump() {
  [[ "${TRACE_ACTIVE}" == "1" ]] || return 0
  echo 0 > "${TRACE_DIR}/tracing_on" 2>/dev/null || true
  TRACE_ACTIVE=0
  echo "=== kvm trace: total event lines ==="
  wc -l < "${TRACE_DIR}/trace" || true
  echo "=== kvm trace: last 3000 events (unfiltered tail; the wedge pre-history) ==="
  tail -3000 "${TRACE_DIR}/trace" || true
  echo "=== end kvm trace ==="
}

# Early wedge detector (debug runs only, i.e. TRACE_KVM=1). The 1200s
# CUBE_VM_BOOT_TIMEOUT teardown destroys the wedged VM before on_exit
# forensics run, so this watcher samples the template VM's vCPU threads while
# the VM is STILL alive: wedge = VM up > 240s, no VsockServerReady in the shim
# log, and every vcpu thread at zero jiffies delta over 30s. On detection it
# touches ${SHARE}/.l1-wedged immediately (the outer runner's gdbstub watcher
# then attaches while the vcpus are still wedged) and snapshots the kvm trace.
wedge_watch() {
  [[ "${TRACE_KVM}" == "1" ]] || return 0
  local pid="" p i t c
  # Must match the CUBE shim (containerd-shim-cube-rs), not any runc shim
  # (registry/coredns containers also have containerd-shim processes and would
  # be picked first by a bare pgrep, silently disabling the detector).
  for i in $(seq 1 180); do
    for p in $(pgrep -f 'containerd-shim-cube' 2>/dev/null); do
      if ls /proc/"${p}"/task/[0-9]*/comm 2>/dev/null | xargs -r grep -l '^vcpu' 2>/dev/null | head -1 | grep -q .; then
        pid="${p}"; break
      fi
    done
    [[ -n "${pid}" ]] && break
    sleep 5
  done
  [[ -n "${pid}" ]] || return 0
  info "wedge_watch: shim pid=${pid}; grace 240s before sampling"
  sleep 240
  for i in $(seq 1 40); do
    kill -0 "${pid}" 2>/dev/null || return 0
    if grep -rqs 'VsockServerReady' /data/log/CubeShim 2>/dev/null; then
      info "wedge_watch: VsockServerReady seen; VM healthy, watcher exiting"
      return 0
    fi
    local a b
    a=$(for t in /proc/"${pid}"/task/[0-9]*; do
          c=$(cat "${t}/comm" 2>/dev/null) || continue
          case "${c}" in *vcpu*) awk '{print $1, $14+$15}' "${t}/stat" 2>/dev/null;; esac
        done)
    if [[ -n "${a}" ]]; then
      sleep 30
      b=$(for t in /proc/"${pid}"/task/[0-9]*; do
            c=$(cat "${t}/comm" 2>/dev/null) || continue
            case "${c}" in *vcpu*) awk '{print $1, $14+$15}' "${t}/stat" 2>/dev/null;; esac
          done)
      # Wedge = vcpu threads nearly idle for 30s with no VsockServerReady.
      # iter-5 lesson: an exact-identity check misses the wedge flavor where
      # vcpu0 keeps a 10ms guest tick (each timer-exit round trip charges a
      # few jiffies/30s) while vcpu1 sits in WFI forever. A booting vcpu
      # burns ~3000 jiffies/30s; a ticking-but-stuck one burns < 30.
      local delta
      delta=$(join -j 1 <(echo "${a}" | sort) <(echo "${b}" | sort) 2>/dev/null \
              | awk '{s += $3-$2} END {print s+0}')
      if [[ "${delta}" -lt 100 ]]; then
        info "WEDGE DETECTED: vcpu threads of shim ${pid} at ${delta} jiffies over 30s, no VsockServerReady"
        # Marker FIRST: the outer runner's gdbstub dump must attach while the
        # wedged vCPUs still exist (it takes ~60s to walk vm_list).
        touch "${SHARE}/.l1-wedged" 2>/dev/null || true
        echo "=== EARLY wedge forensics (VM still alive) ==="
        dump_wedge_forensics
        trace_kvm_stop_dump
        echo "=== end EARLY wedge forensics ==="
        return 0
      fi
    else
      sleep 30
    fi
  done
}
WEDGE_WATCH_PID=""

info() { echo "[cp] $(date +%H:%M:%S) $*"; }
die()  { echo "[cp] ERROR: $*" >&2; exit 2; }

dump_full() { local f="$1"
  echo "=== full log: ${f} ==="
  if [[ -s "${f}" ]]; then cat "${f}"; else echo "(missing or empty: ${f})"; fi
  echo "=== end ${f} ===" ; }

# Nested-TCG wedge forensics (root-causing the 7.2 L1-kernel L2 boot wedge).
# On PASS this is the baseline; on FAIL it shows whether the L2 vCPU threads
# are sleeping in the L1 kernel (lost wakeup / lost virtual interrupt) or
# spinning (guest busy loop, e.g. starved timer). Sampling window is 5s.
dump_wedge_forensics() {
  echo "=== wedge forensics: uptime / loadavg ==="
  uptime || true
  echo "=== wedge forensics: cube-related threads (state + wchan) ==="
  ps -eLo pid,tid,stat,wchan:40,etime,comm 2>/dev/null | awk 'NR==1 || /[Cc]ube|vcpu|shim/' || true
  local procs snap_a snap_b p t
  procs=$(pgrep -f 'cube|containerd-shim' 2>/dev/null || true)
  if [[ -z "${procs}" ]]; then echo "(no cube processes alive)"; return; fi
  snap_a=$(mktemp); snap_b=$(mktemp)
  for p in ${procs}; do
    for t in /proc/${p}/task/[0-9]*; do
      awk '{print "'"${p}/${t##*/}"'", $3, $2, $14+$15}' "${t}/stat" 2>/dev/null
    done
  done > "${snap_a}"
  cp /proc/interrupts "${snap_a}.irq"
  sleep 5
  for p in ${procs}; do
    for t in /proc/${p}/task/[0-9]*; do
      awk '{print "'"${p}/${t##*/}"'", $3, $2, $14+$15}' "${t}/stat" 2>/dev/null
    done
  done > "${snap_b}"
  echo "=== wedge forensics: per-thread jiffies(utime+stime) delta over 5s ==="
  echo "(pid/tid state@t1 comm delta; delta>0 = burning CPU, delta=0 = sleeping)"
  join -j 1 <(sort "${snap_a}") <(sort "${snap_b}") 2>/dev/null \
    | awk '{printf "%-14s %-4s %-28s %d\n", $1, $5, $6, $7-$4}' \
    | sort -k4 -nr || true
  echo "=== wedge forensics: /proc/interrupts t0 ==="
  cat "${snap_a}.irq" || true
  echo "=== wedge forensics: /proc/interrupts t1 (5s later) ==="
  cat /proc/interrupts || true
  # fd-level forensics: decide WHICH wakeup path lost the event. The 7.2
  # wedge signature is both vCPUs parked in kvm_vcpu_block with
  # irqs_pending=0 (virtual interrupt never injected) while every VMM
  # device thread sleeps in epoll/io_wq, so the lost event is in the
  # guest-kick -> VMM -> KVM-inject chain. fdinfo discriminates:
  #   eventfd-count > 0 with its poller thread asleep = event fired but
  #     the epoll wakeup was lost (eventpoll regression);
  #   eventfd-count == 0 = the producer never fired (io_uring completion
  #     or tap RX path regression).
  # epoll fdinfo tfd lines show per-monitored-fd revents: nonzero revents
  # while epoll_wait sleeps = ready event stuck in the epoll ready list.
  local shim_pid="" f lnk
  for p in $(pgrep -f 'containerd-shim-cube' 2>/dev/null); do
    if ls /proc/"${p}"/task/[0-9]*/comm 2>/dev/null | xargs -r grep -l '^vcpu' 2>/dev/null | head -1 | grep -q .; then
      shim_pid="${p}"; break
    fi
  done
  if [[ -n "${shim_pid}" ]]; then
    echo "=== wedge forensics: shim ${shim_pid} fd table ==="
    ls -l /proc/"${shim_pid}"/fd 2>/dev/null || true
    echo "=== wedge forensics: shim ${shim_pid} fdinfo (eventfd/epoll/io_uring/kvm) ==="
    for f in /proc/"${shim_pid}"/fd/[0-9]*; do
      lnk=$(readlink "${f}" 2>/dev/null) || continue
      case "${lnk}" in
        anon_inode:\[eventfd\]|anon_inode:\[eventpoll\]|anon_inode:\[io_uring\]|anon_inode:kvm-*|/dev/kvm|/dev/net/tun|socket:*)
          echo "--- fd ${f##*/} -> ${lnk} ---"
          cat /proc/"${shim_pid}"/fdinfo/"${f##*/}" 2>/dev/null || true
          ;;
      esac
    done
  else
    echo "(no cube shim with vcpu threads alive; fd forensics skipped)"
  fi
  echo "=== wedge forensics: kernel stacks of non-running cube threads ==="
  for p in ${procs}; do
    for t in /proc/${p}/task/[0-9]*; do
      local st
      st=$(awk '{print $3}' "${t}/stat" 2>/dev/null) || continue
      [[ "${st}" == "R" ]] && continue
      echo "--- ${p}/${t##*/} state=${st} comm=$(cat "${t}/comm" 2>/dev/null) ---"
      cat "${t}/stack" 2>/dev/null || echo "(kernel stack unavailable)"
    done
  done
  rm -f "${snap_a}" "${snap_b}" "${snap_a}.irq"
}

# The cube network data plane (cube-dev bridge + tap devices + cubevs eBPF
# maps) is part of what this phase validates -- dump it in full, unfiltered.
dump_net_state() { local label="$1"
  echo "=== cube network state (${label}): ip addr ==="
  ip addr
  echo "=== cube network state (${label}): ip link ==="
  ip link
  echo "=== cube network state (${label}): ip route ==="
  ip route
  echo "=== cube network state (${label}): bridge link ==="
  bridge link 2>/dev/null || echo "(bridge link unavailable)"
  echo "=== cube network state (${label}): cubevsmapdump ==="
  "${TB}/cube-vs/network/bin/cubevsmapdump" 2>&1 || echo "(cubevsmapdump rc=$?)"
  echo "=== end cube network state (${label}) ===" ; }

dump_all_logs() {
  local d
  for d in /data/log/CubeMaster /data/log/CubeTemplateCenter /data/log/Cubelet \
           /data/log/CubeOps /data/log/CubeAPI /data/log/cubecow \
           /data/log/CubeShim /data/log/CubeVmm; do
    [[ -d "${d}" ]] || continue
    find "${d}" -type f | sort | while read -r f; do dump_full "${f}"; done
  done
  for f in /var/log/cube-mysqld.log /var/log/cube-mysqld.out \
           /var/log/mysql/error.log \
           /var/log/cube-redis.log /var/log/cube-registry.log \
           /var/log/cube-cubeops.log /var/log/cube-cubemaster.log \
           /var/log/cube-templatecenter.log /var/log/cube-cubelet.log \
           /var/log/cube-api.log; do
    [[ -e "${f}" ]] && dump_full "${f}"
  done
  # L1 kernel log: captures nested-KVM (gstage/dirty-ring/AIA) errors from
  # the L2 VM's lifetime, which no control-plane log can see.
  echo "=== L1 dmesg (full, unfiltered) ==="
  dmesg 2>&1 || true
  echo "=== end L1 dmesg ==="
}

FAILED=1
on_exit() {
  echo "=== [cp] final state: $([[ ${FAILED} -eq 0 ]] && echo PASS || echo FAIL) ==="
  # Marker for the outer runner's gdbstub watcher: on failure, hold the L1 up
  # (below) so the host can attach to the still-wedged L2 before poweroff.
  [[ ${FAILED} -eq 0 ]] || { touch "${SHARE}/.l1-wedged" 2>/dev/null || true; }
  [[ -z "${WEDGE_WATCH_PID}" ]] || { kill "${WEDGE_WATCH_PID}" 2>/dev/null || true; wait "${WEDGE_WATCH_PID}" 2>/dev/null || true; }
  # Stop + dump the kvm trace FIRST: its tail is the freshest wedge pre-history
  # and must be captured before the (slow) log dumps below run more guests I/O.
  trace_kvm_stop_dump
  echo "=== listening sockets (full, unfiltered) ==="
  ss -ltnp 2>/dev/null || true
  dump_net_state "at exit" 2>/dev/null || true
  dump_wedge_forensics
  dump_all_logs
  if [[ ${FAILED} -ne 0 && -e "${SHARE}/.hold-l1-on-fail" ]]; then
    info "FAIL: holding the L1 up for outer gdbstub forensics (max 15 min)"
    for _ in $(seq 1 180); do
      [[ -e "${SHARE}/.hold-l1-release" ]] && break
      sleep 5
    done
  fi
}
trap on_exit EXIT

# --- 0) preconditions -------------------------------------------------------
info "preconditions"
[[ "$(uname -m)" == "riscv64" ]] || die "must run on riscv64 (uname -m=$(uname -m))"
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
[[ -e /dev/kvm ]] || die "/dev/kvm missing"
for b in cubemaster-riscv64 cubemastercli-riscv64 templatecenter-riscv64 \
         cubeops-riscv64 cubelet-riscv64 cube-api-riscv64 cube-volume-s3-riscv64 \
         cubevsmapdump-riscv64 cube-runtime-riscv64 containerd-shim-cube-rs-riscv64 \
         cube-agent-riscv64 cube-init-riscv64; do
  [[ -s "${SHARE}/${b}" ]] || die "missing ${SHARE}/${b}"
done
for f in cpconf/cubemaster-conf.yaml cpconf/templatecenter-conf.yaml \
         cpconf/cubelet-config.toml cpconf/cubelet-dynamicconf.yaml \
         config-cube.toml coldstart_snapshot_demo.py \
         cpassets/registry-riscv64 cpassets/crane-riscv64 \
         cpassets/coredns-riscv64 \
         cpassets/mkcert-riscv64 cpassets/cube-proxy-image.tar \
         cpproxy/nginx.conf cpproxy/global.conf.template \
         cpassets/sandbox-riscv64.tar cpassets/py3-ci-layer-persist.tar.gz \
         Image cube-guest-image-cpu.img cube-agent.ext4; do
  [[ -s "${SHARE}/${f}" ]] || die "missing ${SHARE}/${f}"
done
mkdir -p /data
mountpoint -q /data || mount /dev/vdb /data 2>/dev/null || true
mountpoint -q /data && info "/data mounted: $(findmnt -n -o FSTYPE /data)" || die "/data not mounted"

# --- 1) apt: mysql-server + redis-server + python venv ----------------------
# Ubuntu noble ports carries mysql-server 8.0 + redis 7.x for riscv64; the
# Yocto-built 8.4 deb from the XuanTie feed (install-native-db.sh) does NOT fit
# here -- it links OpenSSL 3.4 while noble ships 3.0. Native distro packages
# avoid docker-in-TCG entirely. Full apt output on purpose.
# Golden-disk runs (marker present) skip this ~40-min step; the installed
# packages persist on the reused disk.
if [[ -f /etc/c1-cp-apt-done ]]; then
  info "apt stage already done on this disk (golden); skipping"
else
  info "apt-get update + install mysql-server redis-server python3-venv"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y mysql-server redis-server python3-venv python3-pip curl docker.io
  mysqld --version
  redis-server --version
  dockerd --version
  touch /etc/c1-cp-apt-done
fi

# --- 2) MySQL: datadir + cube_mvp + cube user --------------------------------
# mysql_native_password users (the CubeSandbox DSN is plain TCP, no TLS).
# On 8.0 the plugin is always available -- no server flag needed (the 8.4-only
# mysql_native_password=ON knob from the bed my.cnf is intentionally absent).
#
# Use the apt package's systemd unit instead of hand-rolling mysqld: Ubuntu
# noble pins user=mysql in /etc/mysql/mysql.conf.d/mysqld.cnf (mysqld honors
# only the FIRST user option, so --user=root is silently ignored) and the mysql
# user cannot write a root-owned /var/run/mysqld or /var/log path -- manual
# startup aborted with "Could not open file ... Permission denied" (runs
# 39598987778/39607243216). The unit gets user/paths/AppArmor right; the
# postinst already initialized the datadir and defaults (bind 127.0.0.1:3306,
# 128M buffer pool) are fine for this demo.
info "start mysqld (systemd unit from the apt package)"
if [[ ! -d /var/lib/mysql/mysql ]]; then
  info "initializing MySQL datadir (insecure bootstrap)"
  mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql
fi
systemctl start mysql
i=0
until mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; do
  i=$((i+1)); [[ ${i} -ge 300 ]] && die "mysqld not ready (see /var/log/mysql/error.log)"
  sleep 2
done
info "mysqld ready after ~$((i*2))s"
# root@localhost authenticates via auth_socket on a fresh install, but the SQL
# below switches it to mysql_native_password/cube_root -- so on a golden disk
# (where that ALTER already ran) the socket login needs the password.
ROOT_AUTH=()
mysql --socket=/var/run/mysqld/mysqld.sock -uroot -e "SELECT 1" >/dev/null 2>&1 \
  || ROOT_AUTH=(-pcube_root)
mysql --socket=/var/run/mysqld/mysqld.sock -uroot "${ROOT_AUTH[@]}" <<'SQL'
CREATE DATABASE IF NOT EXISTS cube_mvp CHARACTER SET utf8mb4;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'cube_root';
CREATE USER IF NOT EXISTS 'cube'@'%' IDENTIFIED WITH mysql_native_password BY 'cube_pass';
ALTER USER 'cube'@'%' IDENTIFIED WITH mysql_native_password BY 'cube_pass';
GRANT ALL PRIVILEGES ON cube_mvp.* TO 'cube'@'%';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
mysql -h127.0.0.1 -P3306 -ucube -pcube_pass -e "SELECT VERSION() AS v;" cube_mvp

# --- 3) Redis: requirepass on 127.0.0.1:6379 ---------------------------------
info "configure + start redis"
systemctl stop redis-server 2>/dev/null || true
# Same stop-and-verify as mysqld: the apt postinst auto-starts redis on 6379
# without requirepass; a leftover would make our instance fail to bind.
for i in $(seq 1 15); do pgrep -x redis-server >/dev/null || break; sleep 2; done
if pgrep -x redis-server >/dev/null; then die "systemd redis would not stop"; fi
mkdir -p /var/lib/cube-redis
nohup redis-server --bind 127.0.0.1 --port 6379 --requirepass ceuhvu123 \
  --dir /var/lib/cube-redis >/var/log/cube-redis.log 2>&1 </dev/null &
i=0
until redis-cli -h 127.0.0.1 -p 6379 -a ceuhvu123 ping 2>/dev/null | grep -q PONG; do
  i=$((i+1)); [[ ${i} -ge 60 ]] && die "redis not ready (see /var/log/cube-redis.log)"
  sleep 1
done
info "redis ready"

# --- 4) stage the cubetoolbox layout -----------------------------------------
info "stage ${TB}"
mkdir -p "${TB}/CubeMaster/bin" "${TB}/CubeMaster/plugin" \
         "${TB}/CubeTemplateCenter/bin" \
         "${TB}/CubeOps/bin" \
         "${TB}/CubeAPI/bin" \
         "${TB}/Cubelet/bin" "${TB}/Cubelet/config" "${TB}/Cubelet/dynamicconf" \
         "${TB}/Cubelet/plugin" \
         "${TB}/cube-shim/bin" "${TB}/cube-shim/conf" \
         "${TB}/cube-kernel-scf" "${TB}/cube-image" "${TB}/cube-agent" \
         "${TB}/cube-vs/network/bin" "${TB}/cube-snapshot" \
         /data/CubeMaster/storage /data/cubeops/tmp \
         /data/cubelet/root /data/cubelet/state /data/cubelet/shimlog /data/cubelet/cleanup \
         /data/cubelet/storage /data/cube-shared/volume /data/snapshot_pack/disks \
         /data/cube-shim/disks /tmp/cube \
         /data/log/CubeMaster /data/log/CubeTemplateCenter /data/log/Cubelet \
         /data/log/CubeOps /data/log/CubeAPI /data/log/cubecow \
         /data/log/CubeShim /data/log/CubeVmm
install -m 0755 "${SHARE}/cubemaster-riscv64"          "${TB}/CubeMaster/bin/cubemaster"
install -m 0755 "${SHARE}/cubemastercli-riscv64"       "${TB}/CubeMaster/bin/cubemastercli"
install -m 0755 "${SHARE}/templatecenter-riscv64"      "${TB}/CubeTemplateCenter/bin/templatecenter"
install -m 0755 "${SHARE}/cubeops-riscv64"             "${TB}/CubeOps/bin/cubeops"
install -m 0755 "${SHARE}/cubelet-riscv64"             "${TB}/Cubelet/bin/cubelet"
install -m 0755 "${SHARE}/cube-api-riscv64"            "${TB}/CubeAPI/bin/cube-api"
install -m 0755 "${SHARE}/cube-volume-s3-riscv64"      "${TB}/CubeMaster/plugin/cube-volume-s3"
install -m 0755 "${SHARE}/cube-volume-s3-riscv64"      "${TB}/Cubelet/plugin/cube-volume-s3"
install -m 0755 "${SHARE}/cubevsmapdump-riscv64"       "${TB}/cube-vs/network/bin/cubevsmapdump"
install -m 0755 "${SHARE}/cube-runtime-riscv64"        "${TB}/cube-shim/bin/cube-runtime"
install -m 0755 "${SHARE}/containerd-shim-cube-rs-riscv64" "${TB}/cube-shim/bin/containerd-shim-cube-rs"
# cubelet spawns the shim by well-known name (io.containerd.cube.rs ->
# containerd-shim-cube-rs) resolved from PATH.
install -m 0755 "${SHARE}/containerd-shim-cube-rs-riscv64" /usr/local/bin/containerd-shim-cube-rs
install -m 0644 "${SHARE}/cpconf/cubemaster-conf.yaml"      "${TB}/CubeMaster/conf.yaml"
install -m 0644 "${SHARE}/cpconf/templatecenter-conf.yaml"  "${TB}/CubeTemplateCenter/conf.yaml"
install -m 0644 "${SHARE}/cpconf/cubelet-config.toml"       "${TB}/Cubelet/config/config.toml"
install -m 0644 "${SHARE}/cpconf/cubelet-dynamicconf.yaml"  "${TB}/Cubelet/dynamicconf/conf.yaml"
install -m 0644 "${SHARE}/config-cube.toml"                 "${TB}/cube-shim/conf/config-cube.toml"
cp -f "${SHARE}/Image" "${TB}/cube-kernel-scf/vmlinux"
cp -f "${SHARE}/cube-guest-image-cpu.img" "${TB}/cube-image/cube-guest-image-cpu.img"
cp -f "${SHARE}/cube-agent.ext4" "${TB}/cube-agent/cube-agent.ext4"
for d in cube-kernel-scf cube-image cube-agent; do echo "0.0.0-dev" > "${TB}/${d}/version"; done
echo "0.0.0-dev" > "${TB}/cube-shim/version"
# Inventory the staged components into cubelet's versioned store, mirroring
# one-click install.sh inventory_package_component_versions. Sandbox.create
# resolves component versions from /data/cubelet/root/component_versions/
# <name>/<ver>/ and only falls back to the CubeOps component warehouse when a
# version is missing locally; this single-node layout runs no MinIO/S3, so
# without the inventory step Sandbox.create fails with
# "component version not in warehouse: warehouse disabled".
CVROOT=/data/cubelet/root/component_versions
for name in cube-shim cube-image cube-agent; do
  ver="$(tr -d '[:space:]' < "${TB}/${name}/version")"
  dst="${CVROOT}/${name}/${ver}"
  # Dev builds reuse the same version string with changing content, so always
  # refresh those; released versions follow install.sh's keep-existing rule.
  if [[ "${ver}" == *-dev || ! -d "${dst}" ]]; then
    mkdir -p "${CVROOT}/${name}"
    rm -rf "${dst}.new"
    cp -a "${TB}/${name}" "${dst}.new"
    rm -rf "${dst}"
    mv "${dst}.new" "${dst}"
  fi
done
# The kernel inventories by content hash (sha256-<12> of vmlinux) with a bm
# variant file, matching install.sh inventory_kernel_content_variants.
kdigest="$(sha256sum "${TB}/cube-kernel-scf/vmlinux" | awk '{print $1}')"
kdst="${CVROOT}/cube-kernel-scf/sha256-${kdigest:0:12}"
if [ ! -d "${kdst}" ]; then
  mkdir -p "${kdst}"
  cp -f "${TB}/cube-kernel-scf/vmlinux" "${kdst}/vmlinux-bm"
  ln -sfn vmlinux-bm "${kdst}/vmlinux"
  echo bm > "${kdst}/variant"
  echo "sha256:${kdigest}" > "${kdst}/version"
fi
# Empty-but-valid snapshot spec list (loadVmSnapshotSpec tolerates a missing
# file with a warning; an explicit [] keeps the log clean).
echo '[]' > "${TB}/cube-snapshot/spec.json"

# Golden-image producer mode: the outer script drops this marker when invoked
# with CP_STOP_AFTER_STAGE=1. Everything above (apt marker + toolbox staging +
# component inventory) is the disk state worth freezing; mysql/redis services
# are (re)started per run below, so stopping here keeps the golden disk free
# of any per-run control-plane state. rc 77 tells the outer script to save it.
if [[ -f /mnt/share/.stop-after-stage ]]; then
  info "CP_STOP_AFTER_STAGE: staging complete, stopping for golden capture"
  exit 77
fi

# --- 5) start the control plane ----------------------------------------------
# Order mirrors the bed systemd units: cubeops -> cubemaster -> templatecenter
# -> cubelet -> cube-api. Env mirrors scripts/systemd/*-start.sh.
export CUBE_SANDBOX_NODE_IP="${CUBE_SANDBOX_NODE_IP:-$(ip -4 -o addr show eth0 | awk '{split($4,a,"/");print a[1]; exit}')}"
info "node ip: ${CUBE_SANDBOX_NODE_IP}"

info "start cubeops (:3010)"
CUBE_OPS_BIND=0.0.0.0:3010 CUBE_OPS_LOG_LEVEL=info \
  CUBE_OPS_LOG_DIR=/data/log/CubeOps \
  CUBE_MASTER_ADDR=http://127.0.0.1:8089 \
  CUBE_OPS_WAREHOUSE_WORK_DIR=/data/cubeops/tmp TMPDIR=/data/cubeops/tmp \
  CUBE_SANDBOX_MYSQL_HOST=127.0.0.1 CUBE_SANDBOX_MYSQL_PORT=3306 \
  CUBE_SANDBOX_MYSQL_USER=cube CUBE_SANDBOX_MYSQL_PASSWORD=cube_pass \
  CUBE_SANDBOX_MYSQL_DB=cube_mvp \
  REDIS_HOST=127.0.0.1 REDIS_PORT=6379 REDIS_PASSWORD=ceuhvu123 REDIS_DB=0 \
  nohup "${TB}/CubeOps/bin/cubeops" >/var/log/cube-cubeops.log 2>&1 </dev/null &

wait_port() { local port="$1" name="$2" n=0
  until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    n=$((n+1)); [[ ${n} -ge 90 ]] && die "${name} port ${port} never listened"
    sleep 2
  done
  info "${name} listening on :${port}" ; }

wait_port 3010 cubeops

info "start cubemaster (:8089)"
# Shared template-callback secret: cubemaster attaches it to job forwards,
# templatecenter + cubemaster's callback endpoint both verify it. With it
# unset both ends fail closed (TC 503 "not configured", run 39640853172).
CALLBACK_TOKEN="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
CUBE_MASTER_CONFIG_PATH="${TB}/CubeMaster/conf.yaml" \
  CUBEMASTER_ROOTFS_ARTIFACT_STORE_DIR=/data/CubeMaster/storage \
  CUBE_TEMPLATE_CENTER_ADDR=http://127.0.0.1:8090 \
  CUBE_TEMPLATE_CALLBACK_TOKEN="${CALLBACK_TOKEN}" \
  nohup "${TB}/CubeMaster/bin/cubemaster" >/var/log/cube-cubemaster.log 2>&1 </dev/null &
wait_port 8089 cubemaster

info "start templatecenter (:8090)"
CUBE_TEMPLATE_CENTER_CONFIG_PATH="${TB}/CubeTemplateCenter/conf.yaml" \
  CUBE_MASTER_ADDR=http://127.0.0.1:8089 \
  CUBE_TEMPLATE_CENTER_ARTIFACT_STORE_DIR=/data/CubeMaster/storage \
  CUBE_TEMPLATE_CALLBACK_TOKEN="${CALLBACK_TOKEN}" \
  nohup "${TB}/CubeTemplateCenter/bin/templatecenter" >/var/log/cube-templatecenter.log 2>&1 </dev/null &
wait_port 8090 templatecenter

info "start cubelet (:9999)"
# CUBE_VM_BOOT_TIMEOUT_SECS reaches the shim through cubelet's embedded
# containerd (same mechanism as the integration lane): the template build's
# verification sandbox boots an L2 on KVM-over-TCG and 300s was not enough
# (run 39672874331: VsockServerReady never arrived, create timed out).
# CUBE_GUEST_CONSOLE_DIR makes the shim write the L2 guest console to
# per-sandbox files under /data/log/CubeVmm (picked up by dump_all_logs), and
# CUBE_GUEST_DEBUG drops 'quiet' from the guest cmdline so the full kernel
# boot is visible; both default off outside CI.
# CUBE_DISABLE_VM_DIRTY_LOG forces vc.memory.dirty_log=false: with dirty
# logging on (template-verification VMs set app_snapshot_create), the L2
# stalls outright under nested KVM on TCG (runs 39699478142/39709978005),
# while the dirty_log=false integration lane boots the same guest reliably.
CUBE_SANDBOX_NODE_IP="${CUBE_SANDBOX_NODE_IP}" \
  CUBE_VM_BOOT_TIMEOUT_SECS="${CUBE_VM_BOOT_TIMEOUT_SECS:-1200}" \
  CUBE_GUEST_CONSOLE_DIR=/data/log/CubeVmm \
  CUBE_GUEST_DEBUG=1 \
  CUBE_DISABLE_VM_DIRTY_LOG=1 \
  nohup "${TB}/Cubelet/bin/cubelet" \
    --config "${TB}/Cubelet/config/config.toml" \
    --dynamic-conf-path "${TB}/Cubelet/dynamicconf/conf.yaml" \
    >/var/log/cube-cubelet.log 2>&1 </dev/null &
wait_port 9999 cubelet
wait_port 9998 cubelet-http

info "start cube-api (:3000)"
LOG_DIR=/data/log/CubeAPI CUBE_API_BIND=0.0.0.0:3000 \
  CUBE_API_SANDBOX_DOMAIN=cube.app CUBE_MASTER_ADDR=http://127.0.0.1:8089 \
  nohup "${TB}/CubeAPI/bin/cube-api" >/var/log/cube-api.log 2>&1 </dev/null &
wait_port 3000 cube-api

info "wait for the node to register with CubeOps"
for i in $(seq 1 60); do
  nodes="$(curl -s --max-time 10 http://127.0.0.1:3010/internal/v1/nodes 2>/dev/null || true)"
  if grep -q "${CUBE_SANDBOX_NODE_IP}" <<<"${nodes}"; then
    info "node registered: ${nodes}"
    break
  fi
  [[ ${i} -ge 60 ]] && { echo "${nodes}"; die "node never registered with CubeOps"; }
  sleep 5
done

# cube-dev is created by cubelet's network plugin; the template build's
# PortBinding/probe path needs the host-side gateway address on it (bed bug #18).
info "ensure cube-dev gateway address"
for i in $(seq 1 60); do
  ip link show cube-dev >/dev/null 2>&1 && break
  [[ ${i} -ge 60 ]] && die "cube-dev interface never appeared"
  sleep 3
done
ip -4 addr show cube-dev | grep -q 192.168.0.1 || ip addr add 192.168.0.1/18 dev cube-dev
ip -4 addr show cube-dev
dump_net_state "after cubelet init"

# --- 6) local registry + compose the code-interpreter image ------------------
# Identical recipe to the bed's l1-setup-registry.sh + persist-build.sh:
# push the base sandbox image, append the python3 + code-interpreter layer,
# mutate to the envd-wrapped long-running entrypoint (runbook bug #14).
info "start local OCI registry (:1338) + push/append/mutate image"
mkdir -p /opt/cube-img
install -m 0755 "${SHARE}/cpassets/registry-riscv64" /opt/cube-img/registry
install -m 0755 "${SHARE}/cpassets/crane-riscv64"    /opt/cube-img/crane
cp -f "${SHARE}/cpassets/sandbox-riscv64.tar" "${SHARE}/cpassets/py3-ci-layer-persist.tar.gz" /opt/cube-img/
if ! curl -s --max-time 3 http://127.0.0.1:1338/v2/ >/dev/null 2>&1; then
  ( cd /opt/cube-img && setsid nohup ./registry >/var/log/cube-registry.log 2>&1 < /dev/null & )
fi
i=0
until curl -s --max-time 3 http://127.0.0.1:1338/v2/ >/dev/null 2>&1; do
  i=$((i+1)); [[ ${i} -ge 30 ]] && die "registry :1338 never came up"
  sleep 2
done
REG=127.0.0.1:1338
/opt/cube-img/crane push /opt/cube-img/sandbox-riscv64.tar "${REG}/sandbox-riscv64:latest"
/opt/cube-img/crane append -b "${REG}/sandbox-riscv64:latest" \
  --new_layer /opt/cube-img/py3-ci-layer-persist.tar.gz \
  -t "${REG}/sandbox-code-riscv64:persist-app"
CMD='/usr/local/bin/envd -port 49983 -isnotfc >/var/log/envd.log 2>&1 & CODE_INTERPRETER_WORKDIR=/tmp /usr/bin/python3 /opt/ci/server-min.py >/var/log/ci.log 2>&1 & exec sleep infinity'
/opt/cube-img/crane mutate "${REG}/sandbox-code-riscv64:persist-app" \
  --entrypoint '/bin/sh,-c' --cmd "${CMD}" \
  -t "${REG}/sandbox-code-riscv64:persist"
/opt/cube-img/crane config "${REG}/sandbox-code-riscv64:persist"

# --- 7) register the template (poll to READY) --------------------------------
# TRACE_KVM=1: start kvm_entry/kvm_exit capture here so the ring buffer covers
# the whole template VM boot window (where the 7.2 wedge happens).
trace_kvm_start
wedge_watch & WEDGE_WATCH_PID=$!
info "tpl create-from-image (probe 49999 /health, timeout 300s)"
CM="${TB}/CubeMaster/bin/cubemastercli"
"${CM}" --address 127.0.0.1 --port 8089 tpl create-from-image \
  --image "${REG}/sandbox-code-riscv64:persist" \
  --alias riscv64-code-ci \
  --writable-layer-size 1G --backend xfs \
  --expose-port 49983 --expose-port 49999 \
  --probe 49999 --probe-path /health --probe-timeout-ms 300000 \
  --with-cube-ca=false
TID="$("${CM}" --address 127.0.0.1 --port 8089 tpl ls 2>/dev/null | awk '$2=="riscv64-code-ci"{print $1}' | head -1 || true)"
[[ -n "${TID}" ]] || die "could not resolve template id for alias riscv64-code-ci"
info "template id: ${TID}; polling to READY (up to $((TPL_POLL_MAX*20/60)) min)"
ST=""
for i in $(seq 1 "${TPL_POLL_MAX}"); do
  # '|| true': an absent row (early polling) must not trip set -e/pipefail.
  ST="$("${CM}" --address 127.0.0.1 --port 8089 tpl ls 2>/dev/null | { grep "${TID}" || true; } | awk '{print $3}')"
  [[ $((i % 3)) -eq 0 ]] && info "[$((i*20))s] state=${ST:-?} load=$(cut -d' ' -f1 /proc/loadavg)"
  case "${ST}" in
    READY|ACTIVE|SUCCESS) break ;;
    FAIL*|ERROR*) die "template build FAILED (state=${ST})" ;;
  esac
  sleep 20
done
[[ "${ST}" == "READY" || "${ST}" == "ACTIVE" || "${ST}" == "SUCCESS" ]] \
  || die "template not READY after $((TPL_POLL_MAX*20/60)) min (state=${ST:-?})"
info "TEMPLATE_READY ${TID}"
"${CM}" --address 127.0.0.1 --port 8089 tpl ls

# --- 8) run the no-LLM demo --------------------------------------------------
# The SDK data plane (run_code -> envd) dials <port>-<sandboxID>.cube.app, so
# the demo needs wildcard DNS for *.cube.app -> this node. Mirror the validated
# bed: coredns on a dummy interface (169.254.254.53), prepended to resolv.conf.
info "start coredns for *.cube.app -> ${CUBE_SANDBOX_NODE_IP}"
install -m 0755 "${SHARE}/cpassets/coredns-riscv64" /usr/local/bin/coredns
ip link show cube-dns0 >/dev/null 2>&1 || ip link add cube-dns0 type dummy
ip addr replace 169.254.254.53/32 dev cube-dns0 2>/dev/null
ip link set cube-dns0 up
mkdir -p "${TB}/coredns"
cat > "${TB}/coredns/Corefile" <<CORE
cube.app:53 {
    bind 169.254.254.53
    template IN A cube.app {
        answer "{{ .Name }} 60 IN A ${CUBE_SANDBOX_NODE_IP}"
        fallthrough
    }
    cache 300
}
.:53 {
    bind 169.254.254.53
    forward . 10.0.2.3 10.0.2.2 8.8.8.8
    cache 30
}
CORE
setsid nohup /usr/local/bin/coredns -conf "${TB}/coredns/Corefile" \
  >/data/log/coredns.log 2>&1 </dev/null &
grep -q 169.254.254.53 /etc/resolv.conf 2>/dev/null \
  || sed -i "1i nameserver 169.254.254.53" /etc/resolv.conf
for _ in $(seq 1 15); do
  getent hosts probe.cube.app 2>/dev/null | grep -q "${CUBE_SANDBOX_NODE_IP}" && break
  sleep 2
done
getent hosts probe.cube.app >/dev/null 2>&1 || die "coredns: *.cube.app does not resolve"

# --- 8.5) cube-proxy data plane (OpenResty in docker, host network) ---------
# run_code dials http://<envd-port>-<sandboxID>.cube.app/execute on :80;
# cube-proxy is the only component that terminates that Host-based routing
# (lua -> cubevs eBPF DNAT -> L2 envd). dockerd runs with --iptables=false
# --bridge=none: the container is host-networked, so docker's NAT/bridge
# plumbing (and its netfilter module demands on the L1 kernel) is unneeded.
info "start dockerd + cube-proxy (OpenResty data plane on :80)"
mkdir -p /data/log/cube-proxy
nohup dockerd --iptables=false --bridge=none >/data/log/dockerd.log 2>&1 </dev/null &
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || die "dockerd not ready (see /data/log/dockerd.log)"

install -m 0755 "${SHARE}/cpassets/mkcert-riscv64" /usr/local/bin/mkcert
PROXYTB="${TB}/cubeproxy"
mkdir -p "${PROXYTB}/certs"
mkcert -install
(cd "${PROXYTB}/certs" && mkcert cube.app "*.cube.app" localhost 127.0.0.1)
[[ -s "${PROXYTB}/certs/cube.app+3.pem" ]] || die "mkcert did not produce cube.app+3.pem"

sed -e 's/__CUBE_PROXY_REDIS_IP__/127.0.0.1/g' \
    -e 's/__CUBE_PROXY_REDIS_PORT__/6379/g' \
    -e 's/__CUBE_PROXY_REDIS_PASSWORD__/ceuhvu123/g' \
    -e 's/__CUBE_PROXY_REDIS_MASTER_NAME__//g' \
    -e 's/__CUBE_PROXY_REDIS_SENTINEL_NODES__//g' \
    -e 's/__CUBE_PROXY_REDIS_SENTINEL_PASSWORD__//g' \
    -e 's/__CUBE_PROXY_REDIS_DB__/0/g' \
    -e "s/__CUBE_PROXY_HOST_IP__/${CUBE_SANDBOX_NODE_IP}/g" \
    -e 's#__CUBE_SIDECAR_NGX_ADDR__#127.0.0.1:8083#g' \
    -e 's#__CUBE_ADMIN_TOKEN__##g' \
    "${SHARE}/cpproxy/global.conf.template" > "${PROXYTB}/global.conf"

# Repo CubeProxy/nginx.conf carries literal dev ports (8081 http / 8080
# https); the release bundle turns them into __CUBE_PROXY_*_PORT__
# placeholders that up-cube-proxy.sh renders as 80/443. Substitute directly.
sed -e 's/listen 8081 reuseport;/listen 80 reuseport;/' \
    -e 's/listen 8080 ssl reuseport;/listen 443 ssl reuseport;/' \
    "${SHARE}/cpproxy/nginx.conf" > "${PROXYTB}/nginx.conf"
grep -q 'listen 80 reuseport;' "${PROXYTB}/nginx.conf" || die "cube-proxy nginx.conf render failed"

docker load -i "${SHARE}/cpassets/cube-proxy-image.tar"
PROXY_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -i cube-proxy | head -1)"
[[ -n "${PROXY_IMAGE}" ]] || die "cube-proxy image not loaded"
info "cube-proxy image: ${PROXY_IMAGE}"
docker rm -f cube-proxy >/dev/null 2>&1 || true
docker run -d --name cube-proxy --network host \
  -e CUBE_PROXY_REGISTRY_ENABLE=0 \
  -e CUBE_PROXY_NODE_IP="${CUBE_SANDBOX_NODE_IP}" \
  -v /data/log/cube-proxy:/data/log/cube-proxy \
  -v "${PROXYTB}/certs:/usr/local/openresty/nginx/certs:ro" \
  -v "${PROXYTB}/global.conf:/usr/local/openresty/nginx/conf/global/global.conf:ro" \
  -v "${PROXYTB}/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro" \
  "${PROXY_IMAGE}"
for i in $(seq 1 30); do
  ss -lnt | grep -q ':80 ' && break
  sleep 2
done
ss -lnt | grep -q ':80 ' || die "cube-proxy not listening on :80"
info "cube-proxy listening on :80 (container: $(docker ps --format '{{.Names}} {{.Status}}' | grep cube-proxy))"

info "python venv + cubesandbox SDK"
python3 -m venv /opt/demo-venv
/opt/demo-venv/bin/pip install "cubesandbox>=0.2.0" python-dotenv

info "run coldstart_snapshot_demo.py (template=${TID})"
set +e
CUBE_API_URL=http://127.0.0.1:3000 E2B_API_URL=http://127.0.0.1:3000 \
  E2B_API_KEY=local-dev-key CUBE_TEMPLATE_ID="${TID}" \
  timeout "${DEMO_TIMEOUT}" /opt/demo-venv/bin/python "${SHARE}/coldstart_snapshot_demo.py"
rc=$?
set -e
echo "[cp] demo exit code: ${rc}"
[[ "${rc}" -eq 0 ]] || die "demo failed rc=${rc}"

# Post-demo: the two sandboxes (cold + warm-restored) each got a tap on
# cube-dev; the network state here is the evidence the SDK->E2B-API->sandbox
# path wired the cube network data plane end to end.
dump_net_state "after demo"

FAILED=0
echo "CONTROL_PLANE_DEMO: PASS (template=${TID})"
