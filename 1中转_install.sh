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
  python3 - "$REGISTRY_FILE" "$NAME" "$PORT" "$IN" "$OUT" "$PROTO" "$HOST" "$PPORT" "$PUSER" "$PPASS" "$PROXY_IP" "$VPS_IP" "$URL" <<'PY'
import json,sys,datetime,os
p,name,port,intag,outtag,proto,host,pport,user,pw,pip,vip,url=sys.argv[1:]
try:
    d=json.load(open(p,encoding="utf-8"))
    if not isinstance(d,list): d=[]
except Exception:
    d=[]
rec={
 "name":name,"port":int(port),"inTag":intag,"outTag":outtag,
 "protocol":proto,"host":host,"proxyPort":int(pport),
 "username":user,"password":pw,"proxyIP":pip,"vpsIP":vip,
 "vlessURL":url,"createdAt":datetime.datetime.now().isoformat(timespec="seconds")
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
    print(f"[{i}] {x.get('name','未命名')}")
    print(f"    VLESS入口：{x.get('vpsIP','?')}:{x.get('port','?')}")
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

registry_load(){
  local n="$1"
  eval "$(python3 - "$REGISTRY_FILE" "$n" <<'PY'
import json,sys,shlex
d=json.load(open(sys.argv[1],encoding="utf-8"))
i=int(sys.argv[2])-1
if i<0 or i>=len(d): raise SystemExit(2)
x=d[i]
for k,v in {
"NAME":x.get("name",""),"PORT":x.get("port",""),"IN":x.get("inTag",""),"OUT":x.get("outTag",""),
"PROTO":x.get("protocol",""),"HOST":x.get("host",""),"PPORT":x.get("proxyPort",""),
"PUSER":x.get("username",""),"PPASS":x.get("password",""),"PROXY_IP":x.get("proxyIP",""),
"VPS_IP":x.get("vpsIP",""),"URL":x.get("vlessURL","")
}.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)" || return 1
  if [[ -z "${OUT:-}" || -z "${IN:-}" ]]; then
    say "${Y}提示：这是旧版线路记录，缺少 inTag/outTag；查看/测试可用，但“修改上游代理”前建议重新新增该线路。${R}"
  fi
}

show_current_header(){
  say "${C}${B}╔══════════════════════════════════════════════╗${R}"
  say "${C}${B}  当前线路：${NAME}${R}"
  say "${C}${B}╠══════════════════════════════════════════════╣${R}"
  say "  VLESS入口： ${VPS_IP}:${PORT}"
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

show_qr_current(){
  show_current_header
  say "${Y}VLESS导入链接：${R}"
  say "$URL"
  echo
  command -v qrencode >/dev/null 2>&1 && qrencode -t UTF8 -m 1 "$URL" || true
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
    echo "[3] 测试当前住宅代理"
    echo "[4] 微信专项测试"
    echo "[5] 国内 / 海外测速"
    echo "[6] 检查代理出口 / VPS隔离"
    echo "[7] 显示二维码 / VLESS链接"
    echo "[8] 查看 Xray 实时日志"
    echo "[9] 修改当前线路上游代理"
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
      3) clear 2>/dev/null || true;proxy_test_current;read -rp "按回车返回..." ;;
      4) clear 2>/dev/null || true;wechat_test_current;read -rp "按回车返回..." ;;
      5) clear 2>/dev/null || true;speed_test_current;read -rp "按回车返回..." ;;
      6)
        clear 2>/dev/null || true;show_current_header
        ip="$(proxy_ip || true)"
        say "住宅代理出口：${ip:-检测失败}"
        say "VPS公网IP：${VPS_IP}"
        if [[ -n "$ip" && "$ip" != "$VPS_IP" ]]; then
          say "${G}✓ 当前住宅出口 ≠ VPS公网IP${R}"
        else
          say "${E}✗ 出口检查异常${R}"
        fi
        read -rp "按回车返回..."
        ;;
      7) clear 2>/dev/null || true;show_qr_current;read -rp "按回车返回..." ;;
      8)
        say "${Y}按 Ctrl+C 停止实时日志并返回菜单。${R}"
        set +e
        journalctl -u xray -f
        set -e
        ;;
      9) clear 2>/dev/null || true;modify_current_proxy ;;
      0) exit 0 ;;
      *) say "${E}选择无效${R}";sleep 1 ;;
    esac
  done
}


clear 2>/dev/null || true

if [[ "$(registry_count)" -gt 0 ]]; then
  registry_load 1 || true
  quick_menu
  rc=$?
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

LOCAL="$(find_free_local_port)"
[[ -n "$LOCAL" ]] || die "找不到可用的本地自检端口。"
CLIENT="/tmp/relay-client.json"
cat > "$CLIENT" <<EOF2
{"inbounds":[{"listen":"127.0.0.1","port":${LOCAL},"protocol":"socks","settings":{"udp":false}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":${PORT},"users":[{"id":"${UUID}","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"fingerprint":"chrome","serverName":"${SNI}","publicKey":"${PUBLIC_KEY}","shortId":"${SHORT_ID}","spiderX":"/"}}}]}
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
URL="vless://${UUID}@${VPS_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${ENC}"
QR="/root/relay-${PORT}.png"
qrencode -o "$QR" "$URL" >/dev/null 2>&1 || true

echo
say "${G}${B}===== 中转部署成功 =====${R}"
say "线路备注：        $NAME"
say "VPS入口IP：       $VPS_IP"
say "VLESS端口：       $PORT"
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
say "${Y}扫码导入：${R}"
qrencode -t UTF8 -m 1 "$URL" || true
say "二维码PNG：$QR"
say "${Y}若手机连不上，请在云厂商安全组放行 TCP ${PORT}。${R}"
registry_save
say "${G}✓ 线路信息已保存（账号密码明文，文件权限 root-only 600）。${R}"
sleep 1
quick_menu
rc=$?
if [[ "$rc" -eq 10 ]]; then
  exec "$0"
fi

