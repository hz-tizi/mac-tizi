#!/usr/bin/env python3
"""按小时累计每个程序的流量，供"程序流量排行"使用。
用法： 流量账本.py sample      采样一次（由 launchd 每分钟调用）
       流量账本.py query [天]   输出 JSON: [{"p":名称,"gb":数值}]
"""
import json, os, subprocess, sys, time, datetime

BASE = os.path.dirname(os.path.abspath(__file__))
DB   = BASE + "/流量账本.json"
SNAP = "/tmp/lt_traffic_snap.json"

def nettop():
    out = subprocess.run("nettop -P -x -l 1 -J bytes_in,bytes_out 2>/dev/null",
                         shell=True, capture_output=True).stdout.decode("utf-8", "replace")
    m = {}
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 3:
            try: m[f[0].rsplit(".", 1)[0]] = int(f[1]) + int(f[2])
            except Exception: pass
    return m

def sample():
    cur = nettop()
    prev = {}
    try: prev = json.load(open(SNAP))
    except Exception: pass
    now = datetime.datetime.now()
    key = now.strftime("%Y-%m-%d %H")
    db = {}
    try: db = json.load(open(DB))
    except Exception: pass
    db.setdefault(key, {})
    for app, total in cur.items():
        if app in prev and total >= prev[app]:
            d = total - prev[app]
            if d > 0:
                db[key][app] = db[key].get(app, 0) + d
    cutoff = (now - datetime.timedelta(days=32)).strftime("%Y-%m-%d %H")
    db = {k: v for k, v in db.items() if k >= cutoff}
    json.dump(db, open(DB, "w"))
    json.dump(cur, open(SNAP, "w"))

def query(days):
    try: db = json.load(open(DB))
    except Exception: db = {}
    now = datetime.datetime.now()
    since = (now - datetime.timedelta(days=days)).strftime("%Y-%m-%d %H")
    agg = {}
    for k, apps in db.items():
        if k < since: continue
        for a, b in apps.items():
            agg[a] = agg.get(a, 0) + b
    res = [{"p": a, "gb": round(b / 1073741824, 4)} for a, b in agg.items()]
    res.sort(key=lambda x: -x["gb"])
    print(json.dumps(res[:12], ensure_ascii=False))

if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "sample"
    if a == "sample": sample()
    elif a == "query": query(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    else: query(1)
