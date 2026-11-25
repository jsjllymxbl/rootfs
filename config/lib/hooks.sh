#!/bin/sh
# 各层 post-install.sh 的共用函数，构建脚本装进 chroot 后用 LAYER_LIB 传进来

DESKTOP_USER=${DESKTOP_USER:-aries}
DESKTOP_PASSWORD=${DESKTOP_PASSWORD:-123456}
# Android /media/0 的属组；initramfs 把它 bind 到 /android_sdcard
MEDIA_RW_GID=1023

# 普通用户：建号、设密码、加入设备相关的组
hook_user() {
	if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
		echo "==> 建用户 $DESKTOP_USER"
		adduser -D -u 1000 -s /bin/sh "$DESKTOP_USER"
	fi

	addgroup -g $MEDIA_RW_GID media_rw >/dev/null 2>&1 || true
	for g in audio video input render plugdev netdev wheel media_rw; do
		grep -q "^$g:" /etc/group || continue
		addgroup "$DESKTOP_USER" "$g" >/dev/null 2>&1 || true
	done

	printf '%s:%s\n' "$DESKTOP_USER" "$DESKTOP_PASSWORD" | chpasswd
}

hook_sudo() {
	install -d -m 0755 /etc/sudoers.d
	printf '%s ALL=(ALL) ALL\n' "$DESKTOP_USER" > "/etc/sudoers.d/$DESKTOP_USER"
	chmod 0440 "/etc/sudoers.d/$DESKTOP_USER"
}

# skel 只带配置文件，实际目录在这里建好
hook_home() {
	local home=/home/$DESKTOP_USER d
	install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" -m 0700 "$home/.config"
	for d in Desktop Downloads Templates Public Documents Music Pictures Videos; do
		install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" -m 0755 "$home/$d"
	done

	# initramfs 在切根前把 Android 内部存储 bind 到 /android_sdcard；
	# 在家目录留一个同名入口，桌面用户通过它直接访问。
	ln -sfn /android_sdcard "$home/android_sdcard"
	chown -h "$DESKTOP_USER:$DESKTOP_USER" "$home/android_sdcard"
}

# overlay 里的 *.gschema.override 在装包后才拷入，需要重新编译
hook_gschemas() {
	glib-compile-schemas /usr/share/glib-2.0/schemas
}

# base 的 tty 触摸键盘会占 /dev/fb0、/dev/tty0，与 Wayland 合成器冲突
hook_no_fb_keyboard() {
	rc-update del buffyboard default 2>/dev/null || true
}

# 自动登录到 $1（wayland-sessions 下的文件名）
hook_session() {
	local session=/usr/share/wayland-sessions/$1
	if [ ! -e "$session" ]; then
		echo "ERROR: 缺 $session" >&2
		return 1
	fi
	tinydm-set-session -f -s "$session"
	printf '%s\n' "$DESKTOP_USER" > /etc/default-user
	echo "==> 会话 $(basename "$session")，用户 $DESKTOP_USER"
}
