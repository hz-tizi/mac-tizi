#!/bin/bash
# 输出： 状态|项目|说明   （状态：OK / WARN / BAD）
APP="$HOME/Library/Application Support/Tizi"
CFG="$APP/config.json"
HOST=$(python3 -c "import json;print(json.load(open('$CFG'))['host'])" 2>/dev/null)
SPORT=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshPort',22))" 2>/dev/null)
SSHUSER=$(python3 -c "import json;print(json.load(open('$CFG')).get('sshUser','root'))" 2>/dev/null)
say(){ echo "$1|$2|$3"; }
R(){ ssh -o BatchMode=yes -o ConnectTimeout=6 -p $SPORT $SSHUSER@$HOST "$1" 2>/dev/null; }

# 1 本机内核
pgrep -f 'xray-local/xray' >/dev/null && say OK "本机内核" "正在运行" || say BAD "本机内核" "没在跑，点开梯子会自动拉起"
# 2 系统代理
on=$(scutil --proxy | awk '/HTTPEnable/{print $3}')
[ "$on" = "1" ] && say OK "系统代理" "已开启（127.0.0.1:10808）" || say WARN "系统代理" "当前是直连状态"
# 3 隧道（用白名单里的域名测，才真的会走代理；不依赖外部 IP 服务）
c3=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -x http://127.0.0.1:10808 https://www.gstatic.com/generate_204)
[ "$c3" = "204" ] && say OK "隧道出口" "通（经 $HOST 出去）" || say BAD "隧道出口" "走代理打不开谷歌静态资源（$c3）"
# 4 国内直连
c=$(curl -s -o /dev/null -m 6 --noproxy '*' -w '%{http_code}' http://www.baidu.com)
[ "$c" = "200" ] && say OK "国内直连" "百度 200，正常" || say WARN "国内直连" "百度返回 $c"
# 5 服务器服务
a=$(R 'systemctl is-active xray')
[ "$a" = "active" ] && say OK "服务器 Xray" "运行中" || say BAD "服务器 Xray" "状态 $a"
# 6 443 监听
l=$(R 'ss -lntp | grep -c ":443"')
[ "$l" -ge 1 ] && say OK "443 端口" "正在监听" || say BAD "443 端口" "没有监听"
# 7 防火墙
f=$(R 'ufw status | head -1')
echo "$f" | grep -qi active && say OK "防火墙" "已启用，只放行 443 与 $SPORT" || say WARN "防火墙" "未启用"
# 8 SSH 密码
p=$(R 'sshd -T | grep ^passwordauthentication')
echo "$p" | grep -q "no" && say OK "SSH 密码登录" "已关闭，只认密钥" || say WARN "SSH 密码登录" "仍允许密码登录"
# 9 fail2ban
b=$(R 'systemctl is-active fail2ban')
[ "$b" = "active" ] && say OK "防暴破" "fail2ban 运行中" || say WARN "防暴破" "fail2ban 未运行"
# 10 伪装证书
cn=$(echo | openssl s_client -connect $HOST:443 -servername www.intel.com 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*CN=//p')
echo "$cn" | grep -qi "intel" && say OK "伪装验证" "对探测者出示的是真 Intel 证书" || say WARN "伪装验证" "证书异常：$cn"
# 11 磁盘
d=$(R 'df -h / | tail -1' | awk '{print $5}' | tr -d '%')
[ -n "$d" ] && { [ "$d" -lt 80 ] && say OK "磁盘占用" "${d}%" || say WARN "磁盘占用" "${d}%，偏高"; }
# 12 内存
m=$(R 'free -m | sed -n 2p' | awk '{print $3"/"$2" MB"}')
say OK "内存占用" "$m"
# 13 今日流量
t=$(R 'python3 /root/ltcollect.py' 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(round(d.get('today',0),2))" 2>/dev/null)
tv=${t:-0}
awk "BEGIN{exit !($tv > 10)}" && say WARN "今日流量" "${tv} GB，偏多（建议 < 10 GB）" || say OK "今日流量" "${tv} GB（建议 < 10 GB）"
# 14 探测次数
pr=$(R 'journalctl -u xray --since today --no-pager | grep -c "invalid connection"')
pr=${pr:-0}
[ "$pr" -lt 500 ] && say OK "今天被探测" "$pr 次" || say WARN "今天被探测" "$pr 次，明显偏多，留意"
# 15 到期（按日期算，不写死）
EXP=$(python3 -c "import json;print(json.load(open('$CFG')).get('expire',''))" 2>/dev/null)
if [ -z "$EXP" ]; then
  say OK "服务器到期" "未设置（可在 App 设置里填）"
else
dd=$(( ( $(date -j -f "%Y-%m-%d" "$EXP" +%s) - $(date +%s) ) / 86400 ))
[ "$dd" -gt 7 ] && say OK "服务器到期" "$EXP（还剩 $dd 天）" || say WARN "服务器到期" "$EXP（只剩 $dd 天，尽快续费）"
fi
# 16 STUN 规则
[ -f /etc/pf.anchors/dsh-stun ] && say OK "WebRTC 防护" "防泄漏规则已安装" || say WARN "WebRTC 防护" "规则文件不存在"
# 17 备份
n=$(ls -1 "$HOME/Library/Application Support/Tizi/服务器备份" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 1 ] && say OK "配置备份" "已有 $n 个备份文件" || say WARN "配置备份" "还没有备份"
