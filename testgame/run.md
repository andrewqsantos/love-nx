# love-nx networking acceptance run

The Switch build output is `dist/love.nro`. This directory is the test game.

## Package

```sh
cd "$(dirname "$0")/.."
zip -j -r dist/net-test.love testgame/main.lua
```

## Push and run over nxlink

With the Switch in the homebrew menu's netloader (or nxlink-compatible launcher):

```sh
export DEVKITPRO=/opt/devkitpro
$DEVKITPRO/tools/bin/nxlink -a <SWITCH_IP> dist/love.nro -s dist/net-test.love
```

love-nx loads `romfs:/game.love` first, then `./game.love`, then `./main.lua`
(`src/common/nx.cpp:getLoveInResources`). nxlink's `-s` sends the file as
argv, which the engine uses as the game path. stdout from `print()` comes back
over the nxlink TCP console — every PASS/FAIL line also appears there, so the
screen is a fallback.

Alternative without nxlink: copy `dist/love.nro` to `/switch/love.nro` on the
SD card and `dist/net-test.love` to `/switch/game.love`; launch from hbmenu.
The Lua `print` output is then lost, but the on-screen table remains.

## What each check proves

- `tcp local echo` — LuaSocket TCP on-device (stack proof). Does not need a PC.
- `tcp pc relay` — only runs if you set `PC_TCP_HOST` at the top of `main.lua`.
- `tcp remote relay 7778 (optional)` — public gen1recomp relay. Soft/environment.
- `enet host_create :7777 bind` — empty-host form binds all interfaces.
- `enet LAN round-trip` — same-console via LAN IP (not 127.0.0.1).
- Live host — after checks, the app keeps `:7777` open for a PC peer.

## TCP PC relay

1. On the PC: `python3 testgame/pc_tcp_relay.py 7778`
2. Set `PC_TCP_HOST` in `main.lua` to the PC LAN IP, repackage, push.
3. Expect `PASS tcp pc relay …` and `ack:{"hello":"love-nx"}` in the log.

Preflight the public relay from the PC before blaming the Switch:

```sh
python3 - <<'PY'
import socket
s=socket.create_connection(("147.182.215.255",7778),10)
s.sendall(b'{"hello":"love-nx"}\n')
s.settimeout(10)
print(s.recv(4096))
PY
```

## ENet LAN round-trip (PC peer)

1. Launch the test app on the Switch (live host on `:7777`).
2. Note the printed LAN IP from the UDP check.
3. On the PC: `python3 testgame/pc_enet_peer.py client <switch-ip>`
4. Expect `VERDICT: PASS` on the PC and `enet live:` lines on the Switch.

Requires: `pip install pyenet-dlts` (provides the `enet` module).

## Offline leg

Disable wifi on the Switch, rerun. Every networking check must FAIL with a
printed error. A crash or a hang is a defect.

## Threads

`love.thread + Channel (R5 report-only)` is a sanity probe. Failure is
report-only per scope. The harness logs `getError` / `isRunning` / leftover.
