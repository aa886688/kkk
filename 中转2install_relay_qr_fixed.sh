#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/usr/local/etc/xray/relay-manager"
MASTER_FILE="${APP_DIR}/master.json"
REGISTRY_FILE="${APP_DIR}/registry.json"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
XRAY_BIN="${XRAY_BIN:-$(command -v xray || true)}"

R="\033[0m"; G="\033[92m"; Y="\033[93m"; C="\033[96m"; E="\033[91m"; B="\033[1m"
say(){ printf "%b\n" "$*"; }
die(){ say "${E}${B}错误：${R}$*"; exit 1; }
[[ $EUID -eq 0 ]] || die "请使用 root 运行。"

install_pkg(){
  local p="$1"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq "$p" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$p" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then yum install -y "$p" >/dev/null 2>&1
  else die "不支持当前系统的软件包管理器。"; fi
}

for p in curl python3 unzip qrencode; do command -v "$p" >/dev/null 2>&1 || install_pkg "$p" || true; done

# zbarimg 用于生成后反向解码校验二维码；不同发行版包名不同。
if ! command -v zbarimg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    install_pkg zbar-tools || true
  elif command -v dnf >/dev/null 2>&1; then
    install_pkg zbar || true
  elif command -v yum >/dev/null 2>&1; then
    install_pkg zbar || true
  fi
fi

XRAY_BIN="$(command -v xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  say "${Y}未检测到 Xray，正在安装...${R}"
  curl -fL --retry 3 "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o /tmp/xray-install.sh
  bash /tmp/xray-install.sh install
  XRAY_BIN="$(command -v xray || true)"
fi
[[ -x "$XRAY_BIN" ]] || die "Xray 安装失败。"

mkdir -p "$APP_DIR" "$(dirname "$XRAY_CONF")"
chmod 700 "$APP_DIR"
if [[ ! -f "$XRAY_CONF" ]]; then
  cat > "$XRAY_CONF" <<'JSON'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[],"routing":{"domainStrategy":"AsIs","rules":[]}}
JSON
fi
[[ -f "$REGISTRY_FILE" ]] || echo '[]' > "$REGISTRY_FILE"

if [[ ! -f "$MASTER_FILE" ]]; then
  UUID="$("$XRAY_BIN" uuid | tail -n1)"
  KEYS="$("$XRAY_BIN" x25519)"
  PRIV="$(printf "%s\n" "$KEYS" | awk -F': ' '/PrivateKey:/{print $2;exit}')"
  PUB="$(printf "%s\n" "$KEYS" | awk -F': ' '/Password \(PublicKey\):/{print $2;exit}')"
  [[ -n "$PUB" ]] || PUB="$(printf "%s\n" "$KEYS" | awk -F': ' '/PublicKey:/{print $2;exit}')"
  SID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"
  SNI="www.apple.com"
  python3 - "$MASTER_FILE" "$UUID" "$PRIV" "$PUB" "$SID" "$SNI" <<'PY'
import json,sys,os
p,u,pr,pu,sid,sni=sys.argv[1:]
json.dump({"uuid":u,"privateKey":pr,"publicKey":pu,"shortId":sid,"sni":sni},open(p,"w"),indent=2)
os.chmod(p,0o600)
PY
fi

eval "$(python3 - "$MASTER_FILE" <<'PY'
import json,sys,shlex
o=json.load(open(sys.argv[1]))
for k,v in {"UUID":o["uuid"],"PRIVATE_KEY":o["privateKey"],"PUBLIC_KEY":o["publicKey"],"SHORT_ID":o["shortId"],"SNI":o["sni"]}.items():
    print(f"{k}={shlex.quote(v)}")
PY
)"



# ==================== 网络检测基础函数（必须在快捷菜单前定义） ====================
get_public_ip(){
  local ip=""
  for u in \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(curl -4 -fsS --connect-timeout 6 --max-time 10 "$u" 2>/dev/null | tr -d ' \r\n' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

proxy_curl_common(){
  # 用法：proxy_curl_common <curl额外参数...> <URL>
  if [[ "$PROTO" == "socks" ]]; then
    if [[ -n "${PUSER:-}" ]]; then
      curl -4 -fsS --connect-timeout 10 --max-time 20 \
        --socks5-hostname "${HOST}:${PPORT}" \
        --proxy-user "${PUSER}:${PPASS}" "$@"
    else
      curl -4 -fsS --connect-timeout 10 --max-time 20 \
        --socks5-hostname "${HOST}:${PPORT}" "$@"
    fi
  else
    if [[ -n "${PUSER:-}" ]]; then
      curl -4 -fsS --connect-timeout 10 --max-time 20 \
        --proxy "http://${HOST}:${PPORT}" \
        --proxy-user "${PUSER}:${PPASS}" "$@"
    else
      curl -4 -fsS --connect-timeout 10 --max-time 20 \
        --proxy "http://${HOST}:${PPORT}" "$@"
    fi
  fi
}

proxy_ip(){
  local ip=""
  for u in \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(proxy_curl_common "$u" 2>/dev/null | tr -d ' \r\n' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

proxy_https_test(){
  local url="$1" out=""
  if [[ "$PROTO" == "socks" ]]; then
    if [[ -n "${PUSER:-}" ]]; then
      out="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
        --socks5-hostname "${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
    else
      out="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
        --socks5-hostname "${HOST}:${PPORT}" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
    fi
  else
    if [[ -n "${PUSER:-}" ]]; then
      out="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
        --proxy "http://${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
    else
      out="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
        --proxy "http://${HOST}:${PPORT}" \
        -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
    fi
  fi
  python3 - "$out" <<'PY'
import sys
x=(sys.argv[1] or "").split()
if len(x)>=2:
    try: print(x[0], round(float(x[1])*1000))
    except: print("000 -1")
else: print("000 -1")
PY
}

local_socks_ip(){
  local port="$1" ip=""
  for u in \
    "https://api.ipify.org" \
    "https://icanhazip.com" \
    "https://ifconfig.me/ip"
  do
    ip="$(curl -4 -fsS --connect-timeout 10 --max-time 20 \
      --socks5-hostname "127.0.0.1:${port}" "$u" 2>/dev/null | tr -d ' \r\n' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

vless_https_test(){
  local url="$1" out=""
  out="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
    --socks5-hostname "127.0.0.1:${LOCAL}" \
    -w '%{http_code} %{time_total}' "$url" 2>/dev/null || true)"
  python3 - "$out" <<'PY'
import sys
x=(sys.argv[1] or "").split()
if len(x)>=2:
    try: print(x[0], round(float(x[1])*1000))
    except: print("000 -1")
else: print("000 -1")
PY
}

find_free_local_port(){
  python3 - <<'PY'
import socket
for p in range(16000,18000):
    s=socket.socket()
    try:
        s.bind(("127.0.0.1",p))
        print(p)
        break
    except OSError:
        pass
    finally:
        s.close()
PY
}

# ==================== 中转线路管理 / 快捷操作 ====================
mkdir -p "$APP_DIR"
[[ -f "$REGISTRY_FILE" ]] || echo '[]' > "$REGISTRY_FILE"
chmod 700 "$APP_DIR"
chmod 600 "$REGISTRY_FILE"

registry_count(){
  python3 - "$REGISTRY_FILE" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    print(len(d) if isinstance(d,list) else 0)
except Exception:
    print(0)
PY
}

registry_save(){
  python3 - "$REGISTRY_FILE" "$NAME" "$PORT" "$IN" "$OUT" "$PROTO" "$HOST" "$PPORT" "$PUSER" "$PPASS" "$PROXY_IP" "$VPS_IP" "$URL" "$LINE_UUID" "$PUBLIC_KEY" "$LINE_SHORT_ID" "$SNI" <<'PY'
import json,sys,datetime,os
(p,name,port,intag,outtag,proto,host,pport,user,pw,pip,vip,url,
 uuid,pbk,sid,sni)=sys.argv[1:]
try:
    d=json.load(open(p,encoding="utf-8"))
    if not isinstance(d,list): d=[]
except Exception:
    d=[]
rec={
 "name":name,"port":int(port),"inTag":intag,"outTag":outtag,
 "protocol":proto,"host":host,"proxyPort":int(pport),
 "username":user,"password":pw,"proxyIP":pip,"vpsIP":vip,
 "vlessURL":url,
 "uuid":uuid,"publicKey":pbk,"shortId":sid,"sni":sni,
 "flow":"xtls-rprx-vision","fingerprint":"chrome","spiderX":"/",
 "createdAt":datetime.datetime.now().isoformat(timespec="seconds")
}
d=[x for x in d if int(x.get("port",-1)) != int(port)]
d.append(rec)
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
os.chmod(p,0o600)
PY
}

registry_list(){
  python3 - "$REGISTRY_FILE" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception: d=[]
if not d:
    print("暂无线路。")
for i,x in enumerate(d,1):
    print(f"[{i:02d}] {x.get('name','未命名')}")
    print(f"    VLESS主机：{x.get('vpsIP','?')}")
    print(f"    VLESS端口：{x.get('port','?')}")
    print(f"    UUID：{x.get('uuid','旧记录-进入后自动解析')}")
    print(f"    上游协议：{str(x.get('protocol','')).upper()}")
    print(f"    代理Host：{x.get('host','')}")
    print(f"    代理端口：{x.get('proxyPort','')}")
    print(f"    代理账号：{x.get('username','')}")
    print(f"    代理密码：{x.get('password','')}")
    print(f"    住宅出口：{x.get('proxyIP','')}")
    print(f"    创建时间：{x.get('createdAt','')}")
    print()
PY
}


registry_rename_current(){
  local newname="$1"
  python3 - "$REGISTRY_FILE" "$PORT" "$newname" <<'PY'
import json,sys,os,urllib.parse
p,port,newname=sys.argv[1:]
d=json.load(open(p,encoding="utf-8"))
for x in d:
    if int(x.get("port",-1))==int(port):
        x["name"]=newname
        # 更新 VLESS URL 的 fragment，方便安卓导入后直接显示新名称
        url=x.get("vlessURL","")
        if url:
            try:
                u=urllib.parse.urlsplit(url)
                x["vlessURL"]=urllib.parse.urlunsplit((u.scheme,u.netloc,u.path,u.query,urllib.parse.quote(newname,safe="")))
            except Exception:
                pass
        break
else:
    raise SystemExit("线路不存在")
json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
os.chmod(p,0o600)
PY
}

registry_delete_current(){
  python3 - "$REGISTRY_FILE" "$PORT" <<'PY'
import json,sys,os
p,port=sys.argv[1:]
d=json.load(open(p,encoding="utf-8"))
nd=[x for x in d if int(x.get("port",-1))!=int(port)]
if len(nd)==len(d):
    raise SystemExit("线路不存在")
json.dump(nd,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
os.chmod(p,0o600)
PY
}

registry_refresh_numbers(){
  # 当前编号由读取时按数组顺序计算，无需写回文件。
  :
}

registry_load(){
  local n="$1"
  eval "$(python3 - "$REGISTRY_FILE" "$n" <<'PY'
import json,sys,shlex,urllib.parse
d=json.load(open(sys.argv[1],encoding="utf-8"))
i=int(sys.argv[2])-1
if i<0 or i>=len(d): raise SystemExit(2)
x=d[i]
url=x.get("vlessURL","")
uuid=x.get("uuid","")
pbk=x.get("publicKey","")
sid=x.get("shortId","")
sni=x.get("sni","")
flow=x.get("flow","xtls-rprx-vision")
fp=x.get("fingerprint","chrome")
spx=x.get("spiderX","/")
# 兼容旧版 registry：直接从现有 VLESS URL 还原手填参数
try:
    u=urllib.parse.urlsplit(url)
    q=urllib.parse.parse_qs(u.query)
    if not uuid: uuid=urllib.parse.unquote(u.username or "")
    if not pbk: pbk=(q.get("pbk") or [""])[0]
    if not sid: sid=(q.get("sid") or [""])[0]
    if not sni: sni=(q.get("sni") or [""])[0]
    flow=(q.get("flow") or [flow])[0]
    fp=(q.get("fp") or [fp])[0]
    spx=(q.get("spx") or q.get("spiderX") or [spx])[0]
except Exception:
    pass
vals={
"LINE_NO":i+1,
"NAME":x.get("name",""),"PORT":x.get("port",""),"IN":x.get("inTag",""),"OUT":x.get("outTag",""),
"PROTO":x.get("protocol",""),"HOST":x.get("host",""),"PPORT":x.get("proxyPort",""),
"PUSER":x.get("username",""),"PPASS":x.get("password",""),"PROXY_IP":x.get("proxyIP",""),
"VPS_IP":x.get("vpsIP",""),"URL":url,
"LINE_UUID":uuid,"LINE_PUBLIC_KEY":pbk,"LINE_SHORT_ID":sid,"LINE_SNI":sni,
"LINE_FLOW":flow,"LINE_FP":fp,"LINE_SPIDERX":spx
}
for k,v in vals.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)" || return 1
  if [[ -z "${OUT:-}" || -z "${IN:-}" ]]; then
    say "${Y}提示：这是旧版线路记录，缺少 inTag/outTag；查看/测试可用，但“修改上游代理”前建议重新新增该线路。${R}"
  fi
}


all_lines_integrity_check(){
  clear 2>/dev/null || true
  say "${C}${B}════════ 全部线路防串线检查 ════════${R}"

  python3 - "$REGISTRY_FILE" "$XRAY_CONF" <<'PY'
import json,sys,collections
rp,cp=sys.argv[1:]
try:
    reg=json.load(open(rp,encoding="utf-8"))
except Exception as e:
    print("✗ 无法读取 registry.json:",e); raise SystemExit(2)
try:
    conf=json.load(open(cp,encoding="utf-8"))
except Exception as e:
    print("✗ 无法读取 Xray 配置:",e); raise SystemExit(2)

ports=[int(x.get("port",-1)) for x in reg]
uuids=[x.get("uuid","") for x in reg if x.get("uuid")]
sids=[x.get("shortId","") for x in reg if x.get("shortId")]
intags=[x.get("inTag","") for x in reg if x.get("inTag")]
outtags=[x.get("outTag","") for x in reg if x.get("outTag")]

def dup(vals):
    c=collections.Counter(vals)
    return [k for k,v in c.items() if k and v>1]

print(f"线路数量：{len(reg)}")
for title, vals in [
    ("端口重复",dup(ports)),
    ("UUID重复",dup(uuids)),
    ("ShortID重复",dup(sids)),
    ("inTag重复",dup(intags)),
    ("outTag重复",dup(outtags)),
]:
    if vals: print(f"✗ {title}: {', '.join(map(str,vals))}")
    else: print(f"✓ {title}: 0")

inbounds={x.get("tag"):x for x in conf.get("inbounds",[]) if x.get("tag")}
outbounds={x.get("tag"):x for x in conf.get("outbounds",[]) if x.get("tag")}
rules=conf.get("routing",{}).get("rules",[])

bad=0
for i,x in enumerate(reg,1):
    name=x.get("name","未命名")
    port=int(x.get("port",-1))
    it=x.get("inTag","")
    ot=x.get("outTag","")
    pip=x.get("proxyIP","")
    ok=True
    if it not in inbounds:
        print(f"✗ [{i:02d}] {name}: 缺少 inbound {it}"); ok=False
    elif int(inbounds[it].get("port",-1))!=port:
        print(f"✗ [{i:02d}] {name}: inbound端口不匹配"); ok=False
    if ot not in outbounds:
        print(f"✗ [{i:02d}] {name}: 缺少 outbound {ot}"); ok=False
    matches=[r for r in rules if it in r.get("inboundTag",[])]
    if not matches:
        print(f"✗ [{i:02d}] {name}: 缺少专属路由"); ok=False
    elif matches[0].get("outboundTag")!=ot:
        print(f"✗ [{i:02d}] {name}: 路由指向错误 {matches[0].get('outboundTag')}"); ok=False
    if any(str(r.get("outboundTag","")).lower() in ("direct","freedom") for r in matches):
        print(f"✗ [{i:02d}] {name}: 存在 DIRECT/freedom 路由"); ok=False
    if ok:
        print(f"✓ [{i:02d}] {name}: {port} → {ot} → 住宅出口记录 {pip}")
    else:
        bad+=1

if bad:
    print(f"\n防串线检查结果：✗ 发现 {bad} 条异常")
    raise SystemExit(3)
else:
    print("\n防串线检查结果：✓ 配置层未发现串线 / DIRECT泄漏")
PY
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    say "${E}检查发现异常，请不要继续新增/修改线路，先修复。${R}"
  fi
  read -rp "按回车返回..."
}

current_fullchain_check(){
  show_current_header
  say "${C}正在检查当前线路完整出口一致性...${R}"

  # 先检查上游住宅代理出口
  local pip
  pip="$(proxy_ip || true)"
  [[ -n "$pip" ]] || { say "${E}✗ 上游住宅代理不可用${R}"; read -rp "按回车返回..."; return 0; }

  # 临时创建本地 VLESS 客户端，强制走当前线路完整链路
  local lp tmp pid vip
  lp="$(find_free_local_port)"
  [[ -n "$lp" ]] || { say "${E}✗ 找不到本地测试端口${R}"; read -rp "按回车返回..."; return 0; }
  tmp="/tmp/relay-check-${PORT}.json"

  cat > "$tmp" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[{"listen":"127.0.0.1","port":${lp},"protocol":"socks","settings":{"udp":false}}],
  "outbounds":[{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"127.0.0.1","port":${PORT},"users":[{"id":"${LINE_UUID}","encryption":"none","flow":"${LINE_FLOW:-xtls-rprx-vision}"}]}]},
    "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
      "fingerprint":"${LINE_FP:-chrome}","serverName":"${LINE_SNI:-$SNI}",
      "publicKey":"${LINE_PUBLIC_KEY:-$PUBLIC_KEY}","shortId":"${LINE_SHORT_ID}",
      "spiderX":"${LINE_SPIDERX:-/}"
    }}
  }]
}
EOF

  "$XRAY_BIN" run -config "$tmp" >/tmp/relay-check-client.log 2>&1 &
  pid=$!
  sleep 1
  vip="$(local_socks_ip "$lp" || true)"
  kill "$pid" >/dev/null 2>&1 || true
  rm -f "$tmp"

  say "住宅代理出口：${pip}"
  say "VLESS完整链路：${vip:-检测失败}"
  say "VPS公网IP：${VPS_IP}"

  if [[ -n "$vip" && "$vip" == "$pip" && "$vip" != "$VPS_IP" ]]; then
    say "${G}✓ 当前线路出口一致：VLESS = 住宅代理 ≠ VPS${R}"
  else
    say "${E}✗ 当前线路出口异常，请停止使用并检查。${R}"
  fi
  read -rp "按回车返回..."
}

rename_current_line(){
  show_current_header
  local newname
  read -rp "请输入新的线路名称（B=取消）：" newname
  [[ "$newname" =~ ^(B|b|BACK|back|返回)$ ]] && return 0
  [[ -n "$newname" ]] || { say "${E}名称不能为空${R}"; sleep 1; return 0; }
  registry_rename_current "$newname" || { say "${E}改名失败${R}"; sleep 1; return 0; }
  NAME="$newname"
  # 更新当前内存中的 URL fragment
  URL="$(python3 - "$URL" "$newname" <<'PY'
import sys,urllib.parse
u=urllib.parse.urlsplit(sys.argv[1]); name=sys.argv[2]
print(urllib.parse.urlunsplit((u.scheme,u.netloc,u.path,u.query,urllib.parse.quote(name,safe=""))))
PY
)"
  say "${G}✓ 已修改线路名称：${NAME}${R}"
  read -rp "按回车返回..."
}

delete_current_line(){
  show_current_header
  say "${E}${B}警告：将删除当前线路的 VLESS入站、上游出站、路由规则和登记记录。${R}"
  read -rp "请输入 DELETE 确认删除（其他内容取消）：" yes
  [[ "$yes" == "DELETE" ]] || { say "${Y}已取消。${R}"; sleep 1; return 0; }

  [[ -n "${IN:-}" && -n "${OUT:-}" ]] || {
    say "${E}旧线路缺少 inTag/outTag，不能自动安全删除。${R}"
    read -rp "按回车返回..."
    return 0
  }

  local bak="${XRAY_CONF}.backup.delete.$(date +%Y%m%d-%H%M%S)"
  cp "$XRAY_CONF" "$bak"

  python3 - "$XRAY_CONF" "$IN" "$OUT" <<'PY'
import json,sys
p,it,ot=sys.argv[1:]
c=json.load(open(p,encoding="utf-8"))
c["inbounds"]=[x for x in c.get("inbounds",[]) if x.get("tag")!=it]
c["outbounds"]=[x for x in c.get("outbounds",[]) if x.get("tag")!=ot]
r=c.setdefault("routing",{}).setdefault("rules",[])
c["routing"]["rules"]=[x for x in r if it not in x.get("inboundTag",[]) and x.get("outboundTag")!=ot]
json.dump(c,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY

  if ! "$XRAY_BIN" run -test -config "$XRAY_CONF" >/tmp/relay-delete-test.log 2>&1; then
    cp "$bak" "$XRAY_CONF"
    say "${E}✗ 删除后的 Xray 配置检查失败，已回滚。${R}"
    read -rp "按回车返回..."
    return 0
  fi

  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    cp "$bak" "$XRAY_CONF"
    systemctl restart xray >/dev/null 2>&1 || true
    say "${E}✗ Xray重启失败，已回滚。${R}"
    read -rp "按回车返回..."
    return 0
  fi

  registry_delete_current || {
    cp "$bak" "$XRAY_CONF"
    systemctl restart xray >/dev/null 2>&1 || true
    say "${E}✗ registry 删除失败，已回滚 Xray。${R}"
    read -rp "按回车返回..."
    return 0
  }

  say "${G}✓ 当前线路已安全删除。${R}"
  if [[ "$(registry_count)" -gt 0 ]]; then
    registry_load 1 || true
  else
    NAME=""; PORT=""; IN=""; OUT=""; PROTO=""; HOST=""; PPORT=""; PUSER=""; PPASS=""; PROXY_IP=""; VPS_IP=""; URL=""
  fi
  sleep 1
}

restart_xray_safe(){
  say "${C}正在检查并重启 Xray...${R}"
  if ! "$XRAY_BIN" run -test -config "$XRAY_CONF" >/tmp/relay-restart-test.log 2>&1; then
    say "${E}✗ 当前 Xray 配置检查失败，未重启。${R}"
    read -rp "按回车返回..."
    return 0
  fi
  systemctl restart xray
  sleep 1
  if systemctl is-active --quiet xray; then
    say "${G}✓ Xray 已重启并处于运行状态。${R}"
  else
    say "${E}✗ Xray 重启失败，请查看日志。${R}"
  fi
  read -rp "按回车返回..."
}

show_current_header(){
  say "${C}${B}╔══════════════════════════════════════════════╗${R}"
  say "${C}${B}  当前线路：[${LINE_NO:-NEW}] ${NAME}${R}"
  say "${C}${B}╠══════════════════════════════════════════════╣${R}"
  say "  VLESS主机： ${VPS_IP}"
  say "  VLESS端口： ${PORT}"
  say "  上游协议：  ${PROTO^^}"
  say "  代理Host：  ${HOST}"
  say "  代理端口：  ${PPORT}"
  say "  代理账号：  ${Y}${PUSER}${R}"
  say "  代理密码：  ${Y}${PPASS}${R}"
  say "  住宅出口：  ${G}${PROXY_IP}${R}"
  say "${C}${B}╚══════════════════════════════════════════════╝${R}"
}

proxy_test_current(){
  show_current_header
  say "${C}正在通过住宅代理检测出口...${R}"
  local ip
  ip="$(proxy_ip || true)"
  if [[ -n "$ip" ]]; then
    say "${G}✓ 当前住宅出口：${ip}${R}"
  else
    say "${E}✗ 代理连接失败 / 认证错误 / 超时${R}"
  fi
}

wechat_test_current(){
  show_current_header
  local urls=("https://weixin.qq.com/" "https://open.weixin.qq.com/" "https://res.wx.qq.com/")
  local names=("weixin.qq.com" "open.weixin.qq.com" "res.wx.qq.com")
  say "${C}微信/腾讯网络专项检测（强制经过住宅代理）...${R}"
  for i in 0 1 2; do
    local result code ms
    result="$(proxy_https_test "${urls[$i]}")"
    code="$(awk '{print $1}' <<< "$result")"
    ms="$(awk '{print $2}' <<< "$result")"
    if [[ "$code" != "000" && "$ms" -ge 0 ]]; then
      say "${G}✓ ${names[$i]}  HTTP ${code} / ${ms} ms${R}"
    else
      say "${E}✗ ${names[$i]} 失败 / 超时${R}"
    fi
  done
  local ip
  ip="$(proxy_ip || true)"
  [[ -n "$ip" ]] && say "${G}测试出口：${ip}${R}"
  say "${Y}仅验证网络可达性和延迟，不代表注册一定成功。${R}"
}

speed_test_current(){
  show_current_header
  local cn="" ov=""
  if [[ "$PROTO" == "socks" ]]; then
    if [[ -n "$PUSER" ]]; then
      cn="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --socks5-hostname "${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" -w '%{time_total}' https://www.baidu.com/ 2>/dev/null || true)"
      ov="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --socks5-hostname "${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" -w '%{time_total}' https://www.cloudflare.com/ 2>/dev/null || true)"
    else
      cn="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --socks5-hostname "${HOST}:${PPORT}" -w '%{time_total}' https://www.baidu.com/ 2>/dev/null || true)"
      ov="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --socks5-hostname "${HOST}:${PPORT}" -w '%{time_total}' https://www.cloudflare.com/ 2>/dev/null || true)"
    fi
  else
    if [[ -n "$PUSER" ]]; then
      cn="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --proxy "http://${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" -w '%{time_total}' https://www.baidu.com/ 2>/dev/null || true)"
      ov="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --proxy "http://${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" -w '%{time_total}' https://www.cloudflare.com/ 2>/dev/null || true)"
    else
      cn="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --proxy "http://${HOST}:${PPORT}" -w '%{time_total}' https://www.baidu.com/ 2>/dev/null || true)"
      ov="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 --proxy "http://${HOST}:${PPORT}" -w '%{time_total}' https://www.cloudflare.com/ 2>/dev/null || true)"
    fi
  fi
  python3 - "$cn" "$ov" <<'PY'
import sys
def m(x):
    try:return round(float(x)*1000)
    except:return -1
print(f"国内 HTTPS 总耗时：{m(sys.argv[1])} ms")
print(f"海外 HTTPS 总耗时：{m(sys.argv[2])} ms")
PY
}


make_qr_png(){
  local url="$1" png="$2"
  qrencode -l L -s 8 -m 4 -o "$png" "$url" >/dev/null 2>&1
}

validate_qr_png(){
  local png="$1" expected="$2" decoded=""
  command -v zbarimg >/dev/null 2>&1 || return 2
  decoded="$(zbarimg --quiet --raw "$png" 2>/dev/null | head -n1 | tr -d '\r\n' || true)"
  [[ "$decoded" == "$expected" ]]
}

terminal_qr_width(){
  local url="$1"
  qrencode -t UTF8 -m 2 "$url" 2>/dev/null | awk 'length($0)>m{m=length($0)}END{print m+0}'
}

show_terminal_qr_safe(){
  local url="$1"
  local cols need
  cols="$(tput cols 2>/dev/null || echo 80)"
  need="$(terminal_qr_width "$url")"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$need" =~ ^[0-9]+$ ]] || need=999

  echo
  say "${Y}${B}【终端二维码】${R}"
  say "当前终端宽度：${cols} 列；二维码预计需要：${need} 列。"

  if (( cols >= need + 4 )); then
    echo
    qrencode -t UTF8 -l L -m 2 "$url" || true
    echo
    say "${G}✓ 二维码完整显示，没有被终端自动换行。${R}"
  else
    say "${E}当前终端太窄，为避免二维码被裁切/换行，本次不强行显示大二维码。${R}"
    say "${Y}请把终端窗口拉宽后重新进入 [3]，或使用下面生成的 PNG 二维码。${R}"
  fi
}

show_qr_current(){
  show_current_header
  echo
  say "${Y}${B}════════ 安卓 VLESS 手动填写参数 ════════${R}"
  say "线路编号：      ${C}[${LINE_NO:-NEW}]${R}"
  say "线路名称：      ${C}${NAME}${R}"
  say "协议：          ${G}VLESS${R}"
  say "主机 / 地址：   ${C}${VPS_IP}${R}"
  say "端口：          ${C}${PORT}${R}"
  say "用户ID / UUID： ${Y}${LINE_UUID:-未记录}${R}"
  say "加密：          none"
  say "Flow：          ${LINE_FLOW:-xtls-rprx-vision}"
  say "传输：          TCP"
  say "安全：          REALITY"
  say "SNI：           ${LINE_SNI:-$SNI}"
  say "Fingerprint：   ${LINE_FP:-chrome}"
  say "Public Key：    ${Y}${LINE_PUBLIC_KEY:-$PUBLIC_KEY}${R}"
  say "Short ID：      ${Y}${LINE_SHORT_ID:-未记录}${R}"
  say "SpiderX：       ${LINE_SPIDERX:-/}"
  echo

  say "${C}${B}【VLESS完整链接】${R}"
  say "$URL"
  echo

  local png="/root/relay-${PORT}.png"
  if make_qr_png "$URL" "$png"; then
    say "${G}✓ 高清二维码已生成：${png}${R}"
    if validate_qr_png "$png" "$URL"; then
      say "${G}✓ 二维码反向解码校验通过：二维码内容与 VLESS 链接完全一致。${R}"
    else
      case "$?" in
        2) say "${Y}提示：服务器未安装 zbarimg，无法自动反解校验，但 PNG 已正常生成。${R}" ;;
        *) say "${E}✗ 二维码反向解码校验失败，请优先复制 VLESS 链接导入。${R}" ;;
      esac
    fi
  else
    say "${E}✗ PNG二维码生成失败。${R}"
  fi

  # 为避免你照片里那种“二维码顶部/左右被终端裁切”的情况，
  # 先检测终端宽度，只有足够宽才打印二维码。
  show_terminal_qr_safe "$URL"

  say "${Y}如果 V2Ray 客户端扫码仍无反应：${R}"
  say "1. 先复制上面的完整 VLESS 链接尝试“从剪贴板导入”；"
  say "2. 确认安卓客户端版本支持 VLESS + REALITY；"
  say "3. 扫码时尽量扫 PNG，不要扫被终端换行或裁切的二维码。"
}

modify_current_proxy(){
  show_current_header
  if [[ -z "${OUT:-}" ]]; then
    say "${E}该线路来自旧版记录，缺少 outTag，不能安全原地修改。请用[1]新增一条线路后再删除旧记录。${R}"
    read -rp "按回车返回..."
    return 0
  fi
  say "${Y}${B}修改当前线路上游代理${R}"
  echo "输入 B 可返回上一步；输入 0 可取消。"
  local old_proto="$PROTO" old_host="$HOST" old_port="$PPORT" old_user="$PUSER" old_pass="$PPASS"
  local st=1 v=""
  while true; do
    case "$st" in
      1)
        echo "1=SOCKS5  2=HTTP"
        read -rp "协议（B=取消）：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回|0)$ ]] && return 0
        case "$v" in 1) PROTO="socks";st=2;;2) PROTO="http";st=2;;*) say "${E}请选择1或2${R}";;esac
        ;;
      2)
        read -rp "Host（B=上一步）：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回)$ ]] && { st=1; continue; }
        [[ -n "$v" ]] || { say "${E}Host不能为空${R}";continue; }
        HOST="$v";st=3
        ;;
      3)
        read -rp "端口（B=上一步）：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回)$ ]] && { st=2;continue; }
        [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1&&v<=65535)) || { say "${E}端口错误${R}";continue; }
        PPORT="$v";st=4
        ;;
      4)
        read -rp "用户名，可空（B=上一步）：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回)$ ]] && { st=3;continue; }
        PUSER="$v";st=5
        ;;
      5)
        read -rp "密码，可空（B=上一步）：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回)$ ]] && { st=4;continue; }
        PPASS="$v"
        say "协议：${PROTO^^}"
        say "Host：${HOST}:${PPORT}"
        say "账号：${PUSER}"
        say "密码：${PPASS}"
        read -rp "输入 YES 确认修改，B返回：" v
        [[ "$v" =~ ^(B|b|BACK|back|返回)$ ]] && { st=5;continue; }
        [[ "$v" == "YES" ]] && break
        ;;
    esac
  done

  say "${C}先检测新代理...${R}"
  local nip
  nip="$(proxy_ip || true)"
  if [[ -z "$nip" ]]; then
    say "${E}新代理不可用，保持原配置。${R}"
    PROTO="$old_proto";HOST="$old_host";PPORT="$old_port";PUSER="$old_user";PPASS="$old_pass"
    return 0
  fi
  [[ "$nip" != "$VPS_IP" ]] || {
    say "${E}新代理出口等于VPS公网IP，拒绝修改。${R}"
    PROTO="$old_proto";HOST="$old_host";PPORT="$old_port";PUSER="$old_user";PPASS="$old_pass"
    return 0
  }

  local bak="${XRAY_CONF}.backup.relay-edit.$(date +%Y%m%d-%H%M%S)"
  cp "$XRAY_CONF" "$bak"
  python3 - "$XRAY_CONF" "$OUT" "$PROTO" "$HOST" "$PPORT" "$PUSER" "$PPASS" <<'PY'
import json,sys
p,tag,proto,host,port,user,pw=sys.argv[1:]
c=json.load(open(p,encoding="utf-8"))
srv={"address":host,"port":int(port)}
if user or pw:srv["users"]=[{"user":user,"pass":pw}]
for o in c.get("outbounds",[]):
    if o.get("tag")==tag:
        o["protocol"]=proto
        o["settings"]={"servers":[srv]}
        break
else: raise SystemExit("outbound not found")
json.dump(c,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
PY
  "$XRAY_BIN" run -test -config "$XRAY_CONF" >/tmp/relay-edit-test.log 2>&1 || {
    cp "$bak" "$XRAY_CONF"
    say "${E}配置检查失败，已回滚。${R}"
    PROTO="$old_proto";HOST="$old_host";PPORT="$old_port";PUSER="$old_user";PPASS="$old_pass"
    return 0
  }
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    cp "$bak" "$XRAY_CONF";systemctl restart xray >/dev/null 2>&1 || true
    say "${E}Xray启动失败，已回滚。${R}"
    PROTO="$old_proto";HOST="$old_host";PPORT="$old_port";PUSER="$old_user";PPASS="$old_pass"
    return 0
  fi
  PROXY_IP="$nip"
  # 保留当前线路原有 VLESS/REALITY 身份参数
  [[ -n "${LINE_PUBLIC_KEY:-}" ]] && PUBLIC_KEY="$LINE_PUBLIC_KEY"
  [[ -n "${LINE_SNI:-}" ]] && SNI="$LINE_SNI"
  registry_save
  say "${G}✓ 当前线路上游代理已修改并保存。${R}"
  read -rp "按回车返回..."
}

quick_menu(){
  while true; do
    clear 2>/dev/null || true
    show_current_header
    echo
    say "${C}${B}【快捷操作】${R}"
    echo "[1] 新增中转线路"
    echo "[2] 查看 / 选择全部线路"
    echo "[3] 安卓手填参数 / 二维码 / VLESS链接"
    echo "[4] 测试当前住宅代理"
    echo "[5] 微信专项测试"
    echo "[6] 国内 / 海外测速"
    echo "[7] 当前线路出口一致性检查"
    echo "[8] 全部线路防串线检查"
    echo "[9] 修改当前线路住宅代理"
    echo "[10] 删除当前线路"
    echo "[11] 修改线路名称"
    echo "[12] 查看 Xray 实时日志"
    echo "[13] 重启 Xray"
    echo "[0] 退出"
    echo
    read -rp "请输入选择 [0-9]：" op
    case "$op" in
      1) return 10 ;;
      2)
        clear 2>/dev/null || true
        registry_list
        read -rp "输入线路编号选择，按回车返回：" n
        [[ -z "$n" ]] && continue
        registry_load "$n" || { say "${E}编号无效${R}";sleep 1; }
        ;;
      3) clear 2>/dev/null || true;show_qr_current;read -rp "按回车返回..." ;;
      4) clear 2>/dev/null || true;proxy_test_current;read -rp "按回车返回..." ;;
      5) clear 2>/dev/null || true;wechat_test_current;read -rp "按回车返回..." ;;
      6) clear 2>/dev/null || true;speed_test_current;read -rp "按回车返回..." ;;
      7) clear 2>/dev/null || true;current_fullchain_check ;;
      8) all_lines_integrity_check ;;
      9) clear 2>/dev/null || true;modify_current_proxy ;;
      10) clear 2>/dev/null || true;delete_current_line ;;
      11) clear 2>/dev/null || true;rename_current_line ;;
      12)
        say "${Y}按 Ctrl+C 停止实时日志并返回菜单。${R}"
        set +e
        journalctl -u xray -f
        set -e
        ;;
      13) clear 2>/dev/null || true;restart_xray_safe ;;
      0) exit 0 ;;
      *) say "${E}选择无效${R}";sleep 1 ;;
    esac
  done
}


clear 2>/dev/null || true

if [[ "$(registry_count)" -gt 0 ]]; then
  registry_load 1 || true
  rc=0
  rc=0
  quick_menu || rc=$?
  if [[ "$rc" -ne 10 ]]; then
    exit 0
  fi
fi

say "${C}${B}===== VLESS + REALITY 中转部署 =====${R}"
say "${G}中转VPS只做入口，最终出口保持住宅代理IP。${R}"
say "${E}${B}住宅代理失败时不回落到VPS DIRECT。${R}"
echo


# -------------------- 可返回上一步的中文配置向导 --------------------
# 在任意输入步骤输入 B / b / BACK / 返回，可回到上一步。
step=1
NAME=""; PROTO=""; HOST=""; PPORT=""; PUSER=""; PPASS=""
is_back(){ case "${1:-}" in B|b|BACK|back|返回) return 0;; *) return 1;; esac; }

while true; do
  case "$step" in
    1)
      echo
      say "${C}${B}[1/6] 线路备注${R}"
      read -rp "例如：日本动态中转（输入 B 返回/退出）：" v
      if is_back "$v"; then
        read -rp "已经是第一步。按回车继续，或输入 0 退出：" q
        [[ "$q" == "0" ]] && exit 0
        continue
      fi
      [[ -n "$v" ]] || { say "${E}备注不能为空。${R}"; continue; }
      NAME="$v"; step=2
      ;;
    2)
      echo
      say "${C}${B}[2/6] 上游代理协议${R}"
      echo "1 = SOCKS5"
      echo "2 = HTTP"
      read -rp "请选择 [1/2]（B=返回上一步）：" v
      if is_back "$v"; then step=1; continue; fi
      case "$v" in
        1) PROTO="socks"; step=3;;
        2) PROTO="http"; step=3;;
        *) say "${E}请选择 1 或 2。${R}";;
      esac
      ;;
    3)
      echo
      say "${C}${B}[3/6] 代理 Host / IP${R}"
      read -rp "请输入代理 Host/IP（B=返回上一步）：" v
      if is_back "$v"; then step=2; continue; fi
      [[ -n "$v" ]] || { say "${E}Host/IP 不能为空。${R}"; continue; }
      HOST="$v"; step=4
      ;;
    4)
      echo
      say "${C}${B}[4/6] 代理端口${R}"
      read -rp "请输入代理端口（B=返回上一步）：" v
      if is_back "$v"; then step=3; continue; fi
      [[ "$v" =~ ^[0-9]+$ ]] && (( v>=1 && v<=65535 )) || { say "${E}端口必须是 1-65535 的数字。${R}"; continue; }
      PPORT="$v"; step=5
      ;;
    5)
      echo
      say "${C}${B}[5/6] 代理用户名${R}"
      read -rp "请输入代理用户名，可留空（B=返回上一步）：" v
      if is_back "$v"; then step=4; continue; fi
      PUSER="$v"; step=6
      ;;
    6)
      echo
      say "${C}${B}[6/6] 代理密码${R}"
      read -rp "请输入代理密码，可留空（B=返回上一步）：" v
      if is_back "$v"; then step=5; continue; fi
      PPASS="$v"
      echo
      say "${Y}${B}========== 配置核对 ==========${R}"
      say "线路备注：${C}${NAME}${R}"
      say "代理协议：${C}${PROTO^^}${R}"
      say "代理 Host：${C}${HOST}${R}"
      say "代理端口：${C}${PPORT}${R}"
      say "代理用户名：${Y}${PUSER}${R}"
      say "代理密码：${Y}${PPASS}${R}"
      echo
      echo "1 = 确认并开始检测/部署"
      echo "2 = 返回修改密码"
      echo "3 = 从头重新填写"
      echo "0 = 退出"
      read -rp "请选择 [0/1/2/3]：" v
      case "$v" in
        1) break 2;;
        2) step=6;;
        3) step=1;;
        0) exit 0;;
        *) say "${E}选择无效。${R}";;
      esac
      ;;
  esac
done

say "${G}配置已确认，开始检测网络环境...${R}"
say "${C}[检测 1/4] 获取 VPS 公网 IPv4...${R}"
VPS_IP="$(get_public_ip || true)"
[[ -n "$VPS_IP" ]] || die "获取 VPS 公网IP失败（已尝试3个检测源）。"
say "${G}✓ VPS公网IP：${VPS_IP}${R}"
say "${C}[检测 2/4] 测试住宅代理认证与出口（最长15秒）...${R}"
PIP1="$(proxy_ip || true)"
[[ -n "$PIP1" ]] || die "代理连接失败、认证错误或超时。"
say "${G}✓ 第一次代理出口：${PIP1}${R}"

say "${C}[检测 3/4] 再次核对短时出口一致性...${R}"
sleep 1
PIP2="$(proxy_ip || true)"
[[ -n "$PIP2" ]] || die "第二次代理出口检测失败或超时。"
say "${G}✓ 第二次代理出口：${PIP2}${R}"
[[ "$PIP1" == "$PIP2" ]] || die "短时间出口发生变化：${PIP1} -> ${PIP2}。请使用粘性 Session 或更长轮换周期。"
[[ "$PIP1" != "$VPS_IP" ]] || die "代理出口与VPS公网IP相同。"
PROXY_IP="$PIP1"
say "${G}✓ 住宅代理出口稳定：${PROXY_IP}${R}"

WECHAT_URLS=("https://weixin.qq.com/" "https://open.weixin.qq.com/" "https://res.wx.qq.com/")
WECHAT_NAMES=("weixin.qq.com" "open.weixin.qq.com" "res.wx.qq.com")
PROXY_WECHAT_SUMMARY=()

say "${C}[微信测试 A] 强制通过住宅代理测试微信/腾讯端点...${R}"
for i in 0 1 2; do
  result="$(proxy_https_test "${WECHAT_URLS[$i]}")"
  code="$(awk '{print $1}' <<< "$result")"
  ms="$(awk '{print $2}' <<< "$result")"
  if [[ "$code" != "000" && "$ms" -ge 0 ]]; then
    say "${G}✓ ${WECHAT_NAMES[$i]}  HTTP ${code} / ${ms} ms${R}"
  else
    say "${E}✗ ${WECHAT_NAMES[$i]}  失败/超时${R}"
  fi
  PROXY_WECHAT_SUMMARY+=("${WECHAT_NAMES[$i]}|${code}|${ms}")
done

PIP_AFTER_WECHAT="$(proxy_ip || true)"
[[ -n "$PIP_AFTER_WECHAT" ]] || die "微信测试后无法再次读取住宅代理出口。"
[[ "$PIP_AFTER_WECHAT" == "$PROXY_IP" ]] || die "微信测试期间住宅出口发生变化：${PROXY_IP} -> ${PIP_AFTER_WECHAT}"
say "${G}✓ 微信测试期间住宅出口保持一致：${PROXY_IP}${R}"

say "${C}[检测 4/4] 代理出口与 VPS 出口隔离检查通过。开始写入 VLESS 中转...${R}"

PORT="$(python3 - "$XRAY_CONF" <<'PY'
import json,socket,sys
used=set()
try:
 c=json.load(open(sys.argv[1]))
 for x in c.get("inbounds",[]):
  if isinstance(x.get("port"),int): used.add(x["port"])
except: pass
for p in range(8501,9000):
 if p in used: continue
 s=socket.socket()
 try: s.bind(("0.0.0.0",p)); print(p); break
 except: pass
 finally: s.close()
PY
)"
[[ -n "$PORT" ]] || die "没有可用端口。"

# 新增前再次验证 registry / Xray 中不存在同端口，防止并发或旧记录冲突。
python3 - "$REGISTRY_FILE" "$XRAY_CONF" "$PORT" <<'PY'
import json,sys
rp,cp,port=sys.argv[1:]
p=int(port)
try:d=json.load(open(rp,encoding="utf-8"))
except:d=[]
if any(int(x.get("port",-1))==p for x in d):
    raise SystemExit("registry端口重复")
try:c=json.load(open(cp,encoding="utf-8"))
except:c={}
if any(int(x.get("port",-1))==p for x in c.get("inbounds",[])):
    raise SystemExit("Xray inbound端口重复")
PY

# 每条线路独立生成 UUID 与 REALITY Short ID，避免多线路手填时混淆。
LINE_UUID="$("$XRAY_BIN" uuid | tail -n1 | tr -d '\r\n')"
LINE_SHORT_ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"
LINE_PUBLIC_KEY="$PUBLIC_KEY"
LINE_SNI="$SNI"
LINE_FLOW="xtls-rprx-vision"
LINE_FP="chrome"
LINE_SPIDERX="/"
[[ -n "$LINE_UUID" && -n "$LINE_SHORT_ID" ]] || die "生成当前线路 VLESS 身份参数失败。"

ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(5))
PY
)"
IN="relay-in-$ID"; OUT="relay-out-$ID"; BACKUP="${XRAY_CONF}.backup.relay.$(date +%Y%m%d-%H%M%S)"; cp "$XRAY_CONF" "$BACKUP"

python3 - "$XRAY_CONF" "$IN" "$OUT" "$PORT" "$LINE_UUID" "$PRIVATE_KEY" "$LINE_SHORT_ID" "$SNI" "$PROTO" "$HOST" "$PPORT" "$PUSER" "$PPASS" <<'PY'
import json,sys
conf,it,ot,port,uuid,priv,sid,sni,proto,host,pport,user,pw=sys.argv[1:]
c=json.load(open(conf))
server={"address":host,"port":int(pport)}
if user or pw: server["users"]=[{"user":user,"pass":pw}]
c.setdefault("inbounds",[]).append({"tag":it,"listen":"0.0.0.0","port":int(port),"protocol":"vless","settings":{"clients":[{"id":uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":False,"target":f"{sni}:443","xver":0,"serverNames":[sni],"privateKey":priv,"shortIds":[sid]}}})
c.setdefault("outbounds",[]).append({"tag":ot,"protocol":proto,"settings":{"servers":[server]}})
r=c.setdefault("routing",{"domainStrategy":"AsIs","rules":[]})
r.setdefault("rules",[]).insert(0,{"type":"field","inboundTag":[it],"outboundTag":ot})
json.dump(c,open(conf,"w"),indent=2)
PY

"$XRAY_BIN" run -test -config "$XRAY_CONF" >/tmp/relay-test.log 2>&1 || { cp "$BACKUP" "$XRAY_CONF"; die "Xray配置检查失败，已回滚。"; }
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || die "Xray未启动。"

LOCAL="$(find_free_local_port)"
[[ -n "$LOCAL" ]] || die "找不到可用的本地自检端口。"
CLIENT="/tmp/relay-client.json"
cat > "$CLIENT" <<EOF2
{"inbounds":[{"listen":"127.0.0.1","port":${LOCAL},"protocol":"socks","settings":{"udp":false}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":${PORT},"users":[{"id":"${LINE_UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"fingerprint":"chrome","serverName":"${SNI}","publicKey":"${PUBLIC_KEY}","shortId":"${LINE_SHORT_ID}","spiderX":"/"}}}]}
EOF2
"$XRAY_BIN" run -config "$CLIENT" >/tmp/relay-client.log 2>&1 &
PID=$!
trap 'kill $PID >/dev/null 2>&1 || true' EXIT
sleep 1
VLESS_IP="$(local_socks_ip "$LOCAL" || true)"
if [[ "$VLESS_IP" != "$PROXY_IP" || "$VLESS_IP" == "$VPS_IP" ]]; then
  cp "$BACKUP" "$XRAY_CONF"
  systemctl restart xray >/dev/null 2>&1 || true
  die "出口一致性失败，已回滚。住宅=${PROXY_IP} VLESS=${VLESS_IP} VPS=${VPS_IP}"
fi

VLESS_WECHAT_SUMMARY=()
say "${C}[微信测试 B] VLESS → 中转VPS → 住宅代理完整链路测试...${R}"
for i in 0 1 2; do
  result="$(vless_https_test "${WECHAT_URLS[$i]}")"
  code="$(awk '{print $1}' <<< "$result")"
  ms="$(awk '{print $2}' <<< "$result")"
  if [[ "$code" != "000" && "$ms" -ge 0 ]]; then
    say "${G}✓ ${WECHAT_NAMES[$i]}  HTTP ${code} / ${ms} ms${R}"
  else
    say "${E}✗ ${WECHAT_NAMES[$i]}  失败/超时${R}"
  fi
  VLESS_WECHAT_SUMMARY+=("${WECHAT_NAMES[$i]}|${code}|${ms}")
done

VLESS_IP_AFTER_WECHAT="$(local_socks_ip "$LOCAL" || true)"
if [[ "$VLESS_IP_AFTER_WECHAT" != "$PROXY_IP" ]]; then
  cp "$BACKUP" "$XRAY_CONF"
  systemctl restart xray >/dev/null 2>&1 || true
  die "微信完整链路测试后出口发生变化，已回滚。住宅=${PROXY_IP} VLESS=${VLESS_IP_AFTER_WECHAT}"
fi
say "${G}✓ 微信完整链路出口仍为住宅代理IP：${VLESS_IP_AFTER_WECHAT}${R}"

CN="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
  --socks5-hostname "127.0.0.1:${LOCAL}" -w '%{time_total}' https://www.baidu.com/ || true)"
OV="$(curl -4 -sS -o /dev/null --connect-timeout 10 --max-time 20 \
  --socks5-hostname "127.0.0.1:${LOCAL}" -w '%{time_total}' https://www.cloudflare.com/ || true)"
CN_MS="$(python3 - "$CN" <<'PY'
import sys
try: print(round(float(sys.argv[1])*1000))
except: print(-1)
PY
)"
OV_MS="$(python3 - "$OV" <<'PY'
import sys
try: print(round(float(sys.argv[1])*1000))
except: print(-1)
PY
)"
ENC="$(python3 - "$NAME" <<'PY'
import sys,urllib.parse
print(urllib.parse.quote(sys.argv[1],safe=""))
PY
)"
URL="vless://${LINE_UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${LINE_SHORT_ID}&type=tcp#${ENC}"
QR="/root/relay-${PORT}.png"
make_qr_png "$URL" "$QR" || true

echo
say "${G}${B}===== 中转部署成功 =====${R}"
say "线路备注：        $NAME"
say "VPS入口IP：       $VPS_IP"
say "VLESS端口：       $PORT"
say "VLESS UUID：       ${Y}$LINE_UUID${R}"
say "REALITY ShortID： ${Y}$LINE_SHORT_ID${R}"
say "REALITY PublicKey:${Y}$PUBLIC_KEY${R}"
say "上游协议：        ${PROTO^^}"
say "代理Host：        $HOST"
say "代理端口：        $PPORT"
say "代理账号：        ${Y}$PUSER${R}"
say "代理密码：        ${Y}$PPASS${R}"
say "住宅代理出口IP：  $PROXY_IP"
say "VLESS实际出口IP： $VLESS_IP"
say "${G}出口一致：✓${R}"
say "${G}DIRECT回落：禁止${R}"
echo
say "${Y}${B}===== 微信网络专项检测 =====${R}"
for item in "${PROXY_WECHAT_SUMMARY[@]}"; do
  IFS='|' read -r host code ms <<< "$item"
  if [[ "$code" != "000" ]]; then
    say "住宅代理直连 → ${host}：${G}HTTP ${code} / ${ms} ms${R}"
  else
    say "住宅代理直连 → ${host}：${E}失败/超时${R}"
  fi
done
for item in "${VLESS_WECHAT_SUMMARY[@]}"; do
  IFS='|' read -r host code ms <<< "$item"
  if [[ "$code" != "000" ]]; then
    say "VLESS完整链路 → ${host}：${G}HTTP ${code} / ${ms} ms${R}"
  else
    say "VLESS完整链路 → ${host}：${E}失败/超时${R}"
  fi
done
say "${G}微信测试出口核对：✓ 始终为住宅代理IP ${PROXY_IP}${R}"
say "${Y}说明：这里只验证微信/腾讯公开网络端点的可达性和延迟，不代表注册一定成功。${R}"
say "中转后国内HTTPS总耗时：${CN_MS} ms"
say "中转后海外HTTPS总耗时：${OV_MS} ms"
echo
say "${Y}VLESS导入链接：${R}"
say "$URL"
echo
say "二维码PNG：$QR"
if [[ -f "$QR" ]]; then
  if validate_qr_png "$QR" "$URL"; then
    say "${G}✓ PNG二维码反向解码校验通过${R}"
  else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
      say "${Y}提示：未安装 zbarimg，跳过二维码反解校验。${R}"
    else
      say "${E}✗ PNG二维码反向解码校验失败，请使用完整 VLESS 链接导入。${R}"
    fi
  fi
fi
show_terminal_qr_safe "$URL"
say "${Y}若手机连不上，请在云厂商安全组放行 TCP ${PORT}。${R}"
LINE_NO="$(($(registry_count)+1))"
registry_save
say "${G}✓ 线路信息已保存（账号密码明文，文件权限 root-only 600）。${R}"
sleep 1
rc=0
rc=0
quick_menu || rc=$?
if [[ "$rc" -eq 10 ]]; then
  exec "$0"
fi

