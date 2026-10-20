# CubeSandbox 分析:rlimit / systemd / Kata / E2B + 存储内存底座(cubecow·pmem·DAX)

> 面向 riscv64 落地的 CubeSandbox 架构与系统要求分析。整合本轮 ali6000 验证结论。
> 相关:验证现场记录 `cube-ali6000-bed/EVALUATION.md`;差距清单
> `xuantie-yocto/docs/solution/ai-agent/2026-10-13-cubesandbox-riscv64-layer2-gap-analysis.md`。

## 0. 定位

CubeSandbox 是一套**高密度、秒级冷启动的 ephemeral sandbox 服务**:对上暴露 E2B 兼容 API
(供 OpenAI Agents SDK / e2b 客户端驱动),对下用 microVM(KVM 硬件隔离)跑每个 sandbox,
并靠 **cubecow(reflink 存储 CoW)+ pmem(交付)+ DAX(内存直接映射)** 把"磁盘 / 内存 / 快照"
三项开销压到最低。它是 **Kata Containers + Cloud Hypervisor 架构的定制衍生**(见 §2)。

## 1. 架构分层

| 层 | 组件 | 职责 |
|---|---|---|
| ① SDK | OpenAI Agents SDK(`SandboxAgent` + `E2BSandboxClient`) | 应用侧调用 sandbox |
| ② 接口 | **E2B 接口** / CubeAPI(`E2B_API_URL`、`E2B_API_KEY`) | E2B 兼容 REST,create/exec/snapshot |
| ③ 控制面 | CubeMaster / CubeAPI / **cubelet** | 调度、节点管理、生命周期 |
| ④ 运行时 | containerd + **containerd-shim-cube-rs** + **CubeHypervisor** + **cube-agent** + rustjail | shim-v2 → 进程内 VMM → L2 microVM → guest agent → 内层容器 |
| ⑤ 存储/内存底座 | **cubecow**(reflink)/ **pmem**(virtio-pmem)/ **DAX** | 省磁盘 + 省内存 + 小快照 |

## 2. Kata 血统(不是自研,是定制衍生)

`README.md:438` 明确致谢:**Cloud Hypervisor、Kata Containers、virtiofsd、containerd-shim-rs、
ttrpc-rust**,"made tailored modifications ... original in-file copyright notices are preserved"。
组件映射:

| CubeSandbox | Kata Containers 对应 | 证据 |
|---|---|---|
| `containerd-shim-cube-rs` | `containerd-shim-kata-v2`(shim-v2) | runtime v2 两段式握手、`current_exe` re-exec |
| `CubeHypervisor` | Kata 的 cloud-hypervisor VMM | CH fork,进程内 VMM |
| `cube-agent` | `kata-agent`(guest 内,ttRPC over vsock) | L2 日志 `ttRPC server started`、passfd :1027 |
| **rustjail** | Kata 的 Rust 容器运行时 | L2 日志 `"module":"rustjail"` |
| guest kernel + virtio-pmem rootfs | Kata guest 模型 | `root=/dev/pmem0`,pmem0=OS 镜像 / pmem1=agent |
| `cube.sock` / `chapi` | Kata 的 vsock / hypervisor API socket | `/run/vc/vm/<id>/{cube.sock,chapi}` |

含义:很多行为可直接对照 Kata 文档;`cube.vm.kernel.cmdline.append`、`cube.vmmres` 等是 CubeSandbox
自定义的 OCI spec 注解。

## 3. E2B 接口层(②)

- CubeAPI 暴露 **E2B 兼容 API**:`E2B_API_KEY`(本地服务任意非空串即可)、
  `E2B_API_URL`(如 `http://localhost:3000`)。见 `CubeAPI/examples/benchmark.py`。
- `examples/e2b-dev-sidecar`:E2B 开发旁路示例。
- 上层 `e2b_code_interpreter` / `cubesandbox` 的 `Sandbox` 对象即对接此 API;OpenAI Agents SDK
  通过 `E2BSandboxClient` 调用。
- **不接控制面 + 不用模型推理**时,验证只能下沉到 ④/⑤(直接 `ctr run` 起 L2,或 cubecow 单独验)。

## 4. Host 系统要求(跑 CubeSandbox 的宿主/L1)

| 要求 | 用途 | 备注 |
|---|---|---|
| **systemd** | one-click `install.sh`、`cube-sandbox-cubemaster.service` 等 | 无 systemd 只能手动起独立 containerd(runbook step-3 路径) |
| **containerd** | shim-v2 runtime 宿主 | `cubecli` = 跑 Cubelet + containerd 的计算节点 |
| **btrfs 或 reflink-XFS** | cubecow 的 `/data` | 实测:`/` XFS、`/data/cubelet` bind-mount 系统盘 XFS(reflink volumes dir);ext4 **不支持** reflink |
| **/dev/kvm(KVM + H 扩展)** | 嵌套 microVM 的硬件隔离 | riscv64 需 ISA 带 `h` + AIA(smaia/ssaia);L1 日志 `kvm [1]: AIA available with 4 guest external interrupts` |
| **内核 BPF**(BPF_SYSCALL/JIT) | cubevs eBPF 网络策略 | L2 guest 内核也需 |
| **rlimit 可提升** | 见 §5 | CAP_SYS_RESOURCE / fs.nr_open |

> "Cubelet uses the reflink-only `cubecow` storage backend by default"(`docs/guide/dev-environment.md:179`)。

## 5. rlimit 系统要求

- **shim 自身**(`CubeShim/shim/src/main.rs:102-125`):
  - `RLIMIT_CORE` = 2 GiB( core dump);
  - `RLIMIT_NOFILE`:`getrlimit` 后把 `rlim_cur` 抬到 `rlim_max`(软限提到硬限)。
- **容器级**:OCI spec `process.rlimits`(本验证 spec 为空 `[]`),可设 `RLIMIT_NOFILE/NPROC/MEMLOCK`。
- **提高 hard limit 需 `CAP_SYS_RESOURCE`**;否则只能软限≤硬限。
- **`fs.nr_open`** 是 `RLIMIT_NOFILE` 的整机上限(抬 hard limit 前需 ≥ 目标值)。
- **eBPF memlock**:cubevs 的 eBPF 程序/map 受 `RLIMIT_MEMLOCK` 约束(新内核走 memcg 记账则影响小)。
- 结论:host 需允许 shim/cubelet 抬高 NOFILE/CORE,并具备 CAP_SYS_RESOURCE;否则高并发 sandbox
  会撞 fd 上限。

## 6. 存储/内存效率底座:cubecow · pmem · DAX

**三层协同、分属不同层次、可独立存在**(不是单一开关):

```
【存储层】cubecow : host FS reflink(FICLONE)克隆镜像/沙箱数据 → O(1) 磁盘快照, base 只存一份
      ↓ 克隆出的镜像文件
【交付层】pmem     : CH `--pmem file=<img>` 把宿主文件 mmap 进 guest 物理地址 → /dev/pmem0(字节可寻址)
      ↓ guest 怎么访问
【内存层】DAX      : guest ext4 `-o dax` 把 pmem 页直接映射进 guest 页表 → 绕过 guest page cache
```

### 6.1 cubecow 如何省磁盘(reflink)
- reflink(`ioctl(dest, FICLONE, src)` / `cp --reflink`):克隆只新建 inode + extent 指针,
  **数据块与原文件共享**,创建 O(1)、额外盘 ≈0;写时才给被改 extent 新分配块(CoW)。
- 量化(本轮 cube-l1 btrfs 实测,`reflink_cow_demo.py`):2 GiB 文件,普通拷贝 **3.868s + 2 GiB**;
  reflink **0.0002s + ~0**(16835×);`cubecow_smoke.py` 18/18 PASS。
- N 个 sandbox:base 只存一份 + 各自增量;每次快照也是一次 reflink(O(1)、~0 额外盘)。
  例:base 2 GiB × 100 sandbox(各写 50 MiB)→ 无 reflink 200 GiB;有 cubecow ≈ 7 GiB(~28×)。
- **前提**:FS 支持 reflink → btrfs / XFS(`reflink=1`);**ext4 不行**。

### 6.2 pmem 是什么
- **真硬件**:NVDIMM/Optane,内存总线上、字节可寻址、掉电不丢;和 DRAM 并列,**不是从 DRAM reserve**。
- **本方案(virtio-pmem)**:宿主把**镜像文件 mmap 进 guest 物理地址空间**成一段独立区;guest
  `virtio_pmem` 驱动认成 nd_region → `/dev/pmem0`。它与 guest RAM(`--memory`)**并列**、不是从 guest RAM 抠出;
  guest `/proc/iomem` 里是单独的 "Persistent Memory" 段。`discard_writes=true` → guest 写被丢弃(只读根/临时)。
- `unable to guarantee persistence of writes`:virtio-pmem 无真 ADR 掉电保护,对**只读 rootfs 无影响**。

### 6.3 DAX 如何省内存(DAX vs 不启用)
- **不启用 DAX**:guest 把 pmem0 当普通块设备,读文件走 **guest page cache** → 数据拷进 guest RAM;
  host 也缓存该文件 → **同一份 rootfs 存两份**;N 个 sandbox 各拷一份,**不共享**。
- **启用 DAX**:guest `-o dax` 把 pmem 页**直接映射**进 guest 页表,绕过 guest page cache →
  rootfs 数据**只存一份**(host 侧),多 sandbox **共享映射**同一批 host 页。

| 维度 | 不启用 DAX | 启用 DAX |
|---|---|---|
| rootfs 副本 | 2 份(host+guest cache) | 1 份(guest 直接映射 host 页) |
| guest RAM(rootfs) | 随工作集增长 | ≈0 |
| 跨 sandbox 共享 | 无 | 有(共享 base host 页) |
| 单机密度 | 低 | 高 |
| 快照大小 | 大(rootfs cache 进 guest RAM) | 小(base 是 host 映射的 ro clean 页) |
| 正确性 | 一样 | 一样(DAX 只影响性能/内存) |

### 6.4 三者关系
- **两个正交共享轴**:cubecow = 磁盘块共享(reflink,存储层);DAX = 内存页共享(host cache 页,内存层)。
- **pmem = 管道**:把 cubecow 产出的镜像变成"guest 可 DAX 映射的字节可寻址内存区"。
- **可分离 / 优雅降级**:cubecow 不依赖 pmem/DAX(单独可用);pmem 不依赖 DAX(可当普通块设备挂,
  即 6.6.36/fork 当前行为);缺 DAX **不影响正确性**,只损失内存密度/快照大小。
- **别和 overlay2 混**:overlay2 是 guest 内层容器的**文件级 union 挂载**(lowerdir ro + upperdir 写);
  cubecow 是 host 的**块级 reflink CoW**。两者不同层次。

## 7. riscv64 现状与 ali6000 验证结论

### 7.1 为什么之前 riscv64 没有 DAX
CubeShim fork 在 riscv64 上**硬编码去掉 dax**(`CubeShim/shim/src/hypervisor/config.rs:99-104`),
注释原因:xuantie 6.6.36 guest 无 FS_DAX(ZONE_DEVICE 需 `ARCH_HAS_PTE_DEVMAP`,riscv 未 select),
`rootflags=dax` 会被 ext4 以 -EINVAL 拒绝、根挂载失败。

### 7.2 ali6000(6.6.102)补齐了整条 DAX 链
```
arch/riscv/Kconfig:42  select ARCH_HAS_PTE_DEVMAP if 64BIT && MMU   ← fork 注释说 riscv 不 select, ali6000 恰恰 select 了
.config: ARCH_HAS_PTE_DEVMAP=y ZONE_DEVICE=y FS_DAX=y SPARSEMEM_VMEMMAP=y MEMORY_HOTPLUG=y
         MEMORY_HOTREMOVE=y DEVICE_MIGRATION=y VIRTIO_PMEM=y LIBNVDIMM=y BLK_DEV_PMEM=y ND_PFN=y NVDIMM_PFN=y
arch/riscv/include/asm/pgtable.h:396  pte_devmap()(在 ARCH_HAS_PTE_DEVMAP 下)
```

### 7.3 端到端验证(本轮,`cube-ali6000-bed/EVALUATION.md`)
- **前置 bug**:ali6000 作宿主起 L2 时,host 内核在 `kvm_irqfd_assign` panic(确定性复现)。
  根因:`arch/riscv/kvm/Kconfig` 的 `config KVM` 只 `select HAVE_KVM_IRQ_BYPASS`,**漏了 `select IRQ_BYPASS_MANAGER`**
  (x86/arm64/powerpc/vfio/vhost 都有);ali6000 继承 Anolis 的 `IRQ_BYPASS_MANAGER=m` → builtin KVM 调
  只在模块里的 `irq_bypass_register_consumer` → vmlinux 里 `*UND*` → 坏 PLT@`.data.rel` → 取指页错误。
  **修复**:补 `select IRQ_BYPASS_MANAGER`(=y 覆盖 =m)。二进制确认:符号从 `*UND*` → 真实 text,
  崩溃指令从 `jalr→PLT` → `jalr→irq_bypass_register_consumer`。
- **DAX 验证**:放开 config.rs 的 riscv64 dax 门控 + 重编 shim,冷启动 L2:
  - VMM 日志确认 guest cmdline 含 `rootflags=dax`;
  - guest:`EXT4-fs (pmem0): mounted ... ro`、`VFS: Mounted root`、`Run /sbin/init`,**无 dax 报错**;
  - 完整生命周期:`create sandbox!` → `mount overlay2` → `created container!`;`ctr run -d` **rc=0**;
    `ctr task ls` = `RUNNING`;`vm ready, vsock is listening`。
  - **判定**:ext4 在 dax 不支持时会 -EINVAL 拒绝;ali6000 带 `rootflags=dax` 成功挂载并跑通 →
    **FS_DAX 在 ali6000 virtio-pmem 上端到端生效**。换 ali6000 的 DAX 动机成立。

### 7.4 剩余项
- ali6000 `BTRFS_FS=m`、`OVERLAY_FS=m`(6.6.36 rootfs/guest 带的是 6.6.36 模块,版本不匹配)。
  OVERLAY_FS 已在本轮置 =y 修好内层容器;**BTRFS_FS 需置 =y**(或提供匹配模块)才能支撑 L1 `/data` 的 cubecow reflink 路径。
- fork 的 riscv64 dax 门控应改为**按 guest 内核能力条件化**(ali6000 类开 dax、6.6.36 类保留去 dax),
  当前的"无条件放开"仅适配 FS_DAX 内核,勿直接合入。

### 7.5 guest(L2)内核要求 —— 实测清单

> 注意:**containerd/cubelet 是 host(L1)侧,不是 guest 内核要求**;L2 guest 里跑的是 cube-agent + rustjail。
> **铁律:全部必须 builtin(=y)**——L2 从只读 pmem 根 + 无匹配模块树启动(guest 镜像给 6.6.36 建、
> ali6000 是 6.6.102,版本不匹配 → modprobe 失败),任何 `=m` 等于没有(overlayfs=m 曾致内层容器 ENODEV)。

| 分组 | 必需项(ali6000 实测均 =y) | 用途 |
|---|---|---|
| 根/存储交付 | `VIRTIO` `VIRTIO_PCI/MMIO` `VIRTIO_PMEM` `BLK_DEV_PMEM` `LIBNVDIMM` `ND_PFN` `NVDIMM_PFN` `EXT4_FS` `FS_DAX`(+`ZONE_DEVICE`/`ARCH_HAS_PTE_DEVMAP`)`OVERLAY_FS` | pmem0 挂根 + dax + pmem1(agent)+ overlay2 内层容器 |
| shim↔agent | `VIRTIO_VSOCKETS` `VSOCKETS` `VIRTIO_CONSOLE` `HVC_DRIVER` | ttRPC over vsock、`console=hvc0` |
| 网络/块 | `VIRTIO_NET` `VIRTIO_BLK` | sandbox 网卡、blk-cube 存储 |
| 容器隔离(rustjail) | `NAMESPACES`(pid/ipc/uts/net/user)`CGROUPS`+v2 控制器(sched/mem/blkio/pids/…)`SECCOMP` `SECCOMP_FILTER` `SECURITY` | spec 的 ns/cgroup/noNewPrivileges/seccomp |
| eBPF(cubevs) | `BPF` `BPF_SYSCALL` `BPF_JIT` `HAVE_EBPF_JIT` `CGROUP_BPF` | 网络策略 |
| 基础/AIA | `TMPFS` `DEVTMPFS` `PROC_FS` `SYSFS` `SERIAL_8250` `RISCV_IMSIC` `RISCV_APLIC` `RISCV_ISA_V` | 基础 fs、ttyS0、AIA guest irqchip(MSI 投递) |

**guest 里不需要**:KVM/H 扩展(L2 是叶子)、containerd/cubelet(host 侧)、9p/virtiofs(那是 L1 host-share)、btrfs(那是 L1 `/data` cubecow 的要求)。

**eBPF 网络策略实测(cubevs,ebpf 测试镜像,ali6000 L2)**:`L2TESTRUN SUMMARY total=5 failed=0`,
与 6.6.36 基线逐条一致(TestDNSLearn*/TestSessionPolicyRevoked/TestL7Mark/TestTCPUpdate* 全 PASS,RC=0)。
→ 静态看 ali6000 `DEBUG_INFO_BTF` 未开、`NET_CLS_BPF=m`、`TUN=m`,但**实测都不需要**:
- cubevs 嵌入的是**非 CO-RE 固定目标 `.o`**(`dnslearn_riscv_bpfel_test.o`),cilium/ebpf 加载**不需内核 BTF**;
- cubevs 走 **tcx**(BPF_LINK 型 tc 附着,6.6 内置),**不用旧 cls_bpf 模块**(`NET_CLS_BPF`);
- guest 网卡是 virtio-net,**不需 tun**。

**结论:guest 内核唯一需补的两项(本轮已修)= `IRQ_BYPASS_MANAGER=y`(否则 host `kvm_irqfd_assign` panic)+
`OVERLAY_FS=y`(否则内层容器 ENODEV)。** 其余上表项 ali6000 已 builtin,eBPF 策略无需额外配置。

## 8. 落地建议(优先级)
1. **ali6000 Kconfig 持久化**:把 `select IRQ_BYPASS_MANAGER` 做进 `linux-xuantie-ali6000` recipe 补丁
   (work-dir 改动会被 `bitbake -c clean` 冲掉);同时 `OVERLAY_FS=y`、`BTRFS_FS=y`。
2. **fork dax 门控条件化**:config.rs 按 guest 内核 FS_DAX 能力决定 `rootflags=dax`,而非按 arch 硬编码。
3. **host/L1 镜像**:确保 systemd + containerd + btrfs(/data)+ KVM/H 扩展 + BPF 齐备;rlimit 抬高 + CAP_SYS_RESOURCE。
4. **cubecow 校验**:`/data` 用 btrfs 或 reflink-XFS;跑 `cubecow_smoke` + reflink demo 确认 O(1) 克隆/快照。

## 9. 参考(源码/文档位置)
- Kata 血统:`cubesandbox-riscv/README.md:438`
- E2B 接口:`cubesandbox-riscv/CubeAPI/examples/benchmark.py`、`examples/e2b-dev-sidecar/`
- rlimit:`cubesandbox-riscv/CubeShim/shim/src/main.rs:102-125`
- dax 门控 / cmdline:`cubesandbox-riscv/CubeShim/shim/src/hypervisor/config.rs:96-135`
- cmdline 注解注入:`cubesandbox-riscv/CubeShim/shim/src/sandbox/config.rs:236`(`cube.vm.kernel.cmdline.append`)、
  `sandbox/sb.rs:826-838`(冲突检查)
- host 要求:`cubesandbox-riscv/docs/guide/{cli-tools,cross-node-snapshot,cubemaster-scheduler-config,dev-environment}.md`
- 验证现场:`cube-ali6000-bed/EVALUATION.md`
- 差距清单:`xuantie-yocto/docs/solution/ai-agent/2026-10-13-cubesandbox-riscv64-layer2-gap-analysis.md`
