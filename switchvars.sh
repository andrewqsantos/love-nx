#!/bin/bash
# Fallback for $DEVKITPRO/switchvars.sh (shipped by the switch-dev package),
# for devkitPro installs where it is absent. Mirrors the upstream values.

export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export TOOL_PREFIX="aarch64-none-elf-"

# The repo-local prefix holds the packages pacman couldn't install on this
# machine (root-owned /opt/devkitpro, and pkg.devkitpro.org 403s this egress).
# It intentionally complements, not shadows, the system prefix: include and
# link paths list both below.
LOCAL_PORTLIBS="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.portlibs/switch"
export PORTLIBS_PREFIX="$DEVKITPRO/portlibs/switch"
export LOCAL_PORTLIBS

export PATH="$DEVKITPRO/devkitA64/bin:$DEVKITPRO/tools/bin:$PORTLIBS_PREFIX/bin:$PATH"

export CFLAGS="-march=armv8-a+crc+crypto -mtune=cortex-a57 -mtp=soft -fPIC -ftls-model=local-exec -ffunction-sections -fdata-sections"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS=""
export LDFLAGS="-L$LOCAL_PORTLIBS/lib -L$PORTLIBS_PREFIX/lib -L$DEVKITPRO/libnx/lib"
export LIBS="-lnx"
