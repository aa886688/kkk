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
say "${C_YELLOW}动态IP密码为明文输入，输入内容会直接显示。${C_RESET}"
echo

read -rp "$(printf "${C_YELLOW}【1/5】线路名称（例如 us / jp / sg）：${C_RESET}")" TAG
TAG="$(echo "${TAG}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
[[ -n "${TAG}" ]] || fail "线路名称不能为空。"

read -rp "$(printf "${C_YELLOW}【2/5】动态IP服务器地址：${C_RESET}")" UP_HOST
[[ -n "${UP_HOST}" ]] || fail "动态IP服务器地址不能为空。"

read -rp "$(printf "${C_YELLOW}【3/5】动态IP服务器端口：${C_RESET}")" UP_PORT
[[ "${UP_PORT}" =~ ^[0-9]+$ ]] || fail "动态IP服务器端口格式错误。"

read -rp "$(printf "${C_YELLOW}【4/5】动态IP用户名：${C_RESET}")" UP_USER
[[ -n "${UP_USER}" ]] || fail "动态IP用户名不能为空。"

read -rp "$(printf "${C_YELLOW}【5/5】动态IP密码（明文显示）：${C_RESET}")" UP_PASS
[[ -n "${UP_PASS}" ]] || fail "动态IP密码不能为空。"

if python3 - "${TAG}" <<'PY'
import json, sys
tag = "vless-" + sys.argv[1]
with open("/usr/local/etc/xray/config.json", "r", encoding="utf-8") as f:
    c = json.load(f)
raise SystemExit(0 if any(x.get("tag") == tag for x in c.get("inbounds", [])) else 1)
PY
then
  fail "线路 ${TAG} 已经存在。请换一个线路名称。"
fi

show_progress "正在检测可用端口..."

VLESS_PORT="$(python3 - <<'PY'
import socket
for p in range(8500, 9000):
    s = socket.socket()
    try:
        s.bind(("0.0.0.0", p))
        print(p)
        break
    except OSError:
        pass
    finally:
        s.close()
PY
)"

LOCAL_PORT="$(python3 - <<'PY'
import socket
for p in range(1100, 1600):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
        print(p)
        break
    except OSError:
        pass
    finally:
        s.close()
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
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass

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
            pipe(remote_reader, client_writer)
        )
    except Exception:
        try:
            client_writer.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
            await client_writer.drain()
        except Exception:
            pass
    finally:
        try:
            client_writer.close()
        except Exception:
            pass
        if remote_writer:
            try:
                remote_writer.close()
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

python3 - "${TAG}" "${VLESS_PORT}" "${LOCAL_PORT}" "${UUID}" <<'PY'
import json
import sys

path = "/usr/local/etc/xray/config.json"
tag = sys.argv[1]
vless_port = int(sys.argv[2])
local_port = int(sys.argv[3])
uuid = sys.argv[4]

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

rules.insert(0, {
    "type": "field",
    "inboundTag": [in_tag],
    "network": "udp",
    "outboundTag": "direct"
})

rules.insert(1, {
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

VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=none&type=tcp#${TAG}-${VLESS_PORT}"

show_progress "正在生成 VLESS 导入链接和二维码..."

if ! command -v qrencode >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq qrencode >/dev/null 2>&1 || true
fi

QR_FILE="/root/vless-${TAG}-${VLESS_PORT}.png"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -o "${QR_FILE}" -s 8 -m 2 "${VLESS_URL}"
fi

say ""
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
say "${C_GREEN}${C_BOLD}              ✓ 线路配置成功${C_RESET}"
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════${C_RESET}"
say "线路名称：${C_CYAN}${TAG}${C_RESET}"
say "VPS服务器：${C_CYAN}${SERVER_IP}${C_RESET}"
say "VLESS端口：${C_MAGENTA}${VLESS_PORT}${C_RESET}"
say "UUID：${C_MAGENTA}${UUID}${C_RESET}"
say "Network：${C_CYAN}tcp${C_RESET}"
say "Security：${C_CYAN}none${C_RESET}"
say "动态出口IP：${C_CYAN}${EXIT_IP}${C_RESET}"
say "自动备用：${C_GREEN}已启用${C_RESET}"
echo

say "${C_YELLOW}${C_BOLD}手机直接导入的 VLESS 链接：${C_RESET}"
say "${C_CYAN}${VLESS_URL}${C_RESET}"
echo

if [[ -f "${QR_FILE}" ]]; then
  say "二维码文件：${C_MAGENTA}${QR_FILE}${C_RESET}"
else
  say "${C_YELLOW}二维码未生成，但 VLESS 链接已经可以直接导入。${C_RESET}"
fi

echo
say "Xray 状态：${C_GREEN}$(systemctl is-active xray)${C_RESET}"
say "线路服务：${C_GREEN}$(systemctl is-active "socks-fallback-${TAG}")${C_RESET}"
say "${C_BLUE}规则：TCP 优先动态IP；SOCKS5 建连失败/拒绝/超时则走 VPS；UDP 走 VPS。${C_RESET}"
say "${C_BLUE}备份文件：${BACKUP}${C_RESET}"
