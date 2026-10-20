# meta-cubesandbox: CubeSandbox → XuanTie Yocto Integration Design

Status: RESEARCH + DESIGN + DRAFT SKELETON, **revision 2**. Nothing here has been built
with bitbake. No existing layer was modified; all draft files live under
`/mnt/ssd/workarea/yanan.he/cubesandbox-riscv/yocto-integration/meta-cubesandbox/`.

Revision 2 changes (per user directive):
1. **OE-native toolchains**: all external prebuilt native toolchain stubs are removed;
   recipes `inherit cargo` / `inherit go` and build with OE's standard cross machinery.
   The rust (≥1.85) and go (1.25.7) version walls are met by backporting newer recipe
   sets into this layer and selecting them with PREFERRED_VERSION (§4).
2. **Dual guest kernel**: `linux-cube-guest` now exists in two versions — a READY 6.6.36
   recipe reusing the in-tree XuanTie kernel source (bring-up default) and the 7.2.0-rc7
   upstream-parity recipe (opt-in), both deploying `Image` as `vmlinux` (§5.1/§5.2).

Provenance shorthand used below:
- [MK]  = CubeSandbox `Makefile` (repo root, branch `add_riscv_support` @ bedc618801f487b822df7f7ab54a96069b87bbbb)
- [DFB] = `docker/Dockerfile.builder`
- [BK]  = `scripts/build-kernel.sh`
- [KC]  = `configs/kernel-oc9.riscv64.config`
- [SK]  = Skill `add-yocto-package` (`/rvhome/yanan.he/.qoder/skills/add-yocto-package/SKILL.md`)
- [LCM] = Skill `layer-conf-mgmt`
- [XT]  = `/mnt/ssd/workarea/yanan.he/xuantie-yocto` (OE-core `langdale`, `LAYERSERIES_CORENAMES = "langdale"`)

---

## 1. Target environment facts (verified)

| Item | Value | Source |
|---|---|---|
| Yocto release | OE-core **langdale** (4.1), bitbake **2.2.0**, classes in `meta/classes-recipe/` | [XT] `openembedded-core/meta/conf/layer.conf` L10 (`LAYERSERIES_CORENAMES = "langdale"`); `openembedded-core/bitbake/lib/bb/__init__.py` L12 |
| bblayers | oe-core, meta-openembedded (oe/networking/filesystems/python/perl/webserver), **meta-external-toolchain**, **meta-riscv**, **meta-xuantie** (priority 6), meta-k230, **meta-clang** (clang **15.0.x**), **meta-virtualization**; the `ngf` build additionally layers **meta-xuantie-ngf** | [XT] `xuantie-build/xuantie/conf/bblayers.conf`, `xuantie-build/ngf/conf/bblayers.conf`; `meta-clang/recipes-devtools/clang/clang.inc` L7-8 |
| Toolchain mode | `TCMODE = "external"` for all xuantie DISTROs → oe-core's `tcmode-default.inc` is NOT parsed (its `RUSTVERSION ?= "1.63%"` L30 and `PREFERRED_VERSION_{rust,cargo,libstd-rs}` L88-92 never apply); no rust/go handling in `meta-external-toolchain/conf/distro/include/tcmode-external.inc` | [XT] `meta-xuantie/conf/distro/include/xuantie-base.inc` L13; `openembedded-core/meta/conf/distro/include/tcmode-default.inc` |
| OE-core Rust | **1.63.0** recipe set (`rust_1.63.0.bb`, `cargo_1.63.0.bb`, `libstd-rs_1.63.0.bb`, `rust-llvm_1.63.0.bb`; bootstrap snapshot pinned **1.62.0**) — newest rust recipes anywhere in the tree | [XT] `openembedded-core/meta/recipes-devtools/{rust,cargo}/`; `rust-snapshot.inc` L8-9 |
| Newer-rust precedent | `meta-xuantie-ngf/recipes-devtools/rust/rust-standalone-native_1.95.0.bb`: prebuilt rust-lang.org binaries as **-native**, deliberately does NOT PROVIDE rust-native; its header (L1-20) documents why a source backport onto langdale is hard (bootstrap chain, bitbake 2.2.0) | [XT] |
| Cargo machinery works | `meta-xuantie/recipes-electron/ripgrep/ripgrep_13.0.0.bb` (`inherit cargo cargo_common rust rust-target-config`, crate:// SRC_URI) has been BUILT in this tree: `xuantie-build/ngf/tmp-glibc/work/riscv64-oe-linux/ripgrep/13.0.0-r0/` + `work/x86_64-linux/{rust-native,cargo-native,rust-llvm-native,libstd-rs riscv64 debs}` | [XT] |
| OE-core Go | **1.22.8** recipe family (`go_1.22.8.bb`, `go-cross_1.22.8.bb`, `go-runtime_1.22.8.bb`, bootstrap `go-binary-native_1.22.8.bb` from dl.google.com tarballs, L11-15); no newer go anywhere in the tree | [XT] `openembedded-core/meta/recipes-devtools/go/` |
| Go machinery works | `go-cross-riscv64` + `go-binary-native` built (`work/x86_64-linux/`); `containerd-opencontainers`, `docker-ce`, go-* helpers built for riscv64 (`work/riscv64-oe-linux/`) — containerd recipe is the in-tree `inherit go` + CGO precedent (S under `src/<GO_IMPORT>`, `CGO_*FLAGS --sysroot`, its L26-55) | [XT] `meta-virtualization/recipes-containers/containerd/containerd-opencontainers_git.bb` |
| libc switching | `LIBC=glibc|muslc|uclibc-ng` env → `XUANTIE_TCLIBC` → `require xuantie-libc-${LIBC}.inc`; muslc sets `TCLIBC = "musl"`, `TARGET_VENDOR = "-musl"`, `EXTERNAL_TARGET_SYS = riscv64-unknown-linux-musl`, toolchain `${YOCTOROOT}/xuantie-toolchain-gcc-muslc/rv64` (present locally, `riscv64-unknown-linux-musl-*` binaries verified) | [XT] `xuantie-base.inc` L383-387; `xuantie-libc-muslc.inc` L5-14; `xuantie-clang.inc` L2 |
| containerd | `containerd-opencontainers` **v1.6.8** in meta-virtualization (shim v2 OK: needs ≥ 1.4) | [XT] `meta-virtualization/recipes-containers/containerd/containerd-opencontainers_git.bb` |
| libseccomp / libcap-ng | **2.5.4** / **0.8.3** in OE-core, no COMPATIBLE_HOST restrictions (build for riscv64); libseccomp sets `DISABLE_STATIC = ""` (L25) → **libseccomp.a IS produced**; libcap-ng has NO such override, so its static availability follows the distro's global `DISABLE_STATIC` policy — TODO(verify); a one-line bbappend (`DISABLE_STATIC = ""`) forces libcap-ng.a if a static-musl shim build needs it | [XT] `openembedded-core/meta/recipes-support/{libseccomp,libcap-ng}/` |
| In-tree 6.6 kernel | `linux-xuantie_6.6.y.bb`: `git://github.com/ruyisdk/linux-xuantie-kernel.git;branch=linux-6.6.36`, `SRCREV = ${XUANTIE_LINUX_TAG}` (default AUTOREV); **Linux 6.6.36**; the ngf build pinned commit `ccb3ccf128b7d423b98a0b07b0cb2b409b44dea6` (= `XuanTie_V1.4.0-14-gccb3ccf128b7`), gcc-built (clang optional via `:toolchain-clang` overrides L102-127); default for all `KERNEL=6.6-*` DISTROs (`PREFERRED_VERSION_linux-xuantie = 6.6.y`, xuantie-base.inc L394,L417) | [XT] `meta-xuantie/recipes-kernel/linux/linux-xuantie_6.6.y.bb` L4,L37-38; `xuantie-build/ngf/tmp-glibc/work/rva23u64_k6.6xt_kcdefault_tcxt-oe-linux/linux-xuantie/6.6.y-r0/linux-6.6.y/.git` |
| bpftool / pahole | `meta-openembedded/meta-oe/recipes-kernel/bpftool/bpftool.bb`; linux-xuantie 6.6 already `DEPENDS += "pahole-native"` (L100) | [XT] |
| virtiofsd | **not found anywhere in the tree** — gap, see §7; note the riscv64 guest config has `# CONFIG_FUSE_FS is not set` (L6413) → virtiofs likely unused on this branch | grep over all layers; [KC] |
| cargo class | langdale `cargo_common.bbclass` forces **offline vendoring** (`[source.crates-io] replace-with = "bitbake"`, `local-registry = "/nonexistant"`, L54-60) unless `CARGO_DISABLE_BITBAKE_VENDORING = "1"` (L31); no `cargo-update-recipe-crates` task in langdale | [XT] `openembedded-core/meta/classes-recipe/cargo_common.bbclass` |
| cargo/rust model | `cargo.bbclass`: `BASEDEPENDS += cargo-native` (L19), target builds DEPENDS `rust-native ${RUSTLIB_DEP}` (L22) with `RUSTLIB_DEP ?= "libstd-rs"` (`rust-common.bbclass` L19); `--target ${RUST_HOST_SYS}` (L42); musl OS maps to `-musl` triple suffix (`rust-common.bbclass` L67-70); `riscv64gc-unknown-linux-{gnu,musl}` targets defined (`rust-target-config.bbclass` L241-246, L359-360) | [XT] |

## 2. CubeSandbox build facts (verified)

- One git repo contains all components; riscv64 cross build is `make all-riscv64` inside
  `cube-sandbox-builder:riscv64-cross` [MK L96-153, L259-271].
- Userspace target triple `riscv64gc-unknown-linux-musl`, **static musl**, linker
  `riscv64-linux-musl-gcc` (musl.cc prebuilt cross toolchain, sha256-pinned) [DFB L17, L255-261; MK L342, L459, L674].
- Rust toolchains: default **1.89**, hypervisor **1.77.2**, cubeapi/shim **1.85**, agent/cubecow **1.89**
  [DFB L19-22; `*/rust-toolchain.toml`]. These are **MINIMUMS**: `hypervisor/Cargo.toml` L13
  declares `rust-version = "1.77.0"` (MSRV), and the workspace lockfiles are the harder floor —
  `CubeShim/Cargo.lock`, `agent/Cargo.lock`, `guest-init/Cargo.lock`, `CubeAPI/Cargo.lock`,
  `cubecow/Cargo.lock` are all lockfile **`version = 4`** (line 3 of each; needs cargo ≥ 1.78),
  while `hypervisor/Cargo.lock` and `third_party/containerd-shim/Cargo.lock` are `version = 3`.
  Go **1.25.7** [DFB L12; go.mod `go 1.25.7` in Cubelet/CubeMaster/CubeOps/CubeTemplateCenter/
  cube-lifecycle-manager; cubevs go.mod `go 1.24.8`]. protoc **28.3** [DFB L13, L219; plugins
  protoc-gen-go v1.36.11 / protoc-gen-go-grpc v1.6.1 at L234-236]. clang-14 for eBPF [DFB L189-208].
- Static libs cross-built in the image: **libseccomp 2.5.5** and **libcap-ng 0.8.4** for
  `riscv64-linux-musl`, consumed via `LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=... LIBCAPNG_*`
  envs [DFB L271-290; MK L674 shim-riscv64, L498 agent-riscv64].
- Shim = CubeShim cargo workspace (`shim`, `protoc`, `cube-runtime`) with
  `cube-hypervisor = {path = "../../hypervisor", features = ["lib_support"]}`
  [CubeShim/shim/Cargo.toml L42]; hypervisor is Cloud Hypervisor **v28.0.0** fork
  [hypervisor/Cargo.toml L3], license `Apache-2.0 & BSD-3-Clause` (LICENSE-APACHE md5
  3b83ef96387f14655fc854ddc3c6bd57, LICENSE-BSD-3-Clause md5 b1ed361f9fc790c1054d81a7ef041a34).
  Outputs: `containerd-shim-cube-rs`, `cube-runtime` [MK L670-674]. Root repo LICENSE md5
  8cb1257418f6703a382b660af831c8fc.
- 12 riscv64 binaries and their build lines [MK L96-109, L340-549, L672-674]:
  agent (`cube-agent`, needs static libseccomp), cube-init (guest-init), cube-volume-s3 (Go, CGO off),
  cube-lifecycle-manager (Go, CGO off), cubeapi (`cube-api`, Rust 1.85), cubecow (Rust **staticlib**
  `libcubecow.a` consumed by Cubelet via CGO), cubelet (Go **CGO=1**, links libcubecow.a +
  bpf2go-generated cubevs objects + protoc), cubemaster(+cli), cubetemplatecenter (`templatecenter`),
  cubeops(+cli), cubevsmapdump, shim (2 binaries incl. hypervisor lib).
- eBPF: `CubeNet/cubevs` uses cilium/ebpf `bpf2go` with `-I../vmlinux/$BPF_TARGET_ARCH`;
  **riscv64 vmlinux.h is already vendored** at `CubeNet/vmlinux/riscv64/vmlinux.h`
  [CubeNet/cubevs/cubevs.go L12-14; CubeNet/vmlinux/Makefile regenerates it from
  `/sys/kernel/btf/vmlinux` via bpftool — host-only step].
- Guest kernel: out-of-tree kbuild from an external `KERNEL_SRC`, ARCH=riscv,
  CROSS_COMPILE=riscv64-linux-gnu-, config `configs/kernel-oc9.riscv64.config`, produces
  `arch/riscv/boot/Image` copied to `_output/kernel/riscv64/vmlinux` [BK L43-45, L73-82;
  MK L676-693]. Config header says **Linux/riscv 7.2.0-rc7, built with clang 17.0.6**
  [KC L3-12] → the exact kernel repo/tag is a deployment choice: TODO(verify). The only
  6.6 kernel the repo itself references is an **x86_64 host** PVM kernel
  (`kernel-6.6.117_opencloudos9.cubesandbox.pvm.host...rpm/deb`,
  deploy/kubernetes/images/build-cube-images.sh L57-58) — not usable as the riscv64
  guest kernel. This design therefore supports TWO guest kernels (§5.1): 7.2 (upstream
  parity) and a READY 6.6.36 reusing the in-tree XuanTie kernel source.
- Runtime layout (one-click installer): components under
  `/usr/local/services/cubetoolbox/{cube-shim/bin,cube-kernel-scf/vmlinux,cube-image/cube-guest-image-cpu.img,cube-agent/cube-agent.ext4,Cubelet/bin,...}`,
  symlinks into `/usr/local/bin`; containerd runtime type `io.containerd.cube.rs`
  [deploy/one-click/install.sh L2186-2216, config-cube.toml L1-26].
- Guest assets: `cube-init` is PID1 of the guest OS image (`/dev/pmem0`); `cube-agent.ext4`
  is mounted `/dev/pmem1` at `/run/support` [config-cube.toml L13-26; MK agent-ext4 target L516-523].

## 3. Proposed layer layout

```
meta-cubesandbox/
├── conf/layer.conf                       # BBFILE_COLLECTIONS=cubesandbox-layer, PRIORITY 7 (> meta-xuantie 6)
├── conf/distro/include/
│   └── cubesandbox-toolchain-versions.inc # PREFERRED_VERSION pins: rust/cargo/libstd-rs 1.89.0,
│                                          # go family 1.25.7, linux-cube-guest 6.6 (require'd from local.conf)
├── recipes-devtools/
│   ├── rust/rust_1.89.0.bb               # SKELETON — replace with donor oe-core rust 1.89 set (§4.1)
│   └── go/go_1.25.7.bb                   # SKELETON — replace with donor oe-core go 1.25.7 family (§4.2)
├── recipes-cube/
│   ├── cube-sandbox-common.inc           # shared SRC_URI/SRCREV/LICENSE for the mono-repo + toolchain notes
│   ├── cube-hypervisor/cube-hypervisor_git.bb      # OPTIONAL separate lib recipe (default: built inside shim)
│   ├── containerd-shim-cube/containerd-shim-cube_git.bb   # inherit cargo
│   ├── cube-agent/cube-agent_git.bb                # inherit cargo; static via LIBC=muslc variant; cube-init stub note
│   ├── cubecow/cubecow_git.bb                      # inherit cargo; staticlib for cubelet CGO
│   ├── cubelet/cubelet_git.bb                      # inherit go/goarch; CGO=1 + bpf2go + protoc
│   ├── packagegroups/packagegroup-cubesandbox.bb
│   └── images/image-cubesandbox.bb
└── recipes-kernel/linux/
    ├── linux-cube-guest_6.6.bb           # DEFAULT: reuses in-tree linux-xuantie 6.6.36 source, pinned SRCREV
    ├── linux-cube-guest_7.2.bb           # opt-in: upstream 7.2.0-rc7 parity with [KC], DEFAULT_PREFERENCE=-1
    └── linux-cube-guest/cube-guest-riscv64-defconfig   # copy of configs/kernel-oc9.riscv64.config (verified 1:1)
```

Layer conventions follow [SK]/[LCM]: `recipes-<category>/<pn>/<pn>_<pv>.bb`, layer.conf mirrors
meta-xuantie's (`BBPATH .= ":${LAYERDIR}"`, `BBFILES += "${LAYERDIR}/recipes-*/*/*.bb*"`),
`LAYERSERIES_COMPAT_cubesandbox-layer = "langdale"`. Priority 7 so our bbappends (none yet) and
`PREFERRED_*` can win over meta-xuantie without editing it. Because [SK] forbids adding packages via
`local.conf` and forbids editing other layers, image inclusion is done by our own
`image-cubesandbox.bb` that layers `packagegroup-cubesandbox` on top of the xuantie base image.

The mono-repo means every recipe fetches the **same** git repo (common `.inc`) and points `S`
at its subdirectory. That is the cheapest way to satisfy cross-directory path deps
(`../../hypervisor`, `third_party/containerd-shim` patch, `Cubelet/third_party/cubecow`,
`CubeNet/vmlinux/riscv64`). Bitbake will dedupe downloads via DL_DIR; each recipe still needs its
own sstate. (Alternative: `externalsrc` against the local clone for bring-up — recommended for
Phase 0, see §8.)

## 4. Toolchain strategy — OE-native rust/go (REVISED per directive)

The previous revision of this design proposed external prebuilt native toolchain stubs
(`rust-cube-{1.77.2,1.85,1.89}-native`, `go-cube-1.25.7-native`, `musl-cross-cube-native`,
`cube-musl-staticlibs-native`) replicating the Docker cross-builder. **That approach is
dropped.** All CubeSandbox recipes now `inherit cargo` / `inherit go` and build with OE's own
cross machinery (rust-native + cargo-native + libstd-rs / go-cross-riscv64 + go-runtime),
producing riscv64 artifacts inside bitbake. No Docker, no musl.cc tarball, no rustup.

### 4.1 Rust: one bumped OE toolchain (1.89.0), not three external ones

What the tree provides today (verified):
- oe-core langdale: rust **1.63.0** set only — `rust_1.63.0.bb`, `cargo_1.63.0.bb`,
  `libstd-rs_1.63.0.bb`, `rust-llvm_1.63.0.bb`, bootstrap snapshot pinned at **1.62.0**
  (`rust-snapshot.inc` L8-9). No meta-rust layer, no newer oe-core in the tree.
- `meta-xuantie-ngf/recipes-devtools/rust/rust-standalone-native_1.95.0.bb`: prebuilt
  rust-lang.org binaries, host-only (`-native`), deliberately NOT PROVIDES `rust-native`
  (L26-28 of its header). It is the tree's own "version wall" workaround and its L1-20
  header documents exactly why a source backport onto langdale is hard.
- The langdale cargo model works in this tree even under `TCMODE="external"`: ripgrep
  (`inherit cargo`, meta-xuantie) built to completion
  (`xuantie-build/ngf/tmp-glibc/work/riscv64-oe-linux/ripgrep/13.0.0-r0/`), with
  `rust-native`/`cargo-native`/`rust-llvm-native` in `work/x86_64-linux/` and target
  `libstd-rs_1.63.0` riscv64 debs. `cargo.bbclass` L19-23: BASEDEPENDS `cargo-native`,
  target DEPENDS `rust-native ${RUSTLIB_DEP}` where `RUSTLIB_DEP ?= "libstd-rs"`
  (`rust-common.bbclass` L19) — i.e. host cargo/rustc + a target-arch libstd, no
  rust-cross PN needed on langdale.

What CubeSandbox requires (all MINIMUMS, verified):
- `hypervisor/Cargo.toml` L13 `rust-version = "1.77.0"`; `CubeShim/rust-toolchain.toml`
  channel 1.77.2 but the actual riscv64 build line uses `cargo +1.85` (MK L674);
  `CubeAPI/rust-toolchain.toml` 1.85; `agent/`, `agent/libs/`, `cubecow/` 1.89;
  builder default 1.89 (DFB L19-22).
- Hard floor: `CubeShim/Cargo.lock`, `agent/Cargo.lock`, `guest-init/Cargo.lock`,
  `CubeAPI/Cargo.lock`, `cubecow/Cargo.lock` are lockfile `version = 4` (line 3) —
  cargo < 1.78 cannot even parse them, so `cargo build --locked` (MK L674) fails on
  oe-core's cargo 1.63 regardless of rustc.

**Chosen mechanism:** backport ONE newer rust recipe set — **1.89.0** — into
`meta-cubesandbox/recipes-devtools/rust/` (skeleton `rust_1.89.0.bb` committed, to be
replaced by a donor-copy from an oe-core release that ships rust 1.89; TODO(verify) which
release — whinlatter/master era). Since every pin is a minimum and 1.89 ≥ 1.85 ≥ 1.78 ≥
1.77.2 ≥ 1.77.0, **one toolchain satisfies all components** — the previous design's three
parallel rust natives are unnecessary. Selection via
`conf/distro/include/cubesandbox-toolchain-versions.inc` (new file):

```
RUSTVERSION ?= "1.89%"
PREFERRED_VERSION_rust / rust-native / rust-llvm-native / libstd-rs / cargo / cargo-native = "1.89.0"
PREFERRED_VERSION_go / go-native / go-binary-native / go-cross-riscv64 / go-runtime* = "1.25.7"
PREFERRED_VERSION_linux-cube-guest ?= "6.6"
```

activated by one line in the build's `conf/local.conf`
(`require conf/distro/include/cubesandbox-toolchain-versions.inc`). Note the xuantie
distros do NOT get these from oe-core: `TCMODE = "external"` (`xuantie-base.inc` L13)
means `tcmode-default.inc` (RUSTVERSION L30, PREFERRED_VERSION_rust/cargo/libstd-rs L88-92)
is never parsed — our include is the only selector, which also makes the bump explicit.
The stub recipes carry `DEFAULT_PREFERENCE = "-2"` so that before the donor copy lands,
oe-core's working 1.63/1.22.8 sets keep building the rest of the distro.

Known risks of the backport (restated in §9):
1. **Bitbake/class compatibility.** Donor rust recipes may need newer
   `cargo*.bbclass`/`rust*.bbclass` features than langdale's. BBPATH order means oe-core's
   classes win over same-named ones in our layer, so class changes require a mixin
   overlay dir placed ahead of oe-core on BBPATH (or a second, newer oe-core layer in
   bblayers). TODO(verify) at implementation; the ngf recipe header (L1-20) is evidence
   this is the main friction point on bitbake 2.2.0.
2. **Bootstrap chain.** rust 1.89 builds from its stage0 snapshot (donor
   `rust-snapshot.inc`), not from langdale's 1.62.0 pin — copy the donor file, expect
   large downloads and long native builds (hours) for `rust-native` + `rust-llvm-native`.
3. **`--locked` + lockfile v4**: satisfied by cargo 1.89; would break under 1.63 (see above).
4. **`rust-version` MSRV checks**: cargo errors when rustc < a crate's `rust-version`
   (since 1.56) and the MSRV-aware resolver (cargo ≥ 1.84) also honours it during
   resolution — 1.89 ≥ 1.77.0 so hypervisor passes; TODO(verify) transitive deps' MSRVs
   once the lockfiles resolve under the bumped toolchain.
5. **Global bump side-effects.** `rust`/`cargo-native`/`libstd-rs` are shared PNs: with
   PREFERRED_VERSION pinned, ALL rust consumers in the build move to 1.89 —
   `meta-xuantie` ripgrep, electron (`DEPENDS = "rust-native"`, cited in
   rust-standalone-native_1.95.0.bb L26-28), python3-cryptography. Newer rustc building
   older crates is normally fine; mitigation if not: keep the global pin but verify those
   three recipes rebuild; per-recipe scoping of a PREFERRED_VERSION is impossible in
   bitbake, and a separate-PN rust (the ngf prebuilt pattern) was explicitly rejected.

### 4.2 Go: bump OE's go family to 1.25.7

`go.mod` declares `go 1.25.7` (Cubelet/CubeMaster/CubeOps/CubeTemplateCenter/
cube-lifecycle-manager L3; CubeNet/cubevs L3 `go 1.24.8`); the go tool refuses modules
with a newer `go` directive, so langdale's 1.22.8 cannot build any of them. Chosen
mechanism mirrors rust: backport the go recipe family (`go_1.25.7.bb`, `go-1.25.7.inc`,
`go-cross`, `go-runtime`, `go-binary-native_1.25.7.bb`) from a donor oe-core into
`meta-cubesandbox/recipes-devtools/go/` (skeleton `go_1.25.7.bb` committed) and pin via
the same include. Bootstrap: go 1.25 needs a bootstrap toolchain ≥ go1.22.6
(`GOROOT_BOOTSTRAP`, `go-common.inc` L35) — the tree's existing
`go-binary-native_1.22.8.bb` (dl.google.com prebuilt, L11-15) satisfies that if the donor
recipe is adjusted, else ship `go-binary-native_1.25.7.bb`. The whole family must move
together because `go.bbclass` L38-42 wires `DEPENDS_GOLANG:class-target =
"virtual/${TUNE_PKGARCH}-go virtual/${TARGET_PREFIX}go-runtime"`. Recipes then use the
plain OE classes — `inherit go` (+`goarch`), patterned on the in-tree containerd
recipe (containerd-opencontainers_git.bb L26-55: custom do_compile, `CGO_ENABLED=1`,
`CGO_CFLAGS/LDFLAGS --sysroot=${STAGING_DIR_TARGET}`), no custom `cube-go.bbclass`.
Deviation from containerd: cube components are Go **module** mode (go.mod + replace),
so the checkout stays at `${S}=${WORKDIR}/git` (explicit `destsuffix=git` bypasses
go.bbclass's GOPATH `src/${GO_IMPORT}` relocation, L92-94) instead of containerd's
`GO111MODULE=off` GOPATH layout.
Side-effects: containerd/docker-ce/go-* helper recipes rebuild under go 1.25.7 (Go's
compatibility promise makes this low-risk; TODO(verify) by rebuilding containerd once).
Offline modules: none of the Go components has a `vendor/` dir (verified) and langdale's
`go-mod.bbclass` has no vendor task — plan a pre-generated `go mod vendor` tarball per
module in SRC_URI + `GOFLAGS=-mod=vendor` (§4.4).

### 4.3 musl-vs-glibc decision

Upstream builds userspace for `riscv64gc-unknown-linux-musl`, fully static (DFB L17,
L255-261; MK riscv64 targets). Three OE mappings were considered:

| Option | Assessment |
|---|---|
| (a) `TCLIBC=musl` distro/variant for everything | Fully supported by the tree: `LIBC=muslc` env bridge (`xuantie-base.inc` L383-387) → `xuantie-libc-muslc.inc` (`TCLIBC="musl"`, `EXTERNAL_TARGET_SYS=riscv64-unknown-linux-musl`, toolchain `${YOCTOROOT}/xuantie-toolchain-gcc-muslc/rv64` — present locally). OE then derives the rust triple `riscv64gc-unknown-linux-musl` automatically (`rust-common.bbclass` L67-70, `rust-target-config.bbclass` L241-246, L359-360) and go builds for musl. But it flips the WHOLE image to musl — invasive for the xuantie distro, and host-side cube components gain nothing from it. |
| (b) glibc distro + per-recipe musl cross-target (`CARGO_BUILD_TARGET=riscv64gc-unknown-linux-musl`) | Rejected: under a glibc distro `libstd-rs` only provides the **-gnu** target std, so cargo has no musl std to link; we would be back to smuggling an external musl toolchain/std — exactly what the directive forbids. |
| (c) Accept glibc dynamic for the Yocto image | Superseded by the static directive below. (Was: host-side dynamic-glibc, ELF not self-contained, needs the deployment rootfs to provide glibc.) |

**Chosen (current directive): FULLY STATIC via `RUSTFLAGS=-C target-feature=+crt-static`.**
The user directive is to build the cube Rust components static so the host-side binaries
(shim/cube-runtime, cube-api, cubecow, agent, cube-init) are self-contained ELFs that need
**no musl runtime shipped onto the glibc L1 rootfs** — this removes the deployment burden
found on the Docker artifacts (dynamic-musl shim needed `/lib/ld-musl-riscv64.so.1` +
`libc.so` + `libgcc_s.so.1` on L1). Mechanism = **option (a) scoped to the cube Rust
recipes**: build them in a `LIBC=muslc` variant, where OE derives the rust triple
`riscv64gc-unknown-linux-musl` and `+crt-static` yields a clean static ELF, then inject
those static ELFs into the glibc L1 image (a static binary is libc-agnostic at runtime).

**Verified** on the Docker cross-build (same flag): `containerd-shim-cube-rs` goes from
"dynamically linked, interpreter `/lib/ld-musl-riscv64.so.1`, NEEDED{libc.so, libgcc_s.so.1}"
to "**statically linked, 0 NEEDED**" with `RUSTFLAGS=-Ctarget-feature=+crt-static` — matching
how Firecracker / Cloud Hypervisor / kata-agent ship. crt-static is clean **only on musl**;
glibc + crt-static is fragile (NSS/`getaddrinfo` dlopen, needs glibc-staticdev) → hence the
`LIBC=muslc` variant, not a glibc static link.

Wiring (all gated on `:libc-musl`, so a glibc build is untouched):
- `cube-sandbox-common.inc`: `RUSTFLAGS:append:libc-musl = " -C target-feature=+crt-static"`
  (shared by every cube Rust recipe).
- Each Rust recipe with C deps exports the static archives in `do_compile:prepend:libc-musl`:
  `LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=${STAGING_DIR_TARGET}${libdir}` (+ the
  `LIBCAPNG_*` pair for the shim). oe-core libseccomp 2.5.4 ships `libseccomp.a`
  (`DISABLE_STATIC = ""`, `libseccomp_2.5.4.bb` L25); libcap-ng has no such override, so a
  one-line bbappend in this layer (`DISABLE_STATIC = ""`) forces `libcap-ng.a` — REQUIRED now
  that the shim is static (previously only needed if the shim moved to musl).
- Packaging: static ELFs trip `already-stripped`/`staticdev` QA → `INSANE_SKIP:${PN}:append:libc-musl`
  in the shim recipe; no shared-lib RDEPENDS are auto-added for a 0-NEEDED binary.

**cube-agent / cube-init** were already static-mandated (the guest-asset pipeline
`deploy/one-click/lib/guest-image.sh` L376-399 `install_static_agent_binary` runs ldd/file and
`die`s on any dynamic dep, because `cube-agent.ext4` is a bare 2 MiB ext4 with no libc). The
new directive simply extends the same `LIBC=muslc + crt-static` treatment from those two to
**all** cube Rust components.

**Go components** (cubelet, cube-api-front, control plane): static comes from `CGO_ENABLED=0`
(pure-Go static, no libc at all), NOT crt-static. The one snag is **cubelet**, which uses CGO
to link the `cubecow` staticlib + bpf2go eBPF → it cannot be `CGO_ENABLED=0`. For a static
cubelet, build it in the same `LIBC=muslc` variant with CGO on and `-extldflags "-static"`
(musl static CGO is clean); `cubecow` (Rust staticlib consumed by that CGO) must be the musl
static archive too. TODO(verify): musl-static CGO for cubelet + bpf2go object compatibility.

A `conf/multiconfig/musl.conf` (bitbake multiconfig) can fold the musl-variant build of these
recipes into one invocation alongside the glibc L1 image; TODO(verify) multiconfig +
TCMODE=external interactions.

The local XuanTie musl toolchain (`xuantie-toolchain-gcc-muslc/rv64`, verified present)
is consumed by OE itself through `EXTERNAL_TOOLCHAIN_GCC:libc-musl:riscv64`
(`xuantie-libc-muslc.inc` L9) — as a reference/toolchain provider inside the normal OE
flow, not as an external builder bypass.

### 4.4 Vendoring decision (kept, re-justified)

`CARGO_DISABLE_BITBAKE_VENDORING = "1"` is kept for all cargo recipes. Re-justification
against the actual tree/repo state: langdale's `cargo_common.bbclass` (L54-60) points
`[source.crates-io]` at a bitbake-populated local registry (`cargo-bitbake`-generated
`crate://` SRC_URI lists; langdale has NO `cargo-update-recipe-crates` task — that is
newer oe-core). The CubeSandbox workspaces are a poor fit for that model:
`CubeShim/Cargo.toml` L9-10 carries `[patch.crates-io] containerd-shim = { path =
"../third_party/containerd-shim" }` (an in-repo path patch), the workspaces are huge
(hypervisor = Cloud Hypervisor v28 fork), and every lockfile must be honored with
`--locked`. Verified: `CubeShim/.cargo/config` contains only `[net]
git-fetch-with-cli = true` and `agent/.cargo/config.toml` only x86_64/aarch64 musl linker
stanzas — **no pre-existing vendor configuration** to reuse. Plan: generate `cargo
vendor` tarballs once per workspace (or crate:// lists, ripgrep-style), ship in SRC_URI,
and let cargo consume them offline with the bitbake registry disabled. Go modules: the
same problem, same shape (`go mod vendor` tarball + `GOFLAGS=-mod=vendor`, see §9.8).

## 5. Per-component recipe strategy

All recipes use OE's own cross machinery (§4): Rust → `inherit cargo` (rust-native +
cargo-native + libstd-rs from the backported 1.89.0 set); Go → `inherit go`/`goarch`
(go-cross-riscv64 + go-runtime from the backported 1.25.7 family, containerd-recipe
style). Default libc is the distro's glibc (dynamic); `cube-agent`/`cube-init` also have
a `LIBC=muslc` static variant (§4.3). No external prebuilt toolchain DEPENDS remain.

| Recipe (PN) | Source dir | Lang/toolchain | Class strategy | Key deps & notes |
|---|---|---|---|---|
| `containerd-shim-cube` | `CubeShim/` + `hypervisor/` + `third_party/containerd-shim` | Rust (≥1.85; built with 1.89 — the `cargo +1.85` of MK L674 and the workspace's 1.77.2 pin are both minimums) | `inherit cargo`; `--locked` appended to `CARGO_BUILD_FLAGS` (langdale has NO `EXTRA_OECARGO_ARGS` — that hook is newer oe-core; `--release` comes from BUILD_MODE, cargo.bbclass L41-42, L54); `--target`/linker/CC come from `cargo.bbclass` L42 + `oe_cargo_fix_env` (`cargo_common.bbclass` L119-137); build the **whole workspace incl. hypervisor path dep** in one recipe | `DEPENDS += "libseccomp libcap-ng"` (oe-core 2.5.4/0.8.3, shared, pkg-config — the LIBSECCOMP_LINK_TYPE=static envs of MK L674 are dropped in the glibc default); protoc for `shim/build.rs` — CubeShim vendors a `protoc` workspace member (`CubeShim/Cargo.toml` L2-6); TODO(verify) whether system protoc still needed; installs `containerd-shim-cube-rs`, `cube-runtime` via `cargo_do_install` (cargo.bbclass L63-88) |
| `cube-hypervisor` | `hypervisor/` | Rust (rust-version = "1.77.0" minimum, Cargo.toml L13) | **Not built separately by default** — Cargo `path = "../../hypervisor"` deps do not map onto the sysroot handoff; stub recipe kept for docs + `cargo test --features kvm` CI use [MK L663-665] | lockfile v3 (line 3 of hypervisor/Cargo.lock) — any cargo ≥ 1.53 can read it; 1.89 fine |
| `cube-agent` | `agent/` | Rust 1.89 (rust-toolchain.toml), **static-musl required by the guest-asset pipeline** | `inherit cargo`; default glibc build; `:libc-musl` overrides add `-C target-feature=+crt-static` + `LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=${STAGING_DIR_TARGET}${libdir}`; built for the guest via a `LIBC=muslc` variant build (§4.3) | `DEPENDS += "libseccomp"` (oe-core static archive available: `DISABLE_STATIC = ""`, libseccomp_2.5.4.bb L25); hard requirement grounded in `deploy/one-click/lib/guest-image.sh` L376-399 (install_static_agent_binary `die`s on dynamic deps); sibling stub `cube-init` from `guest-init/` (no seccomp), also static-musl (guest PID1) [MK L505-507] |
| `cube-api` | `CubeAPI/` | Rust 1.85 minimum | same cargo pattern as agent (glibc default) | output `cube-api`; TODO recipe (Phase 2) |
| `cubecow` | `cubecow/` | Rust 1.89 → **staticlib** `libcubecow.a` (crate-type at cubecow/Cargo.toml L10) + `include/cubecow.h` | `inherit cargo`; custom `do_install` from `${B}/target/${RUST_HOST_SYS}/release/` (cargo_do_install does not package `.a` into sysroot-consumable form); `-staticdev` package | must share cubelet's libc (CGO link) → glibc by default; mirrors `cubecow-riscv64` staging [MK L340-342] |
| `cubelet` | `Cubelet/` (+ `CubeNet/cubevs`, `pkgs/*` via go.mod replace) | Go 1.25.7, **CGO_ENABLED=1** | `inherit go` + `goarch`, containerd-recipe pattern (containerd-opencontainers_git.bb L30-31,L41-63); **module mode** (go.mod + `replace ../pkgs`) not GOPATH mode, so the whole repo is fetched to `${S}=${WORKDIR}/git` via `destsuffix=git` (stops go.bbclass do_unpack L92-94 relocating it under `src/${GO_IMPORT}`); custom `do_compile` runs `make gen` (bpf2go) → `make proto` → `make build` from `${S}/Cubelet` | `DEPENDS += "cubecow clang-native protobuf-native"`; CGO CC = OE's `${CC}` via go.bbclass env (NOT a hand-set musl gcc); `CGO_CFLAGS/LDFLAGS --sysroot=${STAGING_DIR_TARGET}` (containerd L50-51); bpf2go needs clang with BPF target (meta-clang 15.0.x in-tree vs upstream clang-14 pin — BPF codegen stable, TODO(verify)); protoc-gen-go/-go-grpc plugins need go-native recipes (DFB L234-236); outputs `cubelet`, `cubecli`; offline modules: no `vendor/` in repo (verified) → `go mod vendor` tarball + `GOFLAGS=-mod=vendor` (§4.4) |
| `cubemaster`, `cubeops`, `cubetemplatecenter`, `cube-lifecycle-manager`, `cube-volume-s3`, `cubevsmapdump` | respective dirs | Go, **CGO_ENABLED=0** [MK L436, L448, L468, L479, L489] | plain `inherit go`, trivial once the 1.25.7 family exists | templatecenter/cubelet share go.mod `replace` paths → whole-repo SRC_URI covers it; recipes TODO (Phase 2) |
| `linux-cube-guest` | in-tree 6.6 kernel source / upstream 7.2 | kbuild | **dual recipe** — see §5.1 | deploy `Image` **as `vmlinux`** from both (build-kernel.sh L73-82) |
| `cube-guest-assets` (stub) | `deploy/one-click/build-agent-ext4.sh`, `build-guest-image.sh` | scripts | packages `cube-agent.ext4` + guest OS image containing `cube-init` as `/sbin/init` | needs e2fsprogs-native (`mkfs.ext4 -d`, 4K block size forced for rootflags=dax — guest-image.sh L489-492); guest rootfs currently comes from a Dockerfile (guest-image.sh L459-501 docker build/export) → replace with a Yocto image recipe or keep docker OUT of Yocto by building the rootfs with `do_rootfs`-style tooling; TODO(verify) |

SRC_URI base for all: `git://git@gitlab.alibaba-inc.com/yocto-linux-sdk/cubesandbox.git;protocol=ssh;branch=feat/riscv64-port` (internal Aone Code mirror of the fork; carries the full upstream history + the 10-commit riscv64 port).
`SRCREV = "1a19eadebdd5ae2ae3dc840c79cbebfa6bacb0e2"` (tip of feat/riscv64-port = base bedc618 + 10 signed commits). After the CR merges feat/riscv64-port into add_riscv_support, switch CUBE_BRANCH/CUBE_SRCREV to the merge commit.
For air-gapped/CI use, publish a release tarball and use PREMIRRORS — noted in the `.inc`.

### 5.1 Guest kernel: dual 7.x / 6.6.x support

Two recipes, one PN (`linux-cube-guest`), selectable by version:

| | `linux-cube-guest_6.6.bb` (DEFAULT) | `linux-cube-guest_7.2.bb` (opt-in) |
|---|---|---|
| Source | **Reused in-tree**: same repo/branch as `meta-xuantie/recipes-kernel/linux/linux-xuantie_6.6.y.bb` L4 — `git://github.com/ruyisdk/linux-xuantie-kernel.git;branch=linux-6.6.36` (Linux **6.6.36**) | Upstream Linux **7.2.0-rc7** (the version stamped in [KC] L3); exact repo/tag TODO(verify) — MK `guest-kernel` takes `KERNEL_SRC` from the env, so provenance is a deployment choice |
| SRCREV | **Pinned** `ccb3ccf128b7d423b98a0b07b0cb2b409b44dea6` — the commit the tree itself built (ngf workdir `linux-xuantie/6.6.y-r0/linux-6.6.y/.git`; `git describe` = `XuanTie_V1.4.0-14-gccb3ccf128b7`). TODO(verify) same SHA reachable on the github mirror | `${AUTOREV}` placeholder; must pin at integration |
| Compiler | XuanTie **GCC** (the tree's default `TOOLCHAIN=gcc` path — this kernel is the machine kernel of every `KERNEL=6.6-*` DISTRO and builds today; clang optional via the same `:toolchain-clang` overrides as linux-xuantie_6.6.y.bb L102-127) | [KC] was generated by **clang 17.0.6** ([KC] L5-12) with in-kernel Rust 1.89 stamps (L14-16); meta-clang in-tree provides clang **15** — GCC build via `olddefconfig` cleanup is the planned default, clang 15/17 or upstream toolchain TODO(verify) |
| Config | shared `cube-guest-riscv64-defconfig` (= [KC], 1:1 copy verified) pruned by 6.6 `olddefconfig` + audit list (§5.2) | shared `cube-guest-riscv64-defconfig` verbatim + `olddefconfig` |
| Selection | `PREFERRED_VERSION_linux-cube-guest ?= "6.6"` (cubesandbox-toolchain-versions.inc) **and** `DEFAULT_PREFERENCE = "-1"` on the 7.2 recipe → 6.6 wins even without the include | `PREFERRED_VERSION_linux-cube-guest = "7.2"` |
| Role | **bring-up/stable default**: ready source in-tree, gcc-buildable, same kernel family the host runs | **upstream parity**: matches the CubeSandbox guest config exactly; newer, clang-flavoured |

Both recipes: `inherit kernel`; `KERNEL_IMAGETYPE = "Image"`; `do_deploy:append`
installs `${B}/arch/riscv/boot/Image` as `${DEPLOYDIR}/vmlinux` so the artifact name is
**identical** for both and matches what `scripts/build-kernel.sh` L73-82 produces
(`cube-kernel-scf/vmlinux`, config-cube.toml L13). Neither may become the machine
kernel: `kernel.bbclass` L14 unconditionally adds `PROVIDES += "virtual/kernel"`, so we
rely on (a) `PREFERRED_PROVIDER_virtual/kernel = "linux-xuantie"` staying put
(xuantie-base.inc L25) and (b) `KERNEL_PACKAGE_NAME = "cube-guest-kernel"` to keep
package names disjoint. Note the "PVM 6.6.117 OpenCloudOS kernel" seen in the repo is an
**x86_64 host** kernel RPM/DEB for the Kubernetes deploy path
(`deploy/kubernetes/images/build-cube-images.sh` L57-58) — NOT usable as the riscv64
guest kernel; the reusable 6.6 for riscv64 is the XuanTie one above.

### 5.2 6.6 defconfig derivation from the 7.x config

The starting point is the same [KC] file; 6.6's `olddefconfig` silently drops unknown
symbols. What must be watched (full list in the recipe comments):
- Compiler stamp symbols regenerate automatically: `CONFIG_CC_VERSION_TEXT`,
  `CONFIG_CC_IS_CLANG`, `CONFIG_GCC_VERSION=0`, `CONFIG_CLANG_VERSION`, `CONFIG_AS_IS_LLVM`,
  `CONFIG_LD_IS_LLD` ([KC] L5-12).
- In-kernel Rust stamps (`CONFIG_RUSTC_VERSION=108900`, `CONFIG_HAVE_RUST=y`, [KC] L14-16,
  L641): 6.6.36-riscv does not enable Rust — drops out; ensure `CONFIG_RUST` stays off.
- Clang-only hardening is already "# not set" in [KC] (`CONFIG_SHADOW_CALL_STACK` L663,
  `CONFIG_LTO_CLANG*` L668-670) — no GCC conflicts expected.
- 7.x-only KVM generic symbols ([KC] L558-568, e.g. `KVM_GENERIC_HARDWARE_ENABLING`)
  drop out; verify the guest-side essentials survive on 6.6: `CONFIG_RISCV_SBI` (L306),
  `CONFIG_VIRTIO_{BLK,NET,CONSOLE,VSOCKETS,PMEM}` (L1296-5310), `CONFIG_BLK_DEV_PMEM`
  (L6329), `CONFIG_DAX` (L6335), `CONFIG_9P_FS` (L6540), `CONFIG_BLK_DEV_INITRD` (L221),
  `CONFIG_DEVTMPFS[_MOUNT]` (L1469-1470), `CONFIG_SECCOMP[_FILTER]` (L655-656),
  ext4 (guest rootfs on pmem0 with `rootflags=dax`, guest-image.sh L489-491).
- After the first successful build: `make savedefconfig` → commit a minimal
  6.6-native `cube-guest-6.6-defconfig` so the guest config is explicit, not
  inherited-then-pruned. TODO(verify).

## 6. eBPF / CubeVS specifics

- Compile-time only on the **host**: bpf2go runs `clang -target bpf` during `go generate`
  [cubevs.go L12-14]. In Yocto: `DEPENDS += "clang-native"` from meta-clang (already in
  bblayers [XT]); upstream pins clang-14 [DFB L189-208], in-tree meta-clang is **15.0.x**
  (`meta-clang/recipes-devtools/clang/clang.inc` L7-8) — BPF codegen is stable across
  these: TODO(verify) at first build.
- `vmlinux.h`: use the **vendored** `CubeNet/vmlinux/riscv64/vmlinux.h` (checked into the fork).
  Regeneration path (optional, keeps BTF in sync with linux-cube-guest): run
  `bpftool btf dump file vmlinux format c` (bpftool recipe exists in meta-oe [XT]) against the
  guest kernel's BTF in `linux-cube-guest`'s `do_deploy`, then feed cubelet via a staged header.
  Not required for Phase 1.
- Runtime: eBPF programs load into the **host** kernel → host kernel needs
  `CONFIG_BPF_SYSCALL`, `CONFIG_DEBUG_INFO_BTF`, cgroup/tc hooks; cubelet also needs bpffs mounted.
  In-tree finding: meta-xuantie already ships eBPF/BTF host-kernel fragments
  (`meta-xuantie/recipes-kernel/linux/files/kernel.ebpf.cfg`: BPF_SYSCALL, BPF_JIT,
  CGROUP_BPF, NET_CLS_BPF, KPROBES…; `kernel.btf.cfg`: DEBUG_INFO_BTF), and
  meta-xuantie-ngf wires a `container-builtin.cfg` into the same 6.6 kernel
  (`meta-xuantie-ngf/recipes-kernel/linux/linux-xuantie_6.6.y.bbappend` L32) — so a 6.6
  host built with those fragments may already satisfy cubevs.
  TODO(verify): whether the selected xuantie 6.6 machine/distro config actually pulls
  kernel.ebpf.cfg/kernel.btf.cfg in (`0005-disable-CONFIG_DEBUG_INFO_BTF.patch` in the
  same files dir suggests some variants disable BTF).
- KVM/AIA: the shim links cube-hypervisor with the `kvm` feature; runtime needs host
  `/dev/kvm` with RISC-V H-extension + AIA (IMSIC/APLIC) on real hardware (XuanTie C9xx with H-ext,
  or QEMU with kvm on such a host). Pure QEMU-system validation can only exercise `--version`-level
  smoke, not VM launch (nested virt unavailable).

## 7. Image assembly & runtime deps

`packagegroup-cubesandbox` (RDEPENDS):
- compute-node set: `containerd-shim-cube`, `cubelet` (+`cubecli`), `cube-agent`, `cube-init`,
  `cube-volume-s3`, `cubevsmapdump`, `cube-lifecycle-manager`,
  `containerd-opencontainers` (meta-virtualization; needs a config fragment adding
  `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.cube] runtime_type = "io.containerd.cube.rs"`
  per config-cube.toml — shipped as `/etc/containerd/config.d` snippet or bbappend TODO),
- control-plane set (separate packagegroup `packagegroup-cubesandbox-master`): `cube-api`,
  `cubemaster`, `cubeops`, `cubetemplatecenter`,
- assets (not packages): guest kernel `Image`(→vmlinux), guest OS image, `cube-agent.ext4` —
  deployed to `/usr/local/services/cubetoolbox/...` by `cube-guest-assets` + an install fragment
  mirroring deploy/one-click/install.sh symlink layout.
- `virtiofsd`: **gap** — no recipe in any layer of [XT]. Cloud Hypervisor v28 uses virtiofsd for
  shared FS; the riscv64 guest config has `# CONFIG_FUSE_FS is not set` ([KC] L6413), which
  suggests the riscv64 flow does NOT use virtiofs (9P is enabled instead, [KC] L6540).
  TODO(verify) against the shim's riscv64 fs setup; if needed after all: add a `virtiofsd`
  recipe (Rust, upstream rust-vmm) to meta-cubesandbox — it would build with the same
  bumped OE rust 1.89 set.

`image-cubesandbox.bb`: `inherit core-image`, `IMAGE_INSTALL` = base xuantie image contents
(`require`/`IMAGE_INSTALL += "packagegroup-cubesandbox"` on top of a small base — TODO(verify)
whether `xuantie-image-lite` can be `require`d from another layer cleanly).

## 8. Dependency graph & phased plan

```
BACKPORTED OE TOOLCHAIN SETS (recipes-devtools/ in this layer, PREFERRED_VERSION-selected):
  rust 1.89.0 (rust-native, cargo-native, libstd-rs, rust-llvm-native)
  go   1.25.7 (go-native, go-binary-native, go-cross-riscv64, go-runtime)
OE/tree-provided: clang-native (meta-clang 15)   protobuf-native (OE 3.21)
                  libseccomp 2.5.4 / libcap-ng 0.8.3 (OE-core, target, shared)
        │                                          │
        ├─► cube-init (guest-init, musl-static*)   ├─► cubemaster / cubeops / templatecenter
        ├─► cube-agent (musl-static*)              │     lifecycle-manager / cube-volume-s3
        ├─► cube-api                               ├─► cubevsmapdump (vendored vmlinux.h)
        └─► containerd-shim-cube (⊃ hypervisor)    └─► cubecow(staticlib) ──► cubelet (⊃ cubevs bpf2go, CGO)
linux-cube-guest 6.6 (default) | 7.2 (opt-in)      cube-guest-assets (needs cube-init, cube-agent)
all ──► packagegroup-cubesandbox ──► image-cubesandbox
   * built in a LIBC=muslc variant environment (§4.3); everything else glibc-dynamic
```

- **Phase 0 (unblock, 1-2 days):** `externalsrc` against the local CubeSandbox clone +
  prebuilt artifacts from `make all-riscv64` for the runtime wiring smoke test only
  (containerd `io.containerd.cube.rs`, file layout). Clearly non-production.
- **Phase 1 (toolchain backport — now the critical path):** land the donor rust 1.89.0 +
  go 1.25.7 recipe sets (§4.1/§4.2), the `cubesandbox-toolchain-versions.inc` pin, verify
  ripgrep/containerd still build (global-bump side effects), then build `cube-init` and
  `cube-agent` (smallest cargo workspaces) incl. the LIBC=muslc static variant.
- **Phase 2 (core VM path):** `containerd-shim-cube` (with hypervisor path dep, crate
  vendoring first). Boot a microVM on H-ext hardware/QEMU-KVM with the **6.6** guest kernel.
- **Phase 3 (control plane):** `cube-api`, `cubemaster`, `cubeops`, `cubetemplatecenter`,
  `cube-lifecycle-manager`, `cube-volume-s3` (trivial `inherit go` recipes once 1.25.7 exists).
- **Phase 4 (networking/eBPF):** `cubecow` + `cubelet` + `cubevsmapdump` (clang-native
  bpf2go, CGO, protobuf plugins), host kernel BPF fragment verification (§6).
- **Phase 5 (guest kernel parity + hardening):** 7.2 guest kernel bring-up (clang or GCC,
  §5.1), savedefconfig-derived 6.6 config (§5.2), `cube-guest-assets`, bpftool-generated
  vmlinux.h, virtiofsd if needed, snapshot/restore re-enable tracking.

## 9. Risks / blockers (top items with mitigations)

The former #1/#2 "Rust/Go version walls" are now handled by bumping OE's OWN recipes
(§4.1/§4.2). The residual risks:

1. **Rust 1.89 backport onto langdale (bitbake 2.2.0).** Donor recipes may need newer
   `cargo*.bbclass`/`rust*.bbclass` features; oe-core's classes win on BBPATH order, so a
   mixin overlay ahead of oe-core may be required. Bootstrap chain = donor
   `rust-snapshot.inc` stage0 tarballs (large downloads, hours of native build). The
   tree's own precedent (`meta-xuantie-ngf/.../rust-standalone-native_1.95.0.bb` L1-20)
   documents this friction and chose prebuilts — our fallback if the source backport is
   unbuildable, but rejected as the design. Mitigation: pick the OLDEST donor release
   whose rust ≥ 1.85 (whinlatter-era ships 1.85 — TODO(verify)) to minimise class drift;
   land it behind DEFAULT_PREFERENCE=-2 stubs first (done).
2. **Global rust/go bump side-effects.** PREFERRED_VERSION is per-PN, not per-consumer:
   pinning 1.89/1.25.7 moves meta-xuantie's ripgrep/electron, python3-cryptography and
   meta-virtualization's containerd/docker-ce/go-* onto the new toolchains too.
   Mitigation: rebuild those once in Phase 1; Go's compatibility promise and rustc's
   backward compat make breakage unlikely; a rust provided only to cube recipes would
   require a separate PN (the rejected prebuilt pattern).
3. **`cargo build --locked` vs lockfile versions.** CubeShim/agent/guest-init/CubeAPI/
   cubecow locks are `version = 4` (cargo ≥ 1.78), hypervisor/third_party locks are
   `version = 3` — 1.89 reads both. Residual risk is the opposite direction: if the
   bumped cargo REWRITES locks (it must not, with --locked) or a dep's `rust-version`
   MSRV exceeds 1.89 (unlikely). Also crate MSRV-aware resolution may pick different
   versions if locks are ever regenerated — keep --locked everywhere (MK L674 parity).
4. **musl-vs-glibc divergence from upstream.** Accepted for host components (glibc
   dynamic, §4.3c); cube-agent/cube-init MUST be static (guest-image.sh L376-399) via a
   LIBC=muslc variant build — that path exercises TCLIBC=musl + the external XuanTie
   musl toolchain + crt-static rust + static libseccomp (OE libseccomp ships .a;
   libcap-ng needs a static-enabling bbappend if ever required). Residual: QA checks on
   static-pie ELFs, and keeping two libc variants of the guest binaries in sync.
5. **KVM/AIA runtime requires real H-extension hardware** (or nested KVM). QEMU-system
   smoke can't launch microVMs without /dev/kvm. Mitigation: target XuanTie FPGA/board
   with H-ext for exit criteria; `--version`-level checks elsewhere. Snapshot/restore is
   disabled on the riscv64 branch — feature gap, document only.
6. **containerd integration**: v1.6.8 in meta-virtualization is old but shim-v2-compatible;
   needs runtime registration (`io.containerd.cube.rs`) and the `/usr/local/services/cubetoolbox`
   asset layout the shim expects (hard-coded paths in config-cube.toml) — packaging must
   reproduce those paths or patch the shim config. virtiofsd recipe missing (probably
   unused on riscv64: `# CONFIG_FUSE_FS is not set`, [KC] L6413).
7. **Guest kernel: clang-for-7.x.** [KC] is a clang-17 + rust-1.89-stamped 7.2.0-rc7
   config; in-tree meta-clang is 15. GCC build via olddefconfig is the plan (stamps
   regenerate; clang-only options are all "# not set" in [KC]); residual risk is 7.x
   requiring newer clang/gcc than the tree ships — which is exactly why **6.6 is the
   default** (in-tree source, pinned SRCREV ccb3ccf128b7, gcc-built today by the xuantie
   distros). kernel.bbclass's unconditional `PROVIDES += "virtual/kernel"` (L14) is
   defused by PREFERRED_PROVIDER staying linux-xuantie + KERNEL_PACKAGE_NAME.
8. **Offline vendoring of crates and Go modules.** langdale cargo is offline-vendoring-only
   (cargo_common L54-60) and no component has a `vendor/` dir (verified for all Go modules);
   plan `cargo vendor` / `go mod vendor` tarballs in SRC_URI with
   CARGO_DISABLE_BITBAKE_VENDORING=1 (§4.4) / GOFLAGS=-mod=vendor. protoc 28.3 vs OE
   protobuf 3.21 codegen mismatch is a related unknown (protoc-gen-go plugins must come
   from the bumped go family).
9. **Layer priority / name collisions**: `cube*` PNs are unique today; priority 7 + unique
   collection name keeps us isolated from meta-xuantie (priority 6). The backported
   rust/go PNs intentionally SHADOW oe-core's via PREFERRED_VERSION (see risk 2).

## 10. Skeleton files created / revised (this task)

All under `/mnt/ssd/workarea/yanan.he/cubesandbox-riscv/yocto-integration/meta-cubesandbox/`:
- `conf/layer.conf` (unchanged)
- NEW `conf/distro/include/cubesandbox-toolchain-versions.inc` — the PREFERRED_VERSION
  selection mechanism (rust 1.89.0 / go 1.25.7 / linux-cube-guest 6.6).
- NEW `recipes-devtools/rust/rust_1.89.0.bb` — backport skeleton + donor-copy instructions.
- NEW `recipes-devtools/go/go_1.25.7.bb` — backport skeleton + donor-copy instructions.
- REVISED `recipes-cube/cube-sandbox-common.inc` — external-toolchain stubs removed;
  OE-native toolchain notes + CARGO_DISABLE_BITBAKE_VENDORING re-justification.
- REVISED `recipes-cube/containerd-shim-cube/containerd-shim-cube_git.bb` — `inherit cargo`
  only; DEPENDS libseccomp/libcap-ng (OE target recipes); no hand-set target/linker envs.
- REVISED `recipes-cube/cube-agent/cube-agent_git.bb` — `inherit cargo`; static-musl gated
  on `:libc-musl` overrides (LIBC=muslc variant build); cube-init stub note.
- REVISED `recipes-cube/cubecow/cubecow_git.bb` — `inherit cargo`; staticlib install from
  `${B}/target/${RUST_HOST_SYS}/release`.
- REVISED `recipes-cube/cubelet/cubelet_git.bb` — `inherit go`+`goarch` (containerd
  pattern), module-mode mono-repo layout (`destsuffix=git`), CGO with OE CC/sysroot,
  cubecow staging, bpf2go + protoc steps.
- REVISED `recipes-cube/cube-hypervisor/cube-hypervisor_git.bb` — external rust dep removed.
- REVISED `recipes-kernel/linux/linux-cube-guest_7.2.bb` — opt-in (DEFAULT_PREFERENCE=-1),
  clang-17-config-vs-GCC plan, `vmlinux` deploy alias, virtual/kernel isolation rationale.
- NEW `recipes-kernel/linux/linux-cube-guest_6.6.bb` — reuses the in-tree
  ruyisdk/linux-xuantie-kernel linux-6.6.36 source, SRCREV pinned to
  ccb3ccf128b7d423b98a0b07b0cb2b409b44dea6, same `vmlinux` deploy name.
- REVISED `recipes-cube/packagegroups/packagegroup-cubesandbox.bb` — kernel selection +
  static-agent notes.
- `recipes-cube/images/image-cubesandbox.bb` (unchanged this round).
Stubs contain `# TODO(verify)` markers wherever a claim could not be grounded offline
(donor oe-core release for rust 1.89 / go 1.25.7, 7.2 kernel repo/tag, crate/module
vendoring artifacts, protoc plugin recipes).
