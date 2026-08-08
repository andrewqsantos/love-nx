#!/bin/bash
# User-space dependency install for love-nx on machines where
# /opt/devkitpro is root-owned (dkp pacman unusable). Downloads the official
# switch portlib packages and extracts them into .portlibs/ in this repo.
# switchvars.sh then prefers that prefix over the system one.

set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$ROOT_DIR/_env.sh"

PKG_DIR="$ROOT_DIR/.portlibs/pkg"
PREFIX="$ROOT_DIR/.portlibs/switch"
mkdir -p "$PKG_DIR" "$PREFIX"

PACKAGES=(
	switch-bzip2
	switch-freetype
	switch-harfbuzz
	switch-libdrm
	switch-libjpeg-turbo
	switch-libmodplug
	switch-libogg
	switch-libpng
	switch-libtheora
	switch-libvorbis
	switch-libvorbisidec
	switch-mesa
	switch-mpg123
	switch-openal-soft
	switch-physfs
	switch-sdl2
)

fetch() {
	local name="$1" repo="$2" arch="$3"
	local index="$PKG_DIR/$repo.$arch.db"
	local tmp="$PKG_DIR/.$repo.$arch.db.tmp"

	curl -fsSL -o "$tmp" "https://pkg.devkitpro.org/packages/$repo/$arch/$repo.db"
	mv "$tmp" "$index"

	local filename
	filename=$(tar -xOf "$index" --include="*/desc" -O 2>/dev/null \
		| awk -v pkg="$name" '
			/^%NAME%$/ { getline; found = ($0 == pkg) }
			found && /^%FILENAME%$/ { getline; print; exit }
		')
	if [[ -z "$filename" ]]; then
		echo "package $name not found in $repo/$arch index" 1>&2
		exit 1
	fi

	local out="$PKG_DIR/$filename"
	if [[ ! -f "$out" ]]; then
		echo "downloading $filename"
		curl -fsSL -o "$out" "https://pkg.devkitpro.org/packages/$repo/$arch/$filename"
	fi

	echo "extracting $filename"
	tar -xpf "$out" -C "$PREFIX" --strip-components=3
}

for pkg in "${PACKAGES[@]}"; do
	fetch "$pkg" switch aarch64
done

# Some packages ship devkitA64-host tools; nothing to extract from them here.

echo "Installed ${#PACKAGES[@]} packages into $PREFIX"
