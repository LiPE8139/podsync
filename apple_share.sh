#!/usr/bin/env bash
# apple_share.sh — 把 MP3 曲库写进 iPod 的 Apple 原生库（iTunesDB）
#
# 用法:
#   ./apple_share.sh [iPod挂载点] [manifest.tsv] [--eject]
#
# 做的事:
#   1) 找到 /Volumes/* 上带 iPod_Control 的卷
#   2) 备份现有 iTunesDB / SysInfo
#   3) 用 libgpod 写入曲目（文件拷进 iPod_Control/Music/Fxx + 生成 iTunesDB + hash58 校验）
#   4) 用 libgpod 回读校验曲目数
#
# 不会碰: /Music（Rockbox 曲库）、.rockbox、.crazypod
set -euo pipefail

ITDBWRITE="${ITDBWRITE:-/tmp/itdbwrite}"
ITDBDUMP="${ITDBDUMP:-/tmp/itdbdump}"
WS="$(cd "$(dirname "$0")/.." && pwd)"
BK="$WS/ipod-db-backup"
MANIFEST="${2:-$WS/apple-mp3/manifest.tsv}"

MP="${1:-}"
if [ -z "$MP" ] || [ ! -d "$MP" ]; then
  MP=""
  for c in /Volumes/*; do
    [ -d "$c/iPod_Control" ] || continue
    case "$(basename "$c")" in "Macintosh HD"|Recovery) continue;; esac
    MP="$c"; break
  done
fi
[ -n "$MP" ] || { echo "✗ 没找到 iPod 卷（请确认已插回 Mac 并挂载）"; exit 1; }
[ -f "$MANIFEST" ] || { echo "✗ 清单不存在: $MANIFEST"; exit 1; }
[ -x "$ITDBWRITE" ] || { echo "✗ 找不到 $ITDBWRITE"; exit 1; }

echo "iPod 卷: $MP"
echo "曲目清单: $MANIFEST ($(wc -l < "$MANIFEST" | tr -d ' ') 首)"

echo
echo "== 1/5 备份现有数据库 =="
mkdir -p "$BK"
TS="$(date +%Y%m%d-%H%M%S)"
for f in iTunesDB iTunesCDB SysInfo; do
  src="$MP/iPod_Control/iTunes/$f"; [ -f "$src" ] || src="$MP/iPod_Control/Device/$f"
  if [ -f "$src" ]; then cp "$src" "$BK/${f}.$TS.bak" 2>/dev/null && echo "  备份 $src" || echo "  跳过 $src"; fi
done

echo
echo "== 2/5 清理旧 Apple 曲库与过期封面库 =="
rm -f "$MP/iPod_Control/Music"/*/*.mp3 2>/dev/null || true
rm -rf "$MP/iPod_Control/Artwork"
echo "  已清空；接下来重建"
echo
echo "== 确保 Music/Fxx 目录 =="
for i in $(seq -w 0 19); do mkdir -p "$MP/iPod_Control/Music/F$i"; done
echo "  F00..F19 就绪"

echo
echo "== 3/5 写入曲库（拷贝文件 + 生成 iTunesDB） =="
IPOD_MODEL="${IPOD_MODEL:-MB147}" IPOD_GUID="${IPOD_GUID:-000A2700130F9207}" \
  "$ITDBWRITE" "$MP" "$MANIFEST"

echo
echo "== 4/5 回读校验 =="
if [ -x "$ITDBDUMP" ]; then
  "$ITDBDUMP" "$MP" | head -8
  echo "  ..."
  "$ITDBDUMP" "$MP" | grep -c '^  - ' || true
else
  echo "  (跳过，无 itdbdump)"
fi
echo "  Music 文件数: $(find "$MP/iPod_Control/Music" -type f | wc -l | tr -d ' ')"
echo "  有封面的曲目: $("$ITDBDUMP" "$MP" 2>/dev/null | grep -c 'artwork=YES' || true)"
echo "  Artwork 文件: $(ls "$MP/iPod_Control/Artwork" 2>/dev/null | wc -l | tr -d ' ') 个（ArtworkDB + .ithmb）"
echo "  iTunesDB 大小: $(stat -f%z "$MP/iPod_Control/iTunes/iTunesDB" 2>/dev/null) 字节"

echo
echo "== 5/5 落盘 =="
sync
df -h "$MP" | tail -1

if [ "${3:-}" = "--eject" ] || [ "${EJECT:-0}" = "1" ]; then
  cd /
  diskutil eject "$MP" 2>&1 || diskutil unmount "$MP" 2>&1
fi

echo
echo "完成。验证方式："
echo "  1) 断开连接，重启 iPod 时按住 Menu 约 1 秒进原厂固件 → 看音乐库里是否有这些歌"
echo "  2) CrazyPod 里不要打开「Original iPod Music」（否则会和 /Music 里的 FLAC 重复显示）"
echo "  3) 若原厂固件提示需要恢复/连接 iTunes：不要恢复，先告诉我，可用 $BK 里的备份还原"
