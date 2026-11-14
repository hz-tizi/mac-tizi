#!/bin/bash
# 编译成 MacTizi.app（需要 Xcode 命令行工具：xcode-select --install）
set -e
cd "$(dirname "$0")"

APPNAME="梯子"
BUNDLE="build/$APPNAME.app"
rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "[1/4] 编译 Swift…"
swiftc -O -target arm64-apple-macos13.0 Sources/main.swift -o "$BUNDLE/Contents/MacOS/Ladder"

echo "[2/4] 生成图标…"
if [ -f "图标/App图标.png" ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "图标/App图标.png" --out "build/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1
    d=$((sz*2))
    sips -z $d $d "图标/App图标.png" --out "build/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns build/AppIcon.iconset -o "$BUNDLE/Contents/Resources/Ladder.icns" 2>/dev/null || true
fi

echo "[3/4] 写入 Info.plist…"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>梯子</string>
  <key>CFBundleDisplayName</key><string>梯子</string>
  <key>CFBundleExecutable</key><string>Ladder</string>
  <key>CFBundleIdentifier</key><string>local.tizi.app</string>
  <key>CFBundleIconFile</key><string>Ladder</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "[4/4] 临时签名…"
codesign --force --deep -s - "$BUNDLE" 2>/dev/null || true
echo "完成：$BUNDLE"
echo "下一步：bash install.sh"
