#!/bin/sh
# 构建 Release 版 Regulus.app 并打包成 .build/release-app/Regulus.zip。发布由 GitHub Actions 完成
# （.github/workflows/release.yml），App 的更新检查依赖这个附件名，见 Sources/RegulusCore/Update/AppUpdate.swift
# Build Regulus.app (Release) and zip it to .build/release-app/Regulus.zip. Publishing is done by GitHub Actions
# (.github/workflows/release.yml); the in-app update check relies on this asset name, see
# Sources/RegulusCore/Update/AppUpdate.swift.
#
# 用法 / Usage: scripts/package.sh
set -eu
cd "$(dirname "$0")/.."

out=.build/release-app
rm -rf "$out"
xcodegen generate
xcodebuild -project Regulus.xcodeproj -scheme Regulus -configuration Release -derivedDataPath "$out/derived" build
# --keepParent：压缩包里是 Regulus.app 本身 / the zip holds Regulus.app itself
ditto -c -k --keepParent "$out/derived/Build/Products/Release/Regulus.app" "$out/Regulus.zip"
echo "$out/Regulus.zip"
