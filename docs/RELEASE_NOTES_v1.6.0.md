PodSync v1.6.0 — 首个公开版本
============================

macOS 上把「下载音乐 → 整理 → 一键同步进 iPod」串起来的桌面 App。
支持原厂固件与 Rockbox / CrazyPod，一份 ALAC 曲库两边通用。

## 亮点

### 下载与试听
- 云音乐 / QQ音乐 / 酷狗 搜索，多音质（无损 / 极高 320k / 标准 / Hi-Res）
- 双击在线试听完整曲目，可拖动进度、调节音量（联动 macOS 系统音量）
- 分页（每页 50 条 + 页码）、勾选框、全选 / 清除 / 下载选中 (N)
- 下载队列（未完成 / 已完成）、断点续传、失败重试、实时进度

### 我喜欢的音乐
- 搜索 / 专辑 / 播放条 / 历史里任意歌曲点 ☆ 收藏
- 右侧 Liquid Glass「音乐库」抽屉：我喜欢 / 历史；支持搜索收藏、全部试听、全部下载、清空
- 点搜索页内容自动收起抽屉（⌘L 重新打开）

### 歌手 / 专辑
- 右键「查看 歌手名」：直接在下载页列出该歌手全部歌曲
  （别名深翻页 + 专辑补全，周杰伦约 290+ 首，缓存 12 小时）
- 右键「查看整张专辑」

### 同步与设备
- 插入 iPod 自动识别型号 / 容量；曲库表格（歌名/歌手/专辑/状态/时长 + 封面）
- 勾选同步 / 全选 / 反选；按歌手、专辑筛选与搜索
- 同步自动转 ALAC 16/44.1 写入 `iPod_Control/Music/F00`，重建 iTunesDB + ArtworkDB，
  重置 CrazyPod 曲库缓存，清空收件箱
- 重复曲目提示；「清理已删除歌曲」；安全推出 / 重新挂载
- 歌词写入 iTunesDB（libgpod 歌词补丁）

### macOS 集成
- 接入系统「正在播放」：控制中心 / 菜单栏多媒体卡片、键盘媒体键、耳机线控
- 中 / 英双语、跟随系统深浅色、封面大小、单份 ALAC 曲库开关

## 系统要求

- macOS 14.0+，**Apple Silicon（arm64）**
- 一台 iPod（原厂固件 / Rockbox·CrazyPod，FAT32）

## 安装

1. 下载 `PodSync-macOS-arm64.zip`
2. 解压后把 `PodSync.app` 拖进「应用程序」
3. 首次打开：**右键 → 打开 → 打开**；若提示「已损坏」：
   `sudo xattr -dr com.apple.quarantine "/Applications/PodSync.app"`

校验（SHA256）：

```
c7e6d59e2109eb3b5270eeb28ec07d4ee142ab42a1edd86ecf26425fe22518a9  PodSync-macOS-arm64.zip
```

## 已知限制

- 仅 macOS 14+ / Apple Silicon；未做 Apple 公证，首次需右键打开
- 音乐站点只有搜索接口（单关键词约 275 条上限），「歌手全部歌曲」受站点索引限制
- 第三方站点可能限流/失效；搜索/下载走其 HTTP 接口
- 会写入 iPod 数据库，操作前请备份设备

## 许可证与致谢

- 项目代码 **GPL-3.0-or-later**；第三方组件见 `THIRD_PARTY_NOTICES.md` 与 `licenses/`
- 内嵌：FFmpeg（GPL）、libgpod/libplist/GLib（LGPL）、mutagen（GPL-2.0+）、Python（PSF）
- 设备剪影图为项目自绘（CC0）；SF Symbols 来自系统

## 免责声明

仅用于备份/整理你合法拥有的音乐。下载内容版权归原权利人；
「iPod」是 Apple Inc. 商标，本项目与 Apple 无关。
