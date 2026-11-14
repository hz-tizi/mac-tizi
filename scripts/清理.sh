#!/bin/bash
# 用法: 清理.sh list | 清理.sh clean <key>
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE"
sz(){ du -sk "$@" 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1024}'; }
szb(){ find "$APP/服务器备份" -type f -mtime +60 -print0 2>/dev/null | xargs -0 -I{} du -sk {} 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1024}'; }

list(){
  echo "appcache|梯子App 运行缓存|$(sz /tmp/lt_cache.json /tmp/lt_appcache.json /tmp/lt_traffic_snap.json /tmp/xray-local.log)|3"
  echo "shots|测试截图与预览文件|$(sz /tmp/mock*.png /tmp/v*.png /tmp/ladder_shot.png /tmp/full*.png /tmp/l2.png /tmp/mb*.png)|4"
  echo "backups|超过 60 天的配置备份|$(szb)|5"
  echo "oldchecks|超过保留期的体检历史|0.0|6"
}

clean(){
  case "$1" in
    appcache) rm -f /tmp/lt_cache.json /tmp/lt_appcache.json /tmp/lt_traffic_snap.json; : > /tmp/xray-local.log ;;
    shots) rm -f /tmp/mock*.png /tmp/v*.png /tmp/ladder_shot.png /tmp/full*.png /tmp/l2.png /tmp/mb*.png /tmp/mbcrop.png ;;
    backups) find "$APP/服务器备份" -type f -mtime +60 -delete 2>/dev/null ;;
    oldchecks) python3 - "$APP" <<'PY'
import json,sys,os
app=sys.argv[1]
f=os.path.join(app,"体检历史.json")
try: arr=json.load(open(f))
except Exception: sys.exit(0)
arr=arr[:200]
json.dump(arr,open(f,"w"))
PY
    ;;
  esac
  echo "done"
}

case "$1" in
  list) list ;;
  clean) clean "$2" ;;
esac
