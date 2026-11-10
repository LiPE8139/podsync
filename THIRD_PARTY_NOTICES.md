# 第三方组件与许可（Third-Party Notices）

PodSync 自身代码以 **GPL-3.0-or-later** 发布（见 `LICENSE`）。
App 分发包与 `runtime/` 中内嵌了下列第三方组件，分发时一并遵守它们的许可证。
完整许可证文本放在 [`licenses/`](licenses/)。

## 一、内嵌进 App 的组件（随 release zip 一起分发）

| 组件 | 版本 | 许可证 | 位置 | 说明 |
| --- | --- | --- | --- | --- |
| FFmpeg / ffprobe | 9.0.2（Homebrew 构建，`--enable-gpl --enable-version3`） | GPL-3.0-or-later（含 GPLv2 组件） | `runtime/ffmpeg/` | 含 libx264、libx265、libsvtav1、libvpx、libdav1d、libmp3lame、libmpg123、libopus、libvmaf 等 |
| libgpod | 0.8.3 + 本项目歌词补丁 | LGPL-2.1-or-later | `runtime/itdb/lib/libgpod.4.dylib` | 补丁见 `patches/libgpod-0.8.3-lyrics.patch` |
| libplist | 2.2.0 | LGPL-2.1-or-later | `runtime/itdb/lib/libplist-2.0.3.dylib` | |
| GLib / GObject / GIO / GModule | 2.90.x（构建时 Homebrew 版本） | LGPL-2.1-or-later | `runtime/itdb/lib/` | |
| gdk-pixbuf | 2.44.x | LGPL-2.1-or-later | `runtime/itdb/lib/` | |
| gettext (libintl) | 1.0 | LGPL-2.1-or-later | `runtime/itdb/lib/libintl.8.dylib` | |
| pcre2 | 10.49 | BSD-3-Clause | `runtime/itdb/lib/libpcre2-8.0.dylib` | |
| libpng | 1.6.59 | libpng-2.0 | `runtime/itdb/lib/libpng16.16.dylib` | |
| libjpeg-turbo | 3.2.1 | BSD-3-Clause / IJG | `runtime/itdb/lib/libjpeg.8.dylib` | |
| libtiff / libwebp / xz / zstd | 构建时 Homebrew 版本 | libtiff / BSD / 0BSD+LGPL / BSD | `runtime/ffmpeg/lib/` | FFmpeg 的传递依赖 |
| OpenSSL (libssl/libcrypto) | 3.5.x | Apache-2.0 | `runtime/ffmpeg/lib/` | |
| libopus / libvpx / libdav1d / libSvtAv1Enc / libvmaf / libmp3lame / libmpg123 | 构建时 Homebrew 版本 | BSD / BSD / BSD / BSD / BSD / LGPL-2.1 / LGPL-2.1 | `runtime/ffmpeg/lib/` | 许可文本见各上游仓库 |
| Python | 3.12.16（[python-build-standalone](https://github.com/astral-sh/python-build-standalone)） | PSF-2.0 | `runtime/python/` | 已移除 pip/setuptools |
| mutagen | 1.48.1 | **GPL-2.0-or-later** | `vendor/mutagen/`（源码随包） | Python 脚本 `import mutagen`，因此 `*.py` 以 GPL 兼容方式发布 |

> FFmpeg 与 mutagen 是 GPL 组件。本项目的 `runtime/ffmpeg` 是独立可执行程序，`gui/`（Swift）
> 不链接 GPL 代码；但 `ipodtune.py` / `ipodsync.py` / `coco.py` 通过 `import mutagen` 使用
> GPL 库，因此这些脚本按 GPL-3.0-or-later 发布，整仓库采用同一许可证以避免歧义。

## 二、如何获取对应源代码 / 重建同样的二进制

所有打包步骤都在 `scripts/` 下（每个组件都会记录版本与构建参数）：

- `scripts/build_toolchain.sh`：libplist 2.2.0 + libgpod 0.8.3（`patches/` 补丁）+ `itdbwrite`
- `scripts/build_ffmpeg.sh`：用 Homebrew 的 ffmpeg/ffprobe 收集依赖并重写加载路径
- `scripts/build_python_runtime.sh`：下载 python-build-standalone 3.12
- `scripts/build_runtime.sh`：以上三步 + 依赖打包

FFmpeg 对应源码：按 `ffmpeg -version` 输出的 `configuration:` 行在 <https://ffmpeg.org/download.html>
或 Homebrew formula 取相同版本（9.0.2_1）源码，用同样的 `--enable-gpl --enable-version3` 参数构建即可。
libgpod/libplist/glib 等 LGPL 组件的源码同样可按 `scripts/build_toolchain.sh` 中的版本与补丁重建；
如需逐字节对应的源码包，请提交 issue，我们会提供 tarball。

## 三、项目原创素材

- `gui/assets/ipod*.png`（App 内设备剪影图）由 [tools/make_ipod_assets.py](tools/make_ipod_assets.py)
  用 Pillow 绘制，**项目原创，CC0-1.0（公有领域贡献）**，不含任何厂商产品照片/Logo。
- `tools/AppIcon.icns` 为本项目 App 图标（作者提供）。
- UI 中的 SF Symbols 图标来自系统字体，按 Apple 的 SF Symbols 许可在 Apple 平台 App 内使用。

## 四、Apple 相关

- SF Symbols 为 Apple 提供给 Apple 平台 App 使用的系统图标。
- 「iPod」是 Apple Inc. 的商标。本项目仅用于说明兼容设备，与 Apple 无任何隶属关系。
