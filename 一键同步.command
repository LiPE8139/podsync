#!/bin/bash
cd "$(dirname "$0")"
clear
echo "================================================"
echo "   iPod 一键增量同步  （收件箱 → Rockbox + 原厂）"
echo "================================================"
echo
python3 ipodsync.py sync
echo
read -n 1 -s -r -p "按任意键关闭窗口…"
