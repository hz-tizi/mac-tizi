#!/bin/bash
# 用法: 加规则.sh direct|proxy|none 域名
HERE="$(cd "$(dirname "$0")" && pwd)"
K="$1"; H="$2"
[ -z "$K" ] || [ -z "$H" ] && exit 1

cp "$HERE/规则.txt" "$HERE/规则.bak.$(date +%H%M%S)" 2>/dev/null
ls -t "$HERE"/规则.bak.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null

# 去掉同名旧规则（用 grep 比 sed 稳，域名里的点/星号不会出错）
grep -v -F "|$H" "$HERE/规则.txt" > "$HERE/规则.txt.new" 2>/dev/null
mv "$HERE/规则.txt.new" "$HERE/规则.txt"
[ "$K" != "none" ] && echo "$K|$H" >> "$HERE/规则.txt"

# 按当前模式重新应用（没记过就按智能）
M=$(cat "$HERE/模式.txt" 2>/dev/null)
[ "$M" = "global" ] || [ "$M" = "direct" ] || M=smart
bash "$HERE/应用规则.sh" "$M" >/dev/null
