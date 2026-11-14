#!/usr/bin/env python3
import os
D = os.path.dirname(os.path.abspath(__file__))
direct, proxy = [], []
for line in open(D + "/规则.txt", encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "|" not in line: continue
    k, h = line.split("|", 1)
    if k == "direct": direct.append(h)
    elif k == "proxy": proxy.append(h)
def js(arr):
    return ", ".join('"%s"' % x.replace('"','') for x in arr)
pac = """// 由 生成PAC.py 自动生成，请勿手改
var PROXY = "PROXY 127.0.0.1:10808; DIRECT";
var P = [%s];
var D = [%s];

function FindProxyForURL(url, host) {
  var i;
  for (i = 0; i < P.length; i++) { if (shExpMatch(host, P[i])) return PROXY; }
  return "DIRECT";
}
""" % (js(proxy), js(direct))
import os
out = os.path.expanduser("~/.tizi/rules.pac")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w", encoding="utf-8").write(pac)
open(D + "/rules.pac", "w", encoding="utf-8").write(pac)
print("PAC 已生成：直连 %d 条 / 强制代理 %d 条" % (len(direct), len(proxy)))
