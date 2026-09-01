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

clear 2>/dev/null || true
say "${C}${B}===== VLESS + REALITY 中转部署 =====${R}"
say "${G}中转VPS只做入口，最终出口保持住宅代理IP。${R}"
say "${E}${B}住宅代理失败时不回落到VPS DIRECT。${R}"
echo

read -rp "线路备注（如 日本动态中转）：" NAME
echo "上游代理协议：1=SOCKS5  2=HTTP"
read -rp "请选择：" CH
case "$CH" in 1) PROTO="socks";; 2) PROTO="http";; *) die "协议选择错误。";; esac
read -rp "代理Host/IP：" HOST
read -rp "代理端口：" PPORT
read -rp "代理用户名（可空）：" PUSER
read -rp "代理密码（可空，明文）：" PPASS

say "${Y}${B}===== 请核对 =====${R}"
say "备注：$NAME"; say "协议：${PROTO^^}"; say "Host：$HOST"; say "端口：$PPORT"; say "用户名：$PUSER"; say "密码：$PPASS"
read -rp "确认请输入 YES：" OK
[[ "$OK" == "YES" ]] || die "已取消。"

VPS_IP="$(curl -4 -fsS https://api.ipify.org)"
proxy_ip(){
  if [[ "$PROTO" == "socks" ]]; then
    if [[ -n "$PUSER" ]]; then curl -4 -fsS --socks5-hostname "${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" https://api.ipify.org
    else curl -4 -fsS --socks5-hostname "${HOST}:${PPORT}" https://api.ipify.org; fi
  else
    if [[ -n "$PUSER" ]]; then curl -4 -fsS --proxy "http://${HOST}:${PPORT}" --proxy-user "${PUSER}:${PPASS}" https://api.ipify.org
    else curl -4 -fsS --proxy "http://${HOST}:${PPORT}" https://api.ipify.org; fi
  fi
}
PIP1="$(proxy_ip || true)"; sleep 1; PIP2="$(proxy_ip || true)"
[[ -n "$PIP1" && "$PIP1" == "$PIP2" ]] || die "住宅代理不可用或短时间出口发生变化。"
[[ "$PIP1" != "$VPS_IP" ]] || die "代理出口与VPS公网IP相同。"
PROXY_IP="$PIP1"

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

ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(5))
PY
)"
IN="relay-in-$ID"; OUT="relay-out-$ID"; BACKUP="${XRAY_CONF}.backup.relay.$(date +%Y%m%d-%H%M%S)"; cp "$XRAY_CONF" "$BACKUP"

python3 - "$XRAY_CONF" "$IN" "$OUT" "$PORT" "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" "$PROTO" "$HOST" "$PPORT" "$PUSER" "$PPASS" <<'PY'
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

LOCAL=16888
CLIENT="/tmp/relay-client.json"
cat > "$CLIENT" <<EOF2
{"inbounds":[{"listen":"127.0.0.1","port":${LOCAL},"protocol":"socks","settings":{"udp":false}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":${PORT},"users":[{"id":"${UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"fingerprint":"chrome","serverName":"${SNI}","publicKey":"${PUBLIC_KEY}","shortId":"${SHORT_ID}","spiderX":"/"}}}]}
EOF2
"$XRAY_BIN" run -config "$CLIENT" >/tmp/relay-client.log 2>&1 &
PID=$!
trap 'kill $PID >/dev/null 2>&1 || true' EXIT
sleep 1
VLESS_IP="$(curl -4 -fsS --socks5-hostname "127.0.0.1:${LOCAL}" https://api.ipify.org || true)"
if [[ "$VLESS_IP" != "$PROXY_IP" || "$VLESS_IP" == "$VPS_IP" ]]; then cp "$BACKUP" "$XRAY_CONF"; systemctl restart xray >/dev/null 2>&1 || true; die "出口一致性失败，已回滚。"; fi

CN="$(curl -4 -sS -o /dev/null --socks5-hostname "127.0.0.1:${LOCAL}" -w '%{time_total}' https://www.baidu.com/ || true)"
OV="$(curl -4 -sS -o /dev/null --socks5-hostname "127.0.0.1:${LOCAL}" -w '%{time_total}' https://www.cloudflare.com/ || true)"
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
URL="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${ENC}"
QR="/root/relay-${PORT}.png"
qrencode -o "$QR" "$URL" >/dev/null 2>&1 || true

echo
say "${G}${B}===== 中转部署成功 =====${R}"
say "VPS入口IP：       $VPS_IP"
say "VLESS端口：       $PORT"
say "住宅代理出口IP：  $PROXY_IP"
say "VLESS实际出口IP： $VLESS_IP"
say "${G}出口一致：✓${R}"
say "${G}DIRECT回落：禁止${R}"
say "中转后国内HTTPS总耗时：${CN_MS} ms"
say "中转后海外HTTPS总耗时：${OV_MS} ms"
echo
say "${Y}VLESS导入链接：${R}"
say "$URL"
echo
say "${Y}扫码导入：${R}"
qrencode -t ANSIUTF8 "$URL" || true
say "二维码PNG：$QR"
say "${Y}若手机连不上，请在云厂商安全组放行 TCP ${PORT}。${R}"
