#!/usr/bin/env bash
# 用 abuild 在 armv7 chroot 里编 packages/<pkg>，产物落到 out/packages/。
# 用法: sudo bash scripts/build-package.sh [pkg|umount]
set -euo pipefail

PKG=adbd
MODE=build
if [ -n "${1:-}" ]; then
	if [ "$1" = umount ]; then MODE=umount; else PKG=$1; fi
fi

SRC_DIR=${SRC_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
WORK_DIR=${WORK_DIR:-$SRC_DIR/work}
OUT_DIR=${OUT_DIR:-$SRC_DIR/out}
PKG_DIR=${PKG_DIR:-$SRC_DIR/packages/$PKG}
BUILD_ROOT=${BUILD_ROOT:-$WORK_DIR/pkgbuild}
OUT_PACKAGES=${OUT_PACKAGES:-$OUT_DIR/packages}
TARBALL=${TARBALL:-}
[ -n "$TARBALL" ] || TARBALL=$(ls -1 "$SRC_DIR"/alpine-minirootfs-*-armv7.tar.gz 2>/dev/null | sort -V | tail -1 || true)
REPOS_FILE=${REPOS_FILE:-$SRC_DIR/config/base/repositories}
APK_BRANCH=${APK_BRANCH:-latest-stable}
APK_CACHE=${APK_CACHE:-$WORK_DIR/apkcache}
JOBS=${JOBS:-6}

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

write_repos() {
	mkdir -p "$(dirname "$1")"
	sed "s|@BRANCH@|$APK_BRANCH|g" "$REPOS_FILE" > "$1"
}

umount_all() {
	local m
	for m in var/cache/apk dev/pts dev run proc sys; do
		umount -l "$BUILD_ROOT/$m" 2>/dev/null || true
	done
}

mount_dev() {
	local d=$1 spec n maj min mode
	mount -t tmpfs -o mode=755,size=1m tmpfs "$d/dev"
	for spec in null:1:3:666 zero:1:5:666 full:1:7:666 random:1:8:666 \
	            urandom:1:9:666 tty:5:0:666 console:5:1:600 ptmx:5:2:666; do
		IFS=: read -r n maj min mode <<<"$spec"
		mknod -m "$mode" "$d/dev/$n" c "$maj" "$min"
	done
	mkdir -p "$d/dev/pts"
	mount -t devpts devpts "$d/dev/pts"
	ln -sf /proc/self/fd "$d/dev/fd"
	ln -sf /proc/self/fd/0 "$d/dev/stdin"
	ln -sf /proc/self/fd/1 "$d/dev/stdout"
	ln -sf /proc/self/fd/2 "$d/dev/stderr"
}

mount_in() {
	umount_all
	mount -t proc  proc  "$BUILD_ROOT/proc"
	mount -t sysfs sysfs "$BUILD_ROOT/sys"
	mount_dev "$BUILD_ROOT"
	mkdir -p "$APK_CACHE" "$BUILD_ROOT/var/cache/apk"
	mount --bind "$APK_CACHE" "$BUILD_ROOT/var/cache/apk"
}

check_unmounted() {
	local left
	left=$(awk -v d="$BUILD_ROOT" '$2 == d || index($2, d "/") == 1 { print $2 }' /proc/mounts)
	[ -z "$left" ] || die "$BUILD_ROOT 下面还挂着东西，不敢删：$left"
}

run() { chroot "$BUILD_ROOT" /bin/sh -c "$1"; }
trap umount_all EXIT

setup_chroot() {
	log "准备 chroot: $BUILD_ROOT"
	umount_all
	check_unmounted
	rm -rf "$BUILD_ROOT"
	mkdir -p "$BUILD_ROOT"
	tar -xzf "$TARBALL" -C "$BUILD_ROOT"

	write_repos "$BUILD_ROOT/etc/apk/repositories"
	cp /etc/resolv.conf "$BUILD_ROOT/etc/resolv.conf"

	mount_in
	run 'apk update && apk upgrade --available'
	run 'apk add abuild fakeroot'
	run 'mkdir -p /build /packages'
}

[ "$(id -u)" -eq 0 ] || die '需要 root（make 会用 sudo 调）'

if [ "$MODE" = umount ]; then
	for _ in 1 2 3; do umount_all; sleep 0.2; done
	check_unmounted
	exit 0
fi

[ -f "$PKG_DIR/APKBUILD" ] || die "缺 $PKG_DIR/APKBUILD"
[ -f "$TARBALL" ] || die "缺少 $TARBALL（make fetch 会下载）"
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || die '没有 armv7 binfmt（qemu-user-binfmt）'

if [ -x "$BUILD_ROOT/sbin/apk" ]; then
	log "复用 $BUILD_ROOT"
	write_repos "$BUILD_ROOT/etc/apk/repositories"
	mount_in
else
	setup_chroot
fi

# abuild 把 APKBUILD 的上一层当仓库名，这里固定为 local
log "编 $PKG"
mkdir -p "$BUILD_ROOT/build/local"
rm -rf "$BUILD_ROOT/build/local/$PKG"
cp -a "$PKG_DIR" "$BUILD_ROOT/build/local/$PKG"
run "chmod -R u+w /build/local/$PKG"

# 签名 key 只生成一次；公钥必须进 /etc/apk/keys，否则建索引报 UNTRUSTED。
# abuild 的配置路径 stable/edge 不一样，两个都认；只读取存在的文件，避免 pipefail 误判
find_privkey() {
	local c
	for c in "$BUILD_ROOT/root/.abuild/abuild.conf" "$BUILD_ROOT/root/.config/abuild/abuild.conf"; do
		[ -f "$c" ] || continue
		sed -n 's/^PACKAGER_PRIVKEY="\(.*\)"/\1/p' "$c"
	done | tail -1 || true
}
privkey=$(find_privkey)
[ -n "$privkey" ] || { run 'abuild-keygen -n -a >/dev/null 2>&1'; privkey=$(find_privkey); }
[ -n "$privkey" ] && [ -f "$BUILD_ROOT$privkey.pub" ] || die "abuild 密钥没配好（$privkey）"
pubkey=$(basename "$privkey").pub
install -m 0644 "$BUILD_ROOT$privkey.pub" "$BUILD_ROOT/etc/apk/keys/"

chroot "$BUILD_ROOT" /bin/sh -c \
	"cd /build/local/$PKG && REPODEST=/packages JOBS=$JOBS abuild -F -r"

log "收集产物 -> $OUT_PACKAGES"
mkdir -p "$OUT_PACKAGES"
(cd "$BUILD_ROOT/packages" && find . -type f) | while read -r f; do
	install -D -m 0644 "$BUILD_ROOT/packages/$f" "$OUT_PACKAGES/$f"
done
mkdir -p "$OUT_PACKAGES/keys"
[ -n "$pubkey" ] && install -m 0644 "$BUILD_ROOT$privkey.pub" "$OUT_PACKAGES/keys/"
[ -n "${SUDO_UID:-}" ] && chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT_PACKAGES"
umount_all
log "完成: $(cd "$OUT_PACKAGES" && find . -name '*.apk' | tr '\n' ' ')"
