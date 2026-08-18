# Luckfox Pico WebBee — SPI NAND (RV1103)

`webbee-spinand`:对应官方
`BoardConfig-SPI_NAND-Buildroot-RV1103_Luckfox_Pico_WebBee-IPC.mk` 的
shu-sdk 移植。

## 镜像构成
- SPI NAND 官方分区布局:`256K(env) / 256K@256K(idblock) / 512K(uboot) /
  4M(boot) / 30M(oem) / 6M(userdata) / 85M(rootfs)`,经 env.img 携带;
  `sys_bootargs=ubi.mtd=6 root=ubi0:rootfs rootfstype=ubifs
  rk_dma_heap_cma=1M`。
- rootfs 为 ubifs(官方几何:128KiB block / 2KiB page / lzo,动态卷
  `rootfs` + autoresize);精简核心包集,另含 mtd 工具。
- update.img 按官方流程打包(RK1106 标记)。

## 使用
- 串口控制台:USB 串口,1500000 8N1(ttyFIQ0)。
- SSH:`root@<设备IP>`,密码 `luckfox`。

## 硬件验证状态
- 待用户配合实测(WebBee 未直接连接开发机)。
