# 固件

本项目验证使用的 LuatOS 官方固件（合宙原厂发布，随仓库提供方便直接烧录）：

| 文件 | 适用模组 | 说明 |
|------|----------|------|
| `LuatOS-SoC_V2050_Air780EHV_101.soc` | Air780EHV | 101 号 64 位固件（V2050，2026-08-21 构建），含 TTS + VoLTE，脚本区 512KB / fs 分区 768KB |

## 烧录

1. 用 Luatools 的「固件与工具」选择本目录的 `.soc` 文件刷入底层固件；
2. 再用「项目管理」选择仓库根目录的 `script/` 文件夹烧录脚本；
3. 串口查看运行日志（首次使用需先按 README 配置 `script/config.lua`）。

## 说明

- 固件为合宙开源的 LuatOS 构建，以原样（as-is）形式随仓库分发，版权归属合宙/OpenLuat；
- 如需其他固件版本（如非 TTS 的精简版），请到[合宙固件仓库](https://gitee.com/openLuat/luatos-soc-2023/releases)自行下载。
