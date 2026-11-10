#!/usr/bin/env bash
# 下载 python-build-standalone（3.12.x, aarch64 macOS）解压到 runtime/python
#
# 说明：App 只把 Python 当作独立可执行进程调用，不编译扩展，所以用 install_only 包即可。
#   PBS_URL 可以直接指定某个 release 资产 URL；不指定则自动从 GitHub API 找最新的 3.12 arm64 包。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/runtime/python"
WORK="$HERE/build/work"
mkdir -p "$WORK"

PBS_URL="${PBS_URL:-}"
if [ -z "$PBS_URL" ]; then
  echo "== 查找最新的 python-build-standalone 3.12 arm64 包 =="
  PBS_URL="$(curl -fsSL 'https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=10' \
    | grep -o 'https://[^"]*cpython-3\.12\.[0-9]*+[0-9]*-aarch64-apple-darwin-install_only\.tar\.gz' \
    | head -1 || true)"
  [ -n "$PBS_URL" ] || { echo "自动查找失败，请用 PBS_URL=<url> 指定" >&2; exit 1; }
fi
echo "  使用: $PBS_URL"
TARBALL="$WORK/$(basename "$PBS_URL")"
[ -f "$TARBALL" ] || curl -fL --retry 3 -o "$TARBALL.part" "$PBS_URL" && [ -f "$TARBALL" ] || mv "$TARBALL.part" "$TARBALL"
rm -rf "$OUT" "$WORK/pbs"
mkdir -p "$WORK/pbs"
tar -xzf "$TARBALL" -C "$WORK/pbs"
mv "$WORK/pbs/python" "$OUT"
# 不需要 pip/setuptools：删掉可减小约 20MB，也少一堆许可证
rm -rf "$OUT/lib/python3.12/site-packages/pip" \
       "$OUT/lib/python3.12/site-packages/setuptools" \
       "$OUT/lib/python3.12/site-packages/pkg_resources" 2>/dev/null || true
"$OUT/bin/python3" -V
echo "✓ runtime/python 就绪"
