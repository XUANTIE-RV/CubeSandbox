# go_1.25.7.bb — SKELETON: backported go recipe set for meta-cubesandbox.
#
# PURPOSE
#   CubeSandbox go.mod files declare `go 1.25.7` (Cubelet/go.mod L3,
#   CubeMaster, CubeOps, CubeTemplateCenter, cube-lifecycle-manager;
#   CubeNet/cubevs/go.mod L3 declares 1.24.8) and the builder image installs
#   go 1.25.7 (docker/Dockerfile.builder L12). The go toolchain refuses to
#   build a module whose `go` directive is newer than itself, so oe-core
#   langdale's go 1.22.8 (openembedded-core/meta/recipes-devtools/go/
#   go_1.22.8.bb + go-1.22.8.inc) cannot build ANY of them. Recipes keep
#   `inherit go`/`go-mod` and use OE's standard go-cross machinery — proven
#   to work in this tree under TCMODE="external": go-cross-riscv64 and
#   go-binary-native built in xuantie-build/ngf/tmp-glibc/work/x86_64-linux/,
#   containerd-opencontainers + docker-ce built under work/riscv64-oe-linux/.
#
# WHAT MUST BE BACKPORTED (copy as a coherent set from a donor oe-core that
# ships go 1.25.7; TODO(verify) which release — go 1.25.x lives in current
# oe-core master/whinlatter-era):
#   go_1.25.7.bb  go-1.25.7.inc  go-common.inc  go-target.inc  go-cross.inc
#   go-cross_1.25.7.bb  go-runtime_1.25.7.bb  go-runtime.inc
#   go-binary-native_1.25.7.bb        <- bootstrap from the official
#       go1.25.7.linux-amd64.tar.gz (langdale's go-binary-native_1.22.8.bb
#       L11-15 shows the shape: SRC_URI =
#       https://dl.google.com/go/go${PV}.${BUILD_GOOS}-${BUILD_GOARCH}.tar.gz
#       + sha256 per host arch).
#   NOTE bootstrap chain: go1.25 requires a bootstrap toolchain >= go1.22.6
#   (GOROOT_BOOTSTRAP, go-common.inc L35) — the tree already has
#   go-binary-native 1.22.8, which satisfies this if the donor recipe is
#   adjusted to bootstrap from it; otherwise ship go-binary-native_1.25.7.bb.
#   TODO(verify) donor recipe's bootstrap expectation.
#   Also backport classes-recipe/{go,go-mod,goarch}.bbclass ONLY if the donor
#   recipes need newer class features (langdale's goarch.bbclass already
#   maps riscv64, L91-92). BBPATH-order caveat: same as rust — oe-core's
#   classes win over ours; prefer donor recipes that work with langdale
#   classes, or overlay via a mixin dir ahead of oe-core on BBPATH.
#
# SELECTION
#   conf/distro/include/cubesandbox-toolchain-versions.inc pins
#   PREFERRED_VERSION_{go,go-native,go-binary-native,go-cross-riscv64,
#   go-runtime} = 1.25.7. go.bbclass L38-42 shows the provider chain that
#   must move together: DEPENDS_GOLANG:class-target =
#   "virtual/${TUNE_PKGARCH}-go virtual/${TARGET_PREFIX}go-runtime".
#
# GLOBAL-BUMP SIDE EFFECTS
#   meta-virtualization's containerd-opencontainers v1.6.8, docker-ce and
#   the go-* helper recipes rebuild against go 1.25.7. Go is strongly
#   backward-compatible (go1.x promise); the realistic risks are (a) old
#   recipes using removed flags (e.g. -i), (b) GO_DYNLINK/CGO edge cases on
#   riscv64. TODO(verify) by rebuilding containerd once. Fallback if the
#   global flip is unacceptable: keep go 1.22.8 for the distro and build
#   cube Go components with GOFLAGS=-mod=mod under a *separate PN* — not
#   possible with plain `inherit go`, hence the directive's choice: bump.

SUMMARY = "Go 1.25.7 backport placeholder (see file header for the donor-copy instructions)"
LICENSE = "CLOSED"
PN = "go"
PV = "1.25.7"
# Safety: never let this stub outrank oe-core's working go_1.22.8.bb before
# the donor copy lands (see rust_1.89.0.bb for the same pattern).
DEFAULT_PREFERENCE = "-2"
# TODO(verify): replace this whole file with the donor go_1.25.7.bb copy and
# add the sibling .inc/.bb files listed above.
