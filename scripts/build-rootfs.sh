#!/usr/bin/env bash
# 分层构建 rootfs：解包 -> 装包 -> overlay/服务/钩子 -> 体检 -> 打包。
# 用法: sudo bash scripts/build-rootfs.sh [build|shell|umount]
set -euo pipefail

MODE=${1:-build}

SRC_DIR=${SRC_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG_DIR=${CONFIG_DIR:-$SRC_DIR/config}
WORK_DIR=${WORK_DIR:-$SRC_DIR/work}
OUT_DIR=${OUT_DIR:-$SRC_DIR/out}
APK_CACHE=${APK_CACHE:-$WORK_DIR/apkcache}
ARCH=${ARCH:-armv7}

LAYERS=${LAYERS:-base}
PROFILE=${PROFILE:-$(printf '%s' "$LAYERS" | tr ' ' '-')}

ROOTFS_DIR=${ROOTFS_DIR:-$WORK_DIR/$PROFILE/rootfs}
TARBALL=${TARBALL:-}
[ -n "$TARBALL" ] || TARBALL=$(ls -1 "$SRC_DIR"/alpine-minirootfs-*-"$ARCH".tar.gz 2>/dev/null | sort -V | tail -1 || true)
REPOS_FILE=${REPOS_FILE:-$CONFIG_DIR/base/repositories}
PACKAGES_OUT=${PACKAGES_OUT:-$OUT_DIR/packages}

PACKAGES=${PACKAGES:-}
ADD_PACKAGES=${ADD_PACKAGES:-}
SERVICES=${SERVICES:-}
ADD_SERVICES=${ADD_SERVICES:-}

LOCAL_PKGS=${LOCAL_PKGS:-}
APK_BRANCH=${APK_BRANCH:-latest-stable}
APK_UPGRADE=${APK_UPGRADE:-yes}
# 用 - 而非 :-：命令行传空表示锁定 root，不能被默认值吃掉
ROOT_PASSWORD=${ROOT_PASSWORD-alpine}
TIMEZONE=${TIMEZONE:-Asia/Shanghai}
HOSTNAME=${HOSTNAME:-aries}
KERNEL_MODULES=${KERNEL_MODULES:-}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
COMPRESS=${COMPRESS:-gzip}
ROOTFS_TAR=${ROOTFS_TAR:-$OUT_DIR/rootfs-$PROFILE.tar.gz}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

fix_owner() {
	[ -n "${SUDO_UID:-}" ] || return 0
	chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$@" 2>/dev/null || true
}

layer_dir() {
	case $1 in
		base) printf '%s/base\n' "$CONFIG_DIR" ;;
		*)    printf '%s/profiles/%s\n' "$CONFIG_DIR" "$1" ;;
	esac
}

validate_layers() {
	local l
	for l in $LAYERS; do
		[ -d "$(layer_dir "$l")" ] || die "层 $l 不存在：$(layer_dir "$l")"
	done
}

read_list() {
	[ -f "$1" ] || return 0
	tr -d '\r' < "$1" | sed -e 's/#.*//' | awk 'NF { print $1 }'
}

collect_list() {
	local l
	for l in $LAYERS; do
		read_list "$(layer_dir "$l")/$1"
	done | awk 'NF && !seen[$0]++'
}

dedupe_words() {
	printf '%s\n' $1 | awk 'NF && !seen[$0]++ { printf "%s ", $0 }'
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
	mount -t proc  proc  "$ROOTFS_DIR/proc"
	mount -t sysfs sysfs "$ROOTFS_DIR/sys"
	mount_dev "$ROOTFS_DIR"
	mkdir -p "$APK_CACHE" "$ROOTFS_DIR/var/cache/apk"
	mount --bind "$APK_CACHE" "$ROOTFS_DIR/var/cache/apk"
	if [ -d "$PACKAGES_OUT" ]; then
		mkdir -p "$ROOTFS_DIR/pkgs"
		mount --bind "$PACKAGES_OUT" "$ROOTFS_DIR/pkgs"
	fi
}

umount_all() {
	local m
	for m in var/cache/apk pkgs dev/pts dev run proc sys; do
		umount -l "$ROOTFS_DIR/$m" 2>/dev/null || true
	done
}
trap umount_all EXIT

check_unmounted() {
	local left
	left=$(awk -v d="$ROOTFS_DIR" '$2 == d || index($2, d "/") == 1 { print $2 }' /proc/mounts)
	[ -z "$left" ] || die "$ROOTFS_DIR 下面还挂着东西，不敢删：$left"
}

run() { chroot "$ROOTFS_DIR" /bin/sh -c "$1"; }

# apk 会在仓库 URL 后加 /<arch>，这里给到 APKINDEX 所在目录
local_repo() {
	local idx
	idx=$(find "$PACKAGES_OUT" -maxdepth 3 -name APKINDEX.tar.gz 2>/dev/null | head -1)
	[ -n "$idx" ] || return 1
	idx=${idx#"$PACKAGES_OUT"/}
	printf '/pkgs/%s\n' "$(dirname "${idx%/APKINDEX.tar.gz}")"
}

apply_overlays() {
	local l od
	OVERLAY_RESOLV_CONF=
	for l in $LAYERS; do
		od=$(layer_dir "$l")/overlay
		[ -d "$od" ] || continue
		log "overlay: $l"
		mkdir -p "$ROOTFS_DIR/lib/firmware" "$ROOTFS_DIR/var/log" "$ROOTFS_DIR/data/local/tmp"
		cp -a --no-preserve=ownership "$od/." "$ROOTFS_DIR/"
		[ -f "$od/etc/resolv.conf" ] && OVERLAY_RESOLV_CONF=$od/etc/resolv.conf
	done
	chmod +x "$ROOTFS_DIR"/etc/init.d/* 2>/dev/null || true
}

apply_services() {
	local entry svc lvl
	for entry in $(dedupe_words "$(collect_list services.list) $ADD_SERVICES"); do
		svc=${entry%%:*}
		lvl=${entry##*:}
		[ "$lvl" = "$entry" ] && lvl=default
		run "rc-update add '$svc' '$lvl'" || warn "rc-update add $svc $lvl 失败"
	done
}

run_hooks() {
	local l hook target=/tmp/.aries-post-install.sh
	for l in $LAYERS; do
		hook=$(layer_dir "$l")/post-install.sh
		[ -f "$hook" ] || continue
		log "post-install: $l"
		install -m 0755 "$hook" "$ROOTFS_DIR$target"
		run "LAYER='$l' PROFILE='$PROFILE' sh $target" \
			|| die "层 $l 的 post-install.sh 失败"
		rm -f "$ROOTFS_DIR$target"
	done
}

build_tree() {
	log "profile=$PROFILE 层: $LAYERS"
	log "解包 $(basename "$TARBALL")"
	umount_all
	check_unmounted
	rm -rf "$ROOTFS_DIR"
	mkdir -p "$ROOTFS_DIR"
	tar -xzf "$TARBALL" -C "$ROOTFS_DIR"

	mkdir -p "$ROOTFS_DIR/etc/apk"
	sed "s|@BRANCH@|$APK_BRANCH|g" "$REPOS_FILE" > "$ROOTFS_DIR/etc/apk/repositories"
	cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

	mount_in
	run 'apk update'

	pkgs=$PACKAGES
	[ -n "${pkgs// /}" ] || pkgs=$(collect_list packages.list)
	pkgs=$(dedupe_words "$pkgs $ADD_PACKAGES")
	if [ -n "${pkgs// /}" ]; then
		log "安装软件包: $pkgs"
		run "apk add --cache-packages $pkgs"
	fi

	# 升级放到装包之后，避免 qemu 下 apk-tools 解硬链接失败
	if [ "$APK_UPGRADE" = yes ]; then
		log "切到 $APK_BRANCH：升级已有的包"
		run 'apk upgrade --available --cache-packages'
	fi

	# 本地包只从 /pkgs 装，不写进 rootfs 的仓库源
	if [ -n "${LOCAL_PKGS// /}" ]; then
		repo=$(local_repo) || die "本地仓库里没有 APKINDEX（先 make package）"
		log "安装本地包: $LOCAL_PKGS（$repo）"
		run "apk add --allow-untrusted --repository $repo $LOCAL_PKGS"
	fi

	apply_overlays
	apply_services

	log "配置: hostname=$HOSTNAME tz=$TIMEZONE"
	run "echo '$HOSTNAME' > /etc/hostname"
	if [ -n "$TIMEZONE" ] && [ -f "$ROOTFS_DIR/usr/share/zoneinfo/$TIMEZONE" ]; then
		run "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime; echo '$TIMEZONE' > /etc/timezone"
	else
		warn "时区 $TIMEZONE 不可用（没装 tzdata？）"
	fi

	if [ -n "$ROOT_PASSWORD" ]; then
		log '设置 root 密码'
		( umask 0077; printf 'root:%s\n' "$ROOT_PASSWORD" > "$ROOTFS_DIR/tmp/.rootpw" )
		run 'chpasswd </tmp/.rootpw; rc=$?; rm -f /tmp/.rootpw; exit $rc' \
			|| die '设置 root 密码失败'
		chown root:shadow "$ROOTFS_DIR/etc/shadow" 2>/dev/null || true
		chmod 0640 "$ROOTFS_DIR/etc/shadow"
	else
		warn 'ROOT_PASSWORD 为空，root 保持锁定（串口 passwd 一个）'
	fi

	if [ -n "$KERNEL_MODULES" ]; then
		log "拷内核模块: $KERNEL_MODULES"
		mkdir -p "$ROOTFS_DIR/lib/modules"
		cp -a --no-preserve=ownership "$KERNEL_MODULES"/. "$ROOTFS_DIR/lib/modules/"
		run 'depmod -a' || warn 'depmod 失败（模块目录结构不对？）'
	fi

	run_hooks
	run 'rm -rf /tmp/*'

	# 卸载后再体检，避免 bind 进来的宿主目录触发属主检查误报
	umount_all
	rmdir "$ROOTFS_DIR/pkgs" 2>/dev/null || true

	for f in "$ROOTFS_DIR"/etc/*.apk-new; do
		[ -e "$f" ] || continue
		warn "删掉残留的 $(basename "$f")"
		rm -f "$f"
	done
	rm -f "$ROOTFS_DIR/etc/resolv.conf"
	if [ -n "$OVERLAY_RESOLV_CONF" ]; then
		install -m 0644 "$OVERLAY_RESOLV_CONF" "$ROOTFS_DIR/etc/resolv.conf"
	fi

	for f in sbin/init bin/busybox etc/inittab etc/apk/repositories; do
		{ [ -e "$ROOTFS_DIR/$f" ] || [ -L "$ROOTFS_DIR/$f" ]; } \
			|| die "rootfs 里缺 $f（解包/装包出问题了）"
	done
	if [ -n "${LOCAL_PKGS// /}" ]; then
		local missing='' p
		for p in $LOCAL_PKGS; do
			grep -qx "P:$p" "$ROOTFS_DIR/lib/apk/db/installed" || missing="$missing $p"
		done
		[ -z "$missing" ] || die "本地包没装上：$missing"
	fi
	[ "$(stat -c %G "$ROOTFS_DIR/etc/shadow" 2>/dev/null)" = shadow ] \
		|| die "/etc/shadow 属组不是 shadow，PAM 密码校验会全部失败"
	bad=$(find "$ROOTFS_DIR" -xdev ! -uid 0 -printf '%u %p\n' 2>/dev/null | head -5)
	[ -z "$bad" ] || die "rootfs 里有非 root 属主的文件：$bad"

	umount_all
	log "rootfs 就绪: $(du -sh "$ROOTFS_DIR" | cut -f1)"
}

pack_tar() {
	mkdir -p "$OUT_DIR"
	fix_owner "$OUT_DIR"
	rm -f "$ROOTFS_TAR"
	# 只归一化时间戳，保留文件属组
	OPTS=(--numeric-owner --mtime="@$SOURCE_DATE_EPOCH")
	tar --sort=name -cf /dev/null -T /dev/null 2>/dev/null && OPTS+=(--sort=name)
	case "$COMPRESS" in
		gzip) OPTS+=(-czf) ;;
		xz)   OPTS+=(-cJf) ;;
		none) OPTS+=(-cf)  ;;
		*)    die "COMPRESS 只能是 gzip/xz/none" ;;
	esac
	tar "${OPTS[@]}" "$ROOTFS_TAR" -C "$ROOTFS_DIR" .
	fix_owner "$ROOTFS_TAR"
	log "打包: $ROOTFS_TAR ($(du -h "$ROOTFS_TAR" | cut -f1))"
}

[ "$(id -u)" -eq 0 ] || die '需要 root（make 用 sudo 调；手动跑加 sudo）'

if [ "$MODE" = umount ]; then
	for _ in 1 2 3; do umount_all; sleep 0.2; done
	check_unmounted
	exit 0
fi

validate_layers
[ -n "$TARBALL" ] && [ -f "$TARBALL" ] || die "缺少 minirootfs（make fetch 会下载，或 ALPINE_RELEASE=... ）"
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] \
	|| die '没有 armv7 binfmt（sudo apt install qemu-user-binfmt）'

if [ "$MODE" = shell ] && [ -x "$ROOTFS_DIR/sbin/apk" ]; then
	log "复用已有的 $ROOTFS_DIR（要重建先 make clean）"
else
	build_tree
	[ "$MODE" = shell ] || pack_tar
fi

if [ "$MODE" = shell ]; then
	log "进 chroot（exit 退出）"
	mount_in
	chroot "$ROOTFS_DIR" /bin/sh -l
fi
