# Copyright (c) 2024 Tencent Inc.
# SPDX-License-Identifier: Apache-2.0
"""
coldstart_snapshot_demo.py -- one-file CubeSandbox validation app.

Merges the two upstream examples into a single runnable program:
  * examples/openai-agents-code-interpreter  (start a sandbox over the
    E2B-compatible API and run code in it), and
  * examples/snapshot-rollback-clone          (create_snapshot + create a new
    sandbox from that snapshot_id).

Steps, each timed and reported PASS/FAIL:
  1. cold start   Sandbox.create(template=CUBE_TEMPLATE_ID)  -> boots a fresh
                  microVM from the template rootfs + kernel.
  2. print        run_code('print(...)') in the sandbox, capture stdout.
  3. state        write a marker file + compute a value in the sandbox.
  4. snapshot     sb.create_snapshot() -> snapshot_id (memory + filesystem CoW
                  capture via CubeCoW / XFS reflink).
  5. warm restore Sandbox.create(template=snapshot_id) -> restore from the
                  snapshot; verify the marker survived; compare latency vs the
                  cold start.

Env (the same three knobs as examples/openai-agents-code-interpreter/.env):
  CUBE_API_URL / E2B_API_URL   CubeSandbox: http://127.0.0.1:3000
                               E2B Cloud:   https://api.e2b.dev (or unset and
                                            use E2B_DOMAIN=e2b.app default)
  E2B_API_KEY                  CubeSandbox local: any non-empty string
                               E2B Cloud: a real key from the e2b.dev dashboard
  CUBE_TEMPLATE_ID             CubeSandbox: `cubemastercli tpl list` (tpl-...)
                               E2B Cloud:   'base' (default code-interpreter tpl)
Optional:
  E2B_DOMAIN                   E2B Cloud domain (SDK default: e2b.app)
  SSL_CERT_FILE                root CA when the endpoint is self-hosted HTTPS

No LLM / OPENAI_API_KEY is required: this exercises only the sandbox control
and data plane, which is exactly what cold-start and snapshot validation need.
Both CubeSandbox and E2B Cloud are reachable targets -- create_snapshot /
delete_snapshot are native E2B SDK methods, so the same code runs against both.
"""

import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

# Use the cubesandbox SDK: it is the E2B-compatible drop-in and adds
# clone()/resume()/rollback() on top of the snapshot API. (create_snapshot /
# delete_snapshot also exist on e2b_code_interpreter.Sandbox, so this same code
# runs against E2B Cloud; cubesandbox is required only for the Cube extras.)
try:
    from cubesandbox import Sandbox
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "ERROR: the 'cubesandbox' SDK is not installed (%s).\n"
        "  pip install -r examples/snapshot-rollback-clone/requirements.txt\n"
        "  (or: pip install 'cubesandbox>=0.6' 'e2b-code-interpreter>=2.4,<3')\n" % exc
    )
    sys.exit(2)

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass  # dotenv is optional; plain exported env works too

SENTENCE = "hello from cube sandbox"
MARKER = "coldstart-snapshot-demo-marker"
# Endpoint resolution mirrors the e2b SDK: explicit CUBE_API_URL/E2B_API_URL
# wins; otherwise fall back to E2B Cloud at https://api.<E2B_DOMAIN|e2b.app>.
API_URL = (
    os.environ.get("CUBE_API_URL")
    or os.environ.get("E2B_API_URL")
    or ("https://api." + (os.environ.get("E2B_DOMAIN") or "e2b.app"))
)
TEMPLATE_ID = os.environ.get("CUBE_TEMPLATE_ID") or ""


def _fail(msg, code=2):
    sys.stdout.flush()
    sys.stderr.write("PREFLIGHT FAIL: %s\n" % msg)
    sys.exit(code)


def preflight():
    """Fail fast with a clear reason before touching the SDK."""
    if not TEMPLATE_ID or TEMPLATE_ID == "REPLACE_WITH_TEMPLATE_ID":
        _fail(
            "CUBE_TEMPLATE_ID is unset/placeholder.\n"
            "  Look one up with: cubemastercli tpl list | "
            "awk 'NR>1 && $1 ~ /^tpl-/{print $1; exit}'"
        )
    if not API_URL:
        _fail("neither CUBE_API_URL nor E2B_API_URL is set (e.g. http://127.0.0.1:3000)")
    if not os.environ.get("E2B_API_KEY"):
        # local deploys accept any non-empty string; the SDK still requires one
        os.environ["E2B_API_KEY"] = "local-dev-key"

    # Probe with a real HTTP request, not a bare TCP connect: the local QEMU L1
    # hostfwd ACCEPTS the socket on :3000 even when nothing listens inside the
    # guest, then resets on the request. Any HTTP status (even 404) means the
    # control plane is serving; a reset/URLError means it is not.
    base = API_URL if API_URL.startswith("http") else "http://" + API_URL
    probe = base.rstrip("/") + "/health"
    try:
        with urllib.request.urlopen(probe, timeout=20) as resp:
            print("[preflight] API=%s template=%s -> HTTP %s" % (base, TEMPLATE_ID, resp.status))
    except urllib.error.HTTPError as exc:
        print("[preflight] API=%s template=%s -> HTTP %s (serving)" % (base, TEMPLATE_ID, exc.code))
    except (urllib.error.URLError, ConnectionError, OSError) as exc:
        host = urlparse(base).hostname or ""
        if host in ("127.0.0.1", "localhost", "::1"):
            hint = (
                "  A bare TCP connect can still succeed via the QEMU hostfwd while the\n"
                "  guest service is down. Check inside cube-l1 that cube-api/cubemaster/\n"
                "  cubelet are installed and listening on :3000, and that /data (XFS,\n"
                "  reflink) is mounted, then register a template with cubemastercli."
            )
        else:
            hint = (
                "  Remote endpoint: check HTTPS_PROXY/http_proxy egress, DNS, and that the\n"
                "  URL is correct. A proxied call can be slow -- the probe waits 20s."
            )
        _fail("control plane not serving at %s (%s).\n%s" % (probe, exc, hint))


def _stdout(result):
    logs = getattr(result, "logs", None)
    parts = getattr(logs, "stdout", None) or []
    return "".join(parts).strip()


def main():
    global API_URL, TEMPLATE_ID
    ap = argparse.ArgumentParser(
        description="CubeSandbox / E2B cold-start + snapshot validation",
    )
    ap.add_argument(
        "--api-url",
        help="control-plane URL; overrides E2B_API_URL and the local .env "
        "(e.g. https://api.e2b.dev for E2B Cloud)",
    )
    ap.add_argument(
        "--template",
        help="template id; overrides CUBE_TEMPLATE_ID (e.g. 'base' for E2B Cloud)",
    )
    args = ap.parse_args()
    if args.api_url:
        API_URL = args.api_url
        # the e2b SDK reads its endpoint from the environment, and load_dotenv()
        # may have injected the local .env's :3000 -- force the chosen URL.
        os.environ["E2B_API_URL"] = args.api_url
    if args.template:
        TEMPLATE_ID = args.template

    preflight()
    results = []

    # 1 + 2 + 3: cold start, print a sentence, lay down state to snapshot.
    t0 = time.perf_counter()
    try:
        _cold = Sandbox.create(template=TEMPLATE_ID)
    except Exception as exc:  # noqa: BLE001 - surface a clean diagnostic
        sys.stdout.flush()
        sys.stderr.write(
            "CONTROL-PLANE FAIL at Sandbox.create(template=%s): %s\n"
            "  Likely causes: bad/placeholder E2B_API_KEY (401), unknown template\n"
            "  id, or the control plane is not serving. E2B Cloud: a real key from\n"
            "  the dashboard + template 'base'. CubeSandbox: a tpl-... id from\n"
            "  `cubemastercli tpl list`.\n" % (TEMPLATE_ID, exc)
        )
        return 3
    with _cold as sb:
        cold_s = time.perf_counter() - t0
        print("[1] cold start : %.3f s  (sandbox_id=%s)" % (cold_s, sb.sandbox_id))
        results.append(("cold_start", cold_s, True))

        printed = _stdout(sb.run_code('print("%s")' % SENTENCE))
        ok_print = printed == SENTENCE
        print("[2] print      : %r  -> %s" % (printed, "PASS" if ok_print else "FAIL"))
        results.append(("print_sentence", 0.0, ok_print))

        sb.run_code(
            "open('/tmp/marker.txt','w').write('%s')\n"
            "answer = 6 * 7\n" % MARKER
        )
        print("[3] state      : wrote /tmp/marker.txt and kernel var 'answer'")

        # 4: snapshot (pauses, captures memory + fs, resumes the source).
        t1 = time.perf_counter()
        snap = sb.create_snapshot()
        snap_s = time.perf_counter() - t1
        snapshot_id = snap.snapshot_id
        print("[4] snapshot   : %.3f s  (snapshot_id=%s)" % (snap_s, snapshot_id))
        results.append(("create_snapshot", snap_s, True))

    # 5: warm restore from the snapshot into a brand-new sandbox.
    try:
        t2 = time.perf_counter()
        with Sandbox.create(template=snapshot_id) as cloned:
            warm_s = time.perf_counter() - t2
            print("[5] warm start : %.3f s  (sandbox_id=%s)" % (warm_s, cloned.sandbox_id))

            fs_back = _stdout(cloned.run_code("print(open('/tmp/marker.txt').read())"))
            ok_fs = fs_back == MARKER
            print("    fs state   : %r -> %s" % (fs_back, "PASS" if ok_fs else "FAIL"))

            mem_back = _stdout(cloned.run_code("print(answer)"))
            ok_mem = mem_back == "42"
            print("    mem state  : answer=%r -> %s" % (mem_back, "PASS" if ok_mem else "FAIL(warn)"))

            results.append(("warm_restore", warm_s, True))
            results.append(("snapshot_preserves_fs", 0.0, ok_fs))
            results.append(("snapshot_preserves_mem", 0.0, ok_mem))
            speedup = (cold_s / warm_s) if warm_s > 0 else float("inf")
            print("    cold %.3fs vs warm %.3fs  (%.1fx faster)" % (cold_s, warm_s, speedup))
    finally:
        try:
            Sandbox.delete_snapshot(snapshot_id)
            print("[cleanup] snapshot %s deleted" % snapshot_id)
        except Exception as exc:  # noqa: BLE001 - cleanup is best-effort
            print("[cleanup] delete_snapshot failed: %s" % exc)

    print("\n==== SUMMARY ====")
    passed = True
    for name, secs, ok in results:
        passed = passed and ok
        timing = ("%.3fs" % secs) if secs else "-"
        print("  %-24s %-8s %s" % (name, timing, "PASS" if ok else "FAIL"))
    print("RESULT: %s" % ("PASS" if passed else "FAIL"))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
