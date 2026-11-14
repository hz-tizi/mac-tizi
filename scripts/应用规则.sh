#!/bin/bash
# 用法: 应用规则.sh smart|global|direct
HERE="$(cd "$(dirname "$0")" && pwd)"
M="${1:-smart}"
LABEL=$(python3 -c "import json;print(json.load(open('$HERE/config.json')).get('xrayLabel','com.tizi.xray'))" 2>/dev/null)
[ -z "$LABEL" ] && LABEL=com.tizi.xray
echo "$M" > "$HERE/模式.txt"

case "$M" in
  smart)
    networksetup -setautoproxystate Wi-Fi off >/dev/null 2>&1
    networksetup -setwebproxy Wi-Fi 127.0.0.1 10808 >/dev/null 2>&1
    networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 10808 >/dev/null 2>&1
    networksetup -setproxybypassdomains Wi-Fi localhost 127.0.0.1 "*.local" >/dev/null 2>&1
    python3 "$HERE/客户端路由.py" smart >/dev/null 2>&1
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    echo "smart" ;;
  global)
    networksetup -setautoproxystate Wi-Fi off >/dev/null 2>&1
    networksetup -setwebproxy Wi-Fi 127.0.0.1 10808 >/dev/null 2>&1
    networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 10808 >/dev/null 2>&1
    networksetup -setproxybypassdomains Wi-Fi localhost 127.0.0.1 "*.local" >/dev/null 2>&1
    python3 "$HERE/客户端路由.py" global >/dev/null 2>&1
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    echo "global" ;;
  direct)
    networksetup -setautoproxystate Wi-Fi off >/dev/null 2>&1
    networksetup -setwebproxystate Wi-Fi off >/dev/null 2>&1
    networksetup -setsecurewebproxystate Wi-Fi off >/dev/null 2>&1
    echo "direct" ;;
esac
