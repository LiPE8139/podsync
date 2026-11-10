#!/usr/bin/env bash
# 一键重建 App 内嵌运行时：runtime/{python,ffmpeg,itdb}
#   ./scripts/build_runtime.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$HERE/build/toolchain"

"$HERE/scripts/build_toolchain.sh" "$TOOLCHAIN"
"$HERE/scripts/build_ffmpeg.sh"
"$HERE/scripts/build_python_runtime.sh"

echo "== 打包 itdbwrite 依赖 =="
rm -rf "$HERE/runtime/itdb"
mkdir -p "$HERE/runtime/itdb/bin"
python3 "$HERE/tools/bundle_deps.py" "$HERE/runtime/itdb" "$HERE/runtime/itdb/bin" "$TOOLCHAIN/bin/itdbwrite"

echo
du -sh "$HERE/runtime"/* 2>/dev/null
echo "✓ runtime 重建完成，现在可以 ./build_gui.sh"
