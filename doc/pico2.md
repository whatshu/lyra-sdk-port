# 在 Luckfox Lyra 上调试与控制 Raspberry Pi Pico 2 (RP2350)

Luckfox Lyra Ultra W 既可以作为**调试器**(通过其 RMIO 排针、由 OpenOCD 驱动的 bit-banged SWD),也可以作为外部 Raspberry Pi Pico 2(RP2350,Cortex-M33)的**通信主机**(SPI master)。

该固件是一个**独立的板级变体** — `lyra-ultra-w-emmc-pico2`,它是默认 `lyra-ultra-w-emmc` 板配置的一个分支。默认的 eMMC 板**不**包含任何 pico2 相关组件(没有 spidev 节点,没有 openocd,没有辅助脚本)。

## 构建 pico2 固件

```sh
make build   BOARD=lyra-ultra-w-emmc-pico2     # full build -> out/firmware/
make release BOARD=lyra-ultra-w-emmc-pico2     # full build + immutable RELEASE/ snapshot
```

板配置 `config/boards/lyra-ultra-w-emmc-pico2.mk` 与默认的 emmc 配置逐字节相同,只是它选择了 pico2 设备树和 pico2 的 buildroot defconfig,并且在构建时将板级 rootfs overlay 合并进来(见下文)。

## 接线 — Luckfox Lyra Ultra W ↔ Pico 2

两侧都是 **3.3 V** 逻辑电平 — 无需电平转换。Pico 2 使用其自带的 5 V/USB 电源供电(**不要**从 Lyra 排针反向馈电)。保持导线尽量短(< 10–20 cm),并共用同一个 GND。

| 功能 | Luckfox RMIO 引脚 | Luckfox GPIO | sysfs# | Pico 2 引脚 |
|---|---|---|---|---|
| SPI1 CLK | RMIO8 | GPIO0_PB0 | (复用为 SPI) | SPI SCK |
| SPI1 MOSI | RMIO9 | GPIO0_PB1 | (复用为 SPI) | SPI TX / MOSI |
| SPI1 MISO | RMIO10 | GPIO0_PB2 | (复用为 SPI) | SPI RX / MISO |
| SPI1 CS0 | RMIO14 | GPIO0_PB6 | (复用为 SPI) | SPI CS |
| SWD SWCLK | RMIO24 | GPIO1_PB1 | 41 | Pico 2 调试焊盘 **SWCLK** |
| SWD SWDIO | RMIO25 | GPIO1_PB2 | 42 | Pico 2 调试焊盘 **SWDIO** |
| SWD (spare) | RMIO26 | GPIO1_PB3 | 43 | *(空闲;RP2350 无 SRST)* |
| GND | GND | — | — | Pico 2 GND(调试焊盘 **GND** / 引脚 28) |

> Pico 2 的 3 引脚调试连接器顺序为 **SWCLK – GND – SWDIO**(与 Pico 1 相同)。
> 在 RP2350 上,SWD 引脚是专用的封装引脚,因此它们与 40 引脚排针上的
> GPIO2/GPIO3 相互独立(与 RP2040 不同)。

物理位置:RMIO 标注印在 Lyra 排针的丝印上 — 拿到板子后请对照 [Luckfox Lyra Pinout](https://wiki.luckfox.com/Luckfox-Lyra/Pinout/)
(Ultra/Ultra W 标签页)进行核实。

## 构建提供的内容

- `/dev/spidev1.0` — RMIO8/9/10/14 上的 SPI1 master(默认 1 MHz),已在 pico2 板级设备树中启用(`product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts`)。
- `openocd` — 以 `--enable-sysfsgpio` 和 RP2350 目标支持构建的 OpenOCD(锁定快照 `88b9bd396`,v0.12.0-1240)。
- `/etc/openocd/pico2.cfg` — 在 sysfs GPIO 41/42 上进行 SWD bit-bang。
- `/usr/bin/pico2` — 辅助脚本:`flash`、`halt`、`run`、`reset`、`info`。
- `/usr/bin/pico2-spi-demo.py` — python-spidev 回环自检脚本。

## 使用调试器(在 Lyra 上通过 USB 网络运行)

将 USB-C 插入 Linux 主机 — gadget 会暴露一个 CDC-ECM 链路和一个 DHCP 服务器,因此主机会自动配置(例如 192.168.123.x)。直接 SSH 到设备:

```sh
ssh root@192.168.123.100             # password: luckfox

# connect and list targets
pico2 info

# halt / reset / run
pico2 halt
pico2 reset
pico2 run

# flash an ELF/hex/bin (bit-banged SWD is slow — small images only)
pico2 flash /path/to/hello.elf

# interactive GDB server on the Lyra (openocd -c 'gdb_port 3333'), then from a host:
#   gdb-multiarch hello.elf
#   (gdb) target remote <lyra-ip>:3333
```

注意事项:

- OpenOCD 通过 `/sys/class/gpio` 进行 bit-bang,因此必须以 root 身份运行(`pico2` 辅助脚本在 Lyra 上由 root 调用)。
- 以 `adapter speed 100`(kHz)起步;如果初始连接失败,请在 `/etc/openocd/pico2.cfg` 中降到 `50`/`10` kHz。瓶颈是 sysfs bit-bang,而不是 RP2350。
- 通过 bit-bang 烧写 RP2350 较慢(数分钟)— 适合调试/轻量烧写。
- 如果探测失败并报错 `Require swclk and swdio gpio for SWD mode`,说明 adapter 块使用了 `adapter gpio swclk/swdio` — 该语法属于(此处未编译的)linuxgpiod 驱动。此 sysfsgpio 构建注册了自己的命令:`sysfsgpio swclk_num <n>` / `sysfsgpio swdio_num <n>`。

## SPI 通信

SPI 演示脚本在本地短接 MOSI↔MISO,以验证总线工作正常:

```sh
# on the Lyra: short RMIO9 to RMIO10 with a jumper, then:
pico2-spi-demo.py
# -> "OK: MOSI and MISO are shorted (loopback)"
```

对于真正的双向通信,请将 SPI 引脚连接到 Pico 2 SPI 从设备,并使用 `python3 -c 'import spidev; ...'` 或任何 `/dev/spidev1.0` 的消费者。`python3` 和 `python-spidev` 已包含在 rootfs 中。

## 芯片版本(安全)

广为人知的 RP2350 安全启动漏洞针对 **A2** 步进(`SYSINFO_CHIP_ID` = `0x20004927` — 即 DEF CON 2024 "RP2350 破解挑战赛"的芯片)。更新的芯片不受影响。可通过 SWD 检查一块板子:

```sh
# on the Lyra, with the Pico 2 wired:
openocd -f /etc/openocd/pico2.cfg -c init -c halt \
  -c 'mdw 0x40000000 1' -c 'mdw 0x00000010 1' -c shutdown
```

- `0x40000000`(SYSINFO_CHIP_ID):`0x30004927` → revision 半字节 `0x3` = **A3** 步进(`0x2` = A2,即受影响的那个)。
- `0x00000013`(bootrom 版本字节):`0x04` → **bootrom v4**。A3 硬件 + v4 bootrom 就是社区所称的 "A4" 版本。

本特性使用的参考板是 **A3 + bootrom v4** — 而非受影响的 A2。

## 如何接入 SDK

所有 pico2 相关组件都限定在 `lyra-ultra-w-emmc-pico2` 板;默认的 `lyra-ultra-w-emmc` 板保留普通 DTS、不含 openocd 的 buildroot defconfig,并且没有 pico2 脚本。

- **板配置** — `config/boards/lyra-ultra-w-emmc-pico2.mk`(默认 emmc 配置的分支)选择 `KERNEL_DTS := rk3506b-luckfox-lyra-ultra-w-pico2` 和 `BUILDROOT_CFG := rockchip_rk3506_luckfox_pico2`。
- **设备树** — `product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts` 是带有 `&spi1` spidev 节点的板级 DTS;FULL 构建会将 `$KERNEL_DTS.dts` 复制到 vendored 树(参见 `stages/20-kernel/run.sh`)。如果只想单独迭代 DTS:`cp product/platform/dts/rk3506b-luckfox-lyra-ultra-w-pico2.dts vendor/rockchip/kernel/arch/arm/boot/dts/ && make kernel BOARD=lyra-ultra-w-emmc-pico2`。
- **Buildroot** — `product/platform/configs/buildroot/rockchip_rk3506_luckfox_pico2_defconfig` 启用 `openocd` + sysfsgpio;vendored buildroot 中的 `openocd`/`jimtcl` 包已升级以支持 RP2350。
- **Rootfs overlay** — 上述 config/helper/demo 位于板级目录 `product/platform/rootfs/overlay-lyra-ultra-w-emmc-pico2/` 中,由 `product/platform/rootfs/post-rootfs.sh` 合并(除了共享的 `overlay/` 之外,它还会为当前激活的板应用 `overlay-$TARGET`)。
