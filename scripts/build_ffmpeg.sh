#!/usr/bin/env bash
# 把 Homebrew 的 ffmpeg/ffprobe 及其动态库打包进 runtime/ffmpeg（重写加载路径）
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BREW="${BREW:-/opt/homebrew}"
command -v "$BREW/bin/ffmpeg" >/dev/null 2>&1 || command -v ffmpeg >/dev/null 2>&1 || {
  echo "缺少 ffmpeg，请先: brew install ffmpeg" >&2; exit 1; }
FFMPEG="$(command -v ffmpeg)"; FFPROBE="$(command -v ffprobe)"
[ "$(uname -m)" = "arm64" ] || echo "⚠ 当前不是 arm64，产出的运行时只适用于本机架构"

rm -rf "$HERE/runtime/ffmpeg"
mkdir -p "$HERE/runtime/ffmpeg/bin"
python3 "$HERE/tools/bundle_deps.py" "$HERE/runtime/ffmpeg" "$HERE/runtime/ffmpeg/bin" "$FFMPEG" "$FFPROBE"
"$HERE/runtime/ffmpeg/bin/ffmpeg" -version | head -1
echo "✓ runtime/ffmpeg 就绪"
