#!/usr/bin/env python3
# Copyright (c) 2026 Tencent Inc.
# SPDX-License-Identifier: Apache-2.0
"""
reflink_cow_demo.py -- CubeSandbox cold-start vs snapshot, at the storage layer.

NO control plane (no CubeMaster / CubeAPI / E2B), NO model inference, NO Rust,
NO network, NO microVM. Pure stdlib. This demonstrates the exact primitive
`cubecow`'s ReflinkEngine is built on: the kernel FICLONE ioctl on a
reflink-capable filesystem (XFS reflink=1 / Btrfs / OCFS2).

What it proves, mirroring a sandbox lifecycle:
  * cold start  = provisioning a volume by FULL byte copy  -> O(size)
  * snapshot    = create_snapshot via FICLONE (reflink)     -> O(1), metadata only
  * clone       = create_volume_from_snapshot (reflink)     -> O(1)
  * CoW         = the clone shares extents until written; a write to the clone
                  diverges it and leaves the base untouched
  * state       = a marker written to the base is visible in the clone

Run on a reflink-capable directory (e.g. cube-l1's /data, or any XFS mounted
with -o reflink=1):

    python3 reflink_cow_demo.py --dir /data/cubecow-demo --size-mb 512

On a filesystem without reflink it detects this and exits 0 with an explanation
(it does not silently fall back to a byte copy and pretend it was O(1)).
"""

import argparse
import errno
import fcntl
import os
import shutil
import sys
import time

# Linux FICLONE: ioctl(dest_fd, FICLONE, src_fd) -- reflink src into dest.
FICLONE = 0x40049409
MARKER = b"coldstart-snapshot-demo-marker\n"


def reflink(src, dst):
    """Clone src -> dst sharing extents (O(1)). Raises OSError if unsupported."""
    with open(src, "rb") as s, open(dst, "wb") as d:
        fcntl.ioctl(d.fileno(), FICLONE, s.fileno())


def supports_reflink(dirpath):
    probe_src = os.path.join(dirpath, ".rl-probe-src")
    probe_dst = os.path.join(dirpath, ".rl-probe-dst")
    try:
        with open(probe_src, "wb") as f:
            f.write(b"x")
            f.flush()
        reflink(probe_src, probe_dst)
        return True, None
    except OSError as exc:
        return False, exc
    finally:
        for p in (probe_src, probe_dst):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def human(nbytes, secs):
    rate = (nbytes / secs / (1 << 20)) if secs > 0 else float("inf")
    return "%.4f s (%.1f MiB/s)" % (secs, rate)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=".", help="reflink-capable directory to run in")
    ap.add_argument("--size-mb", type=int, default=512, help="base volume size in MiB")
    args = ap.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    ok, err = supports_reflink(args.dir)
    if not ok:
        code = getattr(err, "errno", None)
        name = errno.errorcode.get(code, code) if code else "?"
        sys.stderr.write(
            "REFLINK NOT SUPPORTED at %s (%s: %s).\n"
            "  cubecow's ReflinkEngine needs FICLONE, i.e. a filesystem mounted\n"
            "  with reflink enabled: XFS (-o reflink=1, mkfs.xfs -m reflink=1),\n"
            "  Btrfs, or OCFS2. On cube-l1 use /data (the 60G XFS disk). This\n"
            "  demo refuses to fake O(1) with a byte copy, so it stops here.\n"
            % (os.path.abspath(args.dir), name, err)
        )
        return 4

    size = args.size_mb * (1 << 20)
    base = os.path.join(args.dir, "template-volume.img")
    snap = os.path.join(args.dir, "snapshot.img")
    clone = os.path.join(args.dir, "clone-volume.img")
    for p in (base, snap, clone):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass

    results = []
    print("[preflight] reflink OK at %s" % os.path.abspath(args.dir))

    # Build the "template" volume and stamp a marker into it.
    with open(base, "wb") as f:
        f.write(MARKER)
        f.truncate(size)
        f.flush()
        os.fsync(f.fileno())
    print("[setup] template volume: %s (%d MiB)" % (base, args.size_mb))

    # 1) COLD START: provision a volume by full byte copy -- O(size).
    cold_dst = os.path.join(args.dir, "cold-copy.img")
    try:
        os.unlink(cold_dst)
    except FileNotFoundError:
        pass
    t0 = time.perf_counter()
    shutil.copyfile(base, cold_dst)
    cold_s = time.perf_counter() - t0
    print("[1] cold start (byte copy) : %s" % human(size, cold_s))
    results.append(("cold_start_bytecopy", True))

    # 2) SNAPSHOT: create_snapshot via reflink -- O(1), metadata only.
    t1 = time.perf_counter()
    reflink(base, snap)
    snap_s = time.perf_counter() - t1
    print("[2] snapshot  (FICLONE)    : %s" % human(size, snap_s))
    results.append(("snapshot_reflink", True))

    # 3) CLONE from snapshot: create_volume_from_snapshot -- O(1).
    t2 = time.perf_counter()
    reflink(snap, clone)
    clone_s = time.perf_counter() - t2
    print("[3] clone     (FICLONE)    : %s" % human(size, clone_s))
    results.append(("clone_reflink", True))

    speedup = cold_s / snap_s if snap_s > 0 else float("inf")
    print("    cold %.4fs vs snapshot %.4fs  (%.0fx faster)" % (cold_s, snap_s, speedup))

    # 4) STATE preserved: marker written to base is visible in the clone.
    with open(clone, "rb") as f:
        head = f.read(len(MARKER))
    ok_state = head == MARKER
    print("[4] state     (marker in clone): %r -> %s"
          % (head[:32], "PASS" if ok_state else "FAIL"))
    results.append(("snapshot_preserves_state", ok_state))

    # 5) CoW divergence: overwrite the clone's head, base must stay intact.
    with open(clone, "r+b") as f:
        f.write(b"DIVERGED" + b"\x00" * (len(MARKER) - 8))
        f.flush()
    with open(base, "rb") as f:
        base_head = f.read(len(MARKER))
    ok_cow = base_head == MARKER
    print("[5] cow       (base unchanged): %r -> %s"
          % (base_head[:32], "PASS" if ok_cow else "FAIL"))
    results.append(("cow_base_untouched", ok_cow))

    for p in (base, snap, clone, cold_dst):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass

    print("\n==== SUMMARY ====")
    passed = all(ok for _, ok in results)
    for name, ok in results:
        print("  %-28s %s" % (name, "PASS" if ok else "FAIL"))
    print("RESULT: %s" % ("PASS" if passed else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
