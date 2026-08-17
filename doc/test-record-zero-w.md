# 测试记录 —— Lyra Zero W:NAND A/B + 完整 AMP + m0ping 实机验证

日期:2026-08-16 → 2026-08-17(08-16 烧写 + A/B 验证,08-17 冷启动 AMP/M0/m0ping 验证)

开发板:**实体 Luckfox Lyra Zero W** —— `lyra-zero-w-spinand-ab-amp`
(RK3506B,512 MB DDR,256 MB 板载 SPI NAND W25N02KV,无 eMMC)。这是 NAND 存储路径
和 AMP 栈第一次在真正的 Zero-W 硬件上跑通;SoC 侧的 AMP 此前已在 eMMC 验证床验证过
(见 [test-record-amp-ota.md](test-record-amp-ota.md))。

环境:硬件串口 `/dev/ttyACM0` @ 1.5 Mbit(console = UART0 @ `0xff0a0000`,
`console=ttyFIQ0`,`earlycon=uart8250,mmio32,0xff0a0000`),登录 `root`/`luckfox`。
M0 的活性/状态用 `devmem` 读它留在 DDR 里的诊断块。

被测固件:`lyra-zero-w-spinand-ab-amp` 一次连贯构建的产物,在 loader 模式下烧进 NAND
(本次启动槽位 **b**)。

---

## 1. 结果汇总

| # | 测试项 | 结果 |
|---|---|---|
| S1 | loader 模式烧写 A/B update.img 到 NAND | ✅ 用 WL 写绕过 32 MB 读掩码(§7) |
| S2 | NAND A/B 启动:u-boot 选槽、注入 `ubi.mtd=` + `root=ubi0:system` | ✅ 槽位 **b**,挂载 `system_b`,rootfs 正常启动 |
| S3 | cpu@f02 上的 RT-Thread 运行 | ✅ UART0 进度标记 M1–M9(§3) |
| S4 | **真断电上电(POR)后 M0 执行** | ✅ 完整启动链 + mailbox poke + 心跳(§2) |
| S5 | 任何软件复位后 M0 **不**再运行 | ✅ 热重启后保持停机(与 eMMC 验证床一致) |
| S6 | Linux ↔ M0 rpmsg announce → `/dev/ttyRPMSG0` | ✅ 通道存在,`creating channel rpmsg-tty addr 0x1f` |
| S7 | `m0ping` ping→pong 往返 | ✅ **100/100,0 丢包,RTT 平均 297 µs**(min 226,p50 298,p99 943) |
| D1 | 已知缺陷:`abctl` 崩溃 —— python3 缺 `zlib` 模块 | ⚠️ §6.1 —— 已修复 defconfig |
| D2 | 已知缺陷:SPL 启动前先花 ~42 s 探测 MMC | ⚠️ §6.2 |

整个移植最重要的结论,先一句话:**M0 只在真断电上电后运行。** 所有热重启路径都让它
保持停机——这在 eMMC 验证床上已经确认;而 Zero W 给这个故事添了个坑人的误导
("确定性卡死"其实是陈旧的 DDR 残留,§2)。

---

## 2. M0 之旅:"心跳卡死"其实是 DDR 残留 —— M0 只在 POR 后运行

### 2.1 误导我们的现象

第一次冷启动(刚烧写完)后 M0 跑了一阵,之后每次**热重启**看到的画面都一样:u-boot
*确实*把 M0 镜像搬了进去(`Loading loadables from 0x1c746080 to 0xfff84000`,
`Handle standalone: 'mcu-rpmsg-responder' at 0xfff84000 ...OK`),释放寄存器也写到位,
但 M0 从没启动。它留在 DDR 的心跳字停在固定值 —— `0x32C9BE` ≈ 3.33 M 计数,每次
重启都一模一样。

因为数值是"确定性的",看起来像是 M0 固件在第 8.52 亿次迭代(计数 × 256)处可复现地
卡死。这个解释是**错的**。

### 2.2 真正的原因:电池/备用电源保持的 DDR 残留

心跳字放在普通 DDR(`0x03c90000`)。本板的"热重启"并不是真正的上电复位——DDR 内容
被保留。那个"确定性"的 `0x32C9BE` 其实就是**上一次冷启动运行写下的最后值**,因为 M0
之后再也没有运行来重置它,所以冻在原地。8.52 亿次迭代 ≈ 烧写后首次上电后 M0 运行了
6–14 分钟。根本没有卡死——只有残留。

下一次热重启确认(先清零诊断块):

```
IRQ46 ff290000.mailbox   = 0        # mailbox0 B2A poke 从没触发
mailbox0 b2a_cmd/dat     = 0 / 0    # Reset_Handler 的首指令 poke 不存在
bootmarks 0x03c91040..58 = 全 0     # BM_RESET..BM_RUN 从没写入
hb / state / detail      = 0 / 0 / 0
fault 0x03c91000         = 0        # 没有 HardFault —— 它根本没运行,不是崩溃
```

### 2.3 决定性实验:清零 + 真断电上电

为了排除所有残留,先把诊断用 DDR 区(`hb 0x03c90000`、`state 0x03c90004`、
`detail 0x03c90008`、`fault 0x03c91000`、bootmarks `0x03c91040..58`)清零,然后**断电
上电**(拉掉电源,不是 `reboot`)。登录后诊断全部活跃:

```
IRQ46 ff290000.mailbox   = 1      # 第一个 B2A poke —— 触发了
mailbox0 b2a_cmd/dat     = 0x2 / 0x524D5347   # cmd=2,dat="RMSG" magic
bootmarks 0x03c91040..58 = 0x07, 0xA0000001..0xA0000006   # BM_RUN + A0–A5,全部置位
hb / state / detail      = 0x0005B05B, DIAG_AFTER_POLL(2), 0xFF290000  # 持续爬升
fault 0x03c91000         = 0
```

之后 M0 一直跑:hb `0x0005B05B` → `0x00082F9B` → `0x0010D8CD` → `0x00180D20`(约 7 分钟
内),`m0ping` 100/100 通过(IRQ46 从 1 爬到 121,每个 "pong" kick 都送达)。整条启动
链——Reset_Handler 的 DDR 无关 B2A poke、TCM 拷贝、SystemInit、entry、
`rpmsg_responder_run`——全部执行完毕。

**u-boot 的搬运路径在真 POR 下是好的。** 它看起来坏,只是因为热重启残留骗我们去追一个
幻影卡死。

### 2.4 为什么热重启跑不了 M0 —— A7 写不进 SRAM 的发现

追查过程中浮出第二个真实的硬件事实:在重启后的状态里,A7 **写不进 M0 SRAM**
`0xfff84000+`——读返回 0,写被*静默丢弃*(写完 `0xdeadbeef`/`0xa5a5a5a5` 再读还是 0),
而对照实验写普通 DDR(`0x03c90000 ← 0x11223344`)是能写进去的。`0xfff80000` 读直接
总线错误(TEE 保护区)。常见嫌疑都排除了:

- M0 时钟已开:`GATE_CON5` 读回 `0x0000F300` → bit 10(`hclk_m0`)= 0 = 开;
  `stclk_m0` 24 MHz;debugfs `hclk_m0 count=1 rate=187500000`。
- gate/软复位写入*确实*生效(`SRST_H_M0` CON05 bit 10 可在 `0x00000000 ↔ 0x00000400`
  间切换;`SRST_HRESETN_M0_AC` CON00 bit 10 比较特殊,写不进去)。
- M0 隔离:`mcu_iso_con0-11`(`0xff289000..0x2c`)和 `mcu_iso_ddr_con0/1` 全 0,
  `mcu_iso_lock` 未锁。

所以 SRAM 处于一种软复位后依然保持的 M0 独占/TEE 保护模式——和"M0 核释放 + bootrom
向量设置只发生在 POR 路径,u-boot/TEE(`sip_smc_mcu_config`)在后续启动只负责搬运代码"
的模型一致。这与 eMMC 验证床完全吻合:**M0 只在 POR 后运行**,Zero W 在上面还多加了
一个陈旧 DDR 的坑。

> 实际后果:任何热重启之后,`/dev/ttyRPMSG0` 都要等到下一次断电上电才出现。冷启动
> 到*另一个* A/B 槽位效果一样——M0 结果与槽位无关(同一个 amp 分区)。

---

## 3. cpu2 上的 RT-Thread —— "看不见的控制台"问题与标记法

AMP 内核树删掉了 `cpu@f02`,并把 **UART3/4 路由给 cpu2**(`rk3506-amp.dtsi`),所以
RT-Thread 真正的控制台在一个*不在*物理调试链路(UART0)上的 UART。在我们的串口上
RT-Thread 静默启动,看起来像死了。

**解决办法 —— 原始 UART0 进度标记。** 在 RT-Thread 启动路径里加了一个临时调试钩子,
直接 poke UART0 的发送保持寄存器(`0xff0a0000` / `0xff0a0014`,也就是 *Linux* 的控制台
UART),在每一步打点 `[rtt] M1 … M9`
(`vendor/rockchip/rtos/libcpu/arm/cortex-a/mmu.c`:M1 = 进入 MMU 页表设置,M2 = MMU 已
使能,等等)。因为 UART0 正是我们抓的 console,这些标记会混在 kernel 日志里出现,证明
cpu2 执行了复位代码:

```
AMP: Brought up cpu[f02] with state 0x10, entry 0x03e00000 ...OK
[rtt] M1 mmu table setup
[rtt] M2 mmu enabled
... M3..M9 ...
```

这些标记明确标注为临时("Remove after the Zero-W amp investigation");RT-Thread 自己的
控制台在 AMP dtsi 里仍是 UART4。

---

## 4. NAND A/B 启动 —— 实机验证通过

[ab-boot-nand.md](ab-boot-nand.md) 里的 NAND 存储设计在硅片上得到了确认:

```
androidboot.slot_suffix=_b   ubi.mtd=6   root=ubi0:system
mtdparts=spi-nand0:0x800000@0x400000(uboot),0x400000@0xc00000(misc),
  0xc00000@0x1000000(boot_a),0xc00000@0x1c00000(boot_b),
  0x400000@0x2800000(amp),0x6000000@0x2c00000(system_a),
  0x6000000@0x8c00000(system_b),0x1360000@0xec00000(spare)
```

- u-boot 从 `misc` 读 `AvbABData`,选中槽位 **b**,从 NAND 加载 `boot_b`(kernel)和
  `amp`(FIT),并注入按槽位生成的 bootargs(`ubi.mtd=6 root=ubi0:system` → `system_b`)。
- 内核在 mtd6 上 attach `ubi0`,挂载 UBIFS 卷 `system`(只读),启动 init。整个用户态栈
  都起来了(rootfs 可写、sshd、USB gadget、……)。
- TF 卡 `userdata` 路径**本次未实测**:没有 `/dev/mmcblk*` 节点(内核 SD 初始化失败
  `mmc0: error -110 whilst initialising SD card`),所以 `/userdata` 没有挂载。首次启动
  的 ext4 格式化 + 挂载(`S10mount-userdata` → `abctl ensure-userdata`)仍是"已构建、待
  实测"的功能,等槽位里有张能用的 SD 卡再说。

`/proc/cmdline` 里的 `mtdparts` 表和文档布局完全一致(mtd0..mtd7)。槽位状态、回滚、
`ota-update` 策略与 eMMC 版不变——流程图见 `ab-boot-nand.md`。

---

## 5. Linux ↔ M0 乒乓 —— 数据

```
$ m0ping --count 100
{"device": "/dev/ttyRPMSG0", "rounds": 100, "ok": 100, "lost": 0,
 "rtt_us": {"min": 225.5, "avg": 296.9, "max": 942.7, "p50": 298.1, "p99": 942.7}}
```

- **100/100 轮,0 丢包**,平均往返 ~297 µs(µs 量级,和 eMMC 验证床的 253 µs 相当)。
- 每个 "pong" 都通过 mailbox0 的 B2A kick 送达:IRQ46 最终停在 **121** = 1(首次
  Reset_Handler poke)+ 20 + 100(两次 m0ping 各一轮一个 kick)——每个 kick 都到达了
  Linux。M0 的诊断 state 停在 `DIAG_SVQ(5)`(正在 serve-tx 循环里),`detail = 0xff290000`。
- 链接在 POR 后**零人工干预**自动就绪:M0 周期性地重申 `A2B_INTEN` bit 0(AP 每次启动
  Linux 的 `v2_startup()` 都会把它清掉),announce `rpmsg-tty` @ `0x1f`,然后
  `/dev/ttyRPMSG0` 出现。这个修复来自 eMMC 验证床 §2,固件是共享的。

---

## 6. 在 Zero W 上发现的已知缺陷

### 6.1 `abctl` 崩溃 —— 精简 rootfs 丢了 python3 的 `zlib` 模块

Zero W 上 A/B 工具一上来就是坏的:

```
# abctl status
Traceback (most recent call last):
  File "/usr/bin/abctl", line 46, in <module>
    import zlib
ModuleNotFoundError: No module named 'zlib'
```

`abctl` 硬依赖 `zlib` 做 `AvbABData` 的 CRC32(`zlib.crc32(body)`),所以**每一个**
abctl/ota-update 命令都会失败。`S99abctl` 跑的是 `abctl mark-success >/dev/null 2>&1
|| true`,失败被静默吞掉,启动的槽位永远不会被标记为成功。

根因:AMP 板 defconfig(`product/platform/configs/buildroot/
rockchip_rk3506_luckfox_ab_amp_defconfig`)是"精简核心":只开了 `BR2_PACKAGE_PYTHON3=y`,
而且——和 base / 非 AMP 的 A/B defconfig 不同,后者至少加了 `BR2_PACKAGE_PYTHON3_SSL=y`
——它**一个** python3 模块选项都没设。`BR2_PACKAGE_PYTHON3_ZLIB=y`(会 `select`
`BR2_PACKAGE_ZLIB`)在整棵仓库里都没人设过,所以构建出来的 python3 没有 zlib 模块
(设备上 `python3 -c "import zlib"` 会失败)。

**修复(已应用到仓库):** 给 AMP defconfig 加上 `BR2_PACKAGE_PYTHON3_ZLIB=y`。下一次
构建 rootfs 后生效。在那之前,活动槽位每启动一次都会扣 `tries_remaining`(见 §6.3)。

### 6.2 SPL 启动前先花 ~42 s 探测 MMC,然后才回落 NAND

每次启动 SPL 都要付 ~42 s 的代价:`Total: 42480.558 ms` 大部分花在 MMC 探测上
(`MMC error: cmd index 13` = SEND_STATUS 超时),之后 SPL 才回落 SPI NAND。内核也会重试
SD 槽(`mmc0: error -110 whilst initialising SD card`),但不阻塞;而且没有 `/dev/mmcblk*`
节点——这块板/这次启动的 SD 槽里没有能用的卡。

卡槽里有卡时这个延迟是否消失、还是需要在本板禁用 SPL 的 MMC 探测 / 把 MTD 排到 MMC
之前,是个待办项。不管怎样,它决定每次上电是 ~2 s 启动还是 ~44 s 启动。

### 6.3 当前镜像的 A/B tries-remaining 账目

槽位 **b** 在本轮测试开始时 `tries_remaining = 3`,冷启动把它扣到 **2**。因为
`abctl mark-success` 坏了(§6.1),没有任何一次启动能给槽位记成功,所以只要还用这个
镜像,每次重启都会继续扣(重刷会重置 A/B 元数据)。**这个镜像别再无故重启**;干净路径是
重刷带 zlib 修复的镜像再冷启动。M0 的结果不受槽位切换影响。

---

## 7. 烧写 Zero W —— 0xcc-at-≥32MB 读掩码

烧 Zero W(NAND)和 eMMC 板相比有两处不同:

1. **进入 loader 模式。** 串口上够不到独立的 BOOT 按键,所以 loader 模式靠下面两种方式
   进入:
   - 已启动系统里跑 `reboot-loader`,或
   - 上电窗口期间发 Ctrl+D(0x04)热键(由 u-boot 的 `HK_ROCKUSB_DNL` 处理)——主机上用
     `/tmp/ctrl_d_spam.py`。
   `upgrade_tool ld` 随后显示 `Mode=Loader`/`Maskrom`。

2. **32 MB 读掩码。** loader 的 rockusb *读*路径在 `RKUSB_READ_LIMIT_ADDR`(≈ 32 MB)
   之后被掩码:该地址及之后的读返回 0xcc 填充。**写不受掩码。** 所以
   `upgrade_tool uf update.img` 这种"写完再读回校验"的方式,会在 32 MB 边界及之后
   的每个分区(amp @ 40 MB,system_a/b @ 44/140 MB)报一个假的校验失败——而数据其实
   已经正确写进去了。

   **解决办法:按正确的 LBA 用写长度(WL/wlx)烧写。** 逐分区用写长度命令写到它对应的
   分区 LBA——完全不读回——然后**用启动来验证**,而不是读回校验。所有槽位镜像都是
   这么烧的;启动本身(§4)就是证据。

---

## 8. 复现 / 工具

本会话用到的宿主侧脚本(构建主机上现存的):

- `/tmp/sercap_amp.py` —— `upgrade_tool RD`(把板子从 rockusb 里复位),然后以 1.5 M
  抓 N 秒串口到 `/tmp/serout_amp.txt`。
- `/tmp/ctrl_d_spam.py` —— 上电时发 Ctrl+D 进入 u-boot loader 模式。
- 板侧诊断(手动,除了注明外全部只读):

```sh
# M0 是否存活 / 走到哪一步了?
grep mailbox /proc/interrupts          # IRQ46 ff290000.mailbox = B2A pokes
devmem 0xff290018 32 ; devmem 0xff29001c 32   # mailbox0 b2a_cmd / b2a_dat
for a in 0x03c91040 0x03c91044 0x03c91048 0x03c9104c 0x03c91050 0x03c91054 0x03c91058; \
  do devmem $a 32; done                 # bootmarks BM_RESET..BM_RUN + A0–A5
devmem 0x03c90000 32                    # 心跳(爬升 = 存活)
devmem 0x03c90004 32 ; devmem 0x03c90008 32   # diag state / detail
devmem 0x03c91000 32                    # 0x0BADF00D = HardFault,0 = 无故障
tail /tmp/hb.log                        # hb 轮询日志(S05hbmon,临时)

# rpmsg 链路
ls -l /dev/ttyRPMSG0
m0ping --count 100
```

诊断块内存图(DDR,A7 可读):`HBASE 0x03c90000`(hb)、`DIAG_STATE 0x03c90004`、
`DIAG_DETAIL 0x03c90008`;`FAULT_BASE 0x03c91000`;`BM_BASE 0x03c91040`(boot_prog
1..7 = BM_RESET..BM_RUN,A0–A5 @ +4..+24)。语义和固件侧标记见 `firmware/mcu/` 和
[amp.md](amp.md)。

---

## 9. 交叉引用

- [amp.md](amp.md) —— AMP 设计(FIT、u-boot 释放路径、内存图、M0 responder、
  RT-Thread、m0ping)。
- [ab-boot-nand.md](ab-boot-nand.md) —— NAND A/B 设计(布局、启动流程、工具)。
- [test-record-amp-ota.md](test-record-amp-ota.md) —— eMMC 验证床,包括 M0 固件在这里
  修复的 `A2B_INTEN` 根因。
