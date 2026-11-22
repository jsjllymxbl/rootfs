#!/usr/bin/env bash
# 下载 Alpine stable 的 minirootfs；stdout 只输出 tarball 绝对路径。
# ALPINE_RELEASE=3.24.4 可钉死版本；取不到 yaml 时回退到已有的包。
set -euo pipefail

SRC_DIR=${SRC_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
ARCH=${ARCH:-armv7}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
ALPINE_RELEASE=${ALPINE_RELEASE:-}
ALPINE_FLAVOR=${ALPINE_FLAVOR:-minirootfs}

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if [ -n "$ALPINE_RELEASE" ]; then
	file="alpine-$ALPINE_FLAVOR-$ALPINE_RELEASE-$ARCH.tar.gz"
	url="$MIRROR/v${ALPINE_RELEASE%.*}/releases/$ARCH/$file"
	sha512=
else
	if ! yaml=$(curl -fsSL "$MIRROR/latest-stable/releases/$ARCH/latest-releases.yaml"); then
		existing=$(ls -1 "$SRC_DIR"/alpine-$ALPINE_FLAVOR-*-$ARCH.tar.gz 2>/dev/null | sort -V | tail -1 || true)
		[ -n "$existing" ] || die "取不到 latest-releases.yaml（网络？）"
		log "取不到 yaml，用已有的 $(basename "$existing")"
		printf '%s\n' "$existing"
		exit 0
	fi
	line=$(printf '%s\n' "$yaml" | awk -v flavor="alpine-$ALPINE_FLAVOR" '
		function emit() { if (f == flavor) print br, ver, file, sum }
		/^-[[:space:]]*$/ { emit(); f = br = ver = file = sum = ""; next }
		{
			key = $1; sub(/:$/, "", key)
			val = $0; sub(/^[^:]*:[[:space:]]*/, "", val); gsub(/^"|"$/, "", val)
			if (key == "flavor")      f = val
			else if (key == "branch") br = val
			else if (key == "version") ver = val
			else if (key == "file")   file = val
			else if (key == "sha512") sum = val
		}
		END { emit() }
	')
	[ -n "$line" ] || die "yaml 里没有 alpine-$ALPINE_FLAVOR ($ARCH) 的记录"
	read -r branch version file sha512 <<<"$line"
	url="$MIRROR/$branch/releases/$ARCH/$file"
fi

tarball="$SRC_DIR/$file"
if [ -f "$tarball" ]; then
	log "已有 $file"
	printf '%s\n' "$tarball"
	exit 0
fi

log "下载 $file ($url)"
curl -fL -# -o "$tarball.part" "$url" || { rm -f "$tarball.part"; die "下载失败"; }
if [ -n "$sha512" ]; then
	echo "$sha512  $tarball.part" | sha512sum -c --quiet - \
		|| { rm -f "$tarball.part"; die "sha512 不匹配"; }
fi
mv -f "$tarball.part" "$tarball"
log "完成 ${version:-$ALPINE_RELEASE}"
printf '%s\n' "$tarball"
