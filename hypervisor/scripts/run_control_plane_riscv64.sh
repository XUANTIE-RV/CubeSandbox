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

info() { echo "[cp] $*"; }
die()  { echo "[cp] ERROR: $*" >&2; exit 2; }

dump_full() { local f="$1"
  echo "=== full log: ${f} ==="
  if [[ -s "${f}" ]]; then cat "${f}"; else echo "(missing or empty: ${f})"; fi
  echo "=== end ${f} ===" ; }

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
}

FAILED=1
on_exit() {
  echo "=== [cp] final state: $([[ ${FAILED} -eq 0 ]] && echo PASS || echo FAIL) ==="
  echo "=== listening sockets (full, unfiltered) ==="
  ss -ltnp 2>/dev/null || true
  dump_net_state "at exit" 2>/dev/null || true
  dump_all_logs
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
info "apt-get update + install mysql-server redis-server python3-venv"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mysql-server redis-server python3-venv python3-pip curl
mysqld --version
redis-server --version

# --- 2) MySQL: datadir + cube_mvp + cube user --------------------------------
# mysql_native_password users (the CubeSandbox DSN is plain TCP, no TLS).
# On 8.0 the plugin is always available -- no server flag needed (the 8.4-only
# mysql_native_password=ON knob from the bed my.cnf is intentionally absent).
info "configure + start mysqld"
systemctl stop mysql 2>/dev/null || true
# The apt postinst auto-starts a systemd mysqld holding the datadir lock; make
# sure it is really gone before starting ours (stop is async under TCG).
for i in $(seq 1 30); do pgrep -x mysqld >/dev/null || break; sleep 2; done
if pgrep -x mysqld >/dev/null; then die "systemd mysqld would not stop"; fi
mkdir -p /var/run/mysqld /data/log
if [[ ! -d /var/lib/mysql/mysql ]]; then
  info "initializing MySQL datadir (insecure bootstrap)"
  mysqld --initialize-insecure --user=root --datadir=/var/lib/mysql
fi
# --log-error: Ubuntu's /etc/mysql/mysql.conf.d/mysqld.cnf silently redirects
# the error log to /var/log/mysql/error.log; without this flag the nohup
# redirect stays empty and failures are invisible (run 39598987778).
nohup mysqld --user=root --datadir=/var/lib/mysql \
  --socket=/var/run/mysqld/mysqld.sock --bind-address=127.0.0.1 --port=3306 \
  --skip-name-resolve --mysqlx=OFF --log-error=/var/log/cube-mysqld.log \
  --innodb_buffer_pool_size=128M --innodb_redo_log_capacity=64M \
  --max_connections=64 \
  >/var/log/cube-mysqld.out 2>&1 &
i=0
until mysqladmin ping --socket=/var/run/mysqld/mysqld.sock --silent 2>/dev/null; do
  i=$((i+1)); [[ ${i} -ge 300 ]] && die "mysqld not ready (see /var/log/cube-mysqld.log)"
  sleep 2
done
info "mysqld ready after ~$((i*2))s"
mysql --socket=/var/run/mysqld/mysqld.sock -uroot <<'SQL'
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
  --dir /var/lib/cube-redis >/var/log/cube-redis.log 2>&1 &
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
# Empty-but-valid snapshot spec list (loadVmSnapshotSpec tolerates a missing
# file with a warning; an explicit [] keeps the log clean).
echo '[]' > "${TB}/cube-snapshot/spec.json"

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
  nohup "${TB}/CubeOps/bin/cubeops" >/var/log/cube-cubeops.log 2>&1 &

wait_port() { local port="$1" name="$2" n=0
  until (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    n=$((n+1)); [[ ${n} -ge 90 ]] && die "${name} port ${port} never listened"
    sleep 2
  done
  info "${name} listening on :${port}" ; }

wait_port 3010 cubeops

info "start cubemaster (:8089)"
CUBE_MASTER_CONFIG_PATH="${TB}/CubeMaster/conf.yaml" \
  CUBEMASTER_ROOTFS_ARTIFACT_STORE_DIR=/data/CubeMaster/storage \
  CUBE_TEMPLATE_CENTER_ADDR=http://127.0.0.1:8090 \
  nohup "${TB}/CubeMaster/bin/cubemaster" >/var/log/cube-cubemaster.log 2>&1 &
wait_port 8089 cubemaster

info "start templatecenter (:8090)"
CUBE_TEMPLATE_CENTER_CONFIG_PATH="${TB}/CubeTemplateCenter/conf.yaml" \
  CUBE_MASTER_ADDR=http://127.0.0.1:8089 \
  CUBE_TEMPLATE_CENTER_ARTIFACT_STORE_DIR=/data/CubeMaster/storage \
  nohup "${TB}/CubeTemplateCenter/bin/templatecenter" >/var/log/cube-templatecenter.log 2>&1 &
wait_port 8090 templatecenter

info "start cubelet (:9999)"
CUBE_SANDBOX_NODE_IP="${CUBE_SANDBOX_NODE_IP}" \
  nohup "${TB}/Cubelet/bin/cubelet" \
    --config "${TB}/Cubelet/config/config.toml" \
    --dynamic-conf-path "${TB}/Cubelet/dynamicconf/conf.yaml" \
    >/var/log/cube-cubelet.log 2>&1 &
wait_port 9999 cubelet
wait_port 9998 cubelet-http

info "start cube-api (:3000)"
LOG_DIR=/data/log/CubeAPI CUBE_API_BIND=0.0.0.0:3000 \
  CUBE_API_SANDBOX_DOMAIN=cube.app CUBE_MASTER_ADDR=http://127.0.0.1:8089 \
  nohup "${TB}/CubeAPI/bin/cube-api" >/var/log/cube-api.log 2>&1 &
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
