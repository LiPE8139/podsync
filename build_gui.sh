#!/bin/bash
# 构建「PodSync.app」— 编译 SwiftUI 前端并打包成可双击的 macOS App
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/PodSync.app"
# Bundle ID：发布用反向域名；可用环境变量覆盖，例如 PODSYNC_BUNDLE_ID=io.github.yourname.podsync
BUNDLE_ID="${PODSYNC_BUNDLE_ID:-io.github.lipe8139.podsync}"
# 开发构建（含截图/调试钩子）：WITH_DEVTOOLS=1 ./build_gui.sh
DEVTOOLS_FLAG=""
if [ "${WITH_DEVTOOLS:-0}" = "1" ]; then DEVTOOLS_FLAG="-D DEVTOOLS"; fi

echo "== 编译 SwiftUI 界面 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$HERE/.swift-module-cache"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$HERE/.swift-module-cache" \
  -framework MediaPlayer $DEVTOOLS_FLAG \
  -o "$APP/Contents/MacOS/PodSync" "$HERE"/gui/*.swift

echo "== App 图标 =="
if [ -f "$HERE/tools/AppIcon.icns" ]; then
  cp "$HERE/tools/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "  使用 tools/AppIcon.icns"
else
  ICONSET="$HERE/.AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  mkdir -p "$HERE/.swift-module-cache"
  if xcrun swiftc -O -swift-version 5 -module-cache-path "$HERE/.swift-module-cache" \
        -o "$HERE/.make_icon" "$HERE/tools/make_icon.swift" >/dev/null 2>&1; then
    "$HERE/.make_icon" "$ICONSET" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
      && echo "  AppIcon.icns 已生成" || echo "  （iconutil 失败，使用默认图标）"
  else
    echo "  （图标编译失败，使用默认图标）"
  fi
  rm -rf "$ICONSET" "$HERE/.make_icon"
fi

echo "== 拷贝界面资源 =="
mkdir -p "$APP/Contents/Resources"
if ls "$HERE"/gui/assets/*.png >/dev/null 2>&1; then
  cp "$HERE"/gui/assets/*.png "$APP/Contents/Resources/"
  echo "  资源已拷贝：$(ls "$HERE"/gui/assets | tr '\n' ' ')"
fi

echo "== 打包引擎与运行时（内嵌） =="
RES_TOOL="$APP/Contents/Resources/tool"
rm -rf "$RES_TOOL"; mkdir -p "$RES_TOOL"
cp "$HERE/ipodsync.py" "$HERE/ipodtune.py" "$HERE/coco.py" "$HERE/README.md" "$RES_TOOL"/
ditto "$HERE/vendor" "$RES_TOOL/vendor"
if [ -d "$HERE/runtime" ]; then
  ditto "$HERE/runtime" "$RES_TOOL/runtime"
  echo "  运行时已内嵌：$(du -sh "$RES_TOOL/runtime" | cut -f1)"
else
  echo "  ⚠ 未找到 runtime 目录（App 将依赖系统 Python/ffmpeg）"
fi

# 清掉开发时残留的 __pycache__（在包里会破坏签名）
find "$RES_TOOL" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "== 写 Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PodSync</string>
  <key>CFBundleDisplayName</key><string>PodSync</string>
  <key>CFBundleExecutable</key><string>PodSync</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.6.0</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict>
</plist>
PLIST

echo "== ad-hoc 签名 =="
# 不用 --deep：内嵌的 python/ffmpeg 已在打包时各自签过；--deep 在部分机器上会卡住
codesign --force --sign - "$APP" >/dev/null 2>&1 && echo "  已签名（ad-hoc）" || echo "  签名失败（可忽略，本机可用）"

echo
echo "✓ 已生成：$APP"
echo "  双击即可运行；命令行自检：\"$APP/Contents/MacOS/PodSync\" --selftest"
