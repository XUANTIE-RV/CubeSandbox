# CubeSandbox riscv64 — Validation Runbook (pure commands)

Reproducible command sequence for validating the CubeSandbox riscv64 port on an
xt-qemu nested-KVM testbed. Commands only — the full captured logs live in
`CUBE-E2E-COMPLETE-LOG.txt` on the testbed share; this file is the procedure.

Arc covered: **L1 launch → L2 cold boot → unit tests (pure-logic + eBPF) →
app-snapshot → snapshot/restore**.

Conventions:
- `[host]` = run on the xt-qemu host. `[L1]` = run inside the L1 guest (riscv64).
- Every L2 boot writes the guest console to the hardcoded shim path
  `/mnt/share/l2-console.log`. **Only one L2 VM may boot at a time** (see
  "Concurrency" below).
- Validation bar: unit tests count as passed only when executed inside the L2
  guest kernel brought up by CubeHypervisor (not on the host / not cross-run).

---

## 验证流程总览 — 每步做了什么 + 测试目的

| 步骤 | 做了什么（action） | 测试目的（purpose） |
|------|--------------------|---------------------|
| **1 构建产物** | 在 `cube-sandbox-builder:riscv64-cross` 里交叉编译 shim/cube-runtime（cargo musl 静态）、`cubevs.test`（go riscv64）、eBPF wrapper，并用 `mkfs.ext4 -d` 免挂载造出 3 个 L2 guest 镜像 | 产出 riscv64 静态二进制 + 测试镜像，作为后续在 L2 上验证的输入；确认整条 CubeSandbox 代码栈能交叉编译到 riscv64 |
| **2 启动 L1** | 用 xt-qemu 启一个带 H 扩展 + AIA 的 riscv64 guest（内含 KVM `/dev/kvm`），登录并挂载 9p share + toolbox | 建立 nested 虚拟化的**宿主层**：L1 提供 KVM，CubeHypervisor 才能在 L1 里再跑 L2 microVM |
| **3 L2 冷启动** | 起一个**独立 containerd 实例** + 导入**空占位镜像** + stage shim/内核/guest 镜像 → `ctr run --runtime io.containerd.cube.rs` 拉起 L2 | 验证 CubeHypervisor 能在 L1 的 KVM 上**冷启动一个 riscv64 L2 guest**：内核引导、virtio-pmem 挂根、cube-agent 起来、vsock 就绪——即 shim↔VMM↔guest 全链路打通 |
| **4 纯逻辑 UT** | 换 test 镜像（`/sbin/init=l2testrun`），boot 时在 L2 guest 内核上跑 cubelog / blobstore-fs / lifecycle-config 三套 | 在**真实 riscv64 guest 内核**里验证 CubeSandbox 的 Go 业务逻辑（日志 / 对象存储 / 生命周期配置）交叉编译后行为正确；满足「UT 必须在 L2 guest 内核上跑」的验收线 |
| **4e eBPF UT** | 换 eBPF test 镜像，boot 时跑 cubevs 的 19 个 eBPF 用例（wrapper 过滤），走 `BPF_PROG_TEST_RUN` 真加载真执行 | 验证 CubeNet 虚拟交换机的 **eBPF 数据面**（DNS 学习 / 出向策略 / TCP 状态 / L7 打标）的 riscv64 eBPF 字节码能被 guest 内核**验证器接受、JIT、加载并正确执行**——即 riscv64 eBPF 全栈可用 |
| **5 快照** | 对活 L2 执行 `cube-runtime snapshot --app-snapshot`（pause→snapshot→resume），落 ~513M 快照 | 验证 riscv64 上能**暂停一个运行中的 microVM**，把完整状态（内存 + vCPU 寄存器 + 设备 + vAIA）序列化到磁盘，再 resume（源 VM 快照后仍存活） |
| **6 恢复** | 销毁源 VM → 用带 restore 注解的 spec 起 cubetest2，从快照恢复续跑 | 验证能把快照恢复成一个**新的 microVM 并续跑**（内存 mmap、vCPU `set_state`、设备/vAIA 恢复、resume），且是「续跑」而非「重启」——快照热恢复/快速冷启能力的核心 |
| **7 并发/清理** | sentinel 串行化单 L1 上的 L2 boot；结束后拆 VM、停 containerd、关 L1 | 保证多 worker 共用一个 L1 时不撞硬编码的 console 日志路径；留下干净可复现的环境 |

**为什么是 nested（L1 里跑 L2）**：CubeSandbox 生产环境是宿主 KVM 上跑 microVM。这里没有 riscv64 裸金属，用一个开了 H 扩展 + AIA 的 xt-qemu guest 当 L1（它自带 KVM），CubeHypervisor 在 L1 里通过 L1 的 `/dev/kvm` 拉起 L2，从而在纯软件模拟环境下等价复现「宿主 KVM → microVM」的真实链路。

---

## 0. Topology & path variables

```
[host] L1 = xt-qemu TCG guest: -M virt,aia=aplic-imsic,aia-guests=4 -cpu xt-c9501fdvkt -smp 4 -m 6G
       L1 kernel has KVM (/dev/kvm) + full BPF (CONFIG_BPF/BPF_SYSCALL/BPF_JIT/HAVE_EBPF_JIT=y)
       L2 = CubeHypervisor (CH v28 fork) microVM run by the containerd shim inside L1 via L1's KVM
       L1 and L2 boot the SAME kernel image (cube-l2-assets/vmlinux)
```

```bash
# [host] define once
export BASE=/mnt/ssd/workarea/yanan.he
export L1=$BASE/cube-l1                      # serial.sock / serial.log / cap.py live here
export SH=$L1/share                          # 9p share -> L1:/mnt/share (host-persistent)
export REPO=$BASE/cubesandbox-riscv
export QEMU=$BASE/xt-qemu/install/bin/qemu-system-riscv64
export L1ROOTFS=$BASE/xuantie-yocto/xuantie-build/ngf/tmp-glibc/deploy/images/rva23u64-k6.6xt-kcdefault-tcxt/xuantie-image-agentos-rva23u64-k6.6xt-kcdefault-tcxt.ext4
export L1PORT=22662                          # pick a FREE host port (22650 may be taken)
```

```bash
# [L1] define once (inside the guest)
export SOCK=/run/containerd-cube.sock
export TB=/usr/local/services/cubetoolbox    # = /dev/vdb (cube-toolbox.ext4)
export REST=/var/tmp/cube-restore            # snapshot base; res dir = $REST/2C512M
```

---

## 1. Prerequisites — build artifacts (host, cross-compiled)

Builder image `cube-sandbox-builder:riscv64-cross` (Go 1.25.7, cargo +1.85,
`riscv64-linux-musl-gcc`). Proxy `http://47.236.63.199:3128`.

```bash
# [host] 1a. containerd shim + cube-runtime (static riscv64 musl)
docker run --rm -u 0 -e HOME=/home/builder -e CARGO_HOME=/home/builder/.cargo -e RUSTUP_HOME=/usr/local/rustup \
  -e http_proxy=http://47.236.63.199:3128 -e https_proxy=http://47.236.63.199:3128 \
  -e no_proxy=.cn,.tencent.com,.alibaba-inc.com,.xrvm.cn,.aliyuncs.com -e GOPATH=/home/builder/go \
  -v "$REPO":/workspace -v /rvhome/yanan.he/.cache/cube-sandbox-builder:/home/builder -w /workspace \
  cube-sandbox-builder:riscv64-cross bash -lc \
  'cd /workspace/CubeShim && RUSTFLAGS=-Ctarget-feature=+crt-static \
   LIBSECCOMP_LINK_TYPE=static LIBSECCOMP_LIB_PATH=/usr/local/riscv64-linux-musl/libseccomp/lib \
   LIBCAPNG_LINK_TYPE=static LIBCAPNG_LIB_PATH=/usr/local/riscv64-linux-musl/libcap-ng/lib \
   CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_MUSL_LINKER=riscv64-linux-musl-gcc \
   cargo +1.85 build --release --locked --target riscv64gc-unknown-linux-musl && \
   install -m0755 target/riscv64gc-unknown-linux-musl/release/containerd-shim-cube-rs /workspace/_output/bin/containerd-shim-cube-rs-riscv64 && \
   install -m0755 target/riscv64gc-unknown-linux-musl/release/cube-runtime /workspace/_output/bin/cube-runtime-riscv64'

# [host] 1b. cubevs eBPF test binary (static riscv64; eBPF .o embedded via go:embed, no clang needed)
docker run --rm -u 0 -e HOME=/home/builder -e GOPATH=/home/builder/go -e GOFLAGS=-mod=mod \
  -e http_proxy=http://47.236.63.199:3128 -e https_proxy=http://47.236.63.199:3128 -e GOPROXY=https://proxy.golang.org,direct \
  -v "$REPO":/workspace -v /rvhome/yanan.he/.cache/cube-sandbox-builder:/home/builder -w /workspace/CubeNet/cubevs \
  cube-sandbox-builder:riscv64-cross bash -lc \
  'go mod download all && GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 go test -c -o /workspace/_output/testbin/cubevs.test .'
# -> _output/testbin/cubevs.test  (ELF RISC-V, static, NEEDED=0)

# [host] 1c. eBPF filter wrapper (l2testrun execs *.test with fixed argv {-test.v}; the wrapper
#            injects -test.run so only the 19 eBPF cases run when invoked as cubevs-ebpf.test)
cat > /tmp/wrapper.c <<'C'
#include <unistd.h>
int main(void){
  char *av[]={"cubevs.test","-test.run",
    "TestDNSLearn|TestTCPUpdate|TestClassifyEgressFlow|TestSessionPolicyRevoked|TestL7Mark|TestResolveL7Marks",
    "-test.v",0};
  return execv("/tests/cubevs-ebpf/cubevs.test",av);
}
C
docker run --rm -u 0 -v /tmp:/tmp -v "$REPO":/workspace -v /rvhome/yanan.he/.cache/cube-sandbox-builder:/home/builder \
  -e HOME=/home/builder cube-sandbox-builder:riscv64-cross bash -lc \
  'riscv64-linux-musl-gcc -static -no-pie -o /workspace/_output/testbin/cubevs-ebpf.test /tmp/wrapper.c'

# [host] 1d. pure-logic test binaries + guest helpers (cubelog/blobstore-fs/lifecycle-config .test,
#            l2testrun, l2hello, l2pause, shim-wrapper) — built per phase-2 recipe; expected in:
ls "$REPO"/_output/testbin/{cubelog.test,blobstore-fs.test,lifecycle-config.test}
ls "$SH"/{l2testrun,l2hello,l2pause,shim-wrapper}   # static riscv64 ELF helpers staged on the share

# [host] 1e. L2 guest images (ext4, built WITHOUT mounting via `mkfs.ext4 -d <rootdir> <img>`)
#   cube-guest-image-cpu.img  : sandbox image, /sbin/init=cube-init, /cube-root mini-rootfs
#   cube-guest-test.img       : test image, /sbin/init=l2testrun, /tests/{cubelog,blobstore-fs,lifecycle-config}
#   cube-guest-test-ebpf.img  : test image + /tests/cubevs-ebpf/{cubevs.test,cubevs-ebpf.test}
ROOT=$BASE/cube-l2-assets/pmem0root-test-ebpf        # copy of pmem0root-test + tests/cubevs-ebpf/{cubevs.test,cubevs-ebpf.test} (chmod 0755)
truncate -s 67108864 "$SH/cube-guest-test-ebpf.img"
mkfs.ext4 -F -d "$ROOT" "$SH/cube-guest-test-ebpf.img"
e2fsck -fn "$SH/cube-guest-test-ebpf.img"
debugfs -R "ls -l /tests/cubevs-ebpf" "$SH/cube-guest-test-ebpf.img"   # both binaries mode 100755
```

Required host artifacts before launching:
`$BASE/cube-l2-assets/{vmlinux,cube-toolbox.ext4}`, `$BASE/aia-snap-bed/fw_dynamic.bin`, `$L1ROOTFS`,
`$SH/{containerd-shim-cube-rs-riscv64,cube-runtime-riscv64,shim-wrapper,vmlinux,cube-guest-image-cpu.img,cube-guest-test.img,cube-guest-test-ebpf.img,cube-min.tar,cube-spec.json,cube-spec-restore.json}`.

---

## 2. Launch L1 (host)

**做了什么**：用 xt-qemu 启一个带 H 扩展 + AIA 的 riscv64 guest（`-snapshot` 使盘临时化，L1 每次从 9p share 重新 stage），等它 boot 到 login，登录后挂载 9p share 与 toolbox。
**测试目的**：建立 nested 虚拟化的宿主层——L1 内核带 KVM（`/dev/kvm`），CubeHypervisor 才能在 L1 内通过 L1 的 KVM 拉起 L2 microVM。L1 与 L2 用同一个内核镜像，故 L1 有的特性（KVM、BPF）L2 也有。

```bash
# [host] stop any prior L1 for THIS testbed only (never kill unrelated qemu)
[ -f "$L1/qemu.pid" ] && kill "$(cat "$L1/qemu.pid")" 2>/dev/null; sleep 2
rm -f "$L1"/{serial.sock,serial.log,qemu.pid,qemu-guest-errors.log}

# [host] launch (explicit; -snapshot => drives ephemeral, L1 re-stages from the 9p share each boot)
nohup "$QEMU" \
  -M virt,aia=aplic-imsic,aia-guests=4 -cpu xt-c9501fdvkt -smp 4 -m 6G \
  -bios "$BASE/aia-snap-bed/fw_dynamic.bin" -kernel "$BASE/cube-l2-assets/vmlinux" \
  -append "root=/dev/vda rw console=ttyS0 earlycon=sbi" \
  -drive file="$L1ROOTFS",format=raw,if=virtio \
  -drive file="$BASE/cube-l2-assets/cube-toolbox.ext4",format=raw,if=virtio \
  -snapshot \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${L1PORT}-:22 -device virtio-net-device,netdev=n0 \
  -virtfs local,path="$SH",mount_tag=cubeshare,security_model=none,id=cubeshare \
  -chardev socket,id=ser0,path="$L1/serial.sock",server=on,wait=off,logfile="$L1/serial.log",logappend=off \
  -serial chardev:ser0 -monitor none -display none -pidfile "$L1/qemu.pid" \
  -d guest_errors -D "$L1/qemu-guest-errors.log" >/dev/null 2>&1 &

# [host] wait for login prompt (~60-90s under TCG)
until grep -q 'login:' "$L1/serial.log" 2>/dev/null; do sleep 3; done
```

Console driver: `$L1/con.py` (one-shot) and `$L1/cap.py` (runs a `set -x` block on L1,
reads the serial socket in real time, appends "commands + output" to the log doc).
L1 login: `root` / `root`.

```bash
# [host] log in + mount the 9p share and toolbox (via cap.py; explicit commands on L1)
WAIT=40 python3 "$L1/cap.py" <<'EOF'
set -x
mkdir -p /mnt/share
mount -t 9p -o trans=virtio,version=9p2000.L cubeshare /mnt/share
mkdir -p /usr/local/services/cubetoolbox
mountpoint -q /usr/local/services/cubetoolbox || mount /dev/vdb /usr/local/services/cubetoolbox
mountpoint /mnt/share; ls /usr/local/services/cubetoolbox
set +x
EOF
```

---

## 3. PHASE 2 — L2 cold boot

**做了什么**：起一个**独立 containerd 守护进程**（不碰 L1 自带的系统 containerd），导入一个**空占位镜像**，stage 好 shim/内核/guest 镜像，然后 `ctr run` 让 cube shim 在 L1 的 KVM 上冷启动一个 L2 microVM。
**测试目的**：验证 CubeHypervisor 能引导一个 riscv64 L2 guest 到「agent 就绪、vsock 监听」——即 host shim ↔ in-process VMM ↔ guest 内核/agent 全链路打通。

两条基座命令的用意：
- `containerd --config … --address $SOCK --state … --root …`：**新建一个隔离的第二 containerd 实例**。`--address` 用非默认 socket（`/run/containerd-cube.sock`）避免与系统 containerd 冲突；`--state` 是临时运行态（shim 状态/socket/fifo，spec 注解 `io.containerd.cube.bundle` 指向它）；`--root` 是持久存储（bolt 元数据 + 镜像 blobs）。containerd 按命名约定把 runtime `io.containerd.cube.rs` 解析到 PATH 里的 `containerd-shim-cube-rs`。用独立实例 → 与 L1 自身 containerd 互不干扰，且 `rm -rf --root/--state` 即可整体重置（PHASE 5 卡死恢复就靠它）。
- `ctr … image import cube-min.tar`：`ctr` 是 containerd CLI，`--address $SOCK` 连上面那个实例，`-n default` 是命名空间，`image import` 把 OCI 镜像 tar 灌进 content store。**cube-min.tar 是个 20KB 空占位镜像**（175B JSON config + 45B 空 gzip 层，riscv64/linux:latest）。导入它只因为 `ctr run` 建容器对象**需要一个镜像引用**；真实负载不用它的文件系统——`ctr run --rootfs -c cube-spec.json` 的 rootfs 来自 spec 的 `root.path=/cube-root`（L2 guest 内的 mini-rootfs），guest 内核与真根来自 toolbox 的 pmem 镜像（`cube-guest-image-cpu.img` + `cube-agent.ext4`），由 shim 传给 CubeHypervisor。对这个嵌套链路，导入的镜像是 vestigial（形式性）的。

### `ctr` 如何挂到 `containerd-shim-cube-rs`（runtime v2 两段式握手）

关键：**ctr 从不直接连 shim**。链路是 `ctr →(gRPC)→ containerd →(exec + stdout 握手 + ttrpc)→ shim`。shim 是夹在 containerd 与工作负载之间的"垫片"进程（`shim` 非缩写，本义即机械垫片/桥接层）。源码在仓库内 vendored 的 `third_party/containerd-shim`（=0.9.0）。

1. **runtime 名 → 二进制名（containerd 侧命名约定，无需在 config.toml 注册）**
   ```
   io.containerd.cube.rs → 去 "io.containerd." 前缀 → cube.rs → 点换横线 → cube-rs → 加前缀 → containerd-shim-cube-rs
   ```
   containerd 在自己的 PATH 里找该二进制（本 runbook 放在 `/usr/local/bin/containerd-shim-cube-rs` = `shim-wrapper` 静态 ELF，`execv` 到 `shim.real`）。`ctr run --runtime io.containerd.cube.rs` 直接把名字传给 containerd 解析。

2. **`start` 调用**：containerd exec
   ```
   containerd-shim-cube-rs -namespace default -id <id> -address <containerd地址> start
   （env TTRPC_ADDRESS=<containerd 的 ttrpc 地址>，供 shim 回发事件）
   ```
   入口 `CubeShim/shim/src/main.rs:54` → `shim_run::<Service>("io.containerd.cube.rs", …)` → `asynchronous/mod.rs:107 run()`；`action=="start"`（`mod.rs:185`）→ `start_shim()` → `spawn()`。

3. **`spawn()` 自我 re-exec**（`mod.rs:305-347`）：
   ```rust
   let cmd = env::current_exe()?;                          // = /proc/self/exe
   let address = socket_address(&opts.address, &ns, id);   // 派生 ttrpc socket 路径
   Command::new(cmd).args(["-namespace",ns,"-id",id,"-address",addr,"-socket",&address]).spawn()
   ```
   `current_exe()`=`/proc/self/exe` ⇒ **shim 必须是真 ELF、不能是脚本**；wrapper `execv` 到 `shim.real` 后 `current_exe` 即 `shim.real`，re-exec 直接拉起守护子进程（这次**不带 `start`**）。

4. **`socket_address()` 派生规则**（`lib.rs:168-184`）：
   ```
   path = <address>/<namespace>/<id>            # 例: /run/containerd-cube.sock/default/cubetest1
   unix://{SOCKET_ROOT}/s/{sha256(path):x}       # 取 SHA256 十六进制，绕开 unix socket ~108B 路径上限
   ```

5. **`start` 把地址打到 stdout 后退出**（`mod.rs:195-199`）：`stdout.write_all(address)` + flush。**这就是握手**——containerd exec `shim start`，从其 **stdout 读到 ttrpc socket 地址**。

6. **守护子进程 serve ttrpc**（`mod.rs:219-254`，action 为空）：`start_listener(&flags.socket)` 在该地址监听 → `register_service(Service)`（CubeSandbox 的 Task API）→ `server.start()`。containerd 用 **ttrpc** 连上来发 `Create/Start/Exec/Kill/Delete`；`Service::create` 读 bundle 里的 OCI spec（`util.rs:96 read_spec`）→ 启动**进程内 CubeHypervisor VMM** → L2 microVM → cube-agent → rustjail 内层容器。

```
ctr --address $SOCK --runtime io.containerd.cube.rs run … cubetest1
  │ gRPC Tasks.Create/Start
  ▼  containerd: ① 名字解析→containerd-shim-cube-rs(PATH)  ② exec "… start"(env TTRPC_ADDRESS)
containerd-shim-cube-rs(shim-wrapper) ── execv ──▶ shim.real
  │ action="start": spawn() 用 current_exe 自我 re-exec(带 -socket <addr>)，把 <addr> 打到 stdout 后退出
  ▼  (containerd 从 stdout 读到 <addr>)
shim.real 守护子进程(action 空): start_listener(-socket <addr>) + 注册 Service
  ▼  containerd ──ttrpc──▶ shim.real (Create/Start/Exec/Kill/Delete)
Service::create → 读 OCI spec → CubeHypervisor(进程内 VMM) → L2 microVM → cube-agent → rustjail → app
```

> 注：shim 的"挂载点"就是那个 `unix://SOCKET_ROOT/s/<sha256(address/namespace/id)>` 的 ttrpc socket，靠 `start` 阶段的 stdout 握手交给 containerd；containerd 与 shim 之间是 ttrpc，ctr 与 containerd 之间是 gRPC。

```bash
# [L1] stage shim/runtime/kernel/image + start standalone containerd + import image
WAIT=90 python3 "$L1/cap.py" <<'EOF'
set -x
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p /usr/local/bin /run/containerd-cube-state /var/lib/containerd-cube /etc/containerd /run/empty-rootfs /data/log/CubeVmm /data/log/CubeShim
cp -f /mnt/share/vmlinux $TB/cube-kernel-scf/vmlinux
cp -f /mnt/share/cube-guest-image-cpu.img $TB/cube-image/cube-guest-image-cpu.img
rm -f /usr/local/bin/containerd-shim-cube-rs /usr/local/bin/shim.real
cp -f /mnt/share/containerd-shim-cube-rs-riscv64 /usr/local/bin/shim.real; chmod 0755 /usr/local/bin/shim.real
cp -f /mnt/share/cube-runtime-riscv64 /usr/local/bin/cube-runtime;       chmod 0755 /usr/local/bin/cube-runtime
cp -f /mnt/share/shim-wrapper /usr/local/bin/containerd-shim-cube-rs;   chmod 0755 /usr/local/bin/containerd-shim-cube-rs
containerd config default > /etc/containerd-cube.toml
pkill -f containerd-cube.sock; sleep 1
containerd --config /etc/containerd-cube.toml --address $SOCK --state /run/containerd-cube-state --root /var/lib/containerd-cube >/mnt/share/containerd-cube.log 2>&1 &
sleep 8
ctr --address $SOCK version
ctr --address $SOCK -n default image import /mnt/share/cube-min.tar
set +x
EOF

# [L1] cold boot the L2 sandbox (run -d blocks until VsockServerReady, ~20-45s under TCG)
WAIT=170 python3 "$L1/cap.py" <<'EOF'
set -x
export RUST_LOG=info RUST_BACKTRACE=full
rm -f /mnt/share/l2-console.log /mnt/share/l2-serial.log
ctr --address $SOCK -n default run -d --rootfs --runtime io.containerd.cube.rs -c /mnt/share/cube-spec.json cubetest1
set +x
EOF
# verify (separate short call — long `run -d` blocks can outrun a single capture window)
WAIT=45 python3 "$L1/cap.py" <<'EOF'
set -x
ctr --address $SOCK -n default task ls                       # expect: cubetest1 RUNNING
ls -l /run/vc/vm/cubetest1/chapi                             # chapi socket present
grep -a "vm ready" /data/log/CubeShim/cube-shim-req.log | tail -1   # "vm ready, vsock is listening, cost:<ms>"
set +x
EOF
```
Expected: `cubetest1 ... RUNNING`; shim log `vm ready, vsock is listening, cost:<ms>`.
Note: a bare `ctr task exec ... <bin>` without draining stdout can hang on the agent
read_stdout fifo (known relay limitation) — always wrap probes in `timeout N` and/or
redirect `>/dev/null 2>&1`; the hang is non-fatal (VM stays RUNNING).

### sandbox ID、L2 内核/rootfs 从哪来、两个 rootfs 的区分

**`cubetest1` / `cubetest2` 是什么**：只是 `ctr run … <ID>` 里我随手起的 **sandbox（容器）ID / 测试名**，不是特殊组件。一个 ID 对应一整套实例标识：
- containerd `default` 命名空间里的 container/task（`ctr task ls` 那行）；
- 一个 `containerd-shim-cube-rs` 进程，bundle 在 `/run/containerd-cube-state/default/<ID>`；
- 一个 CubeHypervisor L2 microVM（`vmm.log` 日志前缀 `<ID> --- …`）；
- vsock `/run/vc/vm/<ID>/cube.sock`（cid=3）+ chapi socket `/run/vc/vm/<ID>/chapi`；
- guest 内层 rustjail 容器 `/run/cube-containers/<ID>/rootfs`。

`cubetest2` 是 PHASE 5 里**从 cubetest1 快照恢复出的第二个 sandbox**（换个 ID 证明能恢复成新实例）。

**L2 内核 / guest rootfs / agent 来自 toolbox 固定常量，不是 OCI spec**（`CubeShim/shim/src/hypervisor/config.rs`）：

```
config.rs:30  IMAGE_PATH         = $TB/cube-image/cube-guest-image-cpu.img   → guest 根 (virtio-pmem0, id pmem-cube-os-image)
config.rs:32  DEFAULT_AGENT_PATH = $TB/cube-agent/cube-agent.ext4            → agent  (virtio-pmem1, id pmem-cube-agent)
              KERNEL_SCF         = $TB/cube-kernel-scf/vmlinux               → L2 内核
```
shim 在 `Service::create` 里用这些常量 + spec 的 `cube.vmmres`（只取 cpu/memory）构造 `VmConfig`：
`payload.kernel=KERNEL_SCF`、`cmdline="root=/dev/pmem0 rootflags=errors=remount-ro ro rootfstype=ext4 … console=hvc0 …"`（`config.rs:98-116`，riscv 特意去掉 `dax`）、`pmem=[IMAGE_PATH→pmem0, DEFAULT_AGENT_PATH→pmem1]`（`config.rs:517/520`）。
**所以换 guest 内核/根 = 覆盖 toolbox 里这几个文件**（本 runbook 各 PHASE 就是 `cp /mnt/share/<img> $TB/cube-image/cube-guest-image-cpu.img`），而不是改 spec。

> **坑：内核文件名叫 `vmlinux`，内容却必须是 PE `Image`。** `KERNEL_SCF` 指向的文件名是 `vmlinux`，但 CH 的 riscv64 `load_kernel` 走 `linux_loader::loader::pe::PE::load`（`vm.rs:987`，`vm.rs:73` import `InvalidImageMagicNumber`），**只认 PE/EFI-stub 的 `Image`（magic `MZ`=0x4d5a，~18MB）**。塞真正的 ELF `vmlinux`（magic `0x7f45`，~300MB）会报 `InvalidImageMagicNumber`（表现为 "RISC-V UEFI boot is not implemented"）。故 stage 时用 yocto deploy 的 `Image` 拷成 `vmlinux` 这个名字：`file` 应显示 `PE32+ executable (EFI application) RISC-V 64-bit`。

**两个 rootfs 别混淆**：
| | 来源 | 用途 |
|---|------|------|
| **L2 guest OS 根** | pmem0 镜像（`cube-guest-image-cpu.img` / test 镜像）| guest 内核的 `/` 与 `/sbin/init`（正常镜像=cube-init；test 镜像=l2testrun）|
| **内层容器根** | spec 的 `root.path`（如 `/cube-root`，在 guest 内）| rustjail 给应用容器用的 rootfs（`ctr run --rootfs` 取的就是它）|

PHASE 3/3e 跑 UT 时，`/sbin/init=l2testrun` 直接在 **guest OS 根**这层作为 PID1 跑测试、跑完 poweroff，**内层容器根本不创建**（故 `ctr run` 返回预期的 `expected:VsockServerReady, actual:VmShutdown`）。PHASE 2/4/5 的正常镜像则会 cube-init→cube-agent→VsockServerReady→再建内层容器跑应用。

---

## 4. PHASE 3 — unit tests on the L2 guest kernel

**做了什么**：把 test 镜像（`/sbin/init=l2testrun`）stage 成 guest OS 镜像并 boot；l2testrun 作为 PID1 在 L2 guest 内核上扫描 `/tests/*/` 跑每个 `*.test -test.v`，把 transcript 打到 console，跑完 poweroff。
**测试目的**：在**真实 riscv64 guest 内核**里验证 CubeSandbox 的 Go 业务逻辑（cubelog 日志 / blobstore-fs 对象存储 / lifecycle-config 生命周期配置）交叉编译到 riscv64 后行为正确。满足「UT 必须在 CubeHypervisor 拉起的 L2 guest 内核上跑才算过」的验收线——而非在 host 上 cross-run。

l2testrun is `/sbin/init` of the test image: it mounts proc+/tmp+/run, scans `/tests/*/`,
runs each `*.test -test.v`, prints transcripts to the console, then powers the VM off
(so `ctr run` returns the EXPECTED `Create sandbox failed: ... expected:VsockServerReady,
actual:VmShutdown`). Capture the console afterwards.

```bash
# [L1] teardown cold-boot VM, stage the TEST image, boot (runs all /tests/* then poweroff)
WAIT=60 python3 "$L1/cap.py" <<'EOF'
set -x
ctr --address $SOCK -n default task kill -s SIGKILL cubetest1; sleep 3
ctr --address $SOCK -n default task rm -f cubetest1
ctr --address $SOCK -n default container rm cubetest1
cp -f /mnt/share/cube-guest-test.img $TB/cube-image/cube-guest-image-cpu.img
rm -f /mnt/share/l2-console.log
set +x
EOF
WAIT=210 python3 "$L1/cap.py" <<'EOF'
set -x
export RUST_LOG=info RUST_BACKTRACE=full
ctr --address $SOCK -n default run -d --rootfs --runtime io.containerd.cube.rs -c /mnt/share/cube-spec.json cubetest1
set +x
EOF
# [host] preserve + inspect the transcript
cp -f "$SH/l2-console.log" "$SH/l2-ut-console.log"
grep -aE 'L2TESTRUN SUMMARY|--- (PASS|FAIL|SKIP)|========== RC ' "$SH/l2-ut-console.log"
```
Expected (pure-logic image): `L2TESTRUN SUMMARY total=3 failed=0`
(cubelog + blobstore-fs + lifecycle-config, all `RC ... = 0`).

### PHASE 3e — eBPF UT (CubeNet/cubevs) on the L2 guest kernel

**做了什么**：换成 `cube-guest-test-ebpf.img`（多出 `/tests/cubevs-ebpf/`），boot 时跑 cubevs 的 19 个 eBPF 用例。l2testrun 固定用 `{-test.v}` execv 每个 `*.test`，无法传 `-test.run`，故用一个静态 **wrapper**（`cubevs-ebpf.test`）execv 真 `cubevs.test` 并注入 `-test.run` 过滤出这 19 个 eBPF 用例（避开 ~107 个需真实网卡/TC/netlink 的测试）。
**测试目的**：验证 CubeNet 虚拟交换机的 **eBPF 数据面**（DNS 学习 / 出向策略 / TCP 会话状态 / L7 打标）的 riscv64 eBPF 字节码能被 guest 内核的**验证器接受、JIT 编译、加载并正确执行**（走 `BPF_PROG_TEST_RUN` 对合成报文真跑）。用例带 `t.Skip("kernel BPF unavailable")` 守卫，所以「PASS 且非零耗时」才证明真跑了而非被跳过——即 riscv64 eBPF 全栈可用。

Same boot, but stage `cube-guest-test-ebpf.img` (adds `/tests/cubevs-ebpf/`). The 19 eBPF
cases use `BPF_PROG_TEST_RUN` (real in-kernel load+run); they `t.Skip` if BPF is unavailable,
so a PASS with non-zero runtime proves they ran.

```bash
# [L1] stage the eBPF test image and boot
WAIT=60 python3 "$L1/cap.py" <<'EOF'
set -x
ctr --address $SOCK -n default task kill -s SIGKILL cubetest1; sleep 3
ctr --address $SOCK -n default task rm -f cubetest1; ctr --address $SOCK -n default container rm cubetest1
cp -f /mnt/share/cube-guest-test-ebpf.img $TB/cube-image/cube-guest-image-cpu.img
rm -f /mnt/share/l2-console.log
set +x
EOF
WAIT=240 python3 "$L1/cap.py" <<'EOF'
set -x
export RUST_LOG=info RUST_BACKTRACE=full
ctr --address $SOCK -n default run -d --rootfs --runtime io.containerd.cube.rs -c /mnt/share/cube-spec.json cubetest1
set +x
EOF
# [host] verify the eBPF results
cp -f "$SH/l2-console.log" "$SH/l2-ebpf-console.log"
grep -aE 'L2TESTRUN SUMMARY' "$SH/l2-ebpf-console.log"                       # total=5 failed=0
echo "PASS=$(grep -ac '^--- PASS' "$SH/l2-ebpf-console.log") SKIP=$(grep -ac '^--- SKIP' "$SH/l2-ebpf-console.log") FAIL=$(grep -ac '^--- FAIL' "$SH/l2-ebpf-console.log")"
grep -ac 'kernel BPF' "$SH/l2-ebpf-console.log"                              # 0 => nothing skipped
```
Expected: `total=5 failed=0`; eBPF subset `19 PASS / 0 SKIP / 0 FAIL`; `kernel BPF` count `0`.
(l2testrun execv's every `*.test`, so the unfiltered `cubevs.test` — all ~126 cubevs cases — also runs.)

---

## 5. PHASE 4 — app-snapshot on a live L2 (pause → snapshot → resume)

**做了什么**：先冷启一个**活**的 L2 sandbox（cubetest1 RUNNING），再执行 `cube-runtime snapshot --app-snapshot`——它向 shim 的 chapi socket（`/run/vc/vm/cubetest1/chapi`）依次 PUT `vm.pause`→`vm.snapshot`→`vm.resume`，把 VM 完整状态写到 `--path` 下（布局 `{base}/{cpu}C{snap_memory}M/{metadata.json, snapshot/{config.json,state.json,memory-ranges}}`）。`store_metadata` 会读 kernel/agent/image 的 version 文件，故先建占位 version。
**测试目的**：验证 riscv64 上能**暂停一个运行中的 microVM 并把完整状态序列化到磁盘**——内存（memory-ranges，~513M）+ vCPU 寄存器（含 0008 reg_list、0010 跳过 OFF timer）+ 设备 + vAIA（0009）+ config/state，然后 resume 让源 VM 继续存活。这是快照/热恢复能力的「存」侧。

```bash
# [L1] re-stage the NORMAL image + version files (store_metadata reads them), create live sandbox
WAIT=130 python3 "$L1/cap.py" <<'EOF'
set -x
export RUST_LOG=info RUST_BACKTRACE=full
cp -f /mnt/share/cube-guest-image-cpu.img $TB/cube-image/cube-guest-image-cpu.img
echo "6.6.36-cube-test" > $TB/cube-kernel-scf/version
echo "cube-agent-test"  > $TB/cube-agent/version
[ -f $TB/cube-image/version ] || echo "cube-image-test" > $TB/cube-image/version
rm -rf $REST; rm -f /mnt/share/l2-console.log
ctr --address $SOCK -n default task kill -s SIGKILL cubetest1; ctr --address $SOCK -n default task rm -f cubetest1; ctr --address $SOCK -n default container rm cubetest1
ctr --address $SOCK -n default run -d --rootfs --runtime io.containerd.cube.rs -c /mnt/share/cube-spec.json cubetest1
ctr --address $SOCK -n default task ls                       # cubetest1 RUNNING
set +x
EOF

# [L1] snapshot (cube-runtime PUTs vm.pause -> vm.snapshot -> vm.resume to /run/vc/vm/cubetest1/chapi)
WAIT=150 python3 "$L1/cap.py" <<'EOF'
set -x
RESD=$REST/2C512M
PMEM='[{"file":"/usr/local/services/cubetoolbox/cube-image/cube-guest-image-cpu.img","fs_type":"ext4","id":"pmem-cube-os-image","size":null},{"file":"/usr/local/services/cubetoolbox/cube-agent/cube-agent.ext4","fs_type":"ext4","id":"pmem-cube-agent","size":null}]'
cube-runtime snapshot --app-snapshot --vm-id cubetest1 --path $RESD --disk '[]' \
  --resource '{"cpu":2,"memory":512}' --pmem "$PMEM" \
  --kernel $TB/cube-kernel-scf/vmlinux --snapshot-type full --force --notap
echo "SNAPSHOT_RC=$?"
find $REST -type f                                           # config.json state.json memory-ranges metadata.json
du -sh $RESD/snapshot                                        # ~513M
ctr --address $SOCK -n default task ls                       # cubetest1 still RUNNING (resumed)
set +x
EOF
```
Expected: `snapshot success`, `SNAPSHOT_RC=0`, 4 artifacts, `~513M`, cubetest1 still RUNNING.

---

## 6. PHASE 5 — snapshot → destroy → restore into a NEW VM

**做了什么**：销毁源 VM cubetest1（若 `task rm` 卡在 "cleaning up dead shim"，用 fresh state 目录重置 containerd——快照不受影响），再用带 restore 注解的 `cube-spec-restore.json` 起 cubetest2；shim 走 `by_snapshot()→restore_vm()→ch.restore_vm(source_url,memory_vol_url)`，VMM 从快照 mmap 内存、`set_state` 恢复 vCPU 寄存器、恢复设备/vAIA，然后 resume。
**测试目的**：验证能把快照恢复成一个**全新的 microVM 并从中断处续跑**（不是重新冷启动）——这是快照热恢复 / 秒级冷启的核心能力。判别「续跑而非重启」的硬证据：VMM 侧 `VmRestore`（非 `VmCreate`）+ `Restoring VCPU 0/1` + `Starting vCPUs … paused=true` + `vm has been restored`→`vm has been resumed`；console 侧 **0 条内核 boot 横幅**，且 guest uptime > shim 自身存活时长（时钟从原实例继承）。

Restore annotations are baked into `cube-spec-restore.json`:
`cube.appsnapshot.restore=true`, `cube.vm.snapshot.base.path=$REST`,
`cube.vm.snapshot.memory_vol_url=$REST/2C512M/snapshot/memory-ranges`, and
`cube.vmmres={"cpu":2,"memory":512,"snap_memory":512}` (res dir must be `2C512M`).

```bash
# [L1] destroy the source VM. If `task rm -f` hangs on "cleaning up dead shim", reset containerd
#      with a FRESH state dir (the snapshot under $REST is unaffected):
WAIT=90 python3 "$L1/cap.py" <<'EOF'
set -x
ctr --address $SOCK -n default task kill -s SIGKILL cubetest1
pkill -f shim.real; pkill -f containerd-cube.sock; sleep 3
rm -rf /var/lib/containerd-cube /run/containerd-cube-state
mkdir -p /var/lib/containerd-cube /run/containerd-cube-state
containerd --config /etc/containerd-cube.toml --address $SOCK --state /run/containerd-cube-state --root /var/lib/containerd-cube >/mnt/share/containerd-cube.log 2>&1 &
sleep 9
ctr --address $SOCK -n default image import /mnt/share/cube-min.tar
ctr --address $SOCK -n default task ls                       # empty
ls -d $REST/2C512M/snapshot                                  # snapshot intact
set +x
EOF

# [L1] restore into cubetest2 (fast resume, ~6s; NO kernel boot)
WAIT=170 python3 "$L1/cap.py" <<'EOF'
set -x
export RUST_LOG=info RUST_BACKTRACE=full
rm -f /mnt/share/l2-console.log
ctr --address $SOCK -n default run -d --rootfs --runtime io.containerd.cube.rs -c /mnt/share/cube-spec-restore.json cubetest2
set +x
EOF

# [L1] verify restore (VM-level evidence + continuity), no hanging exec
WAIT=70 python3 "$L1/cap.py" <<'EOF'
set -x
ctr --address $SOCK -n default task ls                                          # cubetest2 RUNNING
grep -a cubetest2 /data/log/CubeVmm/vmm.log | grep -aiE 'VmRestore|Restoring VCPU|vm has been restored|vm has been resumed|restore non-shared' | tail -8
grep -a cubetest2 /data/log/CubeShim/cube-shim-req.log | grep -aiE 'snapshot restore init|snapshot dir' | tail -2
grep -acE 'Linux version|Booting Linux|cube-init|Freeing unused kernel' /mnt/share/l2-console.log   # 0 => resumed not rebooted
set +x
EOF
```
Restore-vs-boot discriminators (all must hold):
- VMM: `VmRestore(...)` event (not `VmCreate`), `memory_manager ... restore ... share map memory file`,
  `cpu.rs Restoring VCPU 0` + `Restoring VCPU 1`, `Starting vCPUs ... paused = true`,
  `vm has been restored` then `vm has been resumed`.
- Console: **0** fresh-boot banners; guest uptime at teardown **>** the shim's own wall-clock lifetime.

---

## 7. Concurrency (single L1, serialized L2 boots)

The shim console path `/mnt/share/l2-console.log` is hardcoded, so two L2 VMs cannot boot
at once. When the eBPF run is delegated to a second worker while the main flow uses L1,
serialize with a sentinel on the 9p share:

```bash
# [host] main agent, before using L1:      rm -f "$SH/L1FREE"; echo busy > "$SH/L1BUSY"
# [host] second worker: do host-side prep (build wrapper, mkfs image), then poll:
until [ -f "$SH/L1FREE" ]; do sleep 20; done          # wait until main agent releases L1
# [host] main agent, after teardown + containerd reset: rm -f "$SH/L1BUSY"; echo free > "$SH/L1FREE"
```
Also: never interrupt an in-flight L2 lifecycle command (`ctr run`/`task rm`) with Ctrl-C —
it kills the shim uncleanly and wedges containerd's "cleaning up dead shim"; give it a large
capture window instead, and recover with the fresh-state containerd reset in PHASE 5.

---

## 8. Teardown

```bash
# [L1] remove any VM + stop containerd
WAIT=60 python3 "$L1/cap.py" <<'EOF'
set -x
for id in cubetest1 cubetest2; do
  ctr --address $SOCK -n default task kill -s SIGKILL $id
  ctr --address $SOCK -n default task rm -f $id
  ctr --address $SOCK -n default container rm $id
done
pkill -f shim.real; pkill -f containerd-cube.sock
set +x
EOF
# [host] stop L1
[ -f "$L1/qemu.pid" ] && kill "$(cat "$L1/qemu.pid")"
```

---

## Pass criteria (summary)

| Phase | Command-visible pass marker |
|-------|-----------------------------|
| L1 boot | `serial.log` reaches `login:`; BPF `CONFIG_BPF/BPF_SYSCALL/BPF_JIT=y` |
| L2 cold boot | `task ls` → `cubetest1 RUNNING`; shim `vm ready, vsock is listening` |
| UT pure-logic | `L2TESTRUN SUMMARY total=3 failed=0` |
| UT eBPF | `total=5 failed=0`; eBPF subset `19 PASS / 0 SKIP / 0 FAIL`; `kernel BPF` count `0` |
| Snapshot | `snapshot success`; `SNAPSHOT_RC=0`; `~513M`; source VM still RUNNING |
| Restore | `cubetest2 RUNNING`; VMM `vm has been restored` + `resumed`; console boot-banners `0` |
