#!/usr/bin/env bash
set -euo pipefail

# 彩色终端
C_BLUE="\033[94m"; C_CYAN="\033[96m"; C_YELLOW="\033[93m"
C_GREEN="\033[92m"; C_RED="\033[91m"; C_MAGENTA="\033[95m"
C_BOLD="\033[1m"; C_RESET="\033[0m"

# 终端加载进度条
show_progress() {
  local title="$1"
  local i
  printf "\033[96m%s\033[0m\n" "$title"
  for i in 10 20 30 40 50 60 70 80 90 100; do
    local filled=$((i/5))
    local empty=$((20-filled))
    printf "\r\033[92m["
    printf "%${filled}s" "" | tr " " "█"
    printf "%${empty}s" "" | tr " " "░"
    printf "] %3d%%\033[0m" "$i"
    sleep 0.08
  done
  printf "\n"
}

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行。"
  exit 1
fi

[[ -x "$XRAY_BIN" ]] || { echo "找不到 $XRAY_BIN"; exit 1; }
[[ -f "$XRAY_CONF" ]] || { echo "找不到 $XRAY_CONF"; exit 1; }

echo "========== Xray 多国家动态出口一键新增 =========="
read -rp "国家/线路标签（例如 jp、us、sg）: " TAG
TAG="$(echo "$TAG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
[[ -n "$TAG" ]] || { echo "标签不能为空"; exit 1; }

# 自动寻找空闲 VLESS 公网端口（8500-8999）
VLESS_PORT="$(python3 - <<'PY'
import socket
for p in range(8500,9000):
    s=socket.socket()
    try:
        s.bind(("0.0.0.0",p)); print(p); break
    except OSError:
        pass
    finally:
        s.close()
PY
)"

# 自动寻找空闲 fallback 本地端口（1100-1599）
LOCAL_PORT="$(python3 - <<'PY'
import socket
for p in range(1100,1600):
    s=socket.socket()
    try:
        s.bind(("127.0.0.1",p)); print(p); break
    except OSError:
        pass
    finally:
        s.close()
PY
)"

# 每条线路自动生成独立 UUID
UUID_INPUT="$("$XRAY_BIN" uuid | tail -n1 | tr -d '\r\n')"

show_progress "正在生成 VLESS 配置参数..."
echo -e "\033[94m已自动生成 VLESS 参数：\033[0m"
echo -e "  VLESS端口：\033[95m${VLESS_PORT}\033[0m"
echo -e "  内部备用端口：\033[95m${LOCAL_PORT}\033[0m"
echo -e "  UUID：\033[95m${UUID_INPUT}\033[0m"
echo
read -rp "上游 服务器地址: " UP_HOST
read -rp "上游 服务器端口: " UP_PORT
read -rp "上游用户名: " UP_USER
read -rp "$(echo -e "${C_YELLOW}【5】动态IP密码（明文显示）：${C_RESET}")" UP_PASS
echo
[[ "$UP_PORT" =~ ^[0-9]+$ ]] || { echo "上游端口格式错误"; exit 1; }

g.json"))
for ib in c.get("inbounds",[]):
    if ib.get("protocol")=="vless":
        clients=ib.get("settings",{}).get("clients",[])
        if clients and clients[0].get("id"):
            print(clients[0]["id"])
            break
PY
)"
fi

[[ -n "$UUID_INPUT" ]] || { echo "没有找到 UUID，请重新运行并手动填写。"; exit 1; }

BACKUP="${XRAY_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
cp "$XRAY_CONF" "$BACKUP"
echo "已备份 Xray 配置：$BACKUP"

FB_SCRIPT="/usr/local/bin/socks-fallback-${TAG}.py"
FB_SERVICE="/etc/systemd/system/socks-fallback-${TAG}.service"

python3 - "$FB_SCRIPT" "$LOCAL_PORT" "$UP_HOST" "$UP_PORT" "$UP_USER" "$UP_PASS" <<'PY'
import sys
from pathlib import Path

out, local_port, host, port, user, password = sys.argv[1:]
template = r'''#!/usr/bin/env python3
import asyncio, ipaddress, struct

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = __LOCAL_PORT__
UP_HOST = __UP_HOST__
UP_PORT = __UP_PORT__
UP_USER = __UP_USER__
UP_PASS = __UP_PASS__
TIMEOUT = 8

async def rex(r,n):
    return await asyncio.wait_for(r.readexactly(n), TIMEOUT)

async def upstream_connect(host, port):
    r,w = await asyncio.wait_for(asyncio.open_connection(UP_HOST,UP_PORT), TIMEOUT)
    w.write(b"\x05\x01\x02"); await w.drain()
    if await rex(r,2) != b"\x05\x02":
        raise Exception("upstream auth method rejected")
    ub=UP_USER.encode(); pb=UP_PASS.encode()
    w.write(b"\x01"+bytes([len(ub)])+ub+bytes([len(pb)])+pb); await w.drain()
    if await rex(r,2) != b"\x01\x00":
        raise Exception("upstream authentication failed")
    try:
        ip=ipaddress.ip_address(host)
        addr=(b"\x01"+ip.packed) if ip.version==4 else (b"\x04"+ip.packed)
    except ValueError:
        hb=host.encode(); addr=b"\x03"+bytes([len(hb)])+hb
    w.write(b"\x05\x01\x00"+addr+struct.pack("!H",port)); await w.drain()
    head=await rex(r,4)
    if head[1] != 0:
        raise Exception(f"upstream SOCKS rejected request: {head[1]}")
    atyp=head[3]
    if atyp==1: await rex(r,4)
    elif atyp==3:
        ln=(await rex(r,1))[0]; await rex(r,ln)
    elif atyp==4: await rex(r,16)
    await rex(r,2)
    return r,w

async def direct_connect(host,port):
    return await asyncio.wait_for(asyncio.open_connection(host,port),TIMEOUT)

async def pipe(r,w):
    try:
        while True:
            d=await r.read(65536)
            if not d: break
            w.write(d); await w.drain()
    except Exception:
        pass
    finally:
        try: w.close()
        except Exception: pass

async def handle(cr,cw):
    rw=None
    try:
        ver,nm=await rex(cr,2)
        if ver!=5: raise Exception("not SOCKS5")
        await rex(cr,nm)
        cw.write(b"\x05\x00"); await cw.drain()

        ver,cmd,rsv,atyp=await rex(cr,4)
        if ver!=5 or cmd!=1:
            cw.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00"); await cw.drain()
            return

        if atyp==1: host=str(ipaddress.ip_address(await rex(cr,4)))
        elif atyp==3:
            ln=(await rex(cr,1))[0]; host=(await rex(cr,ln)).decode()
        elif atyp==4: host=str(ipaddress.ip_address(await rex(cr,16)))
        else: raise Exception("bad address type")
        port=struct.unpack("!H",await rex(cr,2))[0]

        route="UPSTREAM"
        try:
            rr,rw=await upstream_connect(host,port)
        except Exception as e:
            route="DIRECT"
            print(f"[fallback] {host}:{port} upstream failed: {e} -> DIRECT", flush=True)
            rr,rw=await direct_connect(host,port)

        print(f"[{route}] {host}:{port}", flush=True)
        cw.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"); await cw.drain()
        await asyncio.gather(pipe(cr,rw), pipe(rr,cw))
    except Exception:
        try:
            cw.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00"); await cw.drain()
        except Exception:
            pass
    finally:
        try: cw.close()
        except Exception: pass
        if rw:
            try: rw.close()
            except Exception: pass

async def main():
    s=await asyncio.start_server(handle,LISTEN_HOST,LISTEN_PORT)
    print(f"fallback listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    async with s:
        await s.serve_forever()

asyncio.run(main())
'''
template = template.replace("__LOCAL_PORT__", str(int(local_port)))
template = template.replace("__UP_HOST__", repr(host))
template = template.replace("__UP_PORT__", str(int(port)))
template = template.replace("__UP_USER__", repr(user))
template = template.replace("__UP_PASS__", repr(password))
Path(out).write_text(template)
PY

chmod 700 "$FB_SCRIPT"

cat >"$FB_SERVICE" <<EOF
[Unit]
Description=SOCKS5 Fallback ${TAG}
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
systemctl enable --now "socks-fallback-${TAG}"

python3 - "$TAG" "$VLESS_PORT" "$LOCAL_PORT" "$UUID_INPUT" <<'PY'
import json, sys
p="/usr/local/etc/xray/config.json"
tag, vport, lport, uuid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
c=json.load(open(p))

in_tag=f"vless-{tag}"
out_tag=f"fallback-{tag}"

c["inbounds"]=[x for x in c.get("inbounds",[]) if x.get("tag")!=in_tag]
c["outbounds"]=[x for x in c.get("outbounds",[]) if x.get("tag")!=out_tag]

c.setdefault("inbounds",[]).append({
    "tag": in_tag,
    "listen": "0.0.0.0",
    "port": vport,
    "protocol": "vless",
    "settings": {"clients":[{"id":uuid}], "decryption":"none"},
    "streamSettings": {"network":"tcp","security":"none"}
})

c.setdefault("outbounds",[]).append({
    "tag": out_tag,
    "protocol":"socks",
    "settings":{"servers":[{"address":"127.0.0.1","port":lport}]}
})

routing=c.setdefault("routing",{"domainStrategy":"AsIs","rules":[]})
rules=routing.setdefault("rules",[])
rules=[r for r in rules if in_tag not in r.get("inboundTag",[])]

rules.insert(0,{
    "type":"field",
    "inboundTag":[in_tag],
    "network":"udp",
    "outboundTag":"direct"
})
rules.insert(1,{
    "type":"field",
    "inboundTag":[in_tag],
    "network":"tcp",
    "outboundTag":out_tag
})
routing["rules"]=rules

json.dump(c,open(p,"w"),indent=2)
print(f"Added {in_tag} :{vport} -> {out_tag} 127.0.0.1:{lport}")
PY

echo
echo "检查 Xray 配置..."
if ! "$XRAY_BIN" run -test -config "$XRAY_CONF"; then
  echo "配置检查失败，正在恢复..."
  cp "$BACKUP" "$XRAY_CONF"
  systemctl restart xray || true
  exit 1
fi

systemctl restart xray

echo
echo "========== 完成 =========="
echo "国家标签：$TAG"
echo "VLESS 端口：$VLESS_PORT"
echo "UUID：$UUID_INPUT"
echo "Network：tcp"
echo "TLS/Security：none"
echo "本地 fallback：127.0.0.1:$LOCAL_PORT"
echo
echo "fallback 服务状态：$(systemctl is-active "socks-fallback-${TAG}" || true)"
echo "Xray 状态：$(systemctl is-active xray || true)"
echo
echo "提示：请确保云服务器安全组/防火墙已放行 TCP ${VLESS_PORT}"
