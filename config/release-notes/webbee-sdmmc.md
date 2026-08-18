# Luckfox Pico WebBee — SD 卡启动 (RV1103)

`webbee-sdmmc`:对应官方
`BoardConfig-SD_CARD-Buildroot-RV1103_Luckfox_Pico_WebBee-IPC.mk` 的
shu-sdk 移植。 分区布局与 pico-ultra 相同,但 SD 卡上设备节点为
mmcblk1,`sys_bootargs=root=/dev/mmcblk1p7 rootfstype=ext4
rk_dma_heap_cma=1M`。

## 使用
- 串口控制台:USB 串口,1500000 8N1(ttyFIQ0)。
- SSH:`root@<设备IP>`,密码 `luckfox`。

## 硬件验证状态
- 待用户配合实测。
