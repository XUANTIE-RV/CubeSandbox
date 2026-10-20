# image-cubesandbox: XuanTie base image + CubeSandbox compute-node stack.
# The add-yocto-package skill mandates image inclusion via image recipes (not
# local.conf IMAGE_INSTALL:append), and this task forbids editing meta-xuantie
# recipes — hence a dedicated image in meta-cubesandbox.

SUMMARY = "XuanTie image with CubeSandbox runtime"
LICENSE = "Apache-2.0"

inherit core-image

# TODO(verify): base the image on the xuantie one. Preferred shape:
#   require recipes-core/images/xuantie-image-lite.bb   (if require across
#   layers resolves via BBPATH — meta-xuantie is on BBPATH, so it should)
# Fallback: replicate a minimal core-image and add the xuantie package set.

IMAGE_INSTALL += "packagegroup-cubesandbox"

# Guest-side artifacts are deploy-dir outputs (Image -> vmlinux) plus ext4
# payload images; they are NOT installed into this rootfs. The shim consumes
# them from /usr/local/services/cubetoolbox/ at runtime (config-cube.toml).
# TODO(verify): add cube-guest-assets + linux-cube-guest to a companion
# "assets" deployment (do_image hook or manual copy from tmp/deploy).

IMAGE_ROOTFS_SIZE ?= "8192"
COMPATIBLE_HOST = "(riscv64).*-linux"
