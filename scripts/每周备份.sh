#!/bin/bash
# 每周备份：只备份"系统加固配置"，不落任何含密钥的文件
# 说明：xray 的 config.json 里有私钥/UUID；节点参数已单独存进加密的「梯子机密.dmg」，
#      这里刻意不再生成明文副本。
TIZI="$HOME/Library/Application Support/Tizi"
APP="$HOME/Library/Application Support/Tizi"
CFG="$APP/config.json"
HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['host'])" 2>/dev/null)
SPORT=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshPort',22))" 2>/dev/null)
SSHUSER=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshUser','root'))" 2>/dev/null)
D="$TIZI/服务器备份"; mkdir -p "$D"; chmod 700 "$D"
TS=$(date +%Y%m%d)

ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$SPORT" "$SSHUSER@$HOST" \
  'tar czf - /etc/ssh/sshd_config.d/ /etc/fail2ban/ /etc/sysctl.d/ 2>/dev/null' \
  > "$D/system-$TS.tgz" 2>/dev/null
chmod 600 "$D/system-$TS.tgz" 2>/dev/null

# 只保留最近 8 份
ls -1t "$D"/system-*.tgz 2>/dev/null | tail -n +9 | xargs -r rm -f
