# Luckfox Pico Ultra — eMMC (RV1106G3)

`pico-ultra`:基于官方 `BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Ultra-IPC.mk`
移植到 shu-sdk stage 模式的第一块 Pico 板卡。 各组件精确源码版本见
`release.xml`,仅凭该 manifest 即可复现整个构建。

## 镜像构成
- 官方同款分区布局,由 env.img 携带:`32K(env) / 512K@32K(idblock) /
  256K(uboot) / 32M(boot) / 512M(oem) / 256M(userdata) / 6G(rootfs)`。
  SPL idblock 启动时从 env 分区读分区表和 `sys_bootargs`
  (`root=/dev/mmcblk0p7 rootfstype=ext4 rk_dma_heap_cma=66M`)。
- **精简核心 rootfs**(纯 buildroot):ssh、python3、e2fsprogs、lrzsz、
  nano、htop、iperf3。 不含 media/app/wifi 组件;oem/userdata 为空文件
  系统(保留官方布局)。
- update.img 按官方 mk-update_pack.sh 流程打包(rkImageMaker -RK1106),
  `make flash BOARD=pico-ultra` 一键烧写(需板卡处于 loader/maskrom 模式)。

## 使用
- 串口控制台:USB 串口,1500000 8N1(ttyFIQ0,内核 fiq-debugger)。
- SSH:`root@<设备IP>`,密码 `luckfox`。

## 硬件验证状态
- 待验证(构建完成后烧写实测)。

## 已知限制
- oem/userdata 为空(官方镜像里存放 app/媒体内容,精简核心不构建)。
- 无线(WiFi/BT)未启用;如需无线能力请用官方 luckfox_pico 镜像。
