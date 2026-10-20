# cubelet: node daemon (Go, CGO_ENABLED=1). Most complex Go component.
# Upstream build sequence (Makefile cubelet-riscv64, MK L457-459):
#   1. cubecow staticlib (rust 1.89) -> Cubelet/third_party/cubecow/{lib/libcubecow.a,include/cubecow.h}
#   2. cd CubeNet/cubevs && BPF_TARGET_ARCH=riscv64 make gen   (bpf2go, clang -target bpf;
#      headers from CubeNet/vmlinux/riscv64/vmlinux.h — vendored in repo)
#   3. cd Cubelet && make proto                                 (protoc + protoc-gen-go)
#   4. CC=riscv64-linux-musl-gcc CGO_ENABLED=1 GOOS=linux GOARCH=riscv64 make build
#   -> build/cubelet, build/cubecli
#
# OE-NATIVE BUILD (current directive): `inherit go` + goarch, following the
# tree's own meta-virtualization containerd-opencontainers_git.bb precedent
# (inherit go/goarch L30-31, custom do_compile, CGO_ENABLED=1, CGO_*FLAGS with
# --sysroot L50-51). go-cross-riscv64 / go-runtime providers come from the
# backported go 1.25.7 family (Cubelet/go.mod L3 `go 1.25.7`), selected via
# cubesandbox-toolchain-versions.inc. GOOS/GOARCH/CC/CGO env is set by
# go.bbclass + goarch (TARGET_GOARCH=riscv64, goarch.bbclass L91-92) — we do
# NOT hand-set GOOS/GOARCH/CC.
#
# MODULE mode (unlike containerd's GOPATH mode): CubeSandbox go.mod uses
# `replace` into ../pkgs/* and ../CubeNet, so the WHOLE repo must be present.
# common.inc fetches it to ${S}=${WORKDIR}/git (destsuffix=git keeps
# go_do_unpack from relocating it under src/${GO_IMPORT}, go.bbclass L92-94).
# We build each module in place from ${S}/<component>.

require recipes-cube/cube-sandbox-common.inc

SUMMARY = "CubeSandbox node agent/daemon (Go, CGO, eBPF dataplane via cubevs)"
HOMEPAGE = "https://github.com/TencentCloud/CubeSandbox"

inherit go
inherit goarch

# S is ${WORKDIR}/git (common.inc) = the whole mono-repo root, so ../pkgs and
# ../CubeNet replace targets resolve. GO_IMPORT is only used by go.bbclass's
# default do_install, which we override below; set it for cleanliness.
GO_IMPORT = "github.com/tencentcloud/CubeSandbox"

# cubecow provides libcubecow.a (Rust staticlib) staged into the target sysroot;
# clang-native drives bpf2go (`clang -target bpf`) during `make gen` —
# meta-clang is already in the xuantie bblayers.conf; protobuf-native provides
# protoc for `make proto`.
#   NOTE protoc version: Dockerfile.builder L13/L219 pins protoc v28.3 and
#   installs protoc-gen-go@v1.36.11 / protoc-gen-go-grpc@v1.6.1 (L234-236).
#   oe-core langdale protobuf is 3.21.x — TODO(verify) generated-code
#   compatibility; if it diverges, add a protobuf-28.3 recipe.
DEPENDS += "cubecow clang-native protobuf-native"
# TODO(verify): protoc-gen-go / protoc-gen-go-grpc are Go plugins `go install`ed
# in the builder (DFB L234-236); provide them as DEPENDS (go-native recipes) so
# `make proto` finds them on PATH.

export CGO_ENABLED = "1"
export BPF_TARGET_ARCH = "riscv64"
# CGO must see the target sysroot (containerd precedent, containerd-opencontainers_git.bb L50-51):
export CGO_CFLAGS = "${CFLAGS} --sysroot=${STAGING_DIR_TARGET}"
export CGO_LDFLAGS = "${LDFLAGS} --sysroot=${STAGING_DIR_TARGET}"
# Module-mode offline policy (see go.mod fetch TODO below).
export GOFLAGS = "-mod=mod"
export GOPROXY = "off"

do_configure() {
	# Stage cubecow staticlib into the path Cubelet's cgo flags expect
	# (Makefile cubelet-riscv64 installs it under Cubelet/third_party/cubecow).
	install -d ${S}/Cubelet/third_party/cubecow/lib ${S}/Cubelet/third_party/cubecow/include
	install -m 0644 ${STAGING_DIR_TARGET}${libdir}/libcubecow.a ${S}/Cubelet/third_party/cubecow/lib/
	install -m 0644 ${STAGING_DIR_TARGET}${includedir}/cubecow.h  ${S}/Cubelet/third_party/cubecow/include/
}

do_compile() {
	export GOPATH="${WORKDIR}/go"
	export GOCACHE="${B}/.cache"
	export GOMODCACHE="${GOPATH}/pkg/mod"
	export PATH="${STAGING_BINDIR_NATIVE}:${STAGING_DIR_NATIVE}${bindir_native}:${PATH}"

	# 1. Generate eBPF Go bindings + objects (bpf2go, clang -target bpf).
	#    Uses vendored CubeNet/vmlinux/riscv64/vmlinux.h; regeneration via
	#    bpftool is a Phase-5 option (DESIGN.md §6).
	cd ${S}/CubeNet/cubevs && oe_runmake gen

	# 2. protobuf codegen (Cubelet/Makefile `proto`).
	cd ${S}/Cubelet && oe_runmake proto

	# 3. Build cubelet + cubecli (Cubelet/Makefile `build`). go.bbclass's
	#    GOBUILDFLAGS/GOOS/GOARCH/CC are already exported; `make build`
	#    invokes `go build` under them.
	cd ${S}/Cubelet && oe_runmake build
	# TODO(verify): Cubelet/Makefile may set its own CC/CGO flags that clash
	#    with OE's; may need `make build CC="${CC}" CGO_ENABLED=1` explicitly
	#    or GOFLAGS tuning. Verify `make gen`/`make proto` honour PATH plugins.
}

do_install() {
	install -d ${D}${bindir}
	install -m 0755 ${S}/Cubelet/build/cubelet ${D}${bindir}/
	install -m 0755 ${S}/Cubelet/build/cubecli ${D}${bindir}/
}

# Go module fetch strategy: NO vendor/ dir exists in any component (verified),
# and langdale's go-mod.bbclass has no do_vendor task. GOPROXY=off makes the
# build fail-closed on any un-fetched module. Offline-clean options:
#   (a) pre-generate `go mod vendor` per module and add the vendor trees to
#       SRC_URI (or commit them), then GOFLAGS="-mod=vendor"; OR
#   (b) ship a populated GOMODCACHE. This is the Go analogue of the crate
#   vendoring problem (DESIGN.md §4.4).
# TODO(verify): pick (a) vs (b) at implementation; adjust GOFLAGS accordingly.

RDEPENDS:${PN} += "containerd-shim-cube"
COMPATIBLE_HOST = "(riscv64).*-linux"
