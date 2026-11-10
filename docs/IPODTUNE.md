# ipodtune — iPod Classic / CrazyPod 音乐整理工具（CLI）

> 本文是命令行工具 `ipodtune.py` / `ipodsync.py` 的完整说明。
> 图形界面 App 的说明请看仓库根目录的 [README](../README.md)。
> 文中"三之一、macOS App（图形界面）"一节是早期版本截图与功能，最新界面以 README 为准。

把「**重新填歌曲信息 → 把明显超出 iPod Classic 能力的歌转格式 → 检索封面 → 不确定的告诉你 → 推荐替代封面 → 安全写回**」整条流水线封装成一个命令行工具。

它是为 iPod Classic（6/6.5/7 代，Rockbox / CrazyPod）写的，判定阈值按这台机器的硬件能力来定（16 bit DAC、最高 48 kHz、FAT32 文件系统）。

---

## 一、它到底做哪五件事

| # | 功能 | 说明 |
| --- | --- | --- |
| 1 | **重填歌曲信息** | 用「标题 + 精确时长」去 iTunes 检索，匹配出标题/歌手/专辑/音轨号/年份/流派；MusicBrainz 交叉核对 |
| 2 | **超规格转码** | 采样率 > 48 kHz、位深 > 16 bit、格式不在 CrazyPod 解码器白名单、扩展名与真实格式不符、单文件超 FAT32 上限 → 统一转成 16 bit / ≤48 kHz FLAC（或 320 kbps MP3） |
| 3 | **检索封面** | 从 Apple CDN 取 600×600 封面并嵌入文件（FLAC PICTURE / MP3 APIC）；支持**本地封面文件夹**（`专辑名.jpg` 自动套用）和**歌曲→专辑反查**兜底 |
| 4 | **不确定的告诉你** | 生成 `report.md`：确定 / 存疑 / 未匹配 / 缺封面 / iTunes 与 MusicBrainz 冲突，全部列出 |
| 5 | **推荐替代封面** | 复核时可：给出歌手重新检索、从「同艺人其它专辑」里挑替代封面、指定本地图片、或干脆不要封面 |

> 关键设计：**先分析、再复核、最后才写**。所有写操作都先落在工作目录的 `staging/`，再经 MD5 校验替换，绝不会边扫边改。

---

## 二、什么算「品质明显高于 iPod Classic 能力」

| 判定 | 触发条件 | 处理 |
| --- | --- | --- |
| `rate` | 采样率 > 48000 Hz（如 96k / 192k） | 重采样到 44100/48000 Hz |
| `depth` | 位深 > 16 bit（如 24 bit） | 降到 16 bit |
| `codec` | 不在 {flac, mp3, aac, alac, vorbis, opus, wav, aiff} 内（如 ape / wma / dsd） | 转成 FLAC/MP3 |
| `mislabel` | **扩展名与真实格式不符**（最坑的一种：`.mp3` 里装 FLAC，播放器按扩展名选解码器 → 直接不识别） | 转码并按真实格式命名 |
| `size` | 单文件 > 4 GB（FAT32 上限） | 转码压缩 |
| `to_mp3` | 使用 `--preset mp3` 时的无损源 | 转 320 kbps MP3 |

---

## 三、安装

```bash
cd <本目录>
./bootstrap.sh
```

脚本会：检查/安装 `ffmpeg` + `ffprobe`（Homebrew），把 `mutagen` 装到本地 `vendor/`（不污染系统 Python）。

手动安装也可以：

```bash
brew install ffmpeg
python3 -m pip install --target vendor mutagen
```

要求：macOS + Python 3.9+ + ffmpeg。

---

## 三之一、macOS App（图形界面）

App 有两个页签：**下载音乐**、**同步到 iPod**。

### 下载音乐（COCO 音乐下载站）

- 顶部：搜索框 + 渠道（云音乐 / QQ音乐 / 酷狗）+ 音质（无损 / 极高 320k / 标准 128k / Hi-Res）
- 搜索结果列表显示封面、歌名、歌手/专辑、时长；每行点「下载」即下载到收件箱
- **双击搜索结果即可在线试听完整曲目**：底部出现播放控制条（播放/暂停、可拖动进度条、时间显示、关闭）
  - 实现：拉流解码为本地 WAV 后用 AVAudioPlayer 播放，可任意拖动进度
  - 再双击同一首可暂停/继续；播放结束自动清理临时文件
- **搜索结果分页**：站点接口默认只给 20 条、单页上限 50 条；工具每页取满 50 条，
  页面底部有 **‹ 1 2 3 4 ›** 页码（点数字直接跳页，当前页加粗显示）
- **批量下载**：按住 ⌘/Shift 多选 →「下载选中」；或「下载全部」；右键还可「下载整张专辑」
- **下载队列**：分「未完成 / 已完成」两个页签（分段控件切换），列表带专辑封面
  - 未完成：实时进度条、失败原因、重试全部/清空
  - 已完成：完成时间、右键「重新下载」、在 Finder 中显示、清空已完成
  - 所有下载先进队列并持久化，失败保留可重试；重开 App 自动续传（站点直链支持 HTTP Range）
- **下载进度**：每首歌显示百分比 + 已下载/总大小进度条（下载页行内、底部状态栏、队列页均有）
- 下载时自动：识别真实格式、补写标题/歌手/专辑标签、内嵌封面、**保存同步歌词 `.lrc`**
  （站点返回的音频本身没有标签和封面，这些由工具补齐）
- **下载完就处理好（按最优解规格）**：
  - 最优解 = **ALAC 16bit / 44.1kHz**（原厂与 Rockbox 都原生支持，无需重采样）
  - 超过能力（Hi-Res / >48kHz / >16bit / 不支持的格式）→ 立即转成 ALAC 16/44.1 并删除原文件
  - 补写标签/封面/歌词；同步时遇到已经是 ALAC 16/44.1 的文件直接拷贝，不再二次编码
- 已下载的曲目会打勾；重复下载会提示「已在收件箱」
- 右下角「去同步到 iPod」→ 自动切到同步页并开始同步

> 站点上游偶尔限流（搜索会返回空结果），工具会自动重试；仍然为空就稍等再搜。
> 下载接口失败时会自动改用 `/api/url` 直链兜底。

### 曲库表格（同步页）

- 「待同步曲目」与「同步到 iPod」已合并为一页，用**表格**呈现未同步 + 已同步曲目
- 表头：**歌曲名 / 歌手 / 专辑 / 同步状态 / 时长**，歌曲名前显示**专辑封面缩略图**
- 设备栏仿 iTunes：显示**型号**（如 iPod classic 第 6 代）、**CrazyPod/Rockbox 版本**、**容量条（已用/剩余）**、已同步首数、收件箱待处理首数
- **单份 ALAC 曲库（默认）**：同一份 ALAC 文件同时给 Rockbox 和原厂系统用
  - 位置：`iPod_Control/Music/F00/*.m4a`（原厂只播这个目录；CrazyPod 的曲库扫描也会包含它）
  - 同步：收件箱 → 转 ALAC 写入 F00 → 重建 iTunesDB → 重置 CrazyPod 缓存 → 清理收件箱（不再生成 MP3 镜像）
  - 设置 → 同步 →「单份 ALAC 曲库」可关闭（回退双份模式：`/Music` FLAC + 原厂 MP3）
  - 仅保留 **一份音频**，比双份模式省约 30–40% 空间
- 自动重置 CrazyPod 的曲库缓存（`.crazypod/cache/music-library.bin`），下次开机 Rockbox 会重建曲库、新歌可见
- 「更多 → 刷新 Rockbox 曲库缓存」可手动触发（会先备份缓存到 `sync-work/crazypod-cache-backup/`）
- 设备名后面有「**推出**」按钮：会**整盘弹出**（设备断电，可拔线）；同步中禁用
- 只卸载没弹出时，设备栏显示「iPod（已推出）」并提供「**挂载**」按钮，可随时重新挂载
- 设备状态每 4 秒自动刷新，插拔/挂载后界面自动更新
- 自动忽略 `.` / `._` 开头的隐藏文件（macOS 在 FAT32 上生成的资源文件不会被当成歌曲）
- **勾选同步**：表格多选 →「同步选中」（只同步未同步的）；工具栏/菜单有 **全选 / 反选 / 同步全部未同步**
- **筛选**：工具栏按 **歌手**、**专辑** 下拉筛选
- **搜索**：`.searchable` 支持按 **歌名 / 歌手 / 专辑** 模糊匹配（与筛选可叠加）
- 日志放在工具栏「日志」弹窗里，不占主界面

### 同步到 iPod

- 显示 iPod 连接状态、收件箱路径/待处理数、已同步数
- 一键同步 / 刷新状态 / 打开收件箱 / 选择收件箱 / 清空日志；「更多」里可切换工具目录
- 实时日志；完成后顶部横幅显示「新增 / 跳过 / 疑似重复 / 失败」
- 有疑似重复时**自动弹出重复清单窗口**（歌名/歌手/源文件），可一键打开收件箱处理
- 设置里可开启「同步完成后自动推出 iPod」
- 「更多 → 清理已删除歌曲…」：移除文件已不存在的曲目记录、删除 iPod 上的孤儿文件、重建原厂数据库
  （Rockbox 的 `/Music` 与 `.crazypod` 不受影响；GUI 会先弹确认框）
- App 自带图标（编译时由 `tools/make_icon.swift` 生成 `AppIcon.icns`）

> 界面按 macOS 原生准则搭建：侧边栏 `NavigationSplitView` + `List`/`GroupBox`/`Form`、
> 语义字号与系统色、`Settings` 场景、完整菜单栏（⌘R 同步、⇧⌘⌫ 清理）、
> 空态用 `ContentUnavailableView`，无自绘卡片/渐变/硬编码颜色。
> 首次双击若提示「无法验证开发者」：Finder 右键 → 打开。

## 三之二、一键增量同步（日常最省事）

把新下载的音乐丢进固定收件箱，双击脚本即可增量同步到 iPod（Rockbox + 原厂两套都更新）：

```
收件箱：~/Music/iPod-Inbox
一键：  双击本目录里的「一键同步.command」
命令行：python3 ipodsync.py sync
```

流程：

1. 扫描收件箱（支持 flac / mp3 / m4a / aac / wav / aiff / ogg / opus …）
2. **查重**：文件指纹相同的直接跳过；标题+歌手+时长相近的会提示「疑似重复」并跳过（`--force` 可强制加入）
3. 转码：Rockbox 侧保留/转成 16bit·44.1kHz FLAC（无损）；原厂侧生成 MP3 320k 镜像
4. 封面：优先用文件内嵌图；没有就按「歌名+时长」在线找一张；都没有会提示
5. 写库：原厂侧重建 `iTunesDB` + `ArtworkDB`（只更新数据库，不重拷已有歌曲）
6. 输出「新增 / 跳过 / 重复 / 失败」清单

常用：

```bash
python3 ipodsync.py status            # 看收件箱待处理数量、已同步数量
python3 ipodsync.py sync --dry-run    # 预演，不写任何文件
python3 ipodsync.py sync --force      # 疑似重复也强制加入
```

配置在 `ipodsync.json`（首次运行自动生成）：收件箱路径、是否写 Rockbox/原厂、MP3 码率、同步后是否自动推出。
临时覆盖可用环境变量：`IPODSYNC_INBOX` / `IPODSYNC_MOUNT`。

## 三之三、曲库到底用哪个系统管理？

**结论：日常以 CrazyPod 为主库，原厂系统当"兼容镜像"；管理动作只通过「收件箱 + 本工具」做，不要用 iTunes 手动管理。**

| | CrazyPod / Rockbox | 原厂（Apple） |
|---|---|---|
| 曲库位置 | `/Music`（FLAC 无损） | `iPod_Control/Music`（MP3 320k 镜像） |
| 索引 | 开机自动扫描，随便增删文件 | `iTunesDB`（本工具重建，**不要用 iTunes 改**） |
| 支持格式 | 几乎全格式、支持无损高规格（工具会自动降到 16bit/44.1k） | 仅 MP3/AAC/ALAC/WAV/AIFF；不支持 FLAC |
| 管理方式 | 放文件/删文件即可 | 靠工具重建数据库 |
| 风险 | 低（文件在就丢不了） | 数据库被 iTunes 覆盖/恢复会清 Rockbox |

所以：

- **加歌**：音乐丢进收件箱 → 双击「一键同步.command」→ 安全推出后重启。
- **听歌**：优先用 CrazyPod（无损、格式全、封面/歌词都能用）；想在苹果原界面听就按住 Menu 进原厂固件，两边是同一批歌。
- **删歌**：从 `/Music` 和 `iPod_Control/Music` 删掉对应文件，然后重跑一次同步（会重建原厂数据库）；CrazyPod 下次开机自动重扫。
- **不要**在这台 iPod 上点 iTunes/Finder 的「恢复」或让 iTunes 自动同步——那会重新格式化并破坏 Rockbox。
- 两套系统的播放列表、评分、播放次数互不相通，只是共享同一批音频文件。

## 四、快速开始（5 步）

```bash
# 0) 现在的工作目录（默认 .ipodtune，可以 -w 指定）
cd ~/Documents

# 1) 扫描（自动找 iPod 卷的 Music 目录，也可以 -d 指定任意目录）
python3 <本目录>/ipodtune.py scan

# 2) 联网匹配标签 + 封面
python3 <本目录>/ipodtune.py match

# 3) 交互复核：不确定的逐首确认、改歌手、选封面
python3 <本目录>/ipodtune.py review

# 4) 转码 + 打标签 + 嵌封面 → .ipodtune/staging/
python3 <本目录>/ipodtune.py convert

# 5) 安全写回 iPod（自动识别卷、校验 MD5、清缓存、推出）
python3 <本目录>/ipodtune.py apply --device
```

中途随时可以看报告：

```bash
python3 <本目录>/ipodtune.py report
# 或者直接打开 .ipodtune/report.md
```

### 一条龙（不做交互，先看结果）

```bash
python3 <本目录>/ipodtune.py run -d /Volumes/IPOD/Music
```

---

## 五、`review` 交互键

每首不确定的歌会显示：时长/格式、当前匹配、MusicBrainz 提示、封面状态。然后：

| 按键 | 作用 |
| --- | --- |
| `回车` | 接受当前结果 |
| `a` | 你给出**歌手**，按「歌手 + 歌名」重新检索，再从候选里选（这是修正误配最快的方式） |
| `m` | 手动逐项输入 标题/歌手/专辑/音轨号/年份/流派（留空=不改） |
| `c` | 选封面：当前封面 / 当前专辑 / **同艺人其它专辑（替代推荐）** / `p` 指定本地图片 / `s` 不要封面 |
| `s` | 跳过这首（只做格式修正，不写标签和封面） |
| `q` | 保存并退出复核 |

当 iTunes 完全查不到时，会自动用 MusicBrainz 按「歌名 + 时长」补一版候选（标为「可疑」），你确认或改歌手即可。

---

## 六、写回模式与安全机制

```bash
python3 ipodtune.py apply --device      # 自动找 iPod 卷：/Volumes/*/Music（含 .rockbox 或 iPod_Control）
python3 ipodtune.py apply --to ~/out    # 写到普通目录（不会碰原文件）
python3 ipodtune.py apply --inplace     # 覆盖原目录（--backup 先备份原文件）
```

`--device` / `--inplace` 的流程（和手工操作时一致）：

1. 先复制到目标卷内的临时目录（`.ipodtune-new`）
2. 逐个 **MD5 校验**，任何不一致 → 立刻中止，**原文件一个字节都不动**
3. 校验通过才替换；`--device` 还会清理 CrazyPod 的 `music-library.bin`、`artwork.ready`、`CV10` 封面缓存
4. 检查目标剩余空间（不足 1.1 倍直接拒绝）、检查是否 FAT32
5. `sync` + `diskutil eject`（`--no-eject` 可跳过）

写完把卡插回 iPod / 连上数据线，按 **Menu + Center** 约 12 秒重启，首次会全量重扫并生成封面缓存。

加 `--dry-run` 只打印不写入。

---

## 七、工作目录结构

```
.ipodtune/
├── state.json     # 全部状态：探测结果、匹配候选、你的复核决定
├── report.md      # 中文报告（确定/存疑/未匹配/缺封面/推荐）
├── covers/        # 下载/复制的封面图
└── staging/       # 转码+打标后的成品，apply 就写这里
```

`scan / match / review / convert / apply` 可以分多次跑，状态自动保存，随时中断再继续。

---

## 八、预设

| 预设 | 目标 | 适用 |
| --- | --- | --- |
| `flac`（默认） | 16 bit / ≤48 kHz FLAC | 想要无损、空间够（32 GB 卡放 2 小时歌没问题）、CrazyPod 直接播 |
| `mp3` | 320 kbps MP3 | 更省空间/更省电；无损源会转码，有损源保持原样 |

```bash
python3 ipodtune.py scan -d ... --preset mp3
python3 ipodtune.py convert --preset mp3
```

---

## 九、曲库共用：原厂系统 ↔ Rockbox / CrazyPod

**能共用，但两套系统用两套索引，要按它们的规矩放文件。**

| | 原厂（Apple）固件 | Rockbox / CrazyPod |
| --- | --- | --- |
| 读取目录 | `/iPod_Control/Music/F00…F19` | `/Music`（默认）+ `/iPod_Control/Music`（需开启 `设置 → 播放 → Original iPod Music`） |
| 曲库索引 | `iPod_Control/iTunes/iTunesDB`（**必须由 iTunes/Finder 同步生成**，手拖文件不被识别） | 开机扫描自建缓存（音乐库 bin + 封面缓存），可随时重建 |
| 支持格式 | MP3、AAC/M4A、ALAC、WAV、AIFF（**不支持 FLAC/Ogg/Opus**） | 几乎全格式（FLAC、Opus、Ape、WMA…，随 CrazyPod 内置解码器） |
| 高规格 | 不支持 24bit/96k 以上 | 也受硬件限制：16bit / ≤48kHz（本工具负责转） |

### 三种共用姿势

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A. 真·共用一份**（推荐） | 用 iTunes（Windows 上最稳）把 MP3/AAC/ALAC 同步进 iPod → 落在 `/iPod_Control/Music`；CrazyPod 打开 `Original iPod Music` 就能看到同一批歌 | 只能 MP3/AAC/ALAC，FLAC 用不了；iTunes 同步会重建 iTunesDB |
| **B. 双库并存**（当前状态） | `/Music` 放 FLAC/高规格给 CrazyPod；`/iPod_Control/Music` 留给 iTunes 同步的原生库 | 占用两份空间，但互不干扰 |
| **C. 全 MP3 单库** | 全部转 320k MP3（`--preset mp3`），一份给 iTunes 同步（两边都能播），一份留在 `/Music` | 放弃无损 |

### 重要警告（针对你这台机器）

- 你这台数据分区是 **FAT32（Windows 格式）**。在 **macOS** 上让 iTunes/Finder 管理它，很可能提示「已格式化用于 Windows」并要求和「恢复」——**恢复会重新格式化并删除 Rockbox 目录，千万别点**。
- 想在原生系统里加歌，**用 Windows 上的 iTunes 同步**（FAT32 原生支持，只重建 iTunesDB，不动 `.rockbox`）。
- 本工具**不会**写 `iPod_Control/Music`（因为手写文件不更新 iTunesDB，原生系统照样看不到）。正确用法：`--preset mp3` → `apply --to <Mac 目录>` → 用 iTunes 导入那个目录 → 同步到 iPod。
- CrazyPod 读 `/iPod_Control/Music` 是只读扫描，不会碰 iTunesDB，安全。

## 十、数据源与网络

- **iTunes Search API**（主）：标题/歌手/专辑/时长/封面（600×600）
- **MusicBrainz**（交叉核对 + 兜底候选）：修复 iTunes 查不到的曲目（如 RSD 单曲、现场版）
- 封面统一从 Apple CDN 拉取；Cover Art Archive 的图走 `archive.org`，部分网络环境下不可达，工具会优雅跳过并推荐「同艺人替代封面」

离线时：

```bash
python3 ipodtune.py scan -d /Volumes/IPOD/Music
python3 ipodtune.py match --no-network    # 不联网，标题=文件名，只做格式修复
python3 ipodtune.py convert
```

---

## 十一、常见问题

**Q：明明有 47 首歌，播放器只认 1 首？**
大概率是 `.mp3` 里装的 FLAC（或反之）。`scan` 会判为 `mislabel` 并在 `report.md` 里点名。这正是本工具诞生的原因。

**Q：24 bit / 96 kHz / 192 kHz 的歌能播吗？**
iPod Classic 的 DAC 是 16 bit、最高 48 kHz。`scan` 会把它们标成 `rate`/`depth`，`convert` 统一转成 16 bit / 44.1–48 kHz。192 kHz 的 4 分钟歌约 200 MB，转完约 40 MB。

**Q：自动匹配错了怎么办？**
`review` 里按 `a` 输入正确歌手重新检索，或按 `m` 手填。改完 `convert` 重新生成对应文件即可（工具会重写整个 staging，不会重复堆积）。

**Q：为什么有时封面检索很慢或失败？**
封面主源是 Apple CDN（`is1-ssl.mzstatic.com`），国内一般解析到大陆 CDN，最快。Cover Art Archive 的图片实际托管在 `archive.org`，Wikipedia 的封面在 `upload.wikimedia.org` —— 这两个域名在部分网络环境（如大陆直连）会出现 DNS 污染/TLS 重置，导致取不到。此时工具会自动降级为「同艺人替代封面」，你也可以用 `review` 里的 `p` 指定本地图片。若你有代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
python3 ipodtune.py match
```

（Python 的 urllib 与 curl 都会自动读取这两个环境变量；需要 SOCKS5 的话可先装 `pysocks` 再设 `ALL_PROXY`。）

**Q：我想用自己的封面图怎么办？**
两种办法：
1. 丢进 `.ipodtune/local-covers/`（或任意目录用 `--covers` 指定），文件名用 `专辑名.jpg`、`歌手 - 专辑.jpg`、`歌名.jpg` 均可，`match` 时会自动套用；
2. `review` 里按 `c`，选 `p` 临时指定任意图片。

**Q：封面找不到 / 我不喜欢替代封面？**
`review` 按 `c`：可以选同艺人其它专辑、指定本地图片路径（jpg/png）、或不要封面。也可以把图片发给工具用 `p` 指定。

**Q：会不会删我的歌？**
`apply` 只在**所有 MD5 校验通过**后才替换；`--to` 模式完全不碰原目录；`--inplace` 建议加 `--backup`；`--device` 只动 `Music/` 下被替换的同名文件。

**Q：能用在普通 U 盘/电脑目录吗？**
可以，`scan -d <目录>` + `apply --to <目录>`，与 iPod 无关的步骤都能跑。

---

## 十二、源码

```
PodSync.app            # 图形界面版（双击运行）
build_gui.sh          # 重新编译 .app
gui/                  # SwiftUI 界面源码（按视图拆分：RootView/DownloadView/QueueView/SyncView/SettingsView/AppModel/Models/Design）
ipodtune.py           # 整库整理 CLI（扫描/匹配/复核/转码/写回）
ipodsync.py           # 一键增量同步（收件箱 → Rockbox + 原厂）
coco.py               # COCO 音乐下载站 搜索/下载（补标签+封面）
一键同步.command       # 双击运行的入口
itdbwrite.c / itdbwrite   # libgpod 写 iTunesDB + ArtworkDB（增量重建）
itdbdump                  # 回读校验 iTunesDB
apple_share.sh        # 把整份 MP3 曲库一次性写进原厂库（初始化用）
gpod/  libplist/      # 本地编译的 libgpod 依赖（无需 Homebrew 提供）
bootstrap.sh          # 依赖安装
requirements.txt      # mutagen
vendor/               # 本地依赖（bootstrap 生成）
```

自检（会用 ffmpeg 现场造 24/96 FLAC、合规 FLAC、320k MP3、`.mp3` 里装 FLAC 的样本，验证判定与转码链路）：

```bash
python3 ipodtune.py selftest
```

## 十三、已知限制

- 匹配靠「歌名 + 时长（±2 秒）」：同名同长度的不同版本仍可能误判 → 一律进 `review` 清单。
- 只对 FLAC / MP3 写内嵌标签与封面；其它格式会转码成这两种再写。
- 封面只走 Apple CDN（可用性最好）；Cover Art Archive / Wikipedia 视网络策略可能不可用。
- 目标卷必须是 FAT32（HFS+/APFS 的 iPod 无法启动 Rockbox）。
- 工具不安装/不修改 bootloader，只替换 `Music/` 下的音乐文件。
