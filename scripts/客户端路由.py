#!/usr/bin/env python3
"""把「代理白名单」写进本地 Xray 的路由规则。
   底层规则：命中白名单 → proxy；其余 → direct（直连）。"""
import json, os, sys

BASE = os.path.dirname(os.path.abspath(__file__))
CFG = os.path.join(BASE, "xray-local", "client.json")
RULES = os.path.join(BASE, "规则.txt")

proxy_domains = []
for line in open(RULES, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "|" not in line: continue
    k, h = line.split("|", 1)
    if k == "proxy":
        proxy_domains.append(h if not h.startswith("*.") else "domain:" + h[2:])

d = json.load(open(CFG))
ob = d["outbounds"][0]
ob["tag"] = "proxy"
d["outbounds"] = [ob,
                  {"protocol": "freedom", "tag": "direct"},
                  {"protocol": "blackhole", "tag": "block"}]

mode = sys.argv[1] if len(sys.argv) > 1 else "smart"
if mode == "global":
    d["routing"] = {"domainStrategy": "AsIs",
                    "rules": [{"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}]}
else:
    d["routing"] = {"domainStrategy": "AsIs",
                    "rules": [{"type": "field", "domain": proxy_domains, "outboundTag": "proxy"},
                              {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}]}

# 先写临时文件再替换，写坏了也不会把好配置弄坏
tmp = CFG + ".new"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, CFG)
print("客户端路由已更新：白名单 %d 条，其余全部直连" % len(proxy_domains))
