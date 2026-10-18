#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# gen_cube_snapshot_assets_riscv64.sh -- generate the Cube-specific assets that
# run_integration_tests_riscv64.sh needs to boot an L2 sandbox and exercise
# snapshot/restore, WITHOUT depending on a pre-baked testbed directory:
#
#   * cube-min.tar          -- a minimal, deterministic OCI image layout
#                              (empty riscv64/linux layer). This is the
#                              placeholder container image the sandbox unpacks
#                              into /cube-root; the real entrypoint binary
#                              (e.g. /usr/bin/l2pause) is provided by the guest
#                              image / agent, not this layer, so an empty layer
#                              is sufficient and keeps the tar reproducible.
#   * cube-spec.json        -- OCI runtime spec for the CREATE (snapshot source)
#                              sandbox instance.
#   * cube-spec-restore.json-- OCI runtime spec for the RESTORE (snapshot
#                              target) instance, carrying the cube.vm.snapshot.*
#                              annotations that tell CubeShim to restore from a
#                              memory-ranges volume instead of cold-booting.
#
# These mirror the hand-authored assets under the cube-l1 testbed share/, but
# are generated from parameters so CI (and any runner) can rebuild them.
#
# The OCI layout is byte-reproducible: the single layer is `tar -T /dev/null`
# (10240-byte empty archive, diff_id sha256:84ff9269...) gzipped with `gzip -n`
# (no mtime/name), and every descriptor digest/size is computed from the actual
# blob bytes -- exactly the self-consistency an OCI consumer (containerd/CRI)
# validates.
#
# Usage:
#   OUTPUT_DIR=/path/to/assets \
#     [CUBE_SPEC_HOSTNAME=cubetest1] [CUBE_RESTORE_HOSTNAME=cubetest2] \
#     [CUBE_SPEC_ARGS=/usr/bin/l2pause] [CUBE_VCPU=2] [CUBE_MEMORY_MB=512] \
#     [CUBE_BUNDLE_PATH=/run/containerd-cube-state] \
#     [CUBE_SNAPSHOT_BASE=/var/tmp/cube-restore] [CUBE_ARCH=riscv64] \
#     ./hypervisor/scripts/gen_cube_snapshot_assets_riscv64.sh
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-${1:-}}"
[[ -n "${OUTPUT_DIR}" ]] || { echo "OUTPUT_DIR (or first arg) is required" >&2; exit 1; }

CUBE_ARCH="${CUBE_ARCH:-riscv64}"
CUBE_OS="${CUBE_OS:-linux}"
CUBE_SPEC_HOSTNAME="${CUBE_SPEC_HOSTNAME:-cubetest1}"
CUBE_RESTORE_HOSTNAME="${CUBE_RESTORE_HOSTNAME:-cubetest2}"
CUBE_SPEC_ARGS="${CUBE_SPEC_ARGS:-/usr/bin/l2pause}"
CUBE_VCPU="${CUBE_VCPU:-2}"
CUBE_MEMORY_MB="${CUBE_MEMORY_MB:-512}"
CUBE_SNAP_MEMORY_MB="${CUBE_SNAP_MEMORY_MB:-${CUBE_MEMORY_MB}}"
CUBE_BUNDLE_PATH="${CUBE_BUNDLE_PATH:-/run/containerd-cube-state}"
CUBE_SNAPSHOT_BASE="${CUBE_SNAPSHOT_BASE:-/var/tmp/cube-restore}"
# memory_vol_url convention matches the testbed: <base>/<vcpu>C<mem>M/snapshot/memory-ranges
CUBE_MEMORY_VOL_URL="${CUBE_MEMORY_VOL_URL:-${CUBE_SNAPSHOT_BASE}/${CUBE_VCPU}C${CUBE_MEMORY_MB}M/snapshot/memory-ranges}"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v gzip   >/dev/null 2>&1 || { echo "gzip is required"   >&2; exit 1; }
command -v tar    >/dev/null 2>&1 || { echo "tar is required"    >&2; exit 1; }

mkdir -p "${OUTPUT_DIR}"

# ---- cube-min.tar (deterministic OCI image layout) -------------------------
echo "[gen] building cube-min.tar (OCI layout, empty ${CUBE_ARCH}/${CUBE_OS} layer)"
OCI_STAGE="$(mktemp -d)"
trap 'rm -rf "${OCI_STAGE}"' EXIT

# Reproducible empty layer: 10240-byte empty tar (diff_id 84ff9269...), gzipped
# with -n so the blob digest never depends on wall-clock mtime.
tar cf "${OCI_STAGE}/layer.tar" -T /dev/null
gzip -n -9 -c "${OCI_STAGE}/layer.tar" > "${OCI_STAGE}/layer.tar.gz"

LAYOUT_ROOT="${OCI_STAGE}/oci"
mkdir -p "${LAYOUT_ROOT}/blobs/sha256"
printf '{"imageLayoutVersion":"1.0.0"}' > "${LAYOUT_ROOT}/oci-layout"

ARCH="${CUBE_ARCH}" OS="${CUBE_OS}" \
LAYOUT_ROOT="${LAYOUT_ROOT}" LAYER_GZ="${OCI_STAGE}/layer.tar.gz" \
LAYER_TAR="${OCI_STAGE}/layer.tar" \
python3 <<'PY'
import hashlib, json, os, shutil

layout_root = os.environ["LAYOUT_ROOT"]
layer_gz = os.environ["LAYER_GZ"]
layer_tar = os.environ["LAYER_TAR"]
arch = os.environ["ARCH"]
os_name = os.environ["OS"]
blobs = os.path.join(layout_root, "blobs", "sha256")

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def put_blob(data: bytes) -> tuple[str, int]:
    digest = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, digest), "wb") as f:
        f.write(data)
    return f"sha256:{digest}", len(data)

# layer blob = gzip bytes; diff_id = sha256 of the UNcompressed tar.
layer_bytes = open(layer_gz, "rb").read()
layer_digest, layer_size = put_blob(layer_bytes)
diff_id = "sha256:" + sha256_file(layer_tar)

# config blob
config = {
    "architecture": arch,
    "os": os_name,
    "config": {},
    "rootfs": {"type": "layers", "diff_ids": [diff_id]},
}
config_bytes = json.dumps(config, separators=(", ", ": ")).encode()
config_digest, config_size = put_blob(config_bytes)

# manifest blob
manifest = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": config_digest,
        "size": config_size,
    },
    "layers": [
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "digest": layer_digest,
            "size": layer_size,
        }
    ],
}
manifest_bytes = json.dumps(manifest, separators=(", ", ": ")).encode()
manifest_digest, manifest_size = put_blob(manifest_bytes)

# index.json
index = {
    "schemaVersion": 2,
    "manifests": [
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": manifest_digest,
            "size": manifest_size,
            "annotations": {"org.opencontainers.image.ref.name": "latest"},
            "platform": {"architecture": arch, "os": os_name},
        }
    ],
}
with open(os.path.join(layout_root, "index.json"), "w") as f:
    json.dump(index, f, indent=4)
    f.write("\n")

print(f"[gen]   layer  {layer_digest} ({layer_size}B) diff_id {diff_id}")
print(f"[gen]   config {config_digest} ({config_size}B)")
print(f"[gen]   manifest {manifest_digest} ({manifest_size}B)")
PY

# Pack the OCI layout directory into cube-min.tar (paths relative, like the ref).
tar cf "${OUTPUT_DIR}/cube-min.tar" -C "${LAYOUT_ROOT}" oci-layout index.json blobs
echo "[gen]   -> ${OUTPUT_DIR}/cube-min.tar ($(stat -c '%s' "${OUTPUT_DIR}/cube-min.tar" 2>/dev/null || stat -f '%z' "${OUTPUT_DIR}/cube-min.tar")B)"

# ---- cube-spec.json / cube-spec-restore.json -------------------------------
# Shared OCI runtime spec body; the two files differ only in hostname and the
# restore-only cube.vm.snapshot.* / cube.appsnapshot.restore annotations.
gen_spec() {
  local out_file="$1" hostname="$2" restore="$3"
  HOSTNAME="${hostname}" RESTORE="${restore}" \
  ARGS="${CUBE_SPEC_ARGS}" VCPU="${CUBE_VCPU}" MEM="${CUBE_MEMORY_MB}" \
  SNAPMEM="${CUBE_SNAP_MEMORY_MB}" BUNDLE="${CUBE_BUNDLE_PATH}" \
  SNAPBASE="${CUBE_SNAPSHOT_BASE}" MEMVOL="${CUBE_MEMORY_VOL_URL}" \
  OUT="${out_file}" \
  python3 <<'PY'
import json, os

hostname = os.environ["HOSTNAME"]
restore = os.environ["RESTORE"] == "1"
args = os.environ["ARGS"].split()
vcpu = int(os.environ["VCPU"])
mem = int(os.environ["MEM"])
snapmem = int(os.environ["SNAPMEM"])
bundle = os.environ["BUNDLE"]
snapbase = os.environ["SNAPBASE"]
memvol = os.environ["MEMVOL"]

caps = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"]
vmmres = {"cpu": vcpu, "memory": mem}
annotations = {}
if restore:
    vmmres["snap_memory"] = snapmem
    annotations["cube.vmmres"] = json.dumps(vmmres, separators=(",", ":"))
    annotations["cube.vm.snapshot.base.path"] = snapbase
    annotations["cube.vm.snapshot.memory_vol_url"] = memvol
    annotations["cube.appsnapshot.restore"] = "true"
else:
    annotations["cube.vmmres"] = json.dumps(vmmres, separators=(",", ":"))
annotations["io.containerd.cube.bundle"] = bundle

spec = {
    "ociVersion": "1.0.2",
    "process": {
        "terminal": False,
        "user": {"uid": 0, "gid": 0},
        "args": args,
        "env": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm",
        ],
        "cwd": "/",
        "capabilities": {k: caps for k in
                         ("bounding", "effective", "inheritable", "permitted", "ambient")},
        "rlimits": [],
        "noNewPrivileges": True,
    },
    "root": {"path": "/cube-root", "readonly": False},
    "hostname": hostname,
    "mounts": [
        {"destination": "/proc", "type": "proc", "source": "proc"},
        {"destination": "/dev", "type": "tmpfs", "source": "tmpfs",
         "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
        {"destination": "/sys", "type": "sysfs", "source": "sysfs",
         "options": ["nosuid", "noexec", "nodev", "ro"]},
    ],
    "linux": {"namespaces": [{"type": t} for t in ("pid", "ipc", "uts", "mount")]},
    "annotations": annotations,
}

with open(os.environ["OUT"], "w") as f:
    json.dump(spec, f, indent=2)
    f.write("\n")
PY
}

gen_spec "${OUTPUT_DIR}/cube-spec.json" "${CUBE_SPEC_HOSTNAME}" 0
gen_spec "${OUTPUT_DIR}/cube-spec-restore.json" "${CUBE_RESTORE_HOSTNAME}" 1
echo "[gen]   -> ${OUTPUT_DIR}/cube-spec.json (hostname=${CUBE_SPEC_HOSTNAME})"
echo "[gen]   -> ${OUTPUT_DIR}/cube-spec-restore.json (hostname=${CUBE_RESTORE_HOSTNAME}, restore from ${CUBE_MEMORY_VOL_URL})"

echo "[gen] riscv64 snapshot assets ready in ${OUTPUT_DIR}"
