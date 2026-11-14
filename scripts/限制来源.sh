#!/bin/bash
# 用法: 限制来源.sh status | enable | disable | update
APP="$HOME/Library/Application Support/Tizi"
CFG="$APP/config.json"
HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['host'])" 2>/dev/null)
SPORT=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshPort',22))" 2>/dev/null)
SSHUSER=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshUser','root'))" 2>/dev/null)
KEYFILE=~/.ssh/id_ed25519.pub
PUB=$(cat "$KEYFILE")

ssh_run(){ ssh -o BatchMode=yes -o ConnectTimeout=8 -p $SPORT $SSHUSER@$HOST "$1" 2>/dev/null; }
myip(){ curl -s -m 8 --noproxy '*' https://icanhazip.com | tr -d '\n'; }

case "$1" in
  status)
    cur=$(ssh_run 'grep -o "from=\"[^\"]*\"" /root/.ssh/authorized_keys 2>/dev/null | head -1')
    if [ -z "$cur" ]; then echo "off"; else echo "on|${cur#from=\"}" | tr -d '"'; fi
    ;;
  enable)
    IP=$(myip); [ -z "$IP" ] && { echo "无法获取公网 IP"; exit 1; }
    ssh_run 'cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.bak 2>/dev/null'
    ssh_run "echo 'from=\"$IP\" $PUB' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -p $SPORT $SSHUSER@$HOST true 2>/dev/null; then
      echo "on|$IP"
    else
      ssh_run 'mv /root/.ssh/authorized_keys.bak /root/.ssh/authorized_keys 2>/dev/null'
      echo "失败：已自动回滚"
    fi
    ;;
  disable)
    ssh_run 'if [ -f /root/.ssh/authorized_keys.bak ]; then cp /root/.ssh/authorized_keys.bak /root/.ssh/authorized_keys; else sed -i "s/^from=\"[^\"]*\" //" /root/.ssh/authorized_keys; fi; chmod 600 /root/.ssh/authorized_keys'
    echo "off"
    ;;
esac
