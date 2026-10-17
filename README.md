# MPV Portable Configuration

专为 **4K 高码率流媒体、极简纯净性能流与高效视频处理** 深度定制的 MPV 独立配置套件。

[![GPU](https://img.shields.io/badge/GPU-AMD%20Radeon%20RX%209070%20XT-ED1C24?style=flat-square&logo=amd&logoColor=white)](https://amd.com)
[![CPU](https://img.shields.io/badge/CPU-Intel%20Core%20i9--13900F%20(24C)-0071C5?style=flat-square&logo=intel&logoColor=white)](https://intel.com)
[![RAM](https://img.shields.io/badge/RAM-32%20GB-gray?style=flat-square)](https://github.com)
[![Display](https://img.shields.io/badge/Display-雷鸟%20U8%20(4K%20160Hz%20Mini--LED)-FF6F00?style=flat-square)](https://github.com)
[![Audio](https://img.shields.io/badge/Audio-UGREEN%20HiFi%20Amp%20%7C%20abingo-1DB954?style=flat-square)](https://github.com)
[![OS](https://img.shields.io/badge/OS-Windows%2011%20Workstation-0078D4?style=flat-square&logo=windows&logoColor=white)](https://microsoft.com)
[![Storage](https://img.shields.io/badge/Storage-115%20Netdisk%20(CloudDrive2)-2BA3D4?style=flat-square)](https://115.com)

---

## ⚡ 核心配置解析

- **1.5GB 超大解复用缓存**：
  配置 `1024MB` 前向预读与 `512MB` 后向回退缓存（`demuxer-max-bytes`），专为本地高码率 4K REMUX、网盘挂载（115 / CloudDrive2 / Alist）及局域网 WebDAV 流媒体调优，大幅降低 Seek 缓冲等待。
- **纯净性能取向**：
  采用 `scale=nearest` 极低开销纯净缩放与 `hwdec=auto-safe` 硬解；移除系统原生标题栏（`title-bar=no`），禁用默认原生粗糙进度条，实现极简沉浸视窗。
- **智能资源索引与状态记忆**：
  拖入目录自动递归扫描媒体文件（`directory-mode=recursive`）并自动生成播放列表；外挂中文字幕与音频模糊匹配（`sub-auto=fuzzy` / `audio-file-auto=fuzzy`）；退出时自动持久化保存断点进度、音轨、字幕延迟与音量状态。
- **窄版极简右键菜单 (`menu.conf`)**：
  宽度较原生菜单收窄 50% 以上，纯原生指令驱动；集成 Deband 去色带、HDR 映射模式（Spline / BT.2446a / Auto）、夜间防打扰（DRC 动态压缩）、对白增强与字幕多预设快速切换。
- **GPU 硬件硬字幕压制 & 无损切片合一 (`cut_and_burn.lua`)**：
  内置全功能音视频处理脚本，支持视频秒级无损切片（自动规避黑帧）、调用 AMD AMF (AV1) / NVENC / QSV 进行 GPU 硬件加速硬字幕压制，以及独立 320k MP3 原声音轨一键提取。

---

## ⌨️ 特色快捷键

> 基础通用按键（空格暂停、方向键快进退、全屏退出等）遵循标准逻辑，以下仅列出专属特色映射：

| 快捷键 | 功能 |
| :---: | :--- |
| `\` | **2.5x 高速略读 / 1.0x 原速** 一键往返切换 |
| `Backspace` | 瞬时恢复 1.0x 原速 |
| `Shift + → / ←` | **精确微调 1 秒**（非模糊跳转，剪辑定位必备） |
| `y` | **原生平滑淡入动效** 一键开启 / 关闭 (`sub-filter-regex`) |
| `U` (`Shift + u`) | 强制覆盖 / 恢复 ASS 特效字幕样式 |
| `c` | 标记切片起点 (A) / 终点 (B) 并秒级无损导出 |
| `C` (`Shift + c`) | 清除当前切片起止点标记 |
| `Ctrl + b` | 调用 GPU 硬件编码器启动 **AV1 硬件硬字幕压制** |
| `Ctrl + e` | 一键抽取当前音轨为独立 320k MP3 |

---

## 📂 仓库结构

```text
portable_config/
├── mpv.conf             # 核心引擎调校 (硬件解码 / 1.5G 缓存 / 递归目录 / 断点音量记忆)
├── input.conf           # 核心快捷键 (倍速往返 / 淡入开关 / 剪辑压制)
├── menu.conf            # 窄版现代右键菜单 (画质 / HDR / DRC / 预设切换)
├── scripts/
│   └── cut_and_burn.lua # 无损切片与 GPU AV1 硬件压制合一脚本
└── README.md
```
