#!/usr/bin/env python3
import json, subprocess, time, re, os
import json as _json
_CFG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
try:
    _c = _json.load(open(_CFG))
except Exception:
    _c = {}
HOST = _c.get("host", "CHANGE_ME")
SPORT = int(_c.get("sshPort", 22))
SSHUSER = _c.get("sshUser", "root")
CACHE="/tmp/lt_cache.json"; TTL=60

LOCK = "/tmp/lt_collect.lock"

def locked():
    try:
        if os.path.exists(LOCK):
            if time.time() - os.path.getmtime(LOCK) < 20: return True
        open(LOCK, "w").write(str(time.time()))
        return False
    except Exception:
        return False

def unlock():
    try: os.remove(LOCK)
    except Exception: pass

def sh(c, t=25):
    try:
        env = dict(os.environ); env.setdefault("LANG", "en_US.UTF-8")
        r = subprocess.run(c, shell=True, capture_output=True, timeout=t, env=env)
        return r.stdout.decode("utf-8", "replace").strip()
    except Exception:
        return ""

def local():
    on = False; pac = False
    for line in sh("scutil --proxy").splitlines():
        if "HTTPEnable" in line: on = line.strip().endswith("1")
        if "ProxyAutoConfigEnable" in line: pac = line.strip().endswith("1")
    on = on or pac
    fw_app = sh("/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null")
    fw_stun = os.path.exists("/etc/pf.anchors/dsh-stun")
    running = bool(sh("pgrep -f 'xray-local/xray'"))
    out = sh(f"ping -c 3 -t 4 {HOST} 2>/dev/null")
    m = re.search(r"= [\d.]+/([\d.]+)/", out)
    lat = int(float(m.group(1))) if m else -1
    l = re.search(r"([\d.]+)% packet loss", out)
    loss = float(l.group(1)) if l else -1
    return on, running, lat, loss, ("enabled" if "enabled" in fw_app.lower() else "off"), fw_stun

def _nettop_conns(port):
    out = sh("nettop -m tcp -n -x -l 1 2>/dev/null")
    cur = None; counts = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) < 2: continue
        if "<->" in line:
            addr = f[2] if len(f) > 2 else ""
            if cur and "Established" in line and (":%d<->" % port in addr or "<->127.0.0.1:%d" % port in addr):
                counts[cur] = counts.get(cur, 0) + 1
        else:
            if "." in f[1] and re.match(r"^[A-Za-z\u4e00-\u9fa5]", f[1]):
                cur = f[1].rsplit(".", 1)[0]
    return sorted([{"p": k, "n": v} for k, v in counts.items()], key=lambda x: -x["n"])[:25]

def _lsof_apps(port=None):
    cmd = "lsof -nP -Fpc " + ("-iTCP:%d -sTCP:ESTABLISHED" % port if port else "-iTCP -sTCP:ESTABLISHED") + " 2>/dev/null"
    out = sh(cmd)
    counts = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("p"): cur = line[1:]
        elif line.startswith("c") and cur:
            counts[line[1:]] = counts.get(line[1:], 0) + 1
    return sorted([{"p": k, "n": v} for k, v in counts.items()], key=lambda x: -x["n"])[:25]

def conn_apps():
    out = sh("nettop -m tcp -n -x -l 1 2>/dev/null")
    cur = None; counts = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) < 2: continue
        if "<->" in line:
            if cur and "Established" in line:
                counts[cur] = counts.get(cur, 0) + 1
        else:
            if "." in f[1] and re.match(r"^[A-Za-z\u4e00-\u9fa5]", f[1]):
                cur = f[1].rsplit(".", 1)[0]
    return sorted([{"p": k, "n": v} for k, v in counts.items()], key=lambda x: -x["n"])[:25]

def procs():
    # 方案B：用 lsof 精确查"谁连着代理端口"（首次使用 macOS 会弹一次授权，允许即可）
    out = sh("lsof -nP -iTCP:10808 -sTCP:ESTABLISHED 2>/dev/null", 8)
    counts = {}
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 2: counts[f[0]] = counts.get(f[0], 0) + 1
    return sorted([{"p": k, "n": v} for k, v in counts.items()], key=lambda x: -x["n"])[:25]

def nettop_all():
    """一次 nettop 采样，同时得到：每程序字节数、每程序连接数"""
    def snap():
        return sh("nettop -m tcp -P -x -l 1 -J bytes_in,bytes_out 2>/dev/null", 6)
    a = snap(); time.sleep(1.2); b = snap()
    def parse(out):
        m = {}
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 3:
                try: m[f[0]] = int(f[1]) + int(f[2])
                except Exception: pass
        return m
    ma, mb = parse(a), parse(b)
    res = []
    for k, v in mb.items():
        if k in ma:
            d = max(0, v - ma[k])
            if d > 2000:
                res.append({"p": k.rsplit(".", 1)[0], "kb": round(d / 1.2 / 1024, 1)})
    res.sort(key=lambda x: -x["kb"])
    return res[:12]

def nettop():
    def snap():
        out = sh("nettop -P -x -l 1 -J bytes_in,bytes_out -t wifi 2>/dev/null")
        m = {}
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) >= 3:
                try: m[f[0]] = (int(f[1]), int(f[2]))
                except Exception: pass
        return m
    try:
        a = snap(); time.sleep(1.2); b = snap()
        res = []
        for k, v in b.items():
            if k in a:
                d = max(0, v[0] - a[k][0]) + max(0, v[1] - a[k][1])
                if d > 2000:
                    res.append({"p": k.rsplit(".", 1)[0], "kb": round(d / 1.2 / 1024, 1)})
        res.sort(key=lambda x: -x["kb"])
        return res[:12]
    except Exception:
        return []

APPCACHE="/tmp/lt_appcache.json"

def merge_cache(apps, procs):
    import os, json as _j
    now=time.time()
    try: cache=_j.load(open(APPCACHE))
    except Exception: cache={}
    for a in apps:
        e=cache.get(a["p"], {"ts":0,"kb":0,"n":0})
        e["ts"]=now; e["kb"]=a["kb"]; cache[a["p"]]=e
    for pr in procs:
        e=cache.get(pr["p"], {"ts":0,"kb":0,"n":0})
        e["ts"]=now; e["n"]=pr["n"]; cache[pr["p"]]=e
    # 10 分钟内的都保留
    cache={k:v for k,v in cache.items() if now-v.get("ts",0) < 600}
    try: _j.dump(cache, open(APPCACHE,"w"))
    except Exception: pass
    out=[]
    for k,v in cache.items():
        out.append({"p":k,"kb":v.get("kb",0),"n":v.get("n",0),"age":int(now-v.get("ts",now))})
    out.sort(key=lambda x:(-x["kb"], x["p"]))
    return out

def remote():
    if os.path.exists(CACHE):
        try:
            d = json.load(open(CACHE))
            if time.time() - d.get("_ts", 0) < TTL: return d
        except Exception: pass
    txt = sh(f"ssh -o BatchMode=yes -o ConnectTimeout=8 -p {SPORT} {SSHUSER}@{HOST} 'python3 /root/ltcollect.py'", 30)
    try:
        d = json.loads(txt)
    except Exception:
        d = {}
    d["_ts"] = time.time()
    try: json.dump(d, open(CACHE, "w"))
    except Exception: pass
    return d

PORTMAP = "/tmp/lt_portmap.json"
ACCESS = os.path.expanduser("~/Library/Application Support/Tizi/xray-local/access.log")

def _unescape(name):
    try:
        return name.encode("latin-1", "backslashreplace").decode("unicode_escape").encode("latin-1").decode("utf-8", "replace")
    except Exception:
        return name

def _portmap():
    try: m = json.load(open(PORTMAP))
    except Exception: m = {}
    out = sh("lsof -nP -F pcn -iTCP -sTCP:ESTABLISHED 2>/dev/null", 8)
    now = time.time(); cur = None
    for line in out.splitlines():
        if not line: continue
        k, v = line[0], line[1:]
        if k == "c": cur = _unescape(v)
        elif k == "n" and cur and "127.0.0.1:" in v:
            part = v.split("127.0.0.1:")[1]
            port = part.split("-")[0].split(":")[0]
            if port.isdigit(): m[port] = {"p": cur, "ts": now}
    m = {k: v for k, v in m.items() if now - v.get("ts", 0) < 180}
    try: json.dump(m, open(PORTMAP, "w"))
    except Exception: pass
    return m

def routes():
    try:
        if os.path.getsize(ACCESS) > 50 * 1024 * 1024:
            lines = open(ACCESS, encoding="utf-8", errors="replace").read().splitlines()[-2000:]
            open(ACCESS, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    except Exception: pass
    pm = _portmap()
    try: lines = open(ACCESS, encoding="utf-8", errors="replace").read().splitlines()[-800:]
    except Exception: return []
    agg = {}
    for ln in lines:
        if " from 127.0.0.1:" not in ln: continue
        try:
            port = ln.split(" from 127.0.0.1:")[1].split(" ")[0]
            tag = "proxy" if "-> proxy" in ln else ("direct" if "-> direct" in ln else None)
            if not tag: continue
            proc = pm.get(port, {}).get("p")
            if not proc or proc == "xray": continue
            e = agg.setdefault(proc, {"p": proc, "proxy": 0, "direct": 0, "hosts": []})
            e[tag] += 1
            if tag == "proxy":
                host = ln.split("accepted //")[-1].split(":")[0] if "accepted //" in ln else ""
                if host and host not in e["hosts"]:
                    e["hosts"].append(host)
        except Exception: continue
    for v in agg.values():
        v["hosts"] = v["hosts"][-4:]
    return sorted(agg.values(), key=lambda x: -(x["proxy"] + x["direct"]))

if locked():
    print("{}")
    raise SystemExit
import concurrent.futures as _cf
with _cf.ThreadPoolExecutor(max_workers=2) as _ex:
    _fl = _ex.submit(local)
    _fr = _ex.submit(remote)
    on, running, lat, loss, fw_app, fw_stun = _fl.result()
    r = _fr.result() if running else {}
out = {
    "proxy_on": on, "xray": running, "latency": lat, "loss": loss,
    "today": r.get("today", 0), "month": r.get("month", 0),
    "conns": r.get("conns", 0),
    "daily": r.get("daily", []), "hourly": r.get("hourly", []),
    "cpu": r.get("cpu", 0), "mem_used": r.get("mem_used", 0), "mem_total": r.get("mem_total", 0),
    "disk": r.get("disk", 0), "load": r.get("load", "-"), "uptime": r.get("uptime", "-"),
    "ssh_fail": r.get("ssh_fail", 0), "probes": r.get("probes", 0), "banned": r.get("banned", 0),
    "last": r.get("last", ""), "speed_up": r.get("speed_up", 0), "speed_down": r.get("speed_down", 0),
    "sites": r.get("sites", []),
    "procs": procs(),
    "apps": merge_cache(nettop(), procs()),
    "conn_apps": conn_apps(),
    "fw_app": fw_app, "fw_stun": fw_stun,
    "routes": routes(),
    "ts": int(time.time())
}
unlock()
print(json.dumps(out, ensure_ascii=False))
