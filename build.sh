#!/bin/bash

set -eo pipefail

source "$( dirname "${BASH_SOURCE[0]}" )/_env.sh"

if [[ -z "$DEVKITPRO" ]]; then
	echo "DEVKITPRO env var missing" 1>&2
	exit 1
fi

if [[ -z "$JOBS" ]]; then
	if command -v nproc >/dev/null 2>&1; then
		JOBS="$(nproc --all)"
	else
		JOBS="$(sysctl -n hw.ncpu)"
	fi
fi

echo "** env **"

if [[ -f "$DEVKITPRO/switchvars.sh" ]]; then
	source "$DEVKITPRO/switchvars.sh"
else
	source "$ROOT_DIR/switchvars.sh"
fi
# LOCAL_PORTLIBS (set by the fallback switchvars.sh) carries the portlibs this
# machine is missing; PORTLIBS_PREFIX keeps the system ones (curl, mbedtls, z).
PORTLIBS_INCLUDES=""
if [[ -n "${LOCAL_PORTLIBS:-}" ]]; then
	PORTLIBS_INCLUDES="-I$LOCAL_PORTLIBS/include -I$LOCAL_PORTLIBS/include/freetype2 -I$LOCAL_PORTLIBS/include/SDL2"
fi
CFLAGS="$CFLAGS -g $PORTLIBS_INCLUDES -I$PORTLIBS_PREFIX/include -I$PORTLIBS_PREFIX/include/freetype2 -I$PORTLIBS_PREFIX/include/SDL2 -D__SWITCH__ -I$DEVKITPRO/libnx/include"
export SDL2DIR="$PORTLIBS_PREFIX"

function switch_cmake() {
	cmake -G"Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$DEVKITPRO/cmake/Switch.cmake" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
		-DCMAKE_CXX_FLAGS="$CFLAGS" \
		"$@"
}

echo "** luajit **"

mkdir -p "$BUILD_DIR/luajit"
cp -Rfp "$ROOT_DIR/repo/luajit/." "$BUILD_DIR/luajit"
make -C "$BUILD_DIR/luajit/src" -j$JOBS libluajit.a \
	CROSS="$TOOL_PREFIX" CFLAGS="" LDFLAGS="" LIBS="" TARGET_SYS="SWITCH" BUILDMODE="static" \
	XCFLAGS="-DLJ_TARGET_CONSOLE=1 -DLUAJIT_DISABLE_JIT -DLUAJIT_USE_SYSMALLOC" \
	TARGET_CFLAGS="$CFLAGS" TARGET_LDFLAGS="$LDFLAGS" TARGET_LIBS="$LIBS"

echo "** LÖVE **"

mkdir -p "$BUILD_DIR/love"
cd "$BUILD_DIR/love"
PORTLIBS_FOR_CMAKE="${LOCAL_PORTLIBS:-$PORTLIBS_PREFIX}"
switch_cmake \
	-DPHYSFS_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libphysfs.a" \
	-DOPENAL_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libopenal.a" \
	-DOPENAL_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include/AL" \
	-DFREETYPE_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libfreetype.a;$PORTLIBS_FOR_CMAKE/lib/libharfbuzz.a" \
	-DFREETYPE_INCLUDE_DIRS="$PORTLIBS_FOR_CMAKE/include/freetype2" \
	-DMODPLUG_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libmodplug.a" \
	-DMODPLUG_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include" \
	-DSDL2_DIR="$PORTLIBS_FOR_CMAKE/lib/cmake/SDL2" \
	-DTHEORA_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libtheoradec.a" \
	-DTHEORADEC_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libtheoradec.a" \
	-DTHEORA_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include" \
	-DVORBIS_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libvorbisidec.a" \
	-DVORBISFILE_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libvorbisidec.a" \
	-DVORBIS_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include" \
	-DOGG_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libogg.a" \
	-DOGG_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include" \
	-DMPG123_LIBRARY="$PORTLIBS_FOR_CMAKE/lib/libmpg123.a" \
	-DMPG123_INCLUDE_DIR="$PORTLIBS_FOR_CMAKE/include" \
	-DZLIB_LIBRARY="$PORTLIBS_PREFIX/lib/libz.a" \
	-DZLIB_INCLUDE_DIR="$PORTLIBS_PREFIX/include" \
	-DLUAJIT_LIBRARY="$BUILD_DIR/luajit/src/libluajit.a" \
	-DLUAJIT_INCLUDE_DIR="$ROOT_DIR/repo/luajit/src" \
	"$ROOT_DIR/repo/love"

make -j$JOBS

echo "** CA bundle **"

ROMFS_DIR="$ROOT_DIR/romfs"
mkdir -p "$ROMFS_DIR"
if [[ ! -s "$ROMFS_DIR/cacert.pem" ]]; then
	echo "Fetching https://curl.se/ca/cacert.pem"
	curl -fsSL -o "$ROMFS_DIR/cacert.pem" "https://curl.se/ca/cacert.pem"
fi
grep -q "BEGIN CERTIFICATE" "$ROMFS_DIR/cacert.pem" || { echo "cacert.pem does not look like a PEM bundle" 1>&2; exit 1; }

echo "** NRO **"

mkdir -p "$DIST_DIR"

cp -vf "$BUILD_DIR/love/love.elf" "$DIST_DIR/$APP_NAME.elf"
"$DEVKITPRO/tools/bin/nacptool" --create "$APP_TITLE" "$APP_AUTHOR" "$APP_VERSION" "$DIST_DIR/$APP_NAME.nacp"
"$DEVKITPRO/tools/bin/elf2nro" "$DIST_DIR/$APP_NAME.elf" "$DIST_DIR/$APP_NAME.nro" --icon="$APP_ICON" --nacp="$DIST_DIR/$APP_NAME.nacp" --romfsdir="$ROMFS_DIR"
echo "Built $DIST_DIR/$APP_NAME.nro"
