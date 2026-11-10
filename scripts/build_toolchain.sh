#!/usr/bin/env bash
# 构建 libplist + 打了歌词补丁的 libgpod + itdbwrite
#
# 依赖（Homebrew）：pkg-config glib gdk-pixbuf gettext autoconf automake libtool
#   brew install pkg-config glib gdk-pixbuf gettext autoconf automake libtool
#
# 用法：
#   ./scripts/build_toolchain.sh [安装目录]
#   默认安装到 ./build/toolchain（libgpod 在 <dir>/lib，头文件在 <dir>/include）
#   可用环境变量指定本地源码包：
#     LIBPLIST_TARBALL=/path/libplist-2.2.0.tar.bz2
#     LIBGPOD_TARBALL=/path/libgpod-0.8.3.tar.bz2
#   否则自动从 GitHub / SourceForge 下载（见下方 URL）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-$HERE/build/toolchain}"
WORK="$HERE/build/work"
LIBPLIST_VERSION="${LIBPLIST_VERSION:-2.2.0}"
LIBGPOD_VERSION="${LIBGPOD_VERSION:-0.8.3}"
LIBPLIST_URL="${LIBPLIST_URL:-https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2}"
LIBGPOD_URL="${LIBGPOD_URL:-https://downloads.sourceforge.net/project/gtkpod/libgpod/$LIBGPOD_VERSION/libgpod-$LIBGPOD_VERSION.tar.bz2}"

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

fetch() {  # fetch <url> <tarball> <expected-top-dir>
  local url="$1" tarball="$2" top="$3"
  if [ ! -f "$tarball" ]; then
    echo "== 下载 $(basename "$tarball") =="
    curl -fL --retry 3 -o "$tarball.part" "$url"
    mv "$tarball.part" "$tarball"
  fi
  rm -rf "$top"
  tar -xjf "$tarball"
}

# ---------- 1) libplist ----------
LIBPLIST_TARBALL="${LIBPLIST_TARBALL:-$WORK/libplist-$LIBPLIST_VERSION.tar.bz2}"
fetch "$LIBPLIST_URL" "$LIBPLIST_TARBALL" "libplist-$LIBPLIST_VERSION"
cd "libplist-$LIBPLIST_VERSION"
[ -f configure ] || autoreconf -fi >/dev/null
./configure --prefix="$PREFIX/libplist" --without-cython >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
cd "$WORK"
# libgpod 0.8.3 的 pkg-config 依赖名是 libplist（不是 libplist-2.0），补一个别名
sed 's/^Name:.*/Name: libplist/' "$PREFIX/libplist/lib/pkgconfig/libplist-2.0.pc" \
  > "$PREFIX/libplist/lib/pkgconfig/libplist.pc"
echo "✓ libplist $LIBPLIST_VERSION -> $PREFIX/libplist"

# ---------- 2) libgpod + 歌词补丁 ----------
LIBGPOD_TARBALL="${LIBGPOD_TARBALL:-$WORK/libgpod-$LIBGPOD_VERSION.tar.bz2}"
fetch "$LIBGPOD_URL" "$LIBGPOD_TARBALL" "libgpod-$LIBGPOD_VERSION"
cd "libgpod-$LIBGPOD_VERSION"
patch -p1 -s < "$HERE/patches/libgpod-0.8.3-lyrics.patch"
# libgpod 的 configure 需要 intltool；macOS 上常常没有，用假脚本绕过（只影响翻译）
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
for t in intltool-extract intltool-merge intltool-update; do
  printf '#!/bin/sh\ncase "$1" in --version) echo "intltool (fake) 0.51.0";; esac\nexit 0\n' > "$FAKEBIN/$t"
  chmod +x "$FAKEBIN/$t"
done
PATH="$FAKEBIN:$PATH" \
PKG_CONFIG_PATH="$PREFIX/libplist/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
./configure --prefix="$PREFIX" --without-python --disable-mono --disable-gtk-doc >/dev/null
# 只编译 src（tools/ 里的 ipod_set_info 使用 macOS 已移除的 umount()，与本项目无关）
make -C src -j"$(sysctl -n hw.ncpu)" >/dev/null
make -C src install >/dev/null
echo "✓ libgpod $LIBGPOD_VERSION（含歌词补丁）-> $PREFIX/lib"

# ---------- 3) itdbwrite ----------
PKG_CONFIG_PATH="$PREFIX/libplist/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
cc -O2 -o "$PREFIX/bin/itdbwrite" "$HERE/itdbwrite.c" \
  -I"$PREFIX/include/gpod-1.0" \
  $(pkg-config --cflags glib-2.0 gobject-2.0 gdk-pixbuf-2.0) \
  -L"$PREFIX/lib" -lgpod \
  -L"$PREFIX/libplist/lib" -lplist-2.0 \
  $(pkg-config --libs glib-2.0 gobject-2.0 gdk-pixbuf-2.0) \
  -Wl,-rpath,"$PREFIX/lib" -Wl,-rpath,"$PREFIX/libplist/lib"
echo "✓ itdbwrite -> $PREFIX/bin/itdbwrite"
echo
echo "完成。接下来可运行：./scripts/build_ffmpeg.sh 与 ./scripts/build_python_runtime.sh"
