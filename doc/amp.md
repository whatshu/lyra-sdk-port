# 非对称多处理(AMP)— RK3506:2×Linux + RT-Thread + M0

RK3506B 有三颗 Cortex-A7 核和一颗 Cortex-M0。在 shu-sdk 的 AMP 板上
(`lyra-ultra-w-emmc-ab-amp`、`lyra-zero-w-spinand-ab-amp`),它们分配如下:

| 核 | 运行 |
|------|------|
| cpu0 / cpu1 | Linux(2× Cortex-A7,正常的 SMP 对) |
| cpu@f02     | **RT-Thread**(Rockchip 的 `rk3506-32` BSP,一个最小 demo task) |
| Cortex-M0   | **bare-metal HAL** rpmsg responder(`firmware/mcu/`) |

u-boot 从 `amp` 分区加载一个 **amp.img FIT**,启动时释放两个额外核心;内核随后通过
virtio-rpmsg 与 M0 通信(`/dev/ttyRPMSG0`)。两颗 Linux 核不受影响——cpu@f02 从内核
设备树里被删除(`rk3506-amp.dtsi`)。

> **为什么 RT-Thread 和 M0 responder 都要?** 第 3 颗 A7(RT-Thread)证明 u-boot 的
> PSCI cpu-on 路径可用,并为以后预留第二颗通用 RTOS 核。真正对交付功能有用的是 M0:
> 它是 Linux↔M0 **rpmsg ping-pong**(`m0ping`)的低时延、常驻对端。RT-Thread 不参与
> ping-pong。

## amp.img — AMP FIT

`firmware/amp.its` 把两个镜像打成一个 FIT(`mkimage -f amp.its -E -p 0xe00 amp.img`,
由 firmware 阶段执行):

| 镜像 | 类型 | cpu / load | 启动方式 | 核 |
|-------|------|-----------|-------------|------|
| `amp2` | `firmware` | `cpu = <0xf02>`,load `0x03e00000` | PSCI `smc_cpu_on` | 第 3 颗 Cortex-A7 |
| `mcu`  | `standalone` | load `0xfff84000` | TEE SRAM release | Cortex-M0 |

- `amp2`(RT-Thread)放在 DDR `0x03e00000`(内核的 `amp_reserved` no-map 区),通过
  PSCI 在 cpu@f02(mpidr `0xf02`)上启动。
- `mcu` 放在 SRAM carve-out `0xfff84000`(`mcu_reserved @ 0xfff80000, 0xc000`);TEE
  把地址 0 映射到 SRAM,并以 TCM 模式释放 M0(其向量位于 SRAM `0x0`)。

FIT 为每个镜像带一个 sha256 哈希和一个(当前未强制启用的)`rsa2048` 签名——u-boot 的
`CONFIG_FIT_SIGNATURE` 是关的,所以签名节点只是元数据。

## u-boot 释放路径

开启 `CONFIG_AMP`/`CONFIG_ROCKCHIP_AMP` 后,`rk_board_late_init()` 无条件调用
`amp_cpus_on()`(`drivers/cpu/rockchip_amp.c`):

1. 把 `amp` 分区(GPT/MTD)读进内存作为 FIT。
2. 遍历配置的 `loadables`(`amp2`、`mcu`),对每个调用 `brought_up_amp()`:
   - **type=firmware** → `smc_cpu_on`(PSCI)把第 3 颗 A7 从其 load 地址启动。
   - **type=standalone** → RK3506 上的 `fit_standalone_release(id, entry)`
     (`arch/arm/mach-rockchip/rk3506/rk3506.c`):
     1. `sip_smc_mcu_config(BUSMCU_0, MCU_CODE_START_ADDR, entry)` — TEE 把地址 0
        映射到 SRAM 并搬运镜像。
     2. `writel(0x0c000000, CRU_GATE_CON5)` — 打开 M0 时钟(SWCK/TCK + HCLK)。
     3. `writel(0xbcd3d80, GRF_SOC_CON36)` — M0 system-time 校准。
     4. `writel(0x00060004, PMU_INT_MASK_CON)` — 释放 M0 中断掩码
        (`mcu_rst_dis_cfg=1`, `glb_int_mask_mcu=0`)。
3. 启动核随后继续启动 Linux。内核**不会**重新 gate M0(没有 CRU/PMU 驱动碰
   `GATE_CON5`/`PMU_INT_MASK_CON`),所以 M0 在整个内核启动期间持续运行。

## 内存图(内核侧,`rk3506-amp.dtsi` + 板级 dts)

全部 reserved、`no-map`——内核从不分配它们:

| 区域 | 范围 | 存放 |
|--------|-------|-------|
| `amp_shmem_reserved` | `0x03b00000` 1 MiB | 与 cpu2(RT-Thread)共享内存 |
| `rpmsg_reserved`     | `0x03c00000` 1 MiB | virtio-rpmsg vrings + 元数据 |
| `rpmsg_dma_reserved` | `0x03d00000` 1 MiB | rpmsg 缓冲区的 shared-dma-pool |
| `amp_reserved`       | `0x03e00000` 1 MiB | RT-Thread 镜像 + 堆(板级 dts) |
| `mcu_reserved`       | `0xfff80000` 48 KiB | M0 SRAM (TCM) |

rpmsg vring 布局(两侧必须一致):

- `vring[0]` rvq @ `0x03c00000` — Linux 投放空 rx 缓冲(M0 读)。
- `vring[1]` svq @ `0x03c08000` — Linux 投放 TX 消息(M0 serve)。
- mailbox0 @ `0xff290000` — **B2A**:M0 → Linux kick(`cmd=2`,
  `data=RPMSG_MBOX_MAGIC`),Linux rx。
- mailbox2 @ `0xff292000` — **A2B**:Linux → M0 kick,M0 txdone。
- `link-id 0x02`, `RPMSG_MBOX_MAGIC 0x524D5347`。

## 内核 AMP 接线

- **Config**: `arch/arm/configs/rockchip_amp.config` — mailbox、rpmsg、virtio、
  `rpmsg_tty`。
- **驱动**: `drivers/rpmsg/rockchip_rpmsg_mbox.c`(vrings + mailbox 传输)、
  `drivers/soc/rockchip/rockchip_amp.c`(`/sys/rk_amp/boot_cpu`)、
  `drivers/tty/rpmsg_tty.c`(`/dev/ttyRPMSG0`)。
- **启动**:删除 cpu@f02 后,内核以 2 核启动;AMP dtsi 通过 `amp-irqs` 把 UART3/4 +
  I2C0 + GPIO + mailbox 中断路由给 cpu2,所以这些额外外设属于 RTOS 侧。

## M0 固件(`firmware/mcu/`)

Bare-metal Rockchip HAL,`-mcpu=cortex-m0`,链接到 TCM(`0x0`–`0x8000`,栈在
`0x7c00`);与 Linux 的所有交互都通过 DDR vring 加 mailbox 寄存器——它从不碰 UART
外设。

`rpmsg_responder.c` 实现一个 virtio-rpmsg **responder**(镜像内核
`rockchip_rpmsg_mbox.c` 的常量):

- 轮询 mailbox2(A2B)的 Linux kick;
- serve TX ring(svq),解析 rpmsg 缓冲;
- 通过写 used ring 并 kick mailbox0(B2A,`cmd=0x02`,`RPMSG_MBOX_MAGIC`)回复;
- 收到 "ping" 回复 "pong" —— 即 `m0ping` 往返;
- DDR `0x03c90000` 处一个心跳/诊断块(`hb`、`diag_state`、`diag_detail`)让 Linux 可用
  `devmem` 读 M0 存活/状态;
- `HardFault_Handler`(`fault_diag.c`)把故障转储(MSP、CFSR/BFAR、压栈的 PC/LR/R0-R3)
  记到 `0x03c91000` 并停机。

构建:`make -C firmware/mcu/GCC CROSS_COMPILE=arm-none-eabi-`(主机或构建容器内)。

## RT-Thread(cpu2,`vendor/rockchip/rtos`)

Rockchip 官方 `rk3506-32` BSP 镜像进本仓库。用 **scons** 构建:

```sh
cd vendor/rockchip/rtos/bsp/rockchip/rk3506-32
scons --useconfig=board/evb1/defconfig_cpu2     # 最小非 SMP 配置
RTT_EXEC_PATH=/usr/bin RTT_PRMEM_BASE=0x03e00000 RTT_PRMEM_SIZE=0x00100000 \
RTT_SHMEM_BASE=0x03b00000 RTT_SHMEM_SIZE=0x00100000 CUR_CPU=2 scons -j$(nproc)
```

`defconfig_cpu2` 是最小配置(无 SMP、32 个优先级、1 kHz tick);firmware 阶段固定了与
上游 build.sh 相同的内存环境。RPMSG link-id `0x02` 留给 M0。demo task 只在 RTOS 控制台
上心跳(UART4 在 AMP dtsi 中路由到 cpu2)。

## Linux↔M0 ping-pong(`m0ping`)

`/usr/bin/m0ping`(rootfs overlay)以 raw 方式打开 `/dev/ttyRPMSG0`,每轮做一次同步
ping→pong,以 JSON 输出 RTT 统计:

```sh
m0ping --count 1000
# {"device": "/dev/ttyRPMSG0", "rounds": 1000, "ok": 1000, "lost": 0,
#  "rtt_us": {"min": …, "avg": …, "max": …, "p50": …, "p99": …}}
```

设备节点只在 AMP 固件起来、M0 已 announce 其 endpoint 之后才会出现,所以 `m0ping`
会重试打开几秒。

## 构建接线(`stages/40-firmware/run.sh`)

设置 `AMP := 1` 后,firmware 阶段:

1. 用 scons 构建 RT-Thread → `amp2.bin`;
2. 用 make(arm-none-eabi)构建 M0 → `mcu.bin`;
3. 运行 `mkimage -f amp.its -E -p 0xe00 amp.img`;
4. 把 `amp.img` 打进 update.img 的 `amp` 分区(eMMC 和 NAND A/B 的 package-files
   都列了它)。

构建容器固定了 `scons` + `gcc-arm-none-eabi`(tools/docker)。

## 验证状态

SoC 侧 AMP 在**硬件验证床** `lyra-ultra-w-emmc-ab-amp`(实体 Lyra Ultra W —— 与
Zero W 相同的 RK3506B)上验证。**Linux↔M0 rpmsg 链路现已端到端完全验证**(2026-08-15):

- u-boot `amp_cpus_on()` 从 `amp` 分区加载 amp.img,释放寄存器按设计落地
  (`CRU_GATE_CON5=0x0c000000`、`GRF_SOC_CON36=0x0bcd3d80`、
  `PMU_INT_MASK_CON=0x00060004`)。
- M0 announce→`/dev/ttyRPMSG0`→`m0ping` 链路在真实市电断电上电后**零人工干预**工作:
  responder 自使能其 A2B 接收路径(`A2B_INTEN=0x101`),announce `rpmsg-tty` endpoint
  (`addr 0x1f`),并在 **5/5 轮、RTT 平均 253 µs**(226–295)下 serve `m0ping`。
  完整记录:[doc/test-record-amp-ota.md](test-record-amp-ota.md)。
- 途中发现的一个根因:AP 的 mailbox `v2_startup()` 写入 `A2B_INTEN = 0x01000100`,
  其 bit-24 写使能 key 被消耗后**不留下 bit-0 使能**——所以 AP→M0 kick 永远无法锁存
  `A2B_STATUS`,M0 轮询永不触发。修复:M0 在初始化时和每次心跳时重新断言
  `A2B_INTEN = 0x00010001`(内核期望对端自使能,但每次启动都会重跑 `v2_startup()`)。
  见测试记录 §2。
- **M0 只在 POR 后运行**:它只在真实市电断电上电后执行;热重启(PSCI)和 CRU 复位
  不会重跑它,所以 `reboot` 后 `/dev/ttyRPMSG0` 缺失,直到下一次断电上电。已针对 4 种
  软件复位机制穷举确认(测试记录 §5)。
- AMP 床上的 A/B OTA 回归通过:`ota-update apply` 写入并提升槽位 B,热重启落在其上,
  `S99abctl` 标记成功(`tries 0, successful_boot 1`)。
- NAND Zero-W 板现已在实体 Zero W 上**硬件验证**(2026-08-16/17):AMP 路径(cpu2 上的
  RT-Thread、M0 responder、`m0ping`)和 NAND 存储路径都在硅片上工作。完整记录(包括 M0
  POR-only 行为和烧写读掩码的绕行)在 [doc/test-record-zero-w.md](test-record-zero-w.md);
  NAND 布局见 [doc/ab-boot-nand.md](ab-boot-nand.md)。
