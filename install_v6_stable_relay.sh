#!/usr/bin/env bash
set -euo pipefail

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_RED="\033[91m"
C_GREEN="\033[92m"
C_YELLOW="\033[93m"
C_BLUE="\033[94m"
C_MAGENTA="\033[95m"
C_CYAN="\033[96m"

say() { printf "%b\n" "$*"; }
fail() { say "${C_RED}${C_BOLD}错误：${C_RESET}$*"; exit 1; }

show_progress() {
  local title="$1"
  local pct filled empty
  say "${C_CYAN}${title}${C_RESET}"
  for pct in 10 20 30 40 50 60 70 80 90 100; do
    filled=$((pct / 5))
    empty=$((20 - filled))
    printf "\r${C_GREEN}["
    printf "%${filled}s" "" | tr " " "█"
    printf "%${empty}s" "" | tr " " "░"
    printf "] %3d%%${C_RESET}" "$pct"
    sleep 0.06
  done
  printf "\n"
}

[[ "${EUID}" -eq 0 ]] || fail "请使用 root 用户运行。"
command -v python3 >/dev/null 2>&1 || fail "未安装 python3。"
command -v curl >/dev/null 2>&1 || fail "未安装 curl。"
[[ -x "${XRAY_BIN}" ]] || fail "找不到 ${XRAY_BIN}，请先安装 Xray。"
[[ -f "${XRAY_CONF}" ]] || fail "找不到 ${XRAY_CONF}。"

clear 2>/dev/null || true
say "${C_CYAN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
say "${C_CYAN}${C_BOLD}      动态IP → VLESS 自动配置工具${C_RESET}"
say "${C_CYAN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
say "${C_BLUE}VLESS 端口、UUID、服务器内部备用端口全部自动生成。${C_RESET}"
say "${C_BLUE}可选：配置“固定走 VPS”的普通域名列表。${C_RESET}"
say "${C_YELLOW}动态IP密码为明文输入，输入内容会直接显示。${C_RESET}"
echo

read -rp "$(printf "${C_YELLOW}【1/6】线路备注名称（支持中文，例如 日本住宅IP）：${C_RESET}")" DISPLAY_NAME
[[ -n "${DISPLAY_NAME}" ]] || fail "线路备注名称不能为空。"

# 服务器内部使用安全英文ID，避免中文影响 systemd / 文件名 / Xray tag
TAG="line-$(date +%Y%m%d%H%M%S)-$RANDOM"

read -rp "$(printf "${C_YELLOW}【2/6】动态IP服务器地址：${C_RESET}")" UP_HOST
[[ -n "${UP_HOST}" ]] || fail "动态IP服务器地址不能为空。"

read -rp "$(printf "${C_YELLOW}【3/6】动态IP服务器端口：${C_RESET}")" UP_PORT
[[ "${UP_PORT}" =~ ^[0-9]+$ ]] || fail "动态IP服务器端口格式错误。"

read -rp "$(printf "${C_YELLOW}【4/6】动态IP用户名：${C_RESET}")" UP_USER
[[ -n "${UP_USER}" ]] || fail "动态IP用户名不能为空。"

read -rp "$(printf "${C_YELLOW}【5/6】动态IP密码（明文显示）：${C_RESET}")" UP_PASS
[[ -n "${UP_PASS}" ]] || fail "动态IP密码不能为空。"

read -rp "$(printf "${C_YELLOW}【6/6】固定走 VPS 的普通域名（多个用英文逗号分隔；不需要可直接回车）：${C_RESET}")" DIRECT_DOMAINS_RAW

DIRECT_DOMAINS_CSV="$(python3 - "${DIRECT_DOMAINS_RAW}" <<'PY'
import sys,re
raw=sys.argv[1].strip()
out=[]
for part in raw.split(",") if raw else []:
    d=part.strip().lower()
    d=re.sub(r"^[a-z]+://","",d)
    d=d.split("/",1)[0].split(":",1)[0].strip(".")
    if not d:
        continue
    if not re.fullmatch(r"[a-z0-9.-]+",d):
        print("__ERROR__:"+d)
        raise SystemExit
    out.append(d)
print(",".join(sorted(set(out))))
PY
)"

if [[ "${DIRECT_DOMAINS_CSV}" == __ERROR__:* ]]; then
  fail "域名格式不正确：${DIRECT_DOMAINS_CSV#__ERROR__:}"
fi

show_progress "正在检查已配置线路和可用端口..."


VLESS_PORT="$(python3 - <<'PY'
import json, socket

conf="/usr/local/etc/xray/config.json"
used=set()

# 同时检查 Xray 配置中已经占用的端口，即使服务暂时没监听也不会重复分配
try:
    with open(conf,"r",encoding="utf-8") as f:
        c=json.load(f)
    for ib in c.get("inbounds",[]):
        p=ib.get("port")
        if isinstance(p,int):
            used.add(p)
except Exception:
    pass

for p in range(8500,9000):
    if p in used:
        continue
    sock=socket.socket()
    try:
        sock.bind(("0.0.0.0",p))
        print(p)
        break
    except OSError:
        pass
    finally:
        sock.close()
PY
)"

LOCAL_PORT="$(python3 - <<'PY'
import glob, re, socket

used=set()

# 检查已有 fallback 脚本里记录的 LISTEN_PORT
for fn in glob.glob("/usr/local/bin/socks-fallback-*.py"):
    try:
        txt=open(fn,"r",encoding="utf-8").read()
        m=re.search(r"^LISTEN_PORT\s*=\s*(\d+)",txt,re.M)
        if m:
            used.add(int(m.group(1)))
    except Exception:
        pass

for p in range(1100,1600):
    if p in used:
        continue
    sock=socket.socket()
    try:
        sock.bind(("127.0.0.1",p))
        print(p)
        break
    except OSError:
        pass
    finally:
        sock.close()
PY
)"

[[ -n "${VLESS_PORT}" ]] || fail "找不到可用 VLESS 端口。"
[[ -n "${LOCAL_PORT}" ]] || fail "找不到可用服务器内部备用端口。"

UUID="$("${XRAY_BIN}" uuid | tail -n 1 | tr -d '\r\n')"
[[ "${UUID}" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "自动生成 UUID 失败。"

say "${C_BLUE}已自动生成 VLESS 参数：${C_RESET}"
say "  VLESS 端口：${C_MAGENTA}${VLESS_PORT}${C_RESET}"
say "  UUID：${C_MAGENTA}${UUID}${C_RESET}"
say "  服务器内部备用端口：${C_MAGENTA}${LOCAL_PORT}${C_RESET}"
say "${C_GREEN}端口防重复检查：已通过（同时检查运行状态和现有配置）${C_RESET}"
echo

BACKUP="${XRAY_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
cp "${XRAY_CONF}" "${BACKUP}"
say "${C_BLUE}已备份当前 Xray 配置：${BACKUP}${C_RESET}"

FB_SCRIPT="/usr/local/bin/socks-fallback-${TAG}.py"
FB_SERVICE="/etc/systemd/system/socks-fallback-${TAG}.service"

show_progress "正在创建动态IP自动备用服务..."

python3 - "${FB_SCRIPT}" "${LOCAL_PORT}" "${UP_HOST}" "${UP_PORT}" "${UP_USER}" "${UP_PASS}" <<'PY'
import sys
from pathlib import Path

out, local_port, host, port, user, password = sys.argv[1:]

template = r'''#!/usr/bin/env python3
import asyncio
import ipaddress
import struct

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = __LOCAL_PORT__
UP_HOST = __UP_HOST__
UP_PORT = __UP_PORT__
UP_USER = __UP_USER__
UP_PASS = __UP_PASS__
TIMEOUT = 8

async def read_exact(reader, n):
    return await asyncio.wait_for(reader.readexactly(n), TIMEOUT)

async def upstream_connect(host, port):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(UP_HOST, UP_PORT), TIMEOUT)

    writer.write(b"\x05\x01\x02")
    await writer.drain()
    if await read_exact(reader, 2) != b"\x05\x02":
        raise Exception("上游不接受用户名密码认证")

    ub = UP_USER.encode()
    pb = UP_PASS.encode()
    if len(ub) > 255 or len(pb) > 255:
        raise Exception("用户名或密码过长")

    writer.write(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
    await writer.drain()
    if await read_exact(reader, 2) != b"\x01\x00":
        raise Exception("上游用户名或密码认证失败")

    try:
        ip = ipaddress.ip_address(host)
        addr = (b"\x01" + ip.packed) if ip.version == 4 else (b"\x04" + ip.packed)
    except ValueError:
        hb = host.encode()
        if len(hb) > 255:
            raise Exception("目标域名过长")
        addr = b"\x03" + bytes([len(hb)]) + hb

    writer.write(b"\x05\x01\x00" + addr + struct.pack("!H", port))
    await writer.drain()

    head = await read_exact(reader, 4)
    if head[1] != 0:
        raise Exception(f"上游 SOCKS5 拒绝请求，代码={head[1]}")

    atyp = head[3]
    if atyp == 1:
        await read_exact(reader, 4)
    elif atyp == 3:
        ln = (await read_exact(reader, 1))[0]
        await read_exact(reader, ln)
    elif atyp == 4:
        await read_exact(reader, 16)
    else:
        raise Exception("上游返回未知地址类型")

    await read_exact(reader, 2)
    return reader, writer

async def direct_connect(host, port):
    return await asyncio.wait_for(asyncio.open_connection(host, port), TIMEOUT)

async def pipe(reader, writer):
    """
    单向转发数据。
    这里不能在任意一个方向读到 EOF 后立刻 close 对端 writer，
    否则另一方向尚未发送完的数据可能被提前截断，表现为网页偶发
    ERR_CONNECTION_CLOSED / 节点偶发 -1ms。
    """
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
        # 尽量做半关闭，让另一方向还有机会把剩余数据传完。
        try:
            if writer.can_write_eof():
                writer.write_eof()
                await writer.drain()
        except Exception:
            pass
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    except Exception as e:
        print(f"[relay] {type(e).__name__}: {e}", flush=True)

async def handle(client_reader, client_writer):
    remote_writer = None
    try:
        ver, nmethods = await read_exact(client_reader, 2)
        if ver != 5:
            raise Exception("客户端不是 SOCKS5")
        await read_exact(client_reader, nmethods)

        client_writer.write(b"\x05\x00")
        await client_writer.drain()

        ver, cmd, _, atyp = await read_exact(client_reader, 4)
        if ver != 5 or cmd != 1:
            raise Exception("只支持 SOCKS5 CONNECT")

        if atyp == 1:
            host = str(ipaddress.ip_address(await read_exact(client_reader, 4)))
        elif atyp == 3:
            ln = (await read_exact(client_reader, 1))[0]
            host = (await read_exact(client_reader, ln)).decode()
        elif atyp == 4:
            host = str(ipaddress.ip_address(await read_exact(client_reader, 16)))
        else:
            raise Exception("未知地址类型")

        port = struct.unpack("!H", await read_exact(client_reader, 2))[0]

        try:
            remote_reader, remote_writer = await upstream_connect(host, port)
            route = "动态IP"
        except Exception as e:
            print(f"[自动备用] {host}:{port} 动态IP失败: {e} -> VPS DIRECT", flush=True)
            remote_reader, remote_writer = await direct_connect(host, port)
            route = "VPS"

        print(f"[{route}] {host}:{port}", flush=True)
        client_writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await client_writer.drain()

        await asyncio.gather(
            pipe(client_reader, remote_writer),
            pipe(remote_reader, client_writer),
            return_exceptions=True
        )
    except Exception as e:
        print(f"[连接失败] {type(e).__name__}: {e}", flush=True)
        try:
            client_writer.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            await client_writer.drain()
        except Exception:
            pass
    finally:
        if remote_writer:
            try:
                remote_writer.close()
                await remote_writer.wait_closed()
            except Exception:
                pass
        try:
            client_writer.close()
            await client_writer.wait_closed()
        except Exception:
            pass

async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    print(f"fallback listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    async with server:
        await server.serve_forever()

asyncio.run(main())
'''

template = template.replace("__LOCAL_PORT__", str(int(local_port)))
template = template.replace("__UP_HOST__", repr(host))
template = template.replace("__UP_PORT__", str(int(port)))
template = template.replace("__UP_USER__", repr(user))
template = template.replace("__UP_PASS__", repr(password))

Path(out).write_text(template, encoding="utf-8")
PY

chmod 700 "${FB_SCRIPT}"

cat > "${FB_SERVICE}" <<EOF
[Unit]
Description=Dynamic SOCKS5 Fallback ${TAG}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${FB_SCRIPT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "socks-fallback-${TAG}" >/dev/null

show_progress "正在写入 Xray VLESS 配置..."

python3 - "${TAG}" "${VLESS_PORT}" "${LOCAL_PORT}" "${UUID}" "${DIRECT_DOMAINS_CSV}" <<'PY'
import json
import sys

path = "/usr/local/etc/xray/config.json"
tag = sys.argv[1]
vless_port = int(sys.argv[2])
local_port = int(sys.argv[3])
uuid = sys.argv[4]
direct_domains = [x.strip() for x in sys.argv[5].split(",") if x.strip()]

with open(path, "r", encoding="utf-8") as f:
    c = json.load(f)

in_tag = f"vless-{tag}"
out_tag = f"fallback-{tag}"

c.setdefault("inbounds", []).append({
    "tag": in_tag,
    "listen": "0.0.0.0",
    "port": vless_port,
    "protocol": "vless",
    "settings": {
        "clients": [{"id": uuid}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "none"
    }
})

outbounds = c.setdefault("outbounds", [])
if not any(x.get("tag") == "direct" for x in outbounds):
    outbounds.append({
        "tag": "direct",
        "protocol": "freedom",
        "settings": {}
    })

outbounds.append({
    "tag": out_tag,
    "protocol": "socks",
    "settings": {
        "servers": [{
            "address": "127.0.0.1",
            "port": local_port
        }]
    }
})

routing = c.setdefault("routing", {"domainStrategy": "AsIs", "rules": []})
rules = routing.setdefault("rules", [])

# 仅对当前这条 VLESS 线路生效：指定普通域名固定走 VPS DIRECT
if direct_domains:
    rules.insert(0, {
        "type": "field",
        "inboundTag": [in_tag],
        "domain": [f"full:{d}" for d in direct_domains],
        "outboundTag": "direct"
    })

udp_index = 1 if direct_domains else 0
rules.insert(udp_index, {
    "type": "field",
    "inboundTag": [in_tag],
    "network": "udp",
    "outboundTag": "direct"
})

tcp_index = 2 if direct_domains else 1
rules.insert(tcp_index, {
    "type": "field",
    "inboundTag": [in_tag],
    "network": "tcp",
    "outboundTag": out_tag
})

with open(path, "w", encoding="utf-8") as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
PY

show_progress "正在检查 Xray 配置..."

TEST_LOG="/tmp/xray-auto-test.log"

if ! "${XRAY_BIN}" run -test -config "${XRAY_CONF}" >"${TEST_LOG}" 2>&1; then
  say "${C_RED}${C_BOLD}Xray 配置检查失败，正在自动恢复。${C_RESET}"
  cp "${BACKUP}" "${XRAY_CONF}"
  systemctl disable --now "socks-fallback-${TAG}" >/dev/null 2>&1 || true
  rm -f "${FB_SERVICE}" "${FB_SCRIPT}"
  systemctl daemon-reload
  cat "${TEST_LOG}"
  exit 1
fi

systemctl restart xray

show_progress "正在检测动态出口..."

EXIT_IP="$(
  curl -4 -s \
    --socks5-hostname "127.0.0.1:${LOCAL_PORT}" \
    --connect-timeout 12 \
    --max-time 20 \
    https://api.ipify.org || true
)"

SERVER_IP="$(
  curl -4 -s \
    --connect-timeout 8 \
    --max-time 12 \
    https://api.ipify.org || true
)"

[[ -n "${SERVER_IP}" ]] || SERVER_IP="<服务器公网IP>"
[[ -n "${EXIT_IP}" ]] || EXIT_IP="检测失败"

DISPLAY_NAME_ENCODED="$(python3 - "${DISPLAY_NAME}" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
)"
VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=none&type=tcp#${DISPLAY_NAME_ENCODED}"

show_progress "正在生成 VLESS 导入链接和二维码..."

if ! command -v qrencode >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq qrencode >/dev/null 2>&1 || true
fi

QR_FILE="/root/vless-${TAG}-${VLESS_PORT}.png"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "${QR_FILE}" -s 8 -m 2 "${VLESS_URL}"
fi

# 判断动态IP是否真正生效
DYNAMIC_OK=0
if [[ -n "${EXIT_IP}" && "${EXIT_IP}" != "检测失败" && "${EXIT_IP}" != "${SERVER_IP}" ]]; then
  DYNAMIC_OK=1
fi

say ""
if [[ "${DYNAMIC_OK}" -eq 1 ]]; then
  say "${C_GREEN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
  say "${C_GREEN}${C_BOLD}              ✓ 动态IP线路配置成功${C_RESET}"
  say "${C_GREEN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
else
  say "${C_YELLOW}${C_BOLD}════════════════════════════════════════════${C_RESET}"
  say "${C_YELLOW}${C_BOLD}        ⚠ 当前正在使用 VPS 备用出口${C_RESET}"
  say "${C_YELLOW}${C_BOLD}════════════════════════════════════════════${C_RESET}"
  say "${C_YELLOW}动态IP没有成功生效，请检查动态IP用户名、密码、服务器地址和端口。${C_RESET}"
fi
say "线路备注：${C_CYAN}${DISPLAY_NAME}${C_RESET}"
say "服务器内部线路ID：${C_BLUE}${TAG}${C_RESET}"
say "VPS服务器：${C_CYAN}${SERVER_IP}${C_RESET}"
say "VLESS端口：${C_MAGENTA}${VLESS_PORT}${C_RESET}"
say "UUID：${C_MAGENTA}${UUID}${C_RESET}"
say "Network：${C_CYAN}tcp${C_RESET}"
say "Security：${C_CYAN}none${C_RESET}"
say "动态出口IP：${C_CYAN}${EXIT_IP}${C_RESET}"
if [[ "${DYNAMIC_OK}" -eq 1 ]]; then
  say "当前出口：${C_GREEN}动态IP${C_RESET}"
else
  say "当前出口：${C_YELLOW}VPS备用${C_RESET}"
fi
say "自动备用：${C_GREEN}已启用${C_RESET}"
if [[ -n "${DIRECT_DOMAINS_CSV}" ]]; then
  say "固定走 VPS 的域名：${C_MAGENTA}${DIRECT_DOMAINS_CSV}${C_RESET}"
else
  say "固定走 VPS 的域名：${C_BLUE}未设置${C_RESET}"
fi
echo

say "${C_YELLOW}${C_BOLD}手机直接导入的 VLESS 链接：${C_RESET}"
say "${C_CYAN}${VLESS_URL}${C_RESET}"
echo

if command -v qrencode >/dev/null 2>&1; then
  say "${C_YELLOW}${C_BOLD}手机可直接扫描下面二维码：${C_RESET}"
  qrencode -t ANSIUTF8 "${VLESS_URL}" || true
  echo
fi

if [[ -f "${QR_FILE}" ]]; then
  say "二维码文件：${C_MAGENTA}${QR_FILE}${C_RESET}"
else
  say "${C_YELLOW}二维码未生成，但 VLESS 链接已经可以直接导入。${C_RESET}"
fi

echo
say "Xray 状态：${C_GREEN}$(systemctl is-active xray)${C_RESET}"
say "线路服务：${C_GREEN}$(systemctl is-active "socks-fallback-${TAG}")${C_RESET}"
say "${C_BLUE}规则：指定普通域名固定走 VPS；其他 TCP 优先动态IP，SOCKS5 建连失败/拒绝/超时则走 VPS；UDP 走 VPS。${C_RESET}"
say "${C_GREEN}稳定性修复：已启用双向连接安全收尾，避免半连接被提前关闭。${C_RESET}"
say "${C_BLUE}备份文件：${BACKUP}${C_RESET}"
