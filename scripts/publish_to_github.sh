#!/usr/bin/env bash
# 在你自己电脑的「终端」里运行：登录 GitHub → 创建仓库 → 推送 → 发布 Release
# 用法：./scripts/publish_to_github.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

REPO_NAME="${REPO_NAME:-podsync}"
VISIBILITY="${VISIBILITY:-public}"      # public / private
TAG="v1.6.0"
DESC="macOS iPod downloader & sync app (stock firmware + Rockbox/CrazyPod)"

command -v gh >/dev/null 2>&1 || { echo "缺少 gh：请先安装 GitHub CLI"; exit 1; }

if ! gh auth status >/dev/null 2>&1; then
  echo "== 需要登录 GitHub（浏览器授权一次）=="
  gh auth login --hostname github.com --git-protocol https --web
fi
LOGIN="$(gh api user --jq .login)"
echo "== 已登录：$LOGIN =="

if gh repo view "$LOGIN/$REPO_NAME" >/dev/null 2>&1; then
  echo "== 仓库已存在：$LOGIN/$REPO_NAME =="
else
  echo "== 创建仓库 $LOGIN/$REPO_NAME（$VISIBILITY）=="
  gh repo create "$LOGIN/$REPO_NAME" --"$VISIBILITY" --description "$DESC"
fi

git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$LOGIN/$REPO_NAME.git"
git push -u origin main
git push origin "$TAG"

echo "== 发布 Release $TAG =="
if gh release view "$TAG" -R "$LOGIN/$REPO_NAME" >/dev/null 2>&1; then
  echo "Release $TAG 已存在，补传资产..."
  gh release upload "$TAG" dist/PodSync-macOS-arm64.zip dist/PodSync-macOS-arm64.zip.sha256 docs/安装说明.txt -R "$LOGIN/$REPO_NAME" --clobber
else
  gh release create "$TAG" \
    dist/PodSync-macOS-arm64.zip \
    dist/PodSync-macOS-arm64.zip.sha256 \
    docs/安装说明.txt \
    --repo "$LOGIN/$REPO_NAME" \
    --title "PodSync $TAG" \
    --notes-file docs/RELEASE_NOTES_v1.6.0.md
fi

echo
echo "✓ 完成："
echo "  https://github.com/$LOGIN/$REPO_NAME"
echo "  https://github.com/$LOGIN/$REPO_NAME/releases/tag/$TAG"
