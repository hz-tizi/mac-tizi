#!/bin/bash
# 安装：把脚本放进数据目录、写入 launchd 自启项、安装 App
# 用法：bash install.sh            （默认安装到 /Applications）
set -e
cd "$(dirname "$0")"
APP="$HOME/Library/Application Support/Tizi"
LA="$HOME/Library/LaunchAgents"

if [ ! -f "build/梯子.app" ] && [ ! -f "build/梯子.app/Contents/MacOS/Ladder" ]; then
  echo "先编译：bash build.sh"; exit 1
fi

echo "[1/5] 建数据目录"
mkdir -p "$APP"
chmod 700 "$APP"

echo "[2/5] 复制脚本"
cp scripts/* "$APP"/
chmod +x "$APP"/*.sh 2>/dev/null
chmod 600 "$APP"/*.py 2>/dev/null

echo "[3/5] 配置"
if [ ! -f "$APP/config.json" ]; then
  if [ -f config.json ]; then
    cp config.json "$APP/config.json"
  else
    cp config.example.json "$APP/config.json"
    echo "  ⚠️  已用示例配置，请先编辑：$APP/config.json（填服务器 IP / SSH 端口）"
  fi
fi
chmod 600 "$APP/config.json"

echo "[4/5] 安装 App"
rm -rf "/Applications/梯子.app"
cp -R "build/梯子.app" "/Applications/梯子.app"

echo "[5/5] 写入自启项"
mkdir -p "$LA"
XLABEL=$(python3 -c "import json;print(json.load(open('$APP/config.json')).get('xrayLabel','com.tizi.xray'))")

cat > "$LA/$XLABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$XLABEL</string>
<key>ProgramArguments</key><array>
<string>$APP/xray-local/xray</string><string>run</string><string>-c</string><string>$APP/xray-local/client.json</string>
</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/tmp/xray-local.log</string>
<key>StandardErrorPath</key><string>/tmp/xray-local.log</string>
</dict></plist>
PLIST

cat > "$LA/com.tizi.app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tizi.app</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>/Applications/梯子.app</string></array>
<key>RunAtLoad</key><true/><key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST

cat > "$LA/com.tizi.ledger.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tizi.ledger</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$APP/流量账本.py</string><string>sample</string></array>
<key>StartInterval</key><integer>60</integer><key>RunAtLoad</key><true/>
</dict></plist>
PLIST

cat > "$LA/com.tizi.daily.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tizi.daily</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$APP/每日体检.sh</string></array>
<key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer></dict>
</dict></plist>
PLIST

cat > "$LA/com.tizi.weekly.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tizi.weekly</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$APP/每周备份.sh</string></array>
<key>StartCalendarInterval</key><dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>10</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
PLIST

for f in "$LA/$XLABEL.plist" "$LA/com.tizi.app.plist" "$LA/com.tizi.ledger.plist" "$LA/com.tizi.daily.plist" "$LA/com.tizi.weekly.plist"; do
  launchctl bootout "gui/$(id -u)" "$f" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$f" 2>/dev/null || true
done

echo
echo "装好了。"
echo "  1) 确认内核实现在 $APP/xray-local/（xray 二进制 + client.json）"
echo "  2) 打开「梯子」，顶栏点「智能」"
echo "  3) 需要改配置：$APP/config.json"
