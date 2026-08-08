#!/bin/bash
# Syntax-checks every networking translation unit against the Switch
# toolchain + libnx headers, without a full build. Fails fast on the first
# TU that doesn't compile, so porting fixes can iterate in seconds.

set -uo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$ROOT_DIR/_env.sh"

if [[ -f "$DEVKITPRO/switchvars.sh" ]]; then
	source "$DEVKITPRO/switchvars.sh"
else
	source "$ROOT_DIR/switchvars.sh"
fi

LOVE_SRC="$ROOT_DIR/repo/love/src"
LUASOCKET="$LOVE_SRC/libraries/luasocket/libluasocket"
ENET="$LOVE_SRC/libraries/enet"

INCLUDES=(
	-I"$LOVE_SRC"
	-I"$LOVE_SRC/libraries"
	-I"$ENET/libenet/include"
	-I"$ROOT_DIR/repo/luajit/src"
	-I"$PORTLIBS_PREFIX/include"
	-I"$DEVKITPRO/libnx/include"
)
DEFINES=(-D__SWITCH__ -DHAS_SOCKLEN_T)
ARCH=(-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIC -ftls-model=local-exec)

CC="${TOOL_PREFIX}gcc"
CXX="${TOOL_PREFIX}g++"

fail=0
probe_c() {
	if ! "$CC" -fsyntax-only "${ARCH[@]}" "${DEFINES[@]}" "${INCLUDES[@]}" "$1" 2> >(grep -v '^$' >&2); then
		echo "FAIL: $1"
		fail=1
	else
		echo "ok:   $1"
	fi
}
probe_cxx() {
	if ! "$CXX" -fsyntax-only -std=c++11 "${ARCH[@]}" "${DEFINES[@]}" "${INCLUDES[@]}" "$1" 2> >(grep -v '^$' >&2); then
		echo "FAIL: $1"
		fail=1
	else
		echo "ok:   $1"
	fi
}

echo "-- luasocket --"
for f in auxiliar buffer compat except inet io luasocket mime options select tcp timeout udp usocket; do
	probe_c "$LUASOCKET/$f.c"
done

echo "-- enet --"
for f in callbacks compress host list packet peer protocol unix; do
	probe_c "$ENET/libenet/$f.c"
done
probe_cxx "$ENET/enet.cpp"

echo "-- love luasocket glue --"
probe_cxx "$LOVE_SRC/libraries/luasocket/luasocket.cpp"

exit $fail
