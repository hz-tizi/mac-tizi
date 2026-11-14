#!/bin/bash
# 每日自动体检：梯子是否通 + 今日流量（结果写在 Tizi 数据目录，不碰桌面）
TIZI="$HOME/Library/Application Support/Tizi"
APP="$HOME/Library/Application Support/Tizi"
CFG="$APP/config.json"
HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['host'])" 2>/dev/null)
SPORT=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshPort',22))" 2>/dev/null)

LOG="$TIZI/每日体检.log"
mkdir -p "$TIZI"
ts=$(date "+%Y-%m-%d %H:%M")
out=""

# 1) 内核是否在跑
pgrep -f "xray-local/xray" >/dev/null && out="内核:运行" || out="内核:已停 ❌"

# 2) 隧道是否真的通（用白名单里的域名测，才真的会走代理；不用外部 IP 服务）
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -x http://127.0.0.1:10808 https://www.gstatic.com/generate_204 2>/dev/null)
if [ "$code" = "204" ]; then out="$out | 隧道:通"; else out="$out | 隧道:不通 ❌($code)"; fi

# 3) 服务器今日流量
line=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SPORT" "$SSHUSER@$HOST" \
  "vnstat -d --oneline 2>/dev/null | tail -1" 2>/dev/null)
traffic=$(echo "$line" | awk -F';' '{print $6}' | awk '{v=$1+0; u=$2
  if (u=="GiB") printf "%.2f GB", v
  else if (u=="MiB") printf "%.2f GB", v/1024
  else if (u=="KiB") printf "%.3f GB", v/1048576
  else printf "%.2f GB", v/1073741824}')
[ -n "$traffic" ] && out="$out | 今日:${traffic}" || out="$out | 今日:取不到"

# 只留最近 400 行
echo "$ts  $out" >> "$LOG"
tail -n 400 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# 4) 异常时通知
case "$out" in
  *"不通"*|*"已停"*) osascript -e 'display notification "梯子不通了，需要检查" with title "⚠️ 每日体检"' ;;
esac
