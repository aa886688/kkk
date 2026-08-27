#!/usr/bin/env bash
set -euo pipefail

# V9 出口一致版
# 每运行一次只新增一个国家；所有 V9 国家共享 UUID/REALITY 参数，因此手机换国家只改端口。
# 每条 V9 线路只有一个代理出口（SOCKS5/HTTP），不配置 DIRECT/fallback。
# 安装后强制验证：VLESS实际出口 == 代理出口 != VPS公网IP。

XRAY_BIN="${XRAY_BIN:-$(command -v xray || true)}"
[[ -n "${XRAY_BIN}" ]] || XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"

V9_DIR="/usr/local/etc/xray/v9"
MASTER_FILE="${V9_DIR}/master.json"
REGISTRY_FILE="${V9_DIR}/registry.json"

C_RESET="\033[0m"; C_BOLD="\033[1m"; C_RED="\033[91m"; C_GREEN="\033[92m"
C_YELLOW="\033[93m"; C_BLUE="\033[94m"; C_MAGENTA="\033[95m"; C_CYAN="\033[96m"

say(){ printf "%b\n" "$*"; }
die(){ say "${C_RED}${C_BOLD}错误：${C_RESET}$*"; exit 1; }

progress(){
  local p="$1"; shift
  local width=30 n r
  n=$((p*width/100)); r=$((width-n))
  printf "\r${C_CYAN}["
  printf "%${n}s" "" | tr ' ' '█'
  printf "%${r}s" "" | tr ' ' '░'
  printf "] %3d%%  %s${C_RESET}" "$p" "$*"
  [[ "$p" -lt 100 ]] || printf "\n"
}

cleanup_pids=()
cleanup(){
  local p
  for p in "${cleanup_pids[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行。"
[[ -x "${XRAY_BIN}" ]] || die "找不到 Xray：${XRAY_BIN}"
[[ -f "${XRAY_CONF}" ]] || die "找不到 Xray 配置：${XRAY_CONF}"
command -v python3 >/dev/null 2>&1 || die "未安装 python3"
command -v curl >/dev/null 2>&1 || die "未安装 curl"

mkdir -p "${V9_DIR}"
chmod 700 "${V9_DIR}"
[[ -f "${REGISTRY_FILE}" ]] || printf '[]\n' > "${REGISTRY_FILE}"
chmod 600 "${REGISTRY_FILE}"

clear 2>/dev/null || true
say "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
say "${C_CYAN}${C_BOLD}        V9 出口一致版 · 单国家新增工具${C_RESET}"
say "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
say "${C_BLUE}每次运行只新增一个国家；代理是该线路唯一公网出口。${C_RESET}"
say "${C_BLUE}同一台服务器所有 V9 国家共用手机认证参数，换国家只改端口。${C_RESET}"
say "${C_RED}${C_BOLD}代理失败时直接失败，不允许改走 VPS DIRECT。${C_RESET}"
echo

# 首次自动生成共享手机身份
if [[ ! -f "${MASTER_FILE}" ]]; then
  progress 5 "首次初始化手机认证参数..."
  UUID="$("${XRAY_BIN}" uuid | tail -n1 | tr -d '\r\n')"
  [[ "${UUID}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "UUID 自动生成失败。"

  KEYS="$("${XRAY_BIN}" x25519)"
  PRIVATE_KEY="$(printf "%s\n" "${KEYS}" | awk -F': ' '/PrivateKey:/{print $2; exit}')"
  PUBLIC_KEY="$(printf "%s\n" "${KEYS}" | awk -F': ' '/Password \(PublicKey\):/{print $2; exit}')"
  [[ -n "${PUBLIC_KEY}" ]] || PUBLIC_KEY="$(printf "%s\n" "${KEYS}" | awk -F': ' '/PublicKey:/{print $2; exit}')"
  [[ -n "${PRIVATE_KEY}" && -n "${PUBLIC_KEY}" ]] || die "REALITY 密钥生成失败。"

  SHORT_ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"

  SNI=""
  for candidate in www.microsoft.com www.apple.com www.cloudflare.com; do
    if curl -4 -sS -I --connect-timeout 4 --max-time 7 "https://${candidate}" >/dev/null 2>&1; then
      SNI="${candidate}"; break
    fi
  done
  [[ -n "${SNI}" ]] || SNI="www.microsoft.com"

  python3 - "${MASTER_FILE}" "${UUID}" "${PRIVATE_KEY}" "${PUBLIC_KEY}" "${SHORT_ID}" "${SNI}" <<'PY'
import json,sys,os
path,uuid,priv,pub,sid,sni=sys.argv[1:]
with open(path,"w",encoding="utf-8") as f:
    json.dump({"uuid":uuid,"privateKey":priv,"publicKey":pub,"shortId":sid,"sni":sni},
              f,ensure_ascii=False,indent=2)
os.chmod(path,0o600)
PY
  progress 10 "共享手机认证参数已生成"
  echo
else
  progress 10 "读取已有 V9 共享手机认证参数..."
  echo
fi

eval "$(python3 - "${MASTER_FILE}" <<'PY'
import json,sys,shlex
o=json.load(open(sys.argv[1],encoding="utf-8"))
for k,v in {
 "UUID":o["uuid"],"PRIVATE_KEY":o["privateKey"],"PUBLIC_KEY":o["publicKey"],
 "SHORT_ID":o["shortId"],"SNI":o["sni"]
}.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)"

# 输入 + 明文核对
while true; do
  read -rp "$(printf "${C_YELLOW}【1/6】国家/线路备注（支持中文，例如 日本）：${C_RESET}")" LINE_NAME
  [[ -n "${LINE_NAME}" ]] || { say "${C_RED}不能为空。${C_RESET}"; continue; }

  say "${C_YELLOW}【2/6】代理协议：1=SOCKS5  2=HTTP${C_RESET}"
  read -rp "请选择 [1/2]：" PROTO_CHOICE
  case "${PROTO_CHOICE}" in
    1) PROXY_PROTO="socks" ;;
    2) PROXY_PROTO="http" ;;
    *) say "${C_RED}选择无效。${C_RESET}"; continue ;;
  esac

  read -rp "$(printf "${C_YELLOW}【3/6】代理服务器地址：${C_RESET}")" PROXY_HOST
  [[ -n "${PROXY_HOST}" ]] || { say "${C_RED}代理地址不能为空。${C_RESET}"; continue; }

  read -rp "$(printf "${C_YELLOW}【4/6】代理服务器端口：${C_RESET}")" PROXY_PORT
  [[ "${PROXY_PORT}" =~ ^[0-9]+$ ]] || { say "${C_RED}代理端口必须是数字。${C_RESET}"; continue; }

  read -rp "$(printf "${C_YELLOW}【5/6】代理用户名（明文，可空）：${C_RESET}")" PROXY_USER
  read -rp "$(printf "${C_YELLOW}【6/6】代理密码（明文，可空）：${C_RESET}")" PROXY_PASS

  clear 2>/dev/null || true
  say "${C_MAGENTA}${C_BOLD}═══════════════ 配置核对 ═══════════════${C_RESET}"
  say "国家/线路备注：${C_CYAN}${LINE_NAME}${C_RESET}"
  say "代理协议：      ${C_CYAN}${PROXY_PROTO^^}${C_RESET}"
  say "代理服务器：    ${C_CYAN}${PROXY_HOST}${C_RESET}"
  say "代理端口：      ${C_CYAN}${PROXY_PORT}${C_RESET}"
  say "代理用户名：    ${C_CYAN}${PROXY_USER}${C_RESET}"
  say "代理密码：      ${C_CYAN}${PROXY_PASS}${C_RESET}"
  say "${C_MAGENTA}──────────────────────────────────────────${C_RESET}"
  say "手机 UUID：     ${C_BLUE}${UUID}${C_RESET}"
  say "REALITY SNI：   ${C_BLUE}${SNI}${C_RESET}"
  say "PublicKey：     ${C_BLUE}${PUBLIC_KEY}${C_RESET}"
  say "ShortId：       ${C_BLUE}${SHORT_ID}${C_RESET}"
  say "${C_MAGENTA}──────────────────────────────────────────${C_RESET}"
  say "${C_RED}${C_BOLD}该线路不会配置 VPS DIRECT/fallback。${C_RESET}"
  echo "  [1] 确认并配置"
  echo "  [2] 返回重新填写"
  echo "  [0] 退出"
  read -rp "请选择：" CONFIRM
  case "${CONFIRM}" in
    1) break ;;
    2) clear 2>/dev/null || true ;;
    0) exit 0 ;;
    *) say "${C_RED}选择无效。${C_RESET}"; sleep 1 ;;
  esac
done

# 防止同名国家/线路重复
if python3 - "${REGISTRY_FILE}" "${LINE_NAME}" <<'PY'
import json,sys
reg=json.load(open(sys.argv[1],encoding="utf-8"))
raise SystemExit(0 if any(x.get("name")==sys.argv[2] for x in reg) else 1)
PY
then
  die "已经存在同名 V9 线路「${LINE_NAME}」，请使用其他备注。"
fi

progress 20 "检测 VPS 公网 IP..."
VPS_IP="$(curl -4 -sS --connect-timeout 8 --max-time 12 https://api.ipify.org || true)"
[[ -n "${VPS_IP}" ]] || die "无法检测 VPS 公网 IPv4。"

proxy_curl_ip(){
  if [[ "${PROXY_PROTO}" == "socks" ]]; then
    if [[ -n "${PROXY_USER}" || -n "${PROXY_PASS}" ]]; then
      curl -4 -sS --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
        --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
        --connect-timeout 12 --max-time 20 https://api.ipify.org
    else
      curl -4 -sS --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
        --connect-timeout 12 --max-time 20 https://api.ipify.org
    fi
  else
    if [[ -n "${PROXY_USER}" || -n "${PROXY_PASS}" ]]; then
      curl -4 -sS --proxy "http://${PROXY_HOST}:${PROXY_PORT}" \
        --proxy-user "${PROXY_USER}:${PROXY_PASS}" \
        --connect-timeout 12 --max-time 20 https://api.ipify.org
    else
      curl -4 -sS --proxy "http://${PROXY_HOST}:${PROXY_PORT}" \
        --connect-timeout 12 --max-time 20 https://api.ipify.org
    fi
  fi
}


proxy_curl_metrics(){
  local url="$1"
  if [[ "${PROXY_PROTO}" == "socks" ]]; then
    if [[ -n "${PROXY_USER}" || -n "${PROXY_PASS}" ]]; then
      curl -4 -sS -o /dev/null --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
        --proxy-user "${PROXY_USER}:${PROXY_PASS}" --connect-timeout 12 --max-time 25 \
        -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' "${url}"
    else
      curl -4 -sS -o /dev/null --socks5-hostname "${PROXY_HOST}:${PROXY_PORT}" \
        --connect-timeout 12 --max-time 25 \
        -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' "${url}"
    fi
  else
    if [[ -n "${PROXY_USER}" || -n "${PROXY_PASS}" ]]; then
      curl -4 -sS -o /dev/null --proxy "http://${PROXY_HOST}:${PROXY_PORT}" \
        --proxy-user "${PROXY_USER}:${PROXY_PASS}" --connect-timeout 12 --max-time 25 \
        -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' "${url}"
    else
      curl -4 -sS -o /dev/null --proxy "http://${PROXY_HOST}:${PROXY_PORT}" \
        --connect-timeout 12 --max-time 25 \
        -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' "${url}"
    fi
  fi
}
ms_from_seconds(){ python3 - "$1" <<'PY'
import sys
try: print(round(float(sys.argv[1])*1000))
except Exception: print(-1)
PY
}
metric_field(){ awk -v p="$2" '{print $p}' <<< "$1"; }

progress 30 "检测代理实际出口与短时稳定性..."
PROXY_IP1="$(proxy_curl_ip || true)"
sleep 1
PROXY_IP2="$(proxy_curl_ip || true)"
[[ -n "${PROXY_IP1}" && -n "${PROXY_IP2}" ]] || die "代理连接失败，未取得代理公网 IP。"
[[ "${PROXY_IP1}" == "${PROXY_IP2}" ]] || die "代理短时间内已经换IP：${PROXY_IP1} → ${PROXY_IP2}。请改用 Sticky/更长轮询周期。"
[[ "${PROXY_IP1}" != "${VPS_IP}" ]] || die "代理出口与 VPS 公网IP相同，无法证明独立代理出口。"
PROXY_IP="${PROXY_IP1}"

progress 36 "检测动态代理到国内/海外的 HTTPS 延迟..."
PROXY_METRICS_OVERSEAS="$(proxy_curl_metrics "https://www.cloudflare.com/" || true)"
PROXY_METRICS_DOMESTIC="$(proxy_curl_metrics "https://www.baidu.com/" || true)"
P_OV_CONNECT="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_OVERSEAS}" 1)")"
P_OV_TTFB="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_OVERSEAS}" 2)")"
P_OV_TOTAL="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_OVERSEAS}" 3)")"
P_CN_CONNECT="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_DOMESTIC}" 1)")"
P_CN_TTFB="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_DOMESTIC}" 2)")"
P_CN_TOTAL="$(ms_from_seconds "$(metric_field "${PROXY_METRICS_DOMESTIC}" 3)")"


progress 40 "检查已有线路并分配独立 VLESS 端口..."
VLESS_PORT="$(python3 - "${XRAY_CONF}" "${REGISTRY_FILE}" <<'PY'
import json,socket,sys
used=set()
try:
    c=json.load(open(sys.argv[1],encoding="utf-8"))
    for ib in c.get("inbounds",[]):
        if isinstance(ib.get("port"),int): used.add(ib["port"])
except Exception: pass
try:
    for x in json.load(open(sys.argv[2],encoding="utf-8")):
        if isinstance(x.get("port"),int): used.add(x["port"])
except Exception: pass
for p in range(8501,9000):
    if p in used: continue
    s=socket.socket()
    try:
        s.bind(("0.0.0.0",p)); print(p); break
    except OSError: pass
    finally: s.close()
PY
)"
[[ -n "${VLESS_PORT}" ]] || die "8501-8999 没有可用 VLESS 端口。"

SAFE_ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(6))
PY
)"
IN_TAG="v9-in-${SAFE_ID}"
OUT_TAG="v9-out-${SAFE_ID}"
BACKUP="${XRAY_CONF}.backup.v9.$(date +%Y%m%d-%H%M%S)"
cp "${XRAY_CONF}" "${BACKUP}"

progress 55 "写入 VLESS + REALITY + 唯一代理出口..."
python3 - "${XRAY_CONF}" "${IN_TAG}" "${OUT_TAG}" "${VLESS_PORT}" \
  "${UUID}" "${PRIVATE_KEY}" "${SHORT_ID}" "${SNI}" \
  "${PROXY_PROTO}" "${PROXY_HOST}" "${PROXY_PORT}" "${PROXY_USER}" "${PROXY_PASS}" <<'PY'
import json,sys
(conf,in_tag,out_tag,port,uuid,priv,sid,sni,proto,host,pport,user,password)=sys.argv[1:]
port=int(port); pport=int(pport)
c=json.load(open(conf,encoding="utf-8"))

c.setdefault("inbounds",[]).append({
 "tag":in_tag,"listen":"0.0.0.0","port":port,"protocol":"vless",
 "settings":{"clients":[{"id":uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
 "streamSettings":{
   "network":"tcp","security":"reality",
   "realitySettings":{
     "show":False,"target":f"{sni}:443","xver":0,
     "serverNames":[sni],"privateKey":priv,"shortIds":[sid]
   }
 }
})

server={"address":host,"port":pport}
if user or password:
    server["users"]=[{"user":user,"pass":password}]

if proto=="socks":
    outbound={"tag":out_tag,"protocol":"socks","settings":{"servers":[server]}}
elif proto=="http":
    outbound={"tag":out_tag,"protocol":"http","settings":{"servers":[server]}}
else:
    raise SystemExit("未知代理协议")

c.setdefault("outbounds",[]).append(outbound)
routing=c.setdefault("routing",{"domainStrategy":"AsIs","rules":[]})
routing.setdefault("rules",[]).insert(0,{
    "type":"field","inboundTag":[in_tag],"outboundTag":out_tag
})
json.dump(c,open(conf,"w"),ensure_ascii=False,indent=2)
PY

progress 65 "检查该线路是否存在 VPS DIRECT/fallback..."
python3 - "${XRAY_CONF}" "${IN_TAG}" "${OUT_TAG}" <<'PY'
import json,sys
conf,in_tag,out_tag=sys.argv[1:]
c=json.load(open(conf,encoding="utf-8"))
rules=[r for r in c.get("routing",{}).get("rules",[]) if in_tag in r.get("inboundTag",[])]
if not rules: raise SystemExit("找不到该 V9 路由规则")
if rules[0].get("outboundTag") != out_tag:
    raise SystemExit("V9 第一条专属规则不是唯一代理出口")
for r in rules:
    t=str(r.get("outboundTag","")).lower()
    if t in {"direct","freedom"} or "fallback" in t:
        raise SystemExit("检测到该 V9 线路存在 DIRECT/fallback")
print("V9_ROUTE_OK")
PY

if ! "${XRAY_BIN}" run -test -config "${XRAY_CONF}" >/tmp/v9-xray-test.log 2>&1; then
  cp "${BACKUP}" "${XRAY_CONF}"
  cat /tmp/v9-xray-test.log
  die "Xray 配置检查失败，已自动恢复备份。"
fi

progress 72 "Xray 配置检查通过，正在重启..."
if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
  cp "${BACKUP}" "${XRAY_CONF}"
  systemctl restart xray >/dev/null 2>&1 || true
  die "Xray 重启失败，已自动恢复备份。"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${VLESS_PORT}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 完整穿过新 VLESS/REALITY 线路检查最终公网出口
progress 80 "通过新 VLESS 线路核对最终出口..."
LOCAL_TEST_PORT="$(python3 - <<'PY'
import socket
for p in range(16000,17000):
    s=socket.socket()
    try:
        s.bind(("127.0.0.1",p)); print(p); break
    except OSError: pass
    finally: s.close()
PY
)"
[[ -n "${LOCAL_TEST_PORT}" ]] || die "找不到本地测试端口。"

TMP_CLIENT="/tmp/v9-client-${SAFE_ID}.json"
cat > "${TMP_CLIENT}" <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"listen":"127.0.0.1","port":${LOCAL_TEST_PORT},"protocol":"socks","settings":{"udp":false}}
  ],
  "outbounds":[
    {
      "protocol":"vless",
      "settings":{"vnext":[{"address":"127.0.0.1","port":${VLESS_PORT},
        "users":[{"id":"${UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},
      "streamSettings":{
        "network":"tcp","security":"reality",
        "realitySettings":{
          "fingerprint":"chrome","serverName":"${SNI}",
          "publicKey":"${PUBLIC_KEY}","shortId":"${SHORT_ID}","spiderX":"/"
        }
      }
    }
  ]
}
EOF

"${XRAY_BIN}" run -config "${TMP_CLIENT}" >/tmp/v9-client-${SAFE_ID}.log 2>&1 &
CLIENT_PID=$!
cleanup_pids+=("${CLIENT_PID}")

for _ in $(seq 1 20); do
  if python3 - "${LOCAL_TEST_PORT}" <<'PY'
import socket,sys
s=socket.socket(); s.settimeout(.3)
try:
    s.connect(("127.0.0.1",int(sys.argv[1]))); raise SystemExit(0)
except Exception:
    raise SystemExit(1)
finally:
    s.close()
PY
  then break; fi
  sleep .25
done

VLESS_IP="$(curl -4 -sS --socks5-hostname "127.0.0.1:${LOCAL_TEST_PORT}" \
  --connect-timeout 12 --max-time 25 https://api.ipify.org || true)"

if [[ -z "${VLESS_IP}" || "${VLESS_IP}" != "${PROXY_IP}" || "${VLESS_IP}" == "${VPS_IP}" ]]; then
  say "${C_RED}${C_BOLD}出口一致性检查失败！${C_RESET}"
  say "代理直接测试出口：${PROXY_IP}"
  say "VLESS实际出口：    ${VLESS_IP:-<失败>}"
  say "VPS公网IP：        ${VPS_IP}"
  cp "${BACKUP}" "${XRAY_CONF}"
  systemctl restart xray >/dev/null 2>&1 || true
  die "已自动回滚。"
fi

progress 85 "检测 VLESS → VPS → 动态代理的端到端 HTTPS 延迟..."
VLESS_METRICS_OVERSEAS="$(curl -4 -sS -o /dev/null \
  --socks5-hostname "127.0.0.1:${LOCAL_TEST_PORT}" --connect-timeout 12 --max-time 25 \
  -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' https://www.cloudflare.com/ || true)"
VLESS_METRICS_DOMESTIC="$(curl -4 -sS -o /dev/null \
  --socks5-hostname "127.0.0.1:${LOCAL_TEST_PORT}" --connect-timeout 12 --max-time 25 \
  -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' https://www.baidu.com/ || true)"
V_OV_CONNECT="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_OVERSEAS}" 1)")"
V_OV_TTFB="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_OVERSEAS}" 2)")"
V_OV_TOTAL="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_OVERSEAS}" 3)")"
V_CN_CONNECT="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_DOMESTIC}" 1)")"
V_CN_TTFB="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_DOMESTIC}" 2)")"
V_CN_TOTAL="$(ms_from_seconds "$(metric_field "${VLESS_METRICS_DOMESTIC}" 3)")"


progress 88 "做国内/海外基础连通性测试..."
DOMESTIC_CODE="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
  --socks5-hostname "127.0.0.1:${LOCAL_TEST_PORT}" \
  --connect-timeout 8 --max-time 15 https://www.baidu.com/ || true)"
OVERSEAS_CODE="$(curl -4 -sS -o /dev/null -w '%{http_code}' \
  --socks5-hostname "127.0.0.1:${LOCAL_TEST_PORT}" \
  --connect-timeout 8 --max-time 15 https://www.cloudflare.com/ || true)"

progress 92 "保存 V9 线路登记..."
python3 - "${REGISTRY_FILE}" "${LINE_NAME}" "${VLESS_PORT}" "${IN_TAG}" "${OUT_TAG}" \
  "${PROXY_PROTO}" "${PROXY_HOST}" "${PROXY_PORT}" "${PROXY_USER}" "${PROXY_PASS}" "${PROXY_IP}" <<'PY'
import json,sys,datetime,os
(path,name,port,in_tag,out_tag,proto,host,pport,user,password,ip)=sys.argv[1:]
reg=json.load(open(path,encoding="utf-8"))
reg.append({
 "name":name,"port":int(port),"inboundTag":in_tag,"outboundTag":out_tag,
 "proxyProtocol":proto,"proxyHost":host,"proxyPort":int(pport),
 "proxyUser":user,"proxyPassword":password,"verifiedProxyIP":ip,
 "createdAt":datetime.datetime.now().isoformat(timespec="seconds")
})
json.dump(reg,open(path,"w"),ensure_ascii=False,indent=2)
os.chmod(path,0o600)
PY

progress 96 "生成手机导入链接和二维码..."
ENC_NAME="$(python3 - "${LINE_NAME}" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1],safe=""))
PY
)"
VLESS_URL="vless://${UUID}@${VPS_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${ENC_NAME}"

if ! command -v qrencode >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qrencode >/dev/null 2>&1 || true
  fi
fi

QR_FILE="/root/v9-${VLESS_PORT}.png"
command -v qrencode >/dev/null 2>&1 && qrencode -o "${QR_FILE}" -s 8 -m 2 "${VLESS_URL}" || true

progress 100 "全部检查完成"
echo
say "${C_GREEN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
say "${C_GREEN}${C_BOLD}             ✓ V9 线路配置成功${C_RESET}"
say "${C_GREEN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
say "线路备注：        ${C_CYAN}${LINE_NAME}${C_RESET}"
say "VPS入口IP：       ${C_BLUE}${VPS_IP}${C_RESET}"
say "VLESS端口：       ${C_MAGENTA}${VLESS_PORT}${C_RESET}"
say "UUID：            ${C_MAGENTA}${UUID}${C_RESET}"
say "Flow：            ${C_CYAN}xtls-rprx-vision${C_RESET}"
say "Network：         ${C_CYAN}tcp${C_RESET}"
say "Security：        ${C_CYAN}reality${C_RESET}"
say "SNI：             ${C_CYAN}${SNI}${C_RESET}"
say "PublicKey：       ${C_MAGENTA}${PUBLIC_KEY}${C_RESET}"
say "ShortId：         ${C_MAGENTA}${SHORT_ID}${C_RESET}"
echo
say "代理协议：        ${C_CYAN}${PROXY_PROTO^^}${C_RESET}"
say "代理服务器：      ${C_CYAN}${PROXY_HOST}:${PROXY_PORT}${C_RESET}"
say "代理用户名：      ${C_CYAN}${PROXY_USER}${C_RESET}"
say "代理密码：        ${C_CYAN}${PROXY_PASS}${C_RESET}"
echo
say "代理实际出口IP：  ${C_GREEN}${PROXY_IP}${C_RESET}"
say "VLESS实际出口IP： ${C_GREEN}${VLESS_IP}${C_RESET}"
say "VPS公网IP：       ${C_BLUE}${VPS_IP}${C_RESET}"
say "${C_GREEN}${C_BOLD}出口一致性：      ✓ VLESS出口 = 代理出口 ≠ VPS出口${C_RESET}"
say "${C_GREEN}${C_BOLD}VPS DIRECT兜底：  ✓ 未配置 / 该线路禁止使用${C_RESET}"
echo
say "${C_YELLOW}${C_BOLD}动态IP线路延迟（真实 HTTPS 请求）：${C_RESET}"
say "代理直连 → 海外：连接 ${C_CYAN}${P_OV_CONNECT}ms${C_RESET} / 首包 ${C_CYAN}${P_OV_TTFB}ms${C_RESET} / 总耗时 ${C_GREEN}${P_OV_TOTAL}ms${C_RESET}"
say "代理直连 → 国内：连接 ${C_CYAN}${P_CN_CONNECT}ms${C_RESET} / 首包 ${C_CYAN}${P_CN_TTFB}ms${C_RESET} / 总耗时 ${C_GREEN}${P_CN_TOTAL}ms${C_RESET}"
say "VLESS链路 → 海外：连接 ${C_CYAN}${V_OV_CONNECT}ms${C_RESET} / 首包 ${C_CYAN}${V_OV_TTFB}ms${C_RESET} / 总耗时 ${C_GREEN}${V_OV_TOTAL}ms${C_RESET}"
say "VLESS链路 → 国内：连接 ${C_CYAN}${V_CN_CONNECT}ms${C_RESET} / 首包 ${C_CYAN}${V_CN_TTFB}ms${C_RESET} / 总耗时 ${C_GREEN}${V_CN_TOTAL}ms${C_RESET}"
say "${C_BLUE}说明：动态出口常屏蔽 ICMP，所以这里用真实 HTTPS 请求测延迟。${C_RESET}"

if [[ "${DOMESTIC_CODE}" != "000" && -n "${DOMESTIC_CODE}" ]]; then
  say "国内基础连通性：  ${C_GREEN}✓ HTTP ${DOMESTIC_CODE}${C_RESET}"
else
  say "国内基础连通性：  ${C_YELLOW}⚠ 基础测试站点未成功，请用实际目标再验证${C_RESET}"
fi
if [[ "${OVERSEAS_CODE}" != "000" && -n "${OVERSEAS_CODE}" ]]; then
  say "海外基础连通性：  ${C_GREEN}✓ HTTP ${OVERSEAS_CODE}${C_RESET}"
else
  say "海外基础连通性：  ${C_YELLOW}⚠ 基础测试站点未成功，请用实际目标再验证${C_RESET}"
fi

echo
say "${C_YELLOW}${C_BOLD}手机 VLESS 导入链接：${C_RESET}"
say "${C_CYAN}${VLESS_URL}${C_RESET}"
echo

if command -v qrencode >/dev/null 2>&1; then
  say "${C_YELLOW}${C_BOLD}手机直接扫描：${C_RESET}"
  qrencode -t ANSIUTF8 "${VLESS_URL}" || true
  echo
  say "PNG二维码：${C_MAGENTA}${QR_FILE}${C_RESET}"
fi

echo
say "${C_BLUE}${C_BOLD}换国家方法：${C_RESET}"
say "同一台服务器后续新增的 V9 国家会复用相同 UUID / REALITY 参数。"
say "手机换国家时只改成对应国家的 VLESS 端口。"
say "V9线路登记：${C_MAGENTA}${REGISTRY_FILE}${C_RESET}"
say "本次备份：  ${C_MAGENTA}${BACKUP}${C_RESET}"
say "${C_YELLOW}若云厂商安全组未开放 ${VLESS_PORT}/TCP，请在控制台放行。${C_RESET}"
