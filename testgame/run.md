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
$DEVKITPRO/tools/bin/nxlink -a <SWITCH_IP> dist/love.nro -s net-test.love
```

love-nx loads `romfs:/game.love` first, then `./game.love`, then `./main.lua`
(`src/common/nx.cpp:getLoveInResources`). nxlink's `-s` sends the file as
argv, which the engine uses as the game path. stdout from `print()` comes back
over the nxlink TCP console — every PASS/FAIL line also appears there, so the
screen is a fallback.

Alternative without nxlink: copy `dist/love.nro` to `/switch/love.nro` on the
SD card and `dist/net-test.love` to `/switch/game.love`; launch from hbmenu.
The Lua `print` output is then lost, but the on-screen table remains.

## ENet LAN round-trip

1. On the PC: `python3 testgame/pc_enet_peer.py server`
2. Launch the test app on the Switch (its loopback test is separate; for the
   PC link, host a second app or extend main.lua to connect to the PC's IP).

The acceptance criterion in the task ("host on :7777, connect from a PC enet
peer") maps to: the Switch hosts (`enet.host_create(":7777")` is exercised by
the bind check), the PC runs `pc_enet_peer.py client <switch-ip>` against a
Switch-side host. To keep main.lua self-contained it validates bind + loopback;
use pc_enet_peer.py interactively for the cross-device leg.

## Offline leg

Disable wifi on the Switch, rerun. Every check must FAIL with a printed error.
A crash or a hang is a defect.

## Threads

The "love.thread + Channel" check is the R5 sanity probe. If it fails, that is
a report-only finding per scope.
