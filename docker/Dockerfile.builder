# syntax=docker/dockerfile:1.7

FROM ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
# Base URL of a China-reachable Ubuntu apt mirror (set via `make builder-image
# MIRROR=cn`). When set, amd64 packages resolve under ${APT_MIRROR_BASE}/ubuntu and
# arm64 under ${APT_MIRROR_BASE}/ubuntu-ports; empty leaves the image default
# (archive.ubuntu.com on amd64, ports.ubuntu.com on arm64). The rewrite is also
# skipped when GITHUB_ACTIONS=true so CI always builds against upstream.
ARG APT_MIRROR_BASE=
ARG GO_VERSION=1.25.7
ARG PROTOC_VERSION=28.3
ARG LIBSECCOMP_VERSION=2.5.5
ARG LIBCAP_NG_VERSION=0.8.4
ARG LIBCAP_NG_SHA256=68581d3b38e7553cb6f6ddf7813b1fc99e52856f21421f7b477ce5abd2605a8a
ARG RISCV64_MUSL_CROSS_URL=https://musl.cc/riscv64-linux-musl-cross.tgz
ARG RISCV64_MUSL_CROSS_SHA256=db0bc413bd4a93f2012cc74b9ba0c4af29d8bc18b88e9c61998738ccb918604b
ARG RUST_TOOLCHAIN_DEFAULT=1.89
ARG RUST_TOOLCHAIN_HYPERVISOR=1.77.2
ARG RUST_TOOLCHAIN_E2BAPI=1.85
ARG RUST_TOOLCHAIN_AGENT=1.89
ARG GITHUB_ACTIONS=false
# Base URLs for Rustup. Defaults to upstream official https://static.rust-lang.org.
# Set via `make builder-image MIRROR=cn` to use China-reachable mirror https://rsproxy.cn.
ARG RUSTUP_DIST_SERVER=https://static.rust-lang.org
ARG RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup
# Base URL of a China-reachable LLVM apt mirror (e.g. set via `make builder-image
# MIRROR=cn`). When set, the clang-14 apt packages are sourced from this mirror;
# empty uses upstream apt.llvm.org. The GPG signing key is copied from
# docker/llvm-snapshot.gpg.key so the build does not fetch it from apt.llvm.org.
ARG LLVM_MIRROR_BASE=
ARG TARGETARCH
ARG ENABLE_RISCV64_CROSS=0
ARG BUILD_S3LVOL_DEPS=auto

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    GOPATH=/go \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/cargo/bin:${PATH} \
    CARGO_NET_GIT_FETCH_WITH_CLI=true \
    OPENSSL_INCLUDE_DIR=/usr/include \
    X86_64_UNKNOWN_LINUX_GNU_OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu \
    X86_64_UNKNOWN_LINUX_MUSL_OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu \
    AARCH64_UNKNOWN_LINUX_GNU_OPENSSL_LIB_DIR=/usr/lib/aarch64-linux-gnu \
    AARCH64_UNKNOWN_LINUX_MUSL_OPENSSL_LIB_DIR=/usr/lib/aarch64-linux-gnu \
    LIBSECCOMP_LINK_TYPE=static \
    LIBSECCOMP_LIB_PATH=/usr/local/lib64/libseccomp/lib

RUN set -eux; \
    host_arch="$(dpkg --print-architecture)"; \
    TARGETARCH="${TARGETARCH:-${host_arch}}"; \
    case "${TARGETARCH}" in \
      amd64) PROTOC_ARCH=x86_64; RUST_ARCH=x86_64;; \
      arm64) PROTOC_ARCH=aarch_64; RUST_ARCH=aarch64;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1;; \
    esac; \
    { \
      echo "TARGETARCH=${TARGETARCH}"; \
      echo "HOSTARCH=${host_arch}"; \
      echo "TARGET_UNAME_ARCH=$(uname -m)"; \
      echo "RUST_ARCH=${RUST_ARCH}"; \
      echo "PROTOC_ARCH=${PROTOC_ARCH}"; \
    } > /etc/buildenv

RUN apt-get update -o Acquire::Retries=3 \
    && apt install -y ca-certificates --no-install-recommends

RUN set -eux; \
    if [ "${GITHUB_ACTIONS}" != "true" ] && [ -n "${APT_MIRROR_BASE}" ]; then \
        case "${APT_MIRROR_BASE}" in \
            http://*|https://*) ;; \
            *) echo "APT_MIRROR_BASE must be an http(s) URL: ${APT_MIRROR_BASE}" >&2; exit 1;; \
        esac; \
        case "${APT_MIRROR_BASE}" in \
            *[\$\`\"\;\!\&\|\\]*) echo "APT_MIRROR_BASE contains characters unsafe for sed: ${APT_MIRROR_BASE}" >&2; exit 1;; \
        esac; \
        sed -i "s|http://archive.ubuntu.com/ubuntu|${APT_MIRROR_BASE}/ubuntu|g; \
                s|http://security.ubuntu.com/ubuntu|${APT_MIRROR_BASE}/ubuntu|g; \
                s|http://ports.ubuntu.com/ubuntu-ports|${APT_MIRROR_BASE}/ubuntu-ports|g" \
            /etc/apt/sources.list; \
    fi

RUN . /etc/buildenv \
    && apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        bc \
        binutils-dev \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        cpio \
        curl \
        dmsetup \
        dnsmasq \
        dosfstools \
        file \
        flex \
        bison \
        gperf \
        git \
        git-lfs \
        jq \
        libaio-dev \
        libcap-dev \
        libcap-ng-dev \
        libcap-ng0 \
        libcmocka-dev \
        libcunit1-dev \
        libdevmapper-dev \
        libelf-dev \
        libbpf-dev \
        libfuse3-dev \
        libglib2.0-dev \
        libiscsi-dev \
        libjson-c-dev \
        libkeyutils-dev \
        libncurses5-dev \
        libncursesw5-dev \
        libnuma-dev \
        libpixman-1-dev \
        libseccomp-dev \
        libssl-dev \
        libtool \
        llvm \
        make \
        meson \
        mtools \
        musl-tools \
        docker.io \
        nasm \
        ninja-build \
        ntfs-3g \
        patchelf \
        pkg-config \
        procps \
        python-is-python3 \
        python3 \
        python3-dev \
        python3-distutils \
        python3-pip \
        python3-pyelftools \
        python3-setuptools \
        python3-venv \
        python3.9 \
        python3.9-distutils \
        python3.9-venv \
        qemu-utils \
        socat \
        sudo \
        unzip \
        uuid-dev \
        wget \
        xz-utils \
        zip \
        zlib1g-dev \
        autoconf \
        automake \
        help2man \
        gnupg \
        lsb-release \
        software-properties-common \
    && case "${TARGETARCH}" in \
       amd64) apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu libc6-dev-riscv64-cross ;; \
       arm64) apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu gcc-riscv64-linux-gnu libc6-dev-riscv64-cross ;; \
       *) exit 1 ;; \
    esac \
    && rm -rf /var/lib/apt/lists/*

# Python build-deps for CubeS3lvol's SPDK/DPDK.
# The pinned SPDK needs python >= 3.9 (genrpc.py uses
# argparse.BooleanOptionalAction) and DPDK needs meson >= 0.57.2, neither of
# which ubuntu 20.04's stock python3.8 / apt meson (0.53.2) provides. Install
# python3.9 and keep its toolchain in a venv that setup_dep.sh puts on its own
# PATH, so the shared builder's /usr/bin/python3 and apt meson stay untouched
# for the Go/Rust/kernel tracks.
RUN /usr/bin/python3.9 -m venv /opt/s3lvol-tools \
    && /opt/s3lvol-tools/bin/pip install --no-cache-dir \
        meson==1.10.0 \
        ninja==1.11.1 \
        jinja2==3.1.4 \
        tabulate==0.9.0 \
        pyelftools==0.31

# Install clang-14. With LLVM_MIRROR_BASE set, configure apt repo using the mirror base URL;
# otherwise default to https://apt.llvm.org. The GPG key is vendored in
# docker/llvm-snapshot.gpg.key. Fingerprint: 6084 F3CF 814B 57C1 CF12 EFD5 15CF 4D18 AF4F 7421
COPY docker/llvm-snapshot.gpg.key /etc/apt/trusted.gpg.d/apt.llvm.org.asc
RUN set -eux; \
    . /etc/os-release; \
    distro="${VERSION_CODENAME}"; \
    if [ -n "${LLVM_MIRROR_BASE}" ]; then \
        base_url="${LLVM_MIRROR_BASE}"; \
    else \
        base_url="https://apt.llvm.org"; \
    fi; \
    base_url="${base_url%/}"; \
    echo "deb ${base_url}/${distro}/ llvm-toolchain-${distro}-14 main" > /etc/apt/sources.list.d/llvm-14.list; \
    apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends clang-14 llvm-14 lld-14 lldb-14 \
    && rm -rf /var/lib/apt/lists/* && clang-14 --version && llvm-strip-14 --version \
    && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-14 200 \
    && update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-14 200 \
    && clang --version \
    && if [ -x /usr/bin/llvm-strip-14 ] && [ ! -e /usr/local/bin/llvm-strip ]; then ln -s /usr/bin/llvm-strip-14 /usr/local/bin/llvm-strip; fi \
    && if [ ! -e /usr/bin/musl-g++ ]; then ln -s /usr/bin/g++ /usr/bin/musl-g++; fi

RUN . /etc/buildenv \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tgz \
    && rm -rf /usr/local/go \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz

RUN . /etc/buildenv \
    && wget -q "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${PROTOC_ARCH}.zip" -O /tmp/protoc.zip \
    && unzip -q /tmp/protoc.zip -d /tmp/protoc \
    && install -m 0755 /tmp/protoc/bin/protoc /usr/local/bin/protoc \
    && cp -r /tmp/protoc/include/* /usr/local/include/ \
    && rm -rf /tmp/protoc /tmp/protoc.zip

# Local build fix (CN network): proxy.golang.org and crates.io are unreachable
# from this host. Route Go modules via goproxy.cn and cargo crates via rsproxy.cn.
# Declared as ENV so it applies to BOTH the image build and later `builder-run`
# steps (docker run inherits image ENV; the Makefile does not override these).
ENV GOPROXY=https://goproxy.cn,direct \
    GOSUMDB=sum.golang.google.cn \
    CARGO_SOURCE_CRATES_IO_REPLACE_WITH=rsproxy-sparse \
    CARGO_SOURCE_RSPROXY_SPARSE_REGISTRY=sparse+https://rsproxy.cn/index/

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.11 \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.1 \
    && go install github.com/pseudomuto/protoc-gen-doc/cmd/protoc-gen-doc@v1.5.1

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain none

ENV RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER}"
ENV RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT}"

RUN set -eux; \
    . /etc/buildenv \
    && for toolchain in "${RUST_TOOLCHAIN_HYPERVISOR}" "${RUST_TOOLCHAIN_E2BAPI}" "${RUST_TOOLCHAIN_AGENT}"; do \
        rustup toolchain install "${toolchain}" --profile minimal; \
        rustup component add rust-src clippy rustfmt rust-analyzer llvm-tools-preview --toolchain "${toolchain}"; \
        rustup target add ${RUST_ARCH}-unknown-linux-gnu --toolchain "${toolchain}"; \
        rustup target add ${RUST_ARCH}-unknown-linux-musl --toolchain "${toolchain}"; \
    done; \
    if [ "${ENABLE_RISCV64_CROSS}" = 1 ] && [ "${RUST_ARCH}" != riscv64gc ]; then \
        for toolchain in "${RUST_TOOLCHAIN_E2BAPI}" "${RUST_TOOLCHAIN_AGENT}"; do \
            rustup target add riscv64gc-unknown-linux-gnu --toolchain "${toolchain}"; \
            rustup target add riscv64gc-unknown-linux-musl --toolchain "${toolchain}"; \
        done; \
    fi; \
    rustup default "${RUST_TOOLCHAIN_DEFAULT}"

RUN set -eux; \
    if [ "${ENABLE_RISCV64_CROSS}" = 1 ]; then \
        curl -fsSL --retry 5 --retry-delay 10 --connect-timeout 30 \
            "${RISCV64_MUSL_CROSS_URL}" -o /tmp/riscv64-linux-musl-cross.tgz; \
        echo "${RISCV64_MUSL_CROSS_SHA256}  /tmp/riscv64-linux-musl-cross.tgz" | sha256sum -c -; \
        mkdir -p /opt/riscv64-linux-musl-cross; \
        tar -xzf /tmp/riscv64-linux-musl-cross.tgz -C /opt/riscv64-linux-musl-cross --strip-components=1; \
        rm -f /tmp/riscv64-linux-musl-cross.tgz; \
        ln -s /opt/riscv64-linux-musl-cross/bin/riscv64-linux-musl-gcc /usr/local/bin/riscv64-linux-musl-gcc; \
        ln -s /opt/riscv64-linux-musl-cross/bin/riscv64-linux-musl-g++ /usr/local/bin/riscv64-linux-musl-g++; \
    fi

RUN mkdir -p "${CARGO_HOME}" /root/.cargo \
    && printf '[registries.crates-io]\nprotocol = "sparse"\n\n[net]\ngit-fetch-with-cli = true\n' > "${CARGO_HOME}/config.toml" \
    && ln -sf "${CARGO_HOME}/config.toml" /root/.cargo/config.toml \
    && ln -sf "${CARGO_HOME}/env" /root/.cargo/env

RUN . /etc/buildenv \
    && tmp_dir="$(mktemp -d)" \
    && wget -q "https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" -O "${tmp_dir}/libseccomp.tgz" \
    && tar -xzf "${tmp_dir}/libseccomp.tgz" -C "${tmp_dir}" --strip-components=1 \
    && cd "${tmp_dir}" \
    && CC=musl-gcc ./configure --host=${TARGET_UNAME_ARCH}-linux-musl CPPFLAGS="-I/usr/include/${TARGET_UNAME_ARCH}-linux-musl -idirafter /usr/include -idirafter /usr/include/${TARGET_UNAME_ARCH}-linux-gnu" CFLAGS="-O2 -I/usr/include/${TARGET_UNAME_ARCH}-linux-musl -idirafter /usr/include -idirafter /usr/include/${TARGET_UNAME_ARCH}-linux-gnu" --disable-shared --enable-static --prefix=/usr/local/lib64/libseccomp \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf "${tmp_dir}"

RUN set -eux; \
    if [ "${ENABLE_RISCV64_CROSS}" = 1 ]; then \
        tmp_dir="$(mktemp -d)"; \
        wget -q "https://github.com/seccomp/libseccomp/releases/download/v${LIBSECCOMP_VERSION}/libseccomp-${LIBSECCOMP_VERSION}.tar.gz" -O "${tmp_dir}/libseccomp.tgz"; \
        tar -xzf "${tmp_dir}/libseccomp.tgz" -C "${tmp_dir}" --strip-components=1; \
        cd "${tmp_dir}"; \
        CC=riscv64-linux-musl-gcc ./configure --host=riscv64-linux-musl --disable-shared --enable-static --prefix=/usr/local/riscv64-linux-musl/libseccomp; \
        make -j"$(nproc)"; \
        make install; \
        rm -rf "${tmp_dir}"; \
        tmp_dir="$(mktemp -d)"; \
        curl -fsSL "https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-${LIBCAP_NG_VERSION}.tar.gz" -o "${tmp_dir}/libcap-ng.tgz"; \
        echo "${LIBCAP_NG_SHA256}  ${tmp_dir}/libcap-ng.tgz" | sha256sum -c -; \
        tar -xzf "${tmp_dir}/libcap-ng.tgz" -C "${tmp_dir}" --strip-components=1; \
        cd "${tmp_dir}"; \
        CC=riscv64-linux-musl-gcc ./configure --host=riscv64-linux-musl --disable-shared --enable-static --prefix=/usr/local/riscv64-linux-musl/libcap-ng; \
        make -j"$(nproc)"; \
        make install; \
        rm -rf "${tmp_dir}"; \
    fi

RUN . /etc/buildenv \
    && openssl_dir=/usr/include/${TARGET_UNAME_ARCH}-linux-gnu/openssl \
    && if [ -n "${openssl_dir}" ] && [ -f "${openssl_dir}/opensslconf.h" ] && [ ! -f /usr/include/openssl/opensslconf.h ]; then \
        cp "${openssl_dir}/opensslconf.h" /usr/include/openssl/opensslconf.h; \
    fi

# ISA-L SVE sources on aarch64 need arm_sve.h, which Ubuntu 20.04's gcc-9
# does not ship. gcc-10 does. Keep this off the earlier apt layer so LLVM
# and rustup stay cacheable when only this changes.
RUN . /etc/buildenv \
    && if [ "$(uname -m)" = aarch64 ]; then \
        apt-get update -o Acquire::Retries=3 \
        && apt-get install -y --no-install-recommends gcc-10 g++-10 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# CubeS3lvol prebuilt SPDK + AWS CRT (stamp-driven; trimmed after compile).
COPY CubeS3lvol/setup_dep.sh /tmp/s3lvol-dep/setup_dep.sh
COPY CubeS3lvol/patches /tmp/s3lvol-dep/patches
RUN chmod +x /tmp/s3lvol-dep/setup_dep.sh \
    && . /etc/buildenv \
    && if [ "${BUILD_S3LVOL_DEPS}" = 1 ] || { [ "${BUILD_S3LVOL_DEPS}" = auto ] && [ "${TARGETARCH}" != riscv64 ]; }; then \
         /tmp/s3lvol-dep/setup_dep.sh --jobs "$(nproc)" --emit-builder-prebuilt; \
       else \
         printf 'Skipping CubeS3lvol prebuild for %s (BUILD_S3LVOL_DEPS=%s)\n' "${TARGETARCH}" "${BUILD_S3LVOL_DEPS}"; \
       fi \
    && rm -rf /tmp/s3lvol-dep

ARG S3LVOL_SPDK_STAMP=unknown
ARG S3LVOL_AWS_STAMP=unknown
LABEL org.cubesandbox.s3lvol.spdk-stamp="${S3LVOL_SPDK_STAMP}" \
      org.cubesandbox.s3lvol.aws-stamp="${S3LVOL_AWS_STAMP}"

WORKDIR /workspace

CMD ["/bin/bash"]
