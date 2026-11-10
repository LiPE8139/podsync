#!/usr/bin/env bash
# 依赖安装脚本：ffmpeg/ffprobe + mutagen
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/3 检查 ffmpeg / ffprobe =="
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  echo "  已安装: $(ffmpeg -version 2>/dev/null | head -1)"
else
  if command -v brew >/dev/null 2>&1; then
    echo "  未安装，正在用 Homebrew 安装 ffmpeg（可能需要几分钟）…"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 brew install ffmpeg
  else
    echo "  ✗ 没有 Homebrew。请先安装 https://brew.sh 或手动装 ffmpeg 后再运行本工具。" >&2
    exit 1
  fi
fi

echo "== 2/3 检查 Python =="
python3 -c 'import sys; assert sys.version_info >= (3, 9), sys.version' || {
  echo "  ✗ 需要 Python 3.9+" >&2; exit 1; }
python3 -V

echo "== 3/3 安装 mutagen 到本地 vendor/ =="
mkdir -p "$HERE/vendor"
python3 -m pip install --quiet --no-cache-dir --target "$HERE/vendor" -r "$HERE/requirements.txt"
PYTHONPATH="$HERE/vendor" python3 -c 'import mutagen; print("  mutagen", mutagen.version_string)'

echo
echo "✓ 依赖就绪。试运行："
echo "  python3 $HERE/ipodtune.py --help"
echo "  python3 $HERE/ipodtune.py selftest"
