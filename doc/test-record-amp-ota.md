# 测试记录 — eMMC 验证台上的 AMP (Linux↔M0 rpmsg) + OTA A/B

日期: 2026-08-15(断电重启测试时段 11:50、12:xx)

测试台:**实体 Lyra Ultra W** — 板型 `lyra-ultra-w-emmc-ab-amp`
(RK3506B、eMMC、A/B 启动 + AMP)。NAND 变体 `lyra-zero-w-spinand-ab-amp`
共享 SoC/AMP 路径;其存储路径仅做构建(尚无 Zero W 硬件)。

被测固件(一个整体单元,于 03:28 使用 `make build
BOARD=lyra-ultra-w-emmc-ab-amp` 构建,随后 M0 修复在 11:45 重新构建):

| 镜像 | md5 | 说明 |
|---|---|---|
| `update.img` | `5f7b3898…` | 03:28 的整体单元(u-boot + kernel + rootfs + amp) |
| `boot_a.img` / `boot_b.img` | `3046d6e7…` | 相同,已写入两个槽位 |
| `system_a.img` / `system_b.img` | `198227ec…` | 相同,已写入两个槽位 |
| `amp.img` **修复前** | `04335873…` | mcu.bin `57b60f84…`(标记响应器,未使能 INTEN) |
| `amp.img` **修复后**(已烧写) | `aa37f4fc…` | mcu.bin `273c87f5…`(`mbox_enable_rx` 修复),amp2/RT-Thread `ffd76152…` 未变 |

环境:SSH `root@192.168.123.100`(USB gadget 以太网,`luckfox`),
通过 `devmem` 读取寄存器/缓冲区。

---

## 1. 结果汇总

| # | 测试 | 结果 |
|---|---|---|
| A1 | M0 在一次真实的市电断电重启(POR)后启动 | ✅ 所有启动标记 + heartbeat |
| A2 | AP→M0 (A2B) kick **在修复后零手动干预**即可到达 M0 | ✅ `A2B_INTEN=0x101` 自使能 |
| A3 | M0 通告端点 → `/dev/ttyRPMSG0` | ✅ 通道在 4.0 s 时创建 |
| A4 | `m0ping` ping→pong 往返 | ✅ **5/5,0 丢失,RTT 平均 253 µs**(226–295) |
| B1 | `ota-update apply` 写入非活动槽位并提升 | ✅ 槽位 B 已写入,pri 15 |
| B2 | 重启后落在被提升的槽位 | ✅ `current_slot=b`,`root=PARTUUID d7891b4a…` |
| B3 | `S99abctl` 将已启动槽位标记为成功 | ✅ `tries 0, successful_boot 1` |
| C1 | M0 仅 POR 触发(任何软件复位都不会重新运行) | ✅ 已确认(4 种机制,见 §5) |

---

## 2. 已找到根因:缺少 A2B_INTEN 使能位

通告路径已失效(`/dev/ttyRPMSG0` 从未出现),尽管 M0 在运行且内核已投递其
rx 缓冲区。M0 的轮询**并不是**问题所在 — 官方 HAL 的做法与响应器完全一致
(`HAL_MBOX_*` 检查 `A2B_STATUS & 1` 以判断 B2A 模式远端)。缺陷出在上游的
**AP→M0 方向使能**上:

- AP 的 `rockchip_mbox_v2_startup()` 写入 `A2B_INTEN = 0x01000100`。
  位 24 是写使能密钥,并被硬件*消耗*;只有位 8 的触发方式字段生效。实际读取:
  `A2B_INTEN = 0x00000100`。
- **没有 `INTEN_TX_DONE`(位 0),硬件永远不会锁存 `A2B_STATUS`**,因此 AP 的
  kick 停留在 `A2B_CMD/DAT`(`cmd=2`、`data=0x524D5347`)中,状态一直为 0 —
  M0 永远无法观察到它。
- 内核**期望远端自行使能其接收侧**(`HAL_MBOX_ChanEnable` 写入
  `A2B_INTEN = 1<<16 | 1`),但 rk3506-mcu HAL 工程中不包含任何 mailbox
  代码,因此从未有人设置位 0。
- 对比:`B2A_INTEN = 0x101`(位 0 + 位 8)— 因此 M0→AP(存活探测、应答
  kick)一直正常工作。

**可复用的寄存器经验**(RK3506 V2 mailbox):INTEN/STATUS 使用写使能密钥 —
`1<<16` 作用于位 0–15,`1<<24` 作用于位 8 触发字段。密钥在写入时被消耗,从不
保存;一次写入中*同时*写入两个密钥会被拒绝(位 0 未从 `0x01000101` 落地),而
单密钥写入则保持另一字段不变(当位 8 已置位时,`0x00010001` → `0x101`)。

**修复**(`firmware/mcu/src/rpmsg_responder.c`、`mbox_enable_rx()`):

```c
#define MBOX_A2B_INTEN_EN  0x00010001UL   /* write-enable key | bit 0 */

static void mbox_enable_rx(void)
{
    volatile struct mbox_v2 *m = (volatile struct mbox_v2 *)(uintptr_t)MBOX2_BASE;
    m->a2b_inten = MBOX_A2B_INTEN_EN;
}
```

在响应器初始化时调用,**并在每次 heartbeat(256 次迭代)时调用** — 它必须是周期
性的,因为 AP 在每次 Linux 启动时都会重新运行 `v2_startup()`,其写入会再次清除
位 0(鸡生蛋问题:在使能位 0 之前无法看到握手 kick,因此 M0 不能等待 kick 来自
行使能)。

---

## 3. 测试 A — M0 通告 + m0ping

### A0. 在线诊断(修复前,手动)

修复前,在 M0 运行标记响应器(mcu.bin `57b60f84…`)的情况下观察到以下内容:

```
A2B_INTEN @ff292000 = 0x00000100     # trigger only, no enable
A2B_STATUS @ff292004 = 0x00000000    # never latches
A2B_CMD/DAT @ff292008/0c = 0x2 / 0x524D5347   # kick sits, undelivered
B2A_INTEN @ff292010   = 0x00000101   # M0→AP works
```

手动使能 + 重新 kick(证明该机制):

```
devmem 0xff292000 32 0x00010001      # set bit 0 (key 1<<16), bit 8 preserved
devmem 0xff292008 32 0x2             # cmd
devmem 0xff29200c 32 0x524d5347      # dat -> A2B_STATUS latches, M0 consumes
```

结果:`rvq used idx 0→1`(NS 通告已发布),`/dev/ttyRPMSG0` 出现,
内核记录 `creating channel rpmsg-tty addr 0x1f`。`m0ping` 首次运行:
**5/5 ok,RTT µs {min 231.9, avg 287.6, max 417.4, p50 270.1}**。

### A1–A4. 修复后,真实断电重启,零手动干预

新的 amp.img(mcu.bin `273c87f5…`)已烧写到 `/dev/mmcblk0p6`,随后进行一次市电
断电重启。板卡回来后自动运行测试套件(约 16 s):

```
A2B_INTEN @ff292000 = 0x00000101     # self-enabled by the new firmware  ✅
boot_prog = 7; A0–A5 = 0xA0000001..06  # all boot markers                ✅
heartbeat 0x1732B → 0x19055 → 0x1AD7D # M0 alive, serving                ✅
/dev/ttyRPMSG0 present; dmesg: "creating channel rpmsg-tty addr 0x1f"    ✅
rvq used idx = 1                       # NS announce consumed            ✅
m0ping: {"rounds":5,"ok":5,"lost":0,
         "rtt_us":{"min":226.0,"avg":253.0,"max":295.5,"p50":254.6}}     ✅
post-ping rvq used = 6, svq used = 5   # NS + 5 pongs / 5 pings          ✅
```

固件修复已端到端确认:在干净的 POR 之后,整个
Linux↔M0 rpmsg 链路(通告 → `/dev/ttyRPMSG0` → ping-pong)会自行动作。

---

## 4. 测试 B — OTA A/B 回归

`ota-update`(与 `lyra-ultra-w-emmc-ab` 板型相同的机制,doc/ab-boot.md):

```
ota-update apply --rootfs /system_a.img --boot /boot_a.img
>>> writing system_a.img (261488640 B) -> /dev/mmcblk0p8   # system_b
>>> writing boot_a.img (6322176 B)     -> /dev/mmcblk0p5    # boot_b
{"ok": true, "slot": "b", "dry_run": false}
```

apply 后的元数据:**B pri 15 / tries 7,A 降级为 pri 14**。热重启
(PSCI)→ 落在槽位 B:

```
current_slot: b        root: PARTUUID d7891b4a-7115-4ca8-bd65-19d775fed905
androidboot.slot_suffix: _b
slots.b: priority 15, tries 0, successful_boot 1   # S99abctl mark-success ran
slots.a: priority 14, tries 7, successful_boot 0   # fallback
```

槽位 B 的 rootfs = `/dev/mmcblk0p8`;工具(`abctl`/`m0ping`/`ota-update`)存在;
AMP 内核从 B 启动(`rockchip-rpmsg … rpmsg host is online`)。回滚
(`abctl set-other-active`)已在 `lyra-ultra-w-emmc-ab` 测试台上通过相同的
A/B 机制验证,此处不再重复运行。

---

## 5. 已知行为 / 限制

- **M0 仅 POR 触发。** 它只在真实的市电断电重启后才会执行。所有软件复位路径
  都无法使其重新运行(已于 2026-08-15 详尽测试):
  (1) CRU `SRST_HRESETN_M0_AC`(SOFTRST_CON00 位 10 — 写入甚至不会生效),
  (2) CRU `SRST_H_M0`(SOFTRST_CON05 位 10 — 无效果),(3) PSCI 热 `reboot`,
  (4) CRU `GLB_SRST_FST` 全局复位。根因模型:u-boot/TEE
  (`sip_smc_mcu_config`)只是暂存代码;M0 内核释放 + bootrom 向量设置只发生在
  POR 路径中。因此任何热重启后 `/dev/ttyRPMSG0` 都会缺失,直到下一次断电重启
  (DDR heartbeat 字冻结在重启前的值)。
- **固件必须跨 Linux 重启自愈 A2B 使能**(周期性的 `mbox_enable_rx()`),
  因为 AP 的 `v2_startup` 每次启动都会清除位 0。
- `amp2`(cpu@f02 上的 RT-Thread)存在于 FIT 中并由 u-boot 释放,但本次会话
  未观察到其控制台 heartbeat(不属于 ping-pong 的一部分;见 doc/amp.md)。
- 延后清理:暂存的 OTA 镜像 `/boot_a.img` + `/system_a.img`
  (约 267 MB)位于槽位 A 的 rootfs 中;通过挂载 `/dev/mmcblk0p7` 移除。
  临时启动进度标记(`bootmark.h`、`fault_diag.c`)仍保留在 M0 构建中,一旦
  该链路被认为是稳定的即可移除。

## 6. 复现

测试时在构建主机上使用的宿主机侧脚本(实时):

- `/tmp/watch-powercycle2.sh` — 等待板卡 DOWN→UP,然后运行测试套件。
- `/tmp/verify-amp-postfix.sh` — POR 后测试套件:A2B_INTEN 自使能
  检查 → 启动标记 → heartbeat → `/dev/ttyRPMSG0` → `m0ping` → `abctl`。
- `/tmp/mbox-enable-test.sh`、`/tmp/mbox-enable2.sh` — 在线寄存器使能 +
  重新 kick 诊断。
- 板卡侧:`/tmp/m0diag.sh`、`/tmp/ampmarker.sh`(烧写/读取标记构建)。

关键的手动检查:

```sh
devmem 0xff292000               # A2B_INTEN — want 0x101
devmem 0x03c90000               # M0 heartbeat
devmem 0x03c01002               # rvq used idx (NS announce + replies)
ls -la /dev/ttyRPMSG0
m0ping --count 5
abctl status
```
